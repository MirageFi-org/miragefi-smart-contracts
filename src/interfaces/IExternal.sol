// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal Chainlink aggregator interface (price feeds and the L2 Sequencer Uptime Feed).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice ERC-8056 corporate-action interface exposed by Robinhood Stock Tokens.
interface IERC8056 {
    /// @return Shares per token, 18 decimals. Reflects reinvested dividends and splits.
    function uiMultiplier() external view returns (uint256);
}

/// @notice Optional pause source (corporate action in progress). May be the token or a feed wrapper.
interface IOraclePauseSource {
    function oraclePaused() external view returns (bool);
}

/// @notice Optional market-status source mirroring the Chainlink Data Streams v11 RWA `marketStatus` field.
interface IMarketStatusSource {
    /// @return status 1 = regular session, 2 = extended hours, 5 = closed (Chainlink convention).
    function marketStatus() external view returns (uint8 status);
}

/// @notice Adapter that verifies a Chainlink Data Streams report on-chain and returns a price.
interface IStreamAdapter {
    /// @param report Signed report payload for the configured stream.
    /// @return price Price in the same units as the feed answer (feed decimals).
    /// @return observedAt Report timestamp.
    function verify(address collateralToken, bytes calldata report) external returns (uint256 price, uint256 observedAt);
}
