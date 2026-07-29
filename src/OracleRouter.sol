// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {
    AggregatorV3Interface,
    IERC8056,
    IOraclePauseSource,
    IMarketStatusSource,
    IStreamAdapter
} from "./interfaces/IExternal.sol";
import {Types} from "./libraries/Types.sol";

/// @title OracleRouter
/// @notice Wraps Chainlink Data Feeds (and optionally Data Streams) with the protocol's guards: session
///         classification, staleness bounds, move caps, corporate-action pauses and sequencer-uptime grace.
///         Every quote in the venue is built from the mid this contract reports; nothing else reads a feed.
/// @dev Prices are returned as quote-token base units per one whole listed token. Chainlink equity feeds
///      already include the ERC-8056 multiplier, so the multiplier is reported but never applied twice.
contract OracleRouter is IOracleRouter {
    using SafeCast for uint256;

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint8 feedDecimals;
        uint8 quoteDecimals;
        uint8 tokenDecimals;
        uint32 stalenessRegular;
        uint32 stalenessExtended;
        uint32 stalenessClosed;
        uint16 moveCapBps;
        /// @dev How recent the previous checkpoint must be for the move cap to mean anything.
        uint32 moveCapWindow;
        uint16 streamDivergenceBps;
        address marketStatusSource;
        address pauseSource;
        address multiplierSource;
        address streamAdapter;
        bool configured;
    }

    struct Checkpoint {
        uint128 lastPrice;
        uint40 lastAt;
        bool paused;
    }

    /// @notice Fallback weekly schedule (UTC seconds of day) used when no market-status source is set.
    struct Schedule {
        uint32 regularOpen;
        uint32 regularClose;
        uint32 extendedOpen;
        uint32 extendedClose;
    }

    uint8 internal constant CL_STATUS_CLOSED = 5;
    uint8 internal constant CL_STATUS_EXTENDED = 2;

    IParamController public immutable params;
    AggregatorV3Interface public sequencerFeed;
    Schedule public schedule;

    mapping(address => FeedConfig) internal _feeds;
    mapping(address => Checkpoint) internal _checkpoints;

    event FeedConfigured(address indexed token, address feed, uint8 feedDecimals, uint8 quoteDecimals);
    event SequencerFeedSet(address feed);
    event ScheduleSet(uint32 regularOpen, uint32 regularClose, uint32 extendedOpen, uint32 extendedClose);
    event MarketPausedEvent(address indexed token, uint256 lastPrice, uint256 newPrice);
    event MarketResumed(address indexed token);
    event Checkpointed(address indexed token, uint256 price);

    error NotGovernance();
    error InvalidFeedConfig();
    error MarketHalted(address token);
    error StreamNotConfigured(address token);
    error StreamDivergence(uint256 feedPrice, uint256 streamPrice);

    modifier onlyGovernance() {
        if (msg.sender != params.owner()) revert NotGovernance();
        _;
    }

    constructor(IParamController params_) {
        params = params_;
        // US equities, UTC, standard time: regular 14:30 to 21:00, extended 09:00 to 01:00 next day.
        schedule = Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 25 hours
        });
    }

    // ---------------------------------------------------------------------
    // Configuration (governance)
    // ---------------------------------------------------------------------

    function configureFeed(
        address token,
        address quoteToken,
        AggregatorV3Interface feed,
        uint32 stalenessRegular,
        uint32 stalenessExtended,
        uint32 stalenessClosed,
        uint16 moveCapBps,
        uint32 moveCapWindow,
        uint16 streamDivergenceBps,
        address marketStatusSource,
        address pauseSource,
        address multiplierSource,
        address streamAdapter
    ) external onlyGovernance {
        // Refuse configurations that silently disable their own guard: a zero staleness bound marks
        // every round stale and halts the market for good, a move cap with a zero window can only ever
        // compare prints inside one block, and a zero divergence tolerance rejects every stream report.
        if (stalenessRegular == 0 || stalenessExtended == 0 || stalenessClosed == 0) revert InvalidFeedConfig();
        if (moveCapBps != 0 && moveCapWindow == 0) revert InvalidFeedConfig();
        if (streamAdapter != address(0) && streamDivergenceBps == 0) revert InvalidFeedConfig();
        uint8 fd = feed.decimals();
        uint8 qd = IERC20Metadata(quoteToken).decimals();
        uint8 td = IERC20Metadata(token).decimals();
        _feeds[token] = FeedConfig({
            feed: feed,
            feedDecimals: fd,
            quoteDecimals: qd,
            tokenDecimals: td,
            stalenessRegular: stalenessRegular,
            stalenessExtended: stalenessExtended,
            stalenessClosed: stalenessClosed,
            moveCapBps: moveCapBps,
            moveCapWindow: moveCapWindow,
            streamDivergenceBps: streamDivergenceBps,
            marketStatusSource: marketStatusSource,
            pauseSource: pauseSource,
            multiplierSource: multiplierSource,
            streamAdapter: streamAdapter,
            configured: true
        });
        emit FeedConfigured(token, address(feed), fd, qd);
    }

    function setSequencerFeed(AggregatorV3Interface feed) external onlyGovernance {
        sequencerFeed = feed;
        emit SequencerFeedSet(address(feed));
    }

    function setSchedule(Schedule calldata s) external onlyGovernance {
        schedule = s;
        emit ScheduleSet(s.regularOpen, s.regularClose, s.extendedOpen, s.extendedClose);
    }

    /// @notice Resume a market that was paused by the move cap or manually. Clears the checkpoint too:
    ///         governance reviewed the print it is resuming into, and comparing the next fill against the
    ///         pre-pause price would re-trip the cap on the very gap that was just approved.
    function resume(address token) external onlyGovernance {
        delete _checkpoints[token];
        emit MarketResumed(token);
    }

    function pause(address token) external onlyGovernance {
        _checkpoints[token].paused = true;
        emit MarketPausedEvent(token, _checkpoints[token].lastPrice, 0);
    }

    // ---------------------------------------------------------------------
    // Quotes
    // ---------------------------------------------------------------------

    function quote(address token) public view override returns (Quote memory q) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);

        (, int256 answer,, uint256 updatedAt,) = c.feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert PriceInvalid(token);

        q.price = _scale(uint256(answer), c.feedDecimals, c.quoteDecimals);
        q.updatedAt = uint64(updatedAt);
        q.session = _session(c);
        q.stale = block.timestamp - updatedAt > _stalenessBound(c, q.session);
        q.paused = _checkpoints[token].paused || _sourcePaused(c);
        q.multiplier = _multiplier(c);
        q.sequencerGrace = _sequencerGrace();
    }

    /// @inheritdoc IOracleRouter
    function refresh(address token) external override returns (Quote memory q) {
        q = quote(token);
        FeedConfig storage c = _feeds[token];
        Checkpoint storage cp = _checkpoints[token];
        // The cap is there to catch a single bad print, so it only means something when the previous
        // checkpoint is recent. Checkpoints are only written here, and on a quiet market that can be days
        // ago, by which time an ordinary drift looks identical to a gap. Outside the window, re-baseline.
        bool comparable = cp.lastPrice != 0 && c.moveCapBps != 0 && block.timestamp - cp.lastAt <= c.moveCapWindow;
        if (comparable) {
            uint256 last = cp.lastPrice;
            uint256 diff = q.price > last ? q.price - last : last - q.price;
            if (diff * Types.BPS / last > c.moveCapBps) {
                cp.paused = true;
                q.paused = true;
                emit MarketPausedEvent(token, last, q.price);
                return q;
            }
        }
        cp.lastPrice = q.price.toUint128();
        cp.lastAt = uint40(block.timestamp);
        emit Checkpointed(token, q.price);
    }

    /// @inheritdoc IOracleRouter
    function verifyStreamReport(address token, bytes calldata report) external override returns (uint256 price) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);
        if (c.streamAdapter == address(0)) revert StreamNotConfigured(token);
        // The divergence check anchors on the feed price, and a halted market is exactly the state in
        // which that anchor cannot be trusted: nothing verifies until the halt clears.
        Quote memory q = quote(token);
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted(token);
        (uint256 raw,) = IStreamAdapter(c.streamAdapter).verify(token, report);
        price = _scale(raw, c.feedDecimals, c.quoteDecimals);
        uint256 diff = price > q.price ? price - q.price : q.price - price;
        if (diff * Types.BPS / q.price > c.streamDivergenceBps) revert StreamDivergence(q.price, price);
    }

    function tokenDecimals(address token) external view override returns (uint8) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);
        return c.tokenDecimals;
    }

    function feedConfig(address token) external view returns (FeedConfig memory) {
        return _feeds[token];
    }

    function checkpoint(address token) external view returns (Checkpoint memory) {
        return _checkpoints[token];
    }

    function hasStream(address token) external view override returns (bool) {
        return _feeds[token].streamAdapter != address(0);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _scale(uint256 answer, uint8 fromDec, uint8 toDec) internal pure returns (uint256) {
        if (toDec >= fromDec) return answer * (10 ** (toDec - fromDec));
        return answer / (10 ** (fromDec - toDec));
    }

    function _session(FeedConfig storage c) internal view returns (Types.Session) {
        if (c.marketStatusSource != address(0)) {
            uint8 s = IMarketStatusSource(c.marketStatusSource).marketStatus();
            if (s == CL_STATUS_CLOSED) return Types.Session.Closed;
            if (s == CL_STATUS_EXTENDED) return Types.Session.Extended;
            return Types.Session.Regular;
        }
        return _scheduledSession();
    }

    /// @dev Weekday and time-of-day fallback. Saturday and Sunday are closed. Holidays are not modelled;
    ///      a market-status source should be configured for production.
    function _scheduledSession() internal view returns (Types.Session) {
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7; // 0 = Sunday
        uint256 secondOfDay = block.timestamp % 1 days;
        Schedule memory s = schedule;
        // Extended session may wrap past midnight (extendedClose > 24h); handle the early-morning tail.
        bool inWrappedTail = s.extendedClose > 1 days && secondOfDay < s.extendedClose - 1 days;
        if (inWrappedTail) {
            uint256 prevDay = (dayOfWeek + 6) % 7;
            return (prevDay == 0 || prevDay == 6) ? Types.Session.Closed : Types.Session.Extended;
        }
        if (dayOfWeek == 0 || dayOfWeek == 6) return Types.Session.Closed;
        if (secondOfDay >= s.regularOpen && secondOfDay < s.regularClose) return Types.Session.Regular;
        if (secondOfDay >= s.extendedOpen && secondOfDay < (s.extendedClose > 1 days ? 1 days : s.extendedClose)) {
            return Types.Session.Extended;
        }
        return Types.Session.Closed;
    }

    function _stalenessBound(FeedConfig storage c, Types.Session s) internal view returns (uint256) {
        if (s == Types.Session.Regular) return c.stalenessRegular;
        if (s == Types.Session.Extended) return c.stalenessExtended;
        return c.stalenessClosed;
    }

    function _sourcePaused(FeedConfig storage c) internal view returns (bool) {
        if (c.pauseSource == address(0)) return false;
        try IOraclePauseSource(c.pauseSource).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return false;
        }
    }

    function _multiplier(FeedConfig storage c) internal view returns (uint256) {
        if (c.multiplierSource == address(0)) return Types.WAD;
        try IERC8056(c.multiplierSource).uiMultiplier() returns (uint256 m) {
            return m == 0 ? Types.WAD : m;
        } catch {
            return Types.WAD;
        }
    }

    /// @dev Chainlink L2 Sequencer Uptime Feed: answer 0 = up, 1 = down; startedAt = time of last status change.
    ///      During an outage the underlying market keeps moving while nobody can transact, so trading stays
    ///      halted through the grace period after recovery rather than resuming into a frozen mid.
    function _sequencerGrace() internal view returns (bool) {
        if (address(sequencerFeed) == address(0)) return false;
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        if (answer != 0) return true; // sequencer down: treat as grace so nothing trades
        // A startedAt of zero means the round is not initialized yet; without this check the
        // grace-period arithmetic would treat "no data" as "up since the epoch" and let trading resume.
        if (startedAt == 0) return true;
        uint256 grace = params.riskParams().sequencerGrace;
        return block.timestamp - startedAt < grace;
    }
}
