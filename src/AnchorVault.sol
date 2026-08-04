// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "./libraries/Types.sol";

/// @title AnchorVault
/// @notice One market: one listed token against the quote asset, funded by LPs, quoting both sides around
///         the guarded oracle mid. The vault's price is a function of the oracle, never of its reserves;
///         inventory only moves the spread. LP shares follow value-based accounting and withdrawal is
///         pro-rata in kind, in every state, so no pause or halt can trap LP funds.
/// @dev Swaps enter only through the SwapRouter. Deposits require a live oracle because shares are minted
///      at the current mid; withdrawals never read the oracle at all.
contract AnchorVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleRouter public immutable oracle;
    VaultFactory public immutable factory;
    address public immutable feeCollector;
    IERC20 public immutable quoteToken;
    IERC20 public immutable token;
    uint8 public immutable tokenDec;
    uint8 public immutable quoteDec;
    /// @dev Scales a first deposit's quote-unit value up to 18-decimal shares.
    uint256 internal immutable shareScale;

    /// @notice Quote-token notional filled per UTC day, checked against the market's daily cap.
    mapping(uint256 => uint256) public dailyVolume;

    struct SwapQuote {
        uint256 amountOut;
        /// @dev Quote-token notional at mid, the unit of clips and daily caps.
        uint256 notional;
        uint256 feeAmount;
        uint256 protocolSpread;
        Types.Breakdown breakdown;
    }

    event Deposited(
        address indexed lp, address indexed receiver, uint256 quoteAmount, uint256 tokenAmount, uint256 shares
    );
    event Withdrawn(address indexed lp, address indexed receiver, uint256 shares, uint256 quoteOut, uint256 tokenOut);
    event VaultSwap(
        address indexed to,
        bool buyToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 mid,
        uint16 halfSpreadBps,
        int16 skewBps,
        uint16 feeBps,
        Types.Session session
    );

    error NotRouter();
    error MarketNotListed();
    error MarketHalted();
    error SwapsPaused();
    error NoLiquidity();
    error ZeroAmount();
    error ZeroShares();
    error Slippage(uint256 shares, uint256 minShares);
    error BandExceeded();
    error ClipExceeded(uint256 notional, uint256 clip);
    error DailyCapExceeded();
    error TvlCapExceeded();
    error InventoryBandExceeded();

    modifier onlyRouter() {
        if (msg.sender != factory.router()) revert NotRouter();
        _;
    }

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        IOracleRouter oracle_,
        address feeCollector_,
        address quoteToken_,
        address token_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        factory = VaultFactory(msg.sender);
        feeCollector = feeCollector_;
        quoteToken = IERC20(quoteToken_);
        token = IERC20(token_);
        tokenDec = IERC20Metadata(token_).decimals();
        quoteDec = IERC20Metadata(quoteToken_).decimals();
        shareScale = 10 ** (18 - quoteDec);
    }

    // ---------------------------------------------------------------------
    // LP side
    // ---------------------------------------------------------------------

    /// @notice Deposit the quote asset, the token, or both. The deposit is valued at the guarded mid and
    ///         mints shares at the current value per share. `minShares` bounds the mint the way a swap's
    ///         `minAmountOut` bounds a fill: if the mid moves between signing and inclusion, the deposit
    ///         reverts rather than mints short.
    function deposit(uint256 quoteAmount, uint256 tokenAmount, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (quoteAmount == 0 && tokenAmount == 0) revert ZeroAmount();
        eligibility.requireRole(msg.sender, Roles.LP);
        if (receiver != msg.sender) eligibility.requireRole(receiver, Roles.LP);

        uint256 mid = _liveMid();
        uint256 value = quoteAmount + tokenAmount * mid / 10 ** tokenDec;
        uint256 total = _totalValue(mid);

        IParamController.MarketConfig memory mkt = params.marketConfig(address(token));
        if (!mkt.enabled) revert MarketNotListed();
        if (total + value > mkt.tvlCap) revert TvlCapExceeded();

        uint256 supply = totalSupply();
        shares = supply == 0 ? value * shareScale : value * supply / total;
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert Slippage(shares, minShares);

        if (quoteAmount != 0) quoteToken.safeTransferFrom(msg.sender, address(this), quoteAmount);
        if (tokenAmount != 0) token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, quoteAmount, tokenAmount, shares);
    }

    /// @notice Burn shares for a pro-rata, in-kind mix of the vault's current inventory. Never gated:
    ///         no eligibility check, no pause check, no oracle read. Withdrawal is a property of holding
    ///         shares, not a permission.
    function withdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 quoteOut, uint256 tokenOut)
    {
        if (shares == 0) revert ZeroShares();
        (quoteOut, tokenOut) = previewWithdraw(shares);
        _burn(msg.sender, shares);
        if (quoteOut != 0) quoteToken.safeTransfer(receiver, quoteOut);
        if (tokenOut != 0) token.safeTransfer(receiver, tokenOut);
        emit Withdrawn(msg.sender, receiver, shares, quoteOut, tokenOut);
    }

    // ---------------------------------------------------------------------
    // Trading side (router only)
    // ---------------------------------------------------------------------

    /// @notice Preview a swap against current state. Reverts while the market is halted or when the fill
    ///         would breach a cap, which the router treats as "no vault quote" rather than an error, so
    ///         RFQ can still carry the trade.
    function quoteSwap(bool buyToken, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, Types.Breakdown memory breakdown)
    {
        SwapQuote memory s = _price(oracle.quote(address(token)), buyToken, amountIn);
        return (s.amountOut, s.breakdown);
    }

    /// @notice Fill a swap. Pulls `amountIn` of the input asset from the router, sends the output to `to`,
    ///         and forwards the itemised protocol fee and spread share to the fee collector.
    function swap(bool buyToken, uint256 amountIn, address to) external onlyRouter nonReentrant returns (uint256) {
        // `refresh` checkpoints the move cap; a print past the cap pauses the market instead of filling.
        IOracleRouter.Quote memory q = oracle.refresh(address(token));
        SwapQuote memory s = _price(q, buyToken, amountIn);
        dailyVolume[block.timestamp / 1 days] += s.notional;

        if (buyToken) {
            quoteToken.safeTransferFrom(msg.sender, address(this), amountIn);
            quoteToken.safeTransfer(feeCollector, s.feeAmount + s.protocolSpread);
            token.safeTransfer(to, s.amountOut);
        } else {
            token.safeTransferFrom(msg.sender, address(this), amountIn);
            quoteToken.safeTransfer(to, s.amountOut);
            quoteToken.safeTransfer(feeCollector, s.feeAmount + s.protocolSpread);
        }

        emit VaultSwap(
            to,
            buyToken,
            amountIn,
            s.amountOut,
            s.breakdown.mid,
            s.breakdown.halfSpreadBps,
            s.breakdown.skewBps,
            s.breakdown.feeBps,
            s.breakdown.session
        );
        return s.amountOut;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Shares a deposit of this mix would mint right now. Reverts while the oracle is unusable,
    ///         exactly as `deposit` would; the eligibility and cap checks are left to the call itself.
    function previewDeposit(uint256 quoteAmount, uint256 tokenAmount) external view returns (uint256) {
        uint256 mid = _liveMid();
        uint256 value = quoteAmount + tokenAmount * mid / 10 ** tokenDec;
        uint256 supply = totalSupply();
        return supply == 0 ? value * shareScale : value * supply / _totalValue(mid);
    }

    /// @notice The in-kind mix a withdrawal of `shares` would deliver right now. Pure balance arithmetic,
    ///         like `withdraw` itself: no oracle read, no gate.
    function previewWithdraw(uint256 shares) public view returns (uint256 quoteOut, uint256 tokenOut) {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        quoteOut = quoteToken.balanceOf(address(this)) * shares / supply;
        tokenOut = token.balanceOf(address(this)) * shares / supply;
    }

    /// @notice Vault value in quote units at the current guarded mid. Reverts while the oracle is unusable.
    function totalValue() external view returns (uint256) {
        return _totalValue(_liveMid());
    }

    /// @notice Quote-token notional still fillable today before the market's daily cap binds. Pricing
    ///         enforces the cap, so this is the headroom to size an order against rather than probing
    ///         with quotes until one reverts.
    function remainingDailyCap() external view returns (uint256) {
        uint256 cap = params.marketConfig(address(token)).dailyVolumeCap;
        uint256 used = dailyVolume[block.timestamp / 1 days];
        return used >= cap ? 0 : cap - used;
    }

    /// @notice The token side's share of vault value in bps. 5_000 is on target.
    function inventoryRatioBps() external view returns (uint256) {
        uint256 mid = _liveMid();
        uint256 total = _totalValue(mid);
        if (total == 0) return Types.TARGET_RATIO_BPS;
        return token.balanceOf(address(this)) * mid / 10 ** tokenDec * Types.BPS / total;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev The whole pricing formula in one place: regime-adjusted base spread, signed inventory skew,
    ///      itemised fee, clip, band and daily-cap checks. Everything it reads is public state, so any
    ///      quote is reproducible off-chain from the same inputs.
    function _price(IOracleRouter.Quote memory q, bool buyToken, uint256 amountIn)
        internal
        view
        returns (SwapQuote memory s)
    {
        if (amountIn == 0) revert ZeroAmount();
        // The router refuses fills during the emergency pause; pricing refuses too, so a preview never
        // shows a quote nobody can hit, and the vault stays closed even to a router that forgot to ask.
        if (params.swapsPaused()) revert SwapsPaused();
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted();

        IParamController.MarketConfig memory mkt = params.marketConfig(address(token));
        if (!mkt.enabled) revert MarketNotListed();
        IParamController.TierConfig memory tier = params.tierConfig(mkt.tier);
        IParamController.FeeParams memory fee = params.feeParams();
        (uint256 spreadMul, uint256 clipMul) = _regimeMultipliers(q.session);

        uint256 quoteBal = quoteToken.balanceOf(address(this));
        uint256 tokenBal = token.balanceOf(address(this));
        uint256 tokenValue = tokenBal * q.price / 10 ** tokenDec;
        uint256 total = quoteBal + tokenValue;
        if (total == 0) revert NoLiquidity();

        // Signed skew, positive when the vault is long of the token. The side that rebalances the vault
        // quotes tighter, the side that unbalances it quotes wider, saturating at the band edge.
        int256 skew = int256(uint256(tier.maxSkewBps))
            * (int256(tokenValue * Types.BPS / total) - int256(Types.TARGET_RATIO_BPS))
            / int256(uint256(tier.inventoryBandBps));
        if (skew > int256(uint256(tier.maxSkewBps))) skew = int256(uint256(tier.maxSkewBps));
        if (skew < -int256(uint256(tier.maxSkewBps))) skew = -int256(uint256(tier.maxSkewBps));

        int256 half = int256(uint256(tier.baseHalfSpreadBps) * spreadMul / Types.BPS) + (buyToken ? -skew : skew);
        if (half < 0) half = 0;
        uint256 halfSpread = uint256(half);
        if (halfSpread + fee.swapFeeBps > tier.oracleBandBps) revert BandExceeded();

        // Post-trade balances are simulated alongside the price so that a preview and its fill agree
        // exactly, the inventory band included: what `quoteSwap` says is what `swap` does.
        uint256 newQuoteBal;
        uint256 newTokenVal;
        if (buyToken) {
            s.notional = amountIn;
            s.feeAmount = amountIn * fee.swapFeeBps / Types.BPS;
            uint256 net = amountIn - s.feeAmount;
            uint256 askPrice = q.price * (Types.BPS + halfSpread) / Types.BPS;
            s.amountOut = net * 10 ** tokenDec / askPrice;
            uint256 midValue = s.amountOut * q.price / 10 ** tokenDec;
            s.protocolSpread = (net - midValue) * fee.spreadShareBps / Types.BPS;
            newQuoteBal = quoteBal + amountIn - s.feeAmount - s.protocolSpread;
            newTokenVal = tokenValue - midValue;
        } else {
            uint256 midValue = amountIn * q.price / 10 ** tokenDec;
            s.notional = midValue;
            uint256 bidPrice = q.price * (Types.BPS - halfSpread) / Types.BPS;
            uint256 gross = amountIn * bidPrice / 10 ** tokenDec;
            s.feeAmount = gross * fee.swapFeeBps / Types.BPS;
            s.amountOut = gross - s.feeAmount;
            s.protocolSpread = (midValue - gross) * fee.spreadShareBps / Types.BPS;
            newQuoteBal = quoteBal - gross - s.protocolSpread + s.feeAmount;
            newTokenVal = tokenValue + midValue;
        }

        uint256 clip = uint256(tier.maxClip) * clipMul / Types.BPS;
        if (s.notional > clip) revert ClipExceeded(s.notional, clip);
        if (dailyVolume[block.timestamp / 1 days] + s.notional > mkt.dailyVolumeCap) revert DailyCapExceeded();

        // A fill may not leave the vault outside its inventory band. Beyond the edge the vault goes
        // one-sided: the harmful direction stops quoting here while the rebalancing one keeps working.
        uint256 newTotal = newQuoteBal + newTokenVal;
        if (newTotal == 0) revert NoLiquidity();
        uint256 newRatio = newTokenVal * Types.BPS / newTotal;
        uint256 drift =
            newRatio > Types.TARGET_RATIO_BPS ? newRatio - Types.TARGET_RATIO_BPS : Types.TARGET_RATIO_BPS - newRatio;
        if (drift > tier.inventoryBandBps) revert InventoryBandExceeded();

        s.breakdown = Types.Breakdown({
            mid: q.price,
            halfSpreadBps: uint16(halfSpread),
            skewBps: int16(skew),
            feeBps: fee.swapFeeBps,
            session: q.session
        });
    }

    function _regimeMultipliers(Types.Session session) internal view returns (uint256 spreadMul, uint256 clipMul) {
        IParamController.RegimeParams memory r = params.regimeParams();
        if (session == Types.Session.Regular) return (Types.BPS, Types.BPS);
        if (session == Types.Session.Extended) return (r.extendedSpreadMulBps, r.extendedClipMulBps);
        return (r.closedSpreadMulBps, r.closedClipMulBps);
    }

    function _liveMid() internal view returns (uint256) {
        IOracleRouter.Quote memory q = oracle.quote(address(token));
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted();
        return q.price;
    }

    function _totalValue(uint256 mid) internal view returns (uint256) {
        return quoteToken.balanceOf(address(this)) + token.balanceOf(address(this)) * mid / 10 ** tokenDec;
    }

    /// @dev Shares move only between attested LPs. Minting and burning are exempt so that withdrawal can
    ///      never be blocked by an expired attestation.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) eligibility.requireRole(to, Roles.LP);
        super._update(from, to, value);
    }
}
