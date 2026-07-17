// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Types
/// @notice Shared structs, enums and constants for the MirageFi protocol.
library Types {
    // ---------------------------------------------------------------------
    // Enums
    // ---------------------------------------------------------------------

    /// @notice State of the underlying market as classified by the oracle router. The vault derives its
    ///         trading regime from this: spreads widen and clips shrink outside the regular session.
    enum Session {
        Regular,
        Extended,
        Closed
    }

    /// @notice Which venue filled a swap.
    enum Venue {
        Vault,
        Rfq
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// @dev Every vault targets a 50/50 split of value between the listed token and the quote asset.
    uint256 internal constant TARGET_RATIO_BPS = 5_000;

    // ---------------------------------------------------------------------
    // Signed messages
    // ---------------------------------------------------------------------

    /// @notice An EIP-712 signed maker quote for the RFQ lane. Free to sign and cancel; consumed at settlement.
    ///         Exactly one of `tokenIn` and `tokenOut` must be the quote asset.
    struct MakerQuote {
        address maker;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        /// @dev The trader this quote is reserved for, or zero for an open quote.
        address taker;
        uint40 expiry;
        uint256 nonce;
    }

    // ---------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------

    /// @notice The itemised decomposition of a vault quote. Emitted with every fill so the on-chain record
    ///         carries the same breakdown the ticket showed.
    struct Breakdown {
        /// @dev Quote-token base units per one whole listed token, from the guarded oracle.
        uint256 mid;
        /// @dev The regime-adjusted half-spread applied to this side, after the skew term.
        uint16 halfSpreadBps;
        /// @dev Signed inventory skew term. Positive means the vault is long of the token.
        int16 skewBps;
        /// @dev Protocol fee applied to this fill.
        uint16 feeBps;
        Session session;
    }
}

/// @title Roles
/// @notice Eligibility roles checked by the registry.
library Roles {
    bytes32 internal constant TRADER = keccak256("miragefi.role.TRADER");
    bytes32 internal constant LP = keccak256("miragefi.role.LP");
    bytes32 internal constant MAKER = keccak256("miragefi.role.MAKER");
    bytes32 internal constant RELAYER = keccak256("miragefi.role.RELAYER");
}
