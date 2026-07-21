// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types} from "../libraries/Types.sol";

/// @title IOracleRouter
/// @notice Single entry point for every price in the protocol.
interface IOracleRouter {
    struct Quote {
        /// @dev Quote-token base units per one whole listed token.
        uint256 price;
        uint64 updatedAt;
        Types.Session session;
        /// @dev True when the market is paused (move cap, manual, or `oraclePaused()` on the source).
        bool paused;
        /// @dev True when the price is older than the session's staleness bound.
        bool stale;
        /// @dev ERC-8056 `uiMultiplier()` if the token exposes it, else 1e18.
        uint256 multiplier;
        /// @dev True during the post-outage sequencer grace period.
        bool sequencerGrace;
    }

    error PriceInvalid(address token);
    error FeedNotConfigured(address token);

    function quote(address token) external view returns (Quote memory);
    /// @notice Refresh the move-cap checkpoint. Pauses the market if the price moved more than the cap.
    function refresh(address token) external returns (Quote memory);
    function verifyStreamReport(address token, bytes calldata report) external returns (uint256 price);
    function tokenDecimals(address token) external view returns (uint8);
    function hasStream(address token) external view returns (bool);
}
