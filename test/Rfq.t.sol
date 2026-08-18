// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {RfqSettlement} from "../src/RfqSettlement.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice The RFQ lane: makers win only by beating the vault, settlement is atomic, and every guard
///         (expiry, nonce, signature, role, band) is enforced at the fill.
contract RfqTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
    }

    function _swapWithQuote(Types.MakerQuote memory q, bytes memory sig, uint256 amountIn) internal returns (uint256) {
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = sig;
        vm.prank(trader);
        return router.swapExactIn(p);
    }

    function test_makerWinsWhenBeatingTheVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        uint256 better = vaultOut + vaultOut / 1000; // 10 bps of improvement

        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, better, 1);
        uint256 makerUsdgBefore = usdg.balanceOf(maker);

        uint256 out = _swapWithQuote(q, _sign(q), amountIn);

        assertEq(out, better);
        // The protocol fee comes off the quote-token leg: the maker receives the input net of it.
        uint256 fee = amountIn * 2 / 10_000;
        assertEq(usdg.balanceOf(maker), makerUsdgBefore + amountIn - fee);
        assertEq(usdg.balanceOf(address(fees)), fee);
    }

    function test_vaultWinsWhenMakerIsWorse() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut - 1, 1);

        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, _sign(q), amountIn);

        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore); // the maker was never touched
    }

    function test_sellSideFeeDeductedFromOutput() public {
        uint256 amountIn = 50e18;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(false, amountIn);
        uint256 gross = vaultOut + vaultOut / 500; // clearly better than the vault after the fee
        Types.MakerQuote memory q = _makerQuote(address(nvda), address(usdg), amountIn, gross, 7);

        uint256 out = _swapWithQuote(q, _sign(q), amountIn);
        uint256 fee = gross * 2 / 10_000;
        assertEq(out, gross - fee);
        assertEq(usdg.balanceOf(address(fees)), fee);
    }

    function test_nonceCannotBeReplayed() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut + vaultOut / 1000, 42);
        bytes memory sig = _sign(q);

        _swapWithQuote(q, sig, amountIn);

        // A consumed nonce reads like a cancelled one: the replay is priced as absent and the vault
        // fills, while the maker is never touched a second time.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        (uint256 vaultOut2,) = nvdaVault.quoteSwap(true, amountIn);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut2);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // Settlement itself still refuses the replay, as defence in depth.
        vm.prank(address(router));
        vm.expectRevert(RfqSettlement.NonceAlreadyUsed.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_cancelledQuoteFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 9);
        bytes memory sig = _sign(q);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 9;
        vm.prank(maker);
        rfq.cancel(nonces);

        // A cancelled candidate is a race, not an error: the router prices it as absent.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // Settlement itself still refuses the nonce, as defence in depth.
        vm.prank(address(router));
        vm.expectRevert(RfqSettlement.NonceAlreadyUsed.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_expiredQuoteFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 3);
        q.expiry = uint40(block.timestamp - 1);
        bytes memory sig = _sign(q);

        // A quote that expired in flight is priced as absent and the vault carries the fill.
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);

        // Settlement itself still refuses the expiry, as defence in depth.
        vm.prank(address(router));
        vm.expectRevert(RfqSettlement.QuoteExpired.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_badSignatureRejected() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 4);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPk, rfq.quoteDigest(q)); // wrong key

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = abi.encodePacked(r, s, v);
        vm.prank(trader);
        vm.expectRevert(RfqSettlement.BadSignature.selector);
        router.swapExactIn(p);
    }

    function test_reservedQuoteForAnotherTakerRejected() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 5);
        q.taker = outsider;

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettlement.WrongTaker.selector);
        router.swapExactIn(p);
    }

    function test_cancelRecordsOnlyRealStateChanges() public {
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 77;
        nonces[1] = 77; // duplicate inside the batch

        vm.recordLogs();
        vm.prank(maker);
        rfq.cancel(nonces);
        vm.prank(maker);
        rfq.cancel(nonces); // and the whole batch again

        // Four requests, one real change: exactly one NonceCancelled hits the audit trail.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertTrue(rfq.nonceUsed(maker, 77));
    }

    function test_bandCutsBothWays() public {
        // An SPY vault with no liquidity leaves RFQ as the only venue. A quote 2% better than mid for
        // the trader still fails: whatever a maker signs, nothing settles outside the band.
        spy.mint(maker, 1_000e18);
        vm.prank(maker);
        spy.approve(address(rfq), type(uint256).max);

        uint256 amountIn = 10_000e6;
        uint256 fair = amountIn * 1e18 / SPY_MID;
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(spy), amountIn, fair * 102 / 100, 6);

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert();
        router.swapExactIn(p);
    }

    function test_revokedMakerCannotSettle() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 8);
        bytes memory sig = _sign(q);

        vm.prank(issuer);
        attestations.revoke(maker, Roles.MAKER);

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = sig;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, maker, Roles.MAKER));
        router.swapExactIn(p);
    }

    function test_settleOnlyThroughRouter() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 1_000e6, 1e18, 11);
        bytes memory sig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettlement.NotRouter.selector);
        rfq.settle(q, sig, trader, trader);
    }
}
