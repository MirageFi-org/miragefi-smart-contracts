// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {ParamController} from "../src/ParamController.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice The vault path end to end: pricing against the published formula, itemised fees, skew,
///         caps, bands, two-leg composition and the eligibility boundary.
contract SwapTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
        _seed(spyVault, SPY_MID);
    }

    function test_buyPricesOffTheFormula() public {
        uint256 amountIn = 10_000e6;
        uint256 out = _swap(address(usdg), address(nvda), amountIn);

        // Balanced vault: no skew, regular session, half-spread 10 bps, fee 2 bps off the input.
        uint256 expected = _expectedBuyOut(amountIn, NVDA_MID, 10);
        assertEq(out, expected);
        assertEq(nvda.balanceOf(trader), 1_000e18 + expected);

        // The collector holds the itemised fee plus 10% of the realised spread; the rest stays with LPs.
        uint256 fee = amountIn * 2 / 10_000;
        uint256 net = amountIn - fee;
        uint256 spread = net - expected * NVDA_MID / 1e18;
        assertEq(usdg.balanceOf(address(fees)), fee + spread * 1000 / 10_000);
    }

    function test_sellPricesOffTheFormula() public {
        uint256 amountIn = 50e18;
        uint256 out = _swap(address(nvda), address(usdg), amountIn);

        uint256 bid = NVDA_MID * (10_000 - 10) / 10_000;
        uint256 gross = amountIn * bid / 1e18;
        uint256 expected = gross - gross * 2 / 10_000;
        assertEq(out, expected);
    }

    function test_breakdownIsItemised() public view {
        (uint256 out, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);
        assertGt(out, 0);
        assertEq(b.mid, NVDA_MID);
        assertEq(b.halfSpreadBps, 10);
        assertEq(b.skewBps, 0);
        assertEq(b.feeBps, 2);
        assertEq(uint8(b.session), uint8(Types.Session.Regular));
    }

    function test_skewTightensTheRebalancingSide() public {
        // Drain the token side: the vault goes short of target, so buying more from it must cost more
        // and selling to it must pay better than the balanced spread.
        _swap(address(usdg), address(nvda), 40_000e6);
        _swap(address(usdg), address(nvda), 40_000e6);

        (, Types.Breakdown memory buySide) = nvdaVault.quoteSwap(true, 10_000e6);
        (, Types.Breakdown memory sellSide) = nvdaVault.quoteSwap(false, 50e18);
        assertLt(buySide.skewBps, 0);
        assertGt(buySide.halfSpreadBps, 10);
        assertLt(sellSide.halfSpreadBps, 10);
    }

    function test_inventoryBandMakesVaultOneSided() public {
        // Shrink the vault so the band edge is reachable inside the clip: withdraw most of the seed.
        vm.startPrank(lp1);
        nvdaVault.withdraw(nvdaVault.balanceOf(lp1) * 9 / 10, lp1);
        vm.stopPrank();

        // 100k of value, 50k each side, 20% band: 15k of buys is inside, 10k more crosses.
        _swap(address(usdg), address(nvda), 15_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 10_000e6, 0));

        // The rebalancing side keeps quoting.
        uint256 out = _swap(address(nvda), address(usdg), 10e18);
        assertGt(out, 0);
    }

    function test_clipBoundsSingleSwap() public {
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 60_000e6, 0));
    }

    function test_dailyVolumeCap() public {
        vm.prank(gov);
        params.setMarketConfig(
            address(nvda),
            IParamController.MarketConfig({tier: 1, dailyVolumeCap: 30_000e6, tvlCap: 5_000_000e6, enabled: true})
        );
        assertEq(nvdaVault.remainingDailyCap(), 30_000e6);
        _swap(address(usdg), address(nvda), 20_000e6);
        assertEq(nvdaVault.remainingDailyCap(), 10_000e6);

        // The cap is enforced at quote time, so previews and fills agree and the router treats a
        // capped-out vault as "no vault quote" rather than reverting mid-fill.
        vm.expectRevert(AnchorVault.DailyCapExceeded.selector);
        nvdaVault.quoteSwap(true, 20_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 20_000e6, 0));

        // What the headroom says fits, fills.
        assertGt(_swap(address(usdg), address(nvda), 10_000e6), 0);
        assertEq(nvdaVault.remainingDailyCap(), 0);

        // A new UTC day starts a fresh cap. Refresh the feed so the price is not stale.
        vm.warp(block.timestamp + 1 days);
        nvdaFeed.set(int256(NVDA_PRICE_8));
        assertEq(nvdaVault.remainingDailyCap(), 30_000e6);
        assertGt(_swap(address(usdg), address(nvda), 20_000e6), 0);
    }

    function test_slippageBoundReverts() public {
        uint256 expected = _expectedBuyOut(10_000e6, NVDA_MID, 10);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.Slippage.selector, expected, expected + 1));
        router.swapExactIn(_params(address(usdg), address(nvda), 10_000e6, expected + 1));
    }

    function test_twoLegSwapThroughTheQuoteAsset() public {
        uint256 amountIn = 20e18; // NVDA in, SPY out
        uint256 out = _swap(address(nvda), address(spy), amountIn);

        // Leg one sells NVDA at its bid minus fee; leg two buys SPY at its ask, fee off the input.
        uint256 bid = NVDA_MID * (10_000 - 10) / 10_000;
        uint256 leg1Gross = amountIn * bid / 1e18;
        uint256 leg1Out = leg1Gross - leg1Gross * 2 / 10_000;
        uint256 expected = _expectedBuyOut(leg1Out, SPY_MID, 10);
        assertEq(out, expected);
        assertEq(spy.balanceOf(trader), 100e18 + expected);
    }

    function test_traderEligibilityEnforced() public {
        usdg.mint(outsider, 10_000e6);
        vm.startPrank(outsider);
        usdg.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.TRADER));
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        vm.stopPrank();
    }

    function test_recipientEligibilityEnforced() public {
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 1_000e6, 0);
        p.to = outsider;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.TRADER));
        router.swapExactIn(p);
    }

    function test_guardianPauseStopsSwapsOnly() public {
        vm.prank(guardian);
        params.setPaused(true);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.SwapsPaused.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));

        // Pricing goes dark with the pause, so a preview never shows a quote nobody can hit.
        vm.expectRevert(AnchorVault.SwapsPaused.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Unpausing is not the guardian's to do: a compromised guardian key must not be able to lift
        // a pause mid-incident. The owner clears it.
        vm.prank(guardian);
        vm.expectRevert(ParamController.NotOwner.selector);
        params.setPaused(false);
        vm.prank(gov);
        params.setPaused(false);
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
    }

    function test_swapOnlyThroughRouter() public {
        vm.prank(trader);
        vm.expectRevert(AnchorVault.NotRouter.selector);
        nvdaVault.swap(true, 1_000e6, trader);
    }

    function test_deadlineEnforced() public {
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 1_000e6, 0);
        p.deadline = block.timestamp - 1;
        vm.prank(trader);
        vm.expectRevert(SwapRouter.Expired.selector);
        router.swapExactIn(p);
    }
}
