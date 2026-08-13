// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Roles} from "../src/libraries/Types.sol";

/// @notice LP-side behaviour: value-based shares, pro-rata in-kind withdrawal, and the invariant that
///         nothing can gate an exit.
contract VaultTest is BaseTest {
    function test_depositMintsValueBasedShares() public {
        vm.prank(lp1);
        uint256 shares = nvdaVault.deposit(100_000e6, 0, 0, lp1);
        // First deposit: shares scale a 6-decimal quote value to 18-decimal shares.
        assertEq(shares, 100_000e6 * 1e12);
        assertEq(nvdaVault.balanceOf(lp1), shares);
        assertEq(nvdaVault.totalValue(), 100_000e6);
    }

    function test_tokenDepositValuedAtMid() public {
        uint256 tokenAmount = 100_000e6 * 1e18 / NVDA_MID;
        vm.prank(lp1);
        uint256 shares = nvdaVault.deposit(0, tokenAmount, 0, lp1);
        uint256 value = tokenAmount * NVDA_MID / 1e18;
        assertEq(shares, value * 1e12);
    }

    function test_secondDepositSameValuePerShare() public {
        _seed(nvdaVault, NVDA_MID);
        uint256 supplyBefore = nvdaVault.totalSupply();
        uint256 totalBefore = nvdaVault.totalValue();
        vm.prank(lp2);
        uint256 shares = nvdaVault.deposit(250_000e6, 0, 0, lp2);
        // Same value per share as the pool: shares/supply == value/total.
        assertApproxEqRel(shares, supplyBefore * 250_000e6 / totalBefore, 1e12);
    }

    function test_withdrawProRataInKind() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        uint256 quoteBal = usdg.balanceOf(address(nvdaVault));
        uint256 tokenBal = nvda.balanceOf(address(nvdaVault));

        vm.prank(lp1);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares / 2, lp1);
        assertEq(quoteOut, quoteBal / 2);
        assertEq(tokenOut, tokenBal / 2);
        assertEq(nvdaVault.balanceOf(lp1), shares - shares / 2);
    }

    function test_withdrawWorksWhileHalted() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        nvda.setOraclePaused(true); // corporate action in progress: trading halts

        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
        vm.prank(lp2);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.deposit(1_000e6, 0, 0, lp2);

        // The halt stops pricing and nothing else. Withdrawal reads no oracle.
        vm.prank(lp1);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares, lp1);
        assertGt(quoteOut, 0);
        assertGt(tokenOut, 0);
    }

    function test_withdrawWorksWhileGuardianPaused() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        vm.prank(guardian);
        params.setPaused(true);
        vm.prank(lp1);
        (uint256 quoteOut,) = nvdaVault.withdraw(shares, lp1);
        assertGt(quoteOut, 0);
    }

    function test_depositRequiresLpRole() public {
        vm.prank(trader);
        usdg.approve(address(nvdaVault), type(uint256).max);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, trader, Roles.LP));
        nvdaVault.deposit(1_000e6, 0, 0, trader);
    }

    function test_shareTransfersGatedToLps() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        vm.prank(lp1);
        nvdaVault.transfer(lp2, shares / 4);
        assertEq(nvdaVault.balanceOf(lp2), shares / 4);

        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.LP));
        nvdaVault.transfer(outsider, 1);
    }

    function test_expiredAttestationNeverBlocksWithdraw() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        vm.prank(issuer);
        attestations.revoke(lp1, Roles.LP);
        vm.prank(lp1);
        (uint256 quoteOut,) = nvdaVault.withdraw(shares, lp1);
        assertGt(quoteOut, 0);
    }

    function test_tvlCapBoundsDeposits() public {
        vm.prank(gov);
        params.setMarketConfig(
            address(nvda),
            IParamController.MarketConfig({tier: 1, dailyVolumeCap: 2_000_000e6, tvlCap: 100_000e6, enabled: true})
        );
        vm.prank(lp1);
        nvdaVault.deposit(90_000e6, 0, 0, lp1);
        vm.prank(lp2);
        vm.expectRevert(AnchorVault.TvlCapExceeded.selector);
        nvdaVault.deposit(20_000e6, 0, 0, lp2);
    }

    function test_depositMinSharesBoundsTheMint() public {
        _seed(nvdaVault, NVDA_MID);
        uint256 expected = nvdaVault.previewDeposit(100_000e6, 0);

        // The mid moves against the LP between preview and inclusion: the mint comes up short of the
        // bound and the deposit reverts instead.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 101 / 100));
        uint256 nowExpected = nvdaVault.previewDeposit(100_000e6, 0);
        assertLt(nowExpected, expected);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.Slippage.selector, nowExpected, expected));
        nvdaVault.deposit(100_000e6, 0, expected, lp2);

        // At or above the bound the deposit mints normally.
        vm.prank(lp2);
        assertEq(nvdaVault.deposit(100_000e6, 0, nowExpected, lp2), nowExpected);
    }

    function test_previewsMatchTheRealThing() public {
        // Seed unevenly and trade once so value per share is no longer 1:1 and rounding has teeth.
        _seed(nvdaVault, NVDA_MID);
        _swap(address(usdg), address(nvda), 10_000e6);

        uint256 tokenAmount = 30_000e6 * 1e18 / NVDA_MID;
        uint256 previewedShares = nvdaVault.previewDeposit(50_000e6, tokenAmount);
        vm.prank(lp2);
        uint256 shares = nvdaVault.deposit(50_000e6, tokenAmount, 0, lp2);
        assertEq(shares, previewedShares);

        (uint256 previewedQuote, uint256 previewedToken) = nvdaVault.previewWithdraw(shares);
        vm.prank(lp2);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares, lp2);
        assertEq(quoteOut, previewedQuote);
        assertEq(tokenOut, previewedToken);
    }

    function test_previewWithdrawNeedsNoOracle() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        nvda.setOraclePaused(true); // halts pricing and deposit previews...
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.previewDeposit(1_000e6, 0);

        // ...but the exit preview, like the exit, reads no oracle at all.
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.previewWithdraw(shares);
        assertGt(quoteOut, 0);
        assertGt(tokenOut, 0);
    }

    function test_swapAccruesValuePerShare() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        uint256 valueBefore = nvdaVault.totalValue();
        _swap(address(usdg), address(nvda), 10_000e6);
        // The vault kept the LP share of the spread, so value per share rose while supply is unchanged.
        assertGt(nvdaVault.totalValue(), valueBefore - 1);
        assertEq(nvdaVault.totalSupply(), shares);
        uint256 lpSpread = nvdaVault.totalValue() * 1e18 / shares;
        assertGt(lpSpread, valueBefore * 1e18 / shares);
    }
}
