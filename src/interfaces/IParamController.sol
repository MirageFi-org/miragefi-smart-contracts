// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IParamController
/// @notice Read interface for every tunable protocol parameter.
interface IParamController {
    /// @notice Pricing parameters shared by every market in a tier. Spreads are half-spreads in basis
    ///         points around the oracle mid; the oracle band is the hard bound no fill may cross.
    struct TierConfig {
        uint16 baseHalfSpreadBps;
        uint16 maxSkewBps;
        /// @dev Maximum drift of the token share of vault value from the 50% target, in bps of value.
        uint16 inventoryBandBps;
        /// @dev Hard bound on any fill's distance from the guarded mid, vault and RFQ alike.
        uint16 oracleBandBps;
        /// @dev Largest single swap against the vault in the regular session, quote-token notional.
        uint128 maxClip;
        bool enabled;
    }

    struct MarketConfig {
        uint8 tier;
        /// @dev Per-UTC-day volume ceiling during the guarded launch, quote-token notional.
        uint128 dailyVolumeCap;
        /// @dev Cap on total vault value during the guarded launch, quote-token units.
        uint128 tvlCap;
        bool enabled;
    }

    /// @notice Session multipliers, in bps of the base value (10_000 = x1.0).
    struct RegimeParams {
        uint16 extendedSpreadMulBps;
        uint16 closedSpreadMulBps;
        uint16 extendedClipMulBps;
        uint16 closedClipMulBps;
    }

    struct RiskParams {
        /// @dev Trading stays halted for this long after the sequencer comes back from an outage.
        uint32 sequencerGrace;
    }

    struct FeeParams {
        /// @dev Charged on every vault fill, itemised on the ticket.
        uint16 swapFeeBps;
        /// @dev Charged on every RFQ fill, deducted from the quote-token leg.
        uint16 rfqFeeBps;
        /// @dev The protocol's share of the vault's realised spread.
        uint16 spreadShareBps;
    }

    function owner() external view returns (address);
    function guardian() external view returns (address);

    function tierConfig(uint8 tier) external view returns (TierConfig memory);
    function marketConfig(address token) external view returns (MarketConfig memory);
    function regimeParams() external view returns (RegimeParams memory);
    function riskParams() external view returns (RiskParams memory);
    function feeParams() external view returns (FeeParams memory);
    function attestationIssuer(address issuer) external view returns (bool);
    function eligibilityAdapter() external view returns (address);
    function swapsPaused() external view returns (bool);
}
