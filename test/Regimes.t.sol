// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {OracleRouter} from "../src/OracleRouter.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/IExternal.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockStreamAdapter} from "../src/mocks/Mocks.sol";

/// @notice Sessions and halts: spreads widen and clips shrink when the underlying market is closed, and
///         every oracle failure mode halts trading instead of mispricing it.
contract RegimesTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
    }

    function test_closedSessionWidensSpreadAndShrinksClip() public {
        (uint256 regularOut,) = nvdaVault.quoteSwap(true, 10_000e6);

        nvda.setMarketStatus(5); // Chainlink convention: 5 = closed
        (uint256 closedOut, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);

        assertEq(uint8(b.session), uint8(Types.Session.Closed));
        assertEq(b.halfSpreadBps, 30); // 10 bps base at the x3 closed multiplier
        assertLt(closedOut, regularOut);

        // The clip halves: 26,000 fits the 50,000 regular clip but not the 25,000 closed one.
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.ClipExceeded.selector, 26_000e6, 25_000e6));
        nvdaVault.quoteSwap(true, 26_000e6);
    }

    function test_extendedSessionMultiplier() public {
        nvda.setMarketStatus(2);
        (, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);
        assertEq(uint8(b.session), uint8(Types.Session.Extended));
        assertEq(b.halfSpreadBps, 15); // 10 bps base at the x1.5 extended multiplier
    }

    function test_staleFeedHaltsTrading() public {
        vm.warp(block.timestamp + 2 hours); // regular-session staleness bound is 1 hour
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // A fresh round clears the halt on its own; no privileged action involved.
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_corporateActionPausesAndResumes() public {
        nvda.setOraclePaused(true);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        nvda.setOraclePaused(false);
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_moveCapPausesMarketPendingReview() public {
        _swap(address(usdg), address(nvda), 1_000e6); // writes the first checkpoint

        // A 30% print against a 25% cap reads as halted the moment it lands: the preview refuses it,
        // so the router sees no vault quote, and a maker cannot settle against it either.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        assertFalse(oracle.checkpoint(address(nvda)).paused);

        // A reverted fill cannot persist anything, so the pause is written by whoever calls refresh.
        vm.expectEmit(true, false, false, true);
        emit OracleRouter.MarketPausedEvent(address(nvda), NVDA_MID, NVDA_MID * 130 / 100);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertTrue(oracle.checkpoint(address(nvda)).paused);

        // Once persisted the halt outlives the move-cap window. Without it the suspect print would
        // simply re-baseline after an hour and fill without anyone having reviewed it.
        vm.warp(block.timestamp + 2 hours);
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Clearing the pause is a governance action with a published rationale. Resume re-baselines
        // the checkpoint, so trading restarts at the reviewed price without re-tripping the cap.
        vm.prank(gov);
        oracle.resume(address(nvda));
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
    }

    function test_moveCapRebaselinesAfterTheWindow() public {
        _swap(address(usdg), address(nvda), 1_000e6);

        // The cap compares against a recent checkpoint only. A print that arrives after the window,
        // however far from the last one, is ordinary drift on a quiet market and re-baselines.
        vm.warp(block.timestamp + 2 hours);
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
        assertEq(oracle.checkpoint(address(nvda)).lastPrice, NVDA_MID * 130 / 100);
    }

    function test_sequencerOutageAndGrace() public {
        sequencer.setWithTimestamps(1, block.timestamp, block.timestamp); // down
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Back up, but inside the one-hour grace: still halted.
        sequencer.setWithTimestamps(0, block.timestamp, block.timestamp);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        vm.warp(block.timestamp + 61 minutes);
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_uninitializedSequencerRoundHaltsTrading() public {
        // Chainlink reports startedAt = 0 while the uptime round is not initialized. That must read as
        // an outage, not as "up since the epoch", or the grace arithmetic would wave trading through.
        sequencer.setWithTimestamps(0, 0, block.timestamp);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
    }

    function test_scheduleRefusesImpossibleSessions() public {
        // Regular hours that close before they open would classify every minute as extended or closed.
        OracleRouter.Schedule memory s = OracleRouter.Schedule({
            regularOpen: 21 hours, regularClose: 14 hours + 30 minutes, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // Regular hours must sit inside extended hours.
        s = OracleRouter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 15 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // An extended session that wraps into its own next open leaves the market with no closed period.
        s = OracleRouter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 33 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // The launch shape, extended hours wrapping past midnight, is accepted as it always was.
        s = OracleRouter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        oracle.setSchedule(s);
        (,,, uint32 extendedClose) = oracle.schedule();
        assertEq(extendedClose, 25 hours);
    }

    function test_feedConfigRefusesSelfDisablingGuards() public {
        // A zero staleness bound would mark every round stale and halt the market permanently.
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            0,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );

        // A move cap with a zero window could only ever compare prints inside a single block.
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            0,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );

        // A stream adapter with zero divergence tolerance would reject every report it verifies.
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            0,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0xDEAD)
        );
    }

    function test_streamReportVerifiesOnlyAgainstALiveMid() public {
        MockStreamAdapter stream = new MockStreamAdapter();
        vm.prank(gov);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(stream)
        );

        // In tolerance: the report verifies and scales to quote-token units.
        stream.set(NVDA_PRICE_8);
        assertEq(oracle.verifyStreamReport(address(nvda), ""), NVDA_MID);

        // A 3% divergence against a 2% tolerance is refused.
        stream.set(NVDA_PRICE_8 * 103 / 100);
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.StreamDivergence.selector, NVDA_MID, NVDA_MID * 103 / 100));
        oracle.verifyStreamReport(address(nvda), "");

        // The divergence check anchors on the feed mid; while the market is halted that anchor is
        // exactly the number not to trust, so nothing verifies until the halt clears.
        stream.set(NVDA_PRICE_8);
        vm.prank(gov);
        oracle.pause(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.MarketHalted.selector, address(nvda)));
        oracle.verifyStreamReport(address(nvda), "");
    }

    function test_multiplierReportedNotDoubleApplied() public view {
        // Chainlink equity feeds already include the ERC-8056 multiplier; the router reports it for
        // display and never applies it to the price.
        assertEq(oracle.quote(address(nvda)).multiplier, 1e18);
        assertEq(oracle.quote(address(nvda)).price, NVDA_MID);
    }
}
