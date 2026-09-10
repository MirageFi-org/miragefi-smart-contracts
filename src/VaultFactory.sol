// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {AnchorVault} from "./AnchorVault.sol";

/// @title VaultFactory
/// @notice Deploys one AnchorVault per listed token and is the registry the router resolves vaults from.
///         Opening a market is a governance action; the market's parameters live in the ParamController
///         and its oracle feed must be configured before the first fill can price.
contract VaultFactory {
    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleRouter public immutable oracle;
    address public immutable feeCollector;
    address public immutable quoteToken;

    /// @notice The SwapRouter, set once. Vaults resolve it here so the router can be deployed after the factory.
    address public router;

    mapping(address => address) public vaultOf;
    address[] public allMarkets;

    event RouterSet(address router);
    event MarketOpened(address indexed token, address vault);

    error NotGovernance();
    error RouterAlreadySet();
    error RouterNotSet();
    error MarketExists();
    error MarketNotConfigured();
    error QuoteAssetNotListable();
    error ZeroAddress();

    modifier onlyGovernance() {
        if (msg.sender != params.owner()) revert NotGovernance();
        _;
    }

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        IOracleRouter oracle_,
        address feeCollector_,
        address quoteToken_
    ) {
        if (
            address(params_) == address(0) || address(eligibility_) == address(0) || address(oracle_) == address(0)
                || feeCollector_ == address(0) || quoteToken_ == address(0)
        ) revert ZeroAddress();
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        feeCollector = feeCollector_;
        quoteToken = quoteToken_;
    }

    /// @notice One-shot wiring of the router. Irreversible: replacing the router means a new deployment.
    function setRouter(address router_) external onlyGovernance {
        // Wiring is one-shot, so a zero router would brick the factory for good.
        if (router_ == address(0)) revert ZeroAddress();
        if (router != address(0)) revert RouterAlreadySet();
        router = router_;
        emit RouterSet(router_);
    }

    function createMarket(address token) external onlyGovernance returns (address vault) {
        if (router == address(0)) revert RouterNotSet();
        // Every swap is routed by which leg is the quote asset; a vault quoting the quote asset against
        // itself would be a market the router could never address.
        if (token == quoteToken) revert QuoteAssetNotListable();
        if (vaultOf[token] != address(0)) revert MarketExists();
        // A vault without market parameters or an oracle feed deploys fine and then refuses every
        // deposit and fill; require the wiring up front so a half-opened market cannot exist.
        if (!params.marketConfig(token).enabled) revert MarketNotConfigured();
        oracle.tokenDecimals(token); // reverts FeedNotConfigured until governance configures the feed
        string memory sym = IERC20Metadata(token).symbol();
        vault = address(
            new AnchorVault(
                params,
                eligibility,
                oracle,
                feeCollector,
                quoteToken,
                token,
                string.concat("MirageFi ", sym, " Vault"),
                string.concat("zv", sym)
            )
        );
        vaultOf[token] = vault;
        allMarkets.push(token);
        emit MarketOpened(token, vault);
    }

    function marketsLength() external view returns (uint256) {
        return allMarkets.length;
    }
}
