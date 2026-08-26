// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ParamController} from "../src/ParamController.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {NativeAttestationAdapter} from "../src/adapters/NativeAttestationAdapter.sol";
import {OracleRouter} from "../src/OracleRouter.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {RfqSettlement} from "../src/RfqSettlement.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/IExternal.sol";
import {Roles} from "../src/libraries/Types.sol";
import {MockERC20, MockStockToken, MockAggregatorV3} from "../src/mocks/Mocks.sol";

/// @title Deploy
/// @notice Deploys the full MirageFi stack to Robinhood Chain testnet (chain ID 46630) or mainnet (4663).
/// @dev Environment:
///        PRIVATE_KEY                deployer key (also initial governance owner unless GOV is set)
///        GOV, GUARDIAN              optional governance and guardian addresses
///        TIMELOCK_DELAY             seconds, default 1 hour on testnet
///        USDG                       quote asset address; if unset and DEPLOY_MOCKS=true a mock is deployed
///        STOCK_TOKEN, STOCK_FEED    Tier A listing and its Chainlink feed; mocks if unset and DEPLOY_MOCKS=true
///        SEQUENCER_FEED             Chainlink L2 Sequencer Uptime Feed; skipped if unset
///        ATTESTATION_ISSUER         KYC signer allowed to attest; defaults to the deployer on testnet
///        FINISH_BOOTSTRAP           "true" to lock the ParamController to the timelock at the end
///      Run:
///        forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify
contract Deploy is Script {
    struct Addresses {
        address paramController;
        address eligibilityRegistry;
        address attestationAdapter;
        address oracleRouter;
        address feeCollector;
        address vaultFactory;
        address rfqSettlement;
        address swapRouter;
        address vault;
        address usdg;
        address stockToken;
        address stockFeed;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address gov = vm.envOr("GOV", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(1 hours));
        bool mocks = vm.envOr("DEPLOY_MOCKS", block.chainid != 4663);
        bool finish = vm.envOr("FINISH_BOOTSTRAP", false);
        address issuer = vm.envOr("ATTESTATION_ISSUER", deployer);

        Addresses memory a;
        vm.startBroadcast(pk);

        // ----- External dependencies (real on mainnet, mocks on testnet unless provided) -----
        a.usdg = vm.envOr("USDG", address(0));
        a.stockToken = vm.envOr("STOCK_TOKEN", address(0));
        a.stockFeed = vm.envOr("STOCK_FEED", address(0));
        address sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));

        if (a.usdg == address(0)) {
            require(mocks, "USDG required");
            a.usdg = address(new MockERC20("Global Dollar (mock)", "USDG", 6));
        }
        if (a.stockToken == address(0)) {
            require(mocks, "STOCK_TOKEN required");
            a.stockToken = address(new MockStockToken("NVIDIA Stock Token (mock)", "NVDAx"));
        }
        if (a.stockFeed == address(0)) {
            require(mocks, "STOCK_FEED required");
            a.stockFeed = address(new MockAggregatorV3(8, 176_40_000_000));
        }

        // ----- Core -----
        // Deployer holds ownership through bootstrap, then hands it to `gov`.
        ParamController params = new ParamController(deployer, guardian, delay);
        EligibilityRegistry eligibility = new EligibilityRegistry(params);
        NativeAttestationAdapter attestations = new NativeAttestationAdapter(params);
        OracleRouter oracle = new OracleRouter(params);
        FeeCollector fees = new FeeCollector(params);
        VaultFactory factory = new VaultFactory(params, eligibility, oracle, address(fees), a.usdg);
        RfqSettlement rfqSettlement = new RfqSettlement(params, eligibility, oracle, factory, address(fees));
        SwapRouter router = new SwapRouter(params, eligibility, factory, rfqSettlement);
        factory.setRouter(address(router));

        // ----- Parameters (bootstrap mode: direct setters). Launch values match the documentation. -----
        params.setEligibilityAdapter(address(attestations));
        params.setAttestationIssuer(issuer, true);
        params.setTierConfig(
            1,
            IParamController.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 2000,
                oracleBandBps: 75,
                maxClip: 50_000e6,
                enabled: true
            })
        );
        params.setTierConfig(
            2,
            IParamController.TierConfig({
                baseHalfSpreadBps: 20,
                maxSkewBps: 25,
                inventoryBandBps: 2000,
                oracleBandBps: 150,
                maxClip: 20_000e6,
                enabled: true
            })
        );
        params.setTierConfig(
            3,
            IParamController.TierConfig({
                baseHalfSpreadBps: 40,
                maxSkewBps: 50,
                inventoryBandBps: 2000,
                oracleBandBps: 300,
                maxClip: 5_000e6,
                enabled: true
            })
        );
        params.setMarketConfig(
            a.stockToken,
            IParamController.MarketConfig({tier: 1, dailyVolumeCap: 2_000_000e6, tvlCap: 5_000_000e6, enabled: true})
        );
        params.setRegimeParams(
            IParamController.RegimeParams({
                extendedSpreadMulBps: 15_000,
                closedSpreadMulBps: 30_000,
                extendedClipMulBps: 7_500,
                closedClipMulBps: 5_000
            })
        );
        params.setRiskParams(IParamController.RiskParams({sequencerGrace: 1 hours}));
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 2, rfqFeeBps: 2, spreadShareBps: 1000}));

        // ----- Oracle -----
        // On testnet the mock stock token doubles as market-status, pause and multiplier source.
        address statusSource = mocks ? a.stockToken : vm.envOr("MARKET_STATUS_SOURCE", address(0));
        oracle.configureFeed(
            a.stockToken,
            a.usdg,
            AggregatorV3Interface(a.stockFeed),
            uint32(vm.envOr("STALENESS_REGULAR", uint256(1 hours))),
            uint32(vm.envOr("STALENESS_EXTENDED", uint256(2 hours))),
            uint32(vm.envOr("STALENESS_CLOSED", uint256(4 days))),
            2500,
            uint32(vm.envOr("MOVE_CAP_WINDOW", uint256(1 hours))),
            200,
            statusSource,
            a.stockToken,
            a.stockToken,
            vm.envOr("STREAM_ADAPTER", address(0))
        );
        if (sequencerFeed != address(0)) oracle.setSequencerFeed(AggregatorV3Interface(sequencerFeed));

        // ----- Open the launch market -----
        a.vault = factory.createMarket(a.stockToken);

        // Testnet convenience: the deployer can attest itself for every role to smoke-test flows.
        if (mocks && issuer == deployer) {
            uint64 exp = uint64(block.timestamp + 365 days);
            attestations.attest(deployer, Roles.TRADER, "LT", 2, exp);
            attestations.attest(deployer, Roles.LP, "LT", 3, exp);
            attestations.attest(deployer, Roles.MAKER, "LT", 3, exp);
            attestations.attest(deployer, Roles.RELAYER, "LT", 0, exp);
        }

        if (finish) params.finishBootstrap();
        if (gov != deployer) params.transferOwnership(gov);

        vm.stopBroadcast();

        a.paramController = address(params);
        a.eligibilityRegistry = address(eligibility);
        a.attestationAdapter = address(attestations);
        a.oracleRouter = address(oracle);
        a.feeCollector = address(fees);
        a.vaultFactory = address(factory);
        a.rfqSettlement = address(rfqSettlement);
        a.swapRouter = address(router);
        _write(a);
    }

    function _write(Addresses memory a) internal {
        string memory root = "miragefi";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "ParamController", a.paramController);
        vm.serializeAddress(root, "EligibilityRegistry", a.eligibilityRegistry);
        vm.serializeAddress(root, "NativeAttestationAdapter", a.attestationAdapter);
        vm.serializeAddress(root, "OracleRouter", a.oracleRouter);
        vm.serializeAddress(root, "FeeCollector", a.feeCollector);
        vm.serializeAddress(root, "VaultFactory", a.vaultFactory);
        vm.serializeAddress(root, "RfqSettlement", a.rfqSettlement);
        vm.serializeAddress(root, "SwapRouter", a.swapRouter);
        vm.serializeAddress(root, "AnchorVault", a.vault);
        vm.serializeAddress(root, "USDG", a.usdg);
        vm.serializeAddress(root, "StockToken", a.stockToken);
        string memory json = vm.serializeAddress(root, "StockFeed", a.stockFeed);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment written to", path);
        console2.log("SwapRouter", a.swapRouter);
    }
}
