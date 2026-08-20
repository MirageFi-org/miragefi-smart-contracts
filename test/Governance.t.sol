// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Roles} from "../src/libraries/Types.sol";
import {ParamController} from "../src/ParamController.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {IOracleRouter} from "../src/interfaces/IOracleRouter.sol";
import {NativeAttestationAdapter} from "../src/adapters/NativeAttestationAdapter.sol";
import {MockStockToken} from "../src/mocks/Mocks.sol";

/// @notice The change-control surface: bootstrap locks to the timelock, the guardian can only pause,
///         and parameter validation refuses configurations the pricing formula cannot honour.
contract GovernanceTest is BaseTest {
    function _feeCall(uint16 swapFee) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            ParamController.setFeeParams,
            (IParamController.FeeParams({swapFeeBps: swapFee, rfqFeeBps: 2, spreadShareBps: 1000}))
        );
    }

    function test_bootstrapLocksSettersToTheTimelock() public {
        vm.prank(gov);
        params.finishBootstrap();

        // Direct setter calls are refused for everyone, the owner included.
        vm.prank(gov);
        vm.expectRevert(ParamController.NotSelf.selector);
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 5, rfqFeeBps: 2, spreadShareBps: 1000}));

        // The only path is schedule, wait out the delay, execute.
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), keccak256("rationale: fee retune per Q3 execution data"));

        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotReady.selector);
        params.execute(calls, bytes32("salt"));

        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        params.execute(calls, bytes32("salt"));
        assertEq(params.feeParams().swapFeeBps, 5);
    }

    function test_scheduledOperationCanBeCancelled() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.prank(gov);
        params.cancel(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotFound.selector);
        params.execute(calls, bytes32("salt"));

        // Cancelling twice is refused; a cancelled operation is as good as gone.
        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotFound.selector);
        params.cancel(id);
    }

    function test_cancelledOperationCanBeRescheduled() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.prank(gov);
        params.cancel(id);

        // The same batch under the same salt gets a fresh timelock rather than a burned id.
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        params.execute(calls, bytes32("salt"));
        assertEq(params.feeParams().swapFeeBps, 5);
    }

    function test_guardianCanPauseAndNothingElse() public {
        vm.prank(guardian);
        params.setPaused(true);
        assertTrue(params.swapsPaused());

        vm.prank(guardian);
        vm.expectRevert(ParamController.NotOwner.selector);
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 0, rfqFeeBps: 0, spreadShareBps: 0}));

        vm.prank(outsider);
        vm.expectRevert(ParamController.NotGuardian.selector);
        params.setPaused(true);
    }

    function test_tierValidationRefusesUnpriceableConfigs() public {
        // A base spread plus full skew that cannot fit inside the oracle band is refused outright.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setTierConfig(
            4,
            IParamController.TierConfig({
                baseHalfSpreadBps: 60,
                maxSkewBps: 30,
                inventoryBandBps: 2000,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );

        // An enabled tier with a zero inventory band would divide skew by zero at the first fill.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setTierConfig(
            4,
            IParamController.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 0,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );
    }

    function test_regimeValidationKeepsMultipliersHonest() public {
        // Session multipliers may only widen spreads and shrink clips.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setRegimeParams(
            IParamController.RegimeParams({
                extendedSpreadMulBps: 9_000,
                closedSpreadMulBps: 30_000,
                extendedClipMulBps: 7_500,
                closedClipMulBps: 5_000
            })
        );
    }

    function test_marketRequiresEnabledTier() public {
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidTier.selector);
        params.setMarketConfig(
            address(0xBEEF), IParamController.MarketConfig({tier: 9, dailyVolumeCap: 1e6, tvlCap: 1e6, enabled: true})
        );
    }

    function test_deploymentRefusesZeroAddresses() public {
        // A zero owner is a controller nobody can ever govern.
        vm.expectRevert(ParamController.ZeroAddress.selector);
        new ParamController(address(0), guardian, 1 days);

        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(params, eligibility, oracle, address(0), address(usdg));

        // Router wiring is one-shot, so a zero router would brick the factory for good.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setRouter(address(0));
    }

    function test_marketOpensOnlyOnceFullyWired() public {
        MockStockToken fresh = new MockStockToken("Tesla Stock Token", "TSLAx");

        // No market parameters yet: refused.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.MarketNotConfigured.selector);
        factory.createMarket(address(fresh));

        // Parameters set but no oracle feed: still refused.
        vm.prank(gov);
        params.setMarketConfig(
            address(fresh),
            IParamController.MarketConfig({tier: 1, dailyVolumeCap: 1_000e6, tvlCap: 1_000e6, enabled: true})
        );
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.FeedNotConfigured.selector, address(fresh)));
        factory.createMarket(address(fresh));
    }

    function test_revokeRequiresAnAttestation() public {
        // An issuer typo must fail loudly, not emit a zero-uid revocation of nothing.
        vm.prank(issuer);
        vm.expectRevert(NativeAttestationAdapter.NotAttested.selector);
        attestations.revoke(outsider, Roles.TRADER);

        // A real record still revokes.
        vm.prank(issuer);
        attestations.revoke(trader, Roles.TRADER);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_ownershipHandoverIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(gov);
        params.transferOwnership(next);
        assertEq(params.owner(), gov); // nothing changes until the new owner accepts
        vm.prank(next);
        params.acceptOwnership();
        assertEq(params.owner(), next);
    }
}
