// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {AnchorVault} from "./AnchorVault.sol";
import {RfqSettlement} from "./RfqSettlement.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "./libraries/Types.sol";

/// @title SwapRouter
/// @notice The sole trader entry point. Checks eligibility, compares the anchor vault against an optional
///         maker quote, settles whichever prices better for the trader, and composes token-to-token swaps
///         as two atomic legs through the quote asset. The comparison is on-chain and exact: the vault
///         quote is re-derived from oracle and vault state in the same transaction and the maker quote is
///         verified by signature, so a front-end cannot route a trade to a worse price than the vault's.
contract SwapRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    VaultFactory public immutable factory;
    RfqSettlement public immutable rfq;
    address public immutable quoteToken;

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        /// @dev Recipient; zero means the trader.
        address to;
        uint256 deadline;
        /// @dev Optional RFQ candidate for a single-leg swap; `quote.maker == address(0)` means none.
        Types.MakerQuote quote;
        bytes quoteSig;
    }

    event Swapped(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Types.Venue venue
    );

    error Expired();
    error SwapsPaused();
    error SameToken();
    error ZeroAmount();
    error NoLiquidity();
    error Slippage(uint256 amountOut, uint256 minAmountOut);
    error QuoteMismatch();
    error QuoteNotApplicable();
    error ZeroAddress();

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        VaultFactory factory_,
        RfqSettlement rfq_
    ) {
        // The factory is exercised right below by quoteToken(); the rest would only fail at first use.
        if (address(params_) == address(0) || address(eligibility_) == address(0) || address(rfq_) == address(0)) {
            revert ZeroAddress();
        }
        params = params_;
        eligibility = eligibility_;
        factory = factory_;
        rfq = rfq_;
        quoteToken = factory_.quoteToken();
    }

    /// @notice Swap an exact input amount. The signed `minAmountOut` and `deadline` bound the fill; if
    ///         state moves so the fill would be worse than the bound, the swap reverts rather than fills.
    function swapExactIn(SwapParams calldata p) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert Expired();
        if (params.swapsPaused()) revert SwapsPaused();
        if (p.tokenIn == p.tokenOut) revert SameToken();
        if (p.amountIn == 0) revert ZeroAmount();
        eligibility.requireRole(msg.sender, Roles.TRADER);
        address to = p.to == address(0) ? msg.sender : p.to;
        if (to != msg.sender) eligibility.requireRole(to, Roles.TRADER);

        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);

        Types.Venue venue;
        if (p.tokenIn == quoteToken || p.tokenOut == quoteToken) {
            (amountOut, venue) = _bestLeg(p, p.tokenIn == quoteToken, to);
        } else {
            // Two legs through the quote asset, atomic end to end. RFQ candidates apply to single-leg
            // swaps only; a candidate here is a client error, surfaced rather than silently ignored.
            if (p.quote.maker != address(0)) revert QuoteNotApplicable();
            uint256 quoteOut = _vaultSwap(p.tokenIn, false, p.amountIn, address(this));
            amountOut = _vaultSwap(p.tokenOut, true, quoteOut, to);
            venue = Types.Venue.Vault;
        }

        if (amountOut < p.minAmountOut) revert Slippage(amountOut, p.minAmountOut);
        emit Swapped(msg.sender, p.tokenIn, p.tokenOut, p.amountIn, amountOut, venue);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Price the vault and the optional maker candidate, settle the better one. A halted or absent
    ///      vault prices as zero rather than reverting, so RFQ can carry a market the vault cannot.
    function _bestLeg(SwapParams calldata p, bool buyToken, address to)
        internal
        returns (uint256 amountOut, Types.Venue venue)
    {
        address base = buyToken ? p.tokenOut : p.tokenIn;
        address vault = factory.vaultOf(base);

        uint256 vaultOut;
        if (vault != address(0)) {
            try AnchorVault(vault).quoteSwap(buyToken, p.amountIn) returns (uint256 out, Types.Breakdown memory) {
                vaultOut = out;
            } catch {}
        }

        uint256 rfqNet;
        if (p.quote.maker != address(0)) {
            if (p.quote.tokenIn != p.tokenIn || p.quote.tokenOut != p.tokenOut || p.quote.amountIn != p.amountIn) {
                revert QuoteMismatch();
            }
            // A candidate that expired in flight or was cancelled by its maker is a normal race, not a
            // client error: price it as absent so the vault can still carry the fill. A malformed or
            // badly signed candidate stays a loud revert in settlement.
            bool usable = block.timestamp <= p.quote.expiry && !rfq.nonceUsed(p.quote.maker, p.quote.nonce);
            if (usable) {
                // The RFQ fee comes off the quote-token leg: on a buy the maker receives it out of the
                // input, on a sell it is deducted from the trader's output. Compare what the trader
                // actually receives.
                rfqNet = buyToken
                    ? p.quote.amountOut
                    : p.quote.amountOut - p.quote.amountOut * params.feeParams().rfqFeeBps / Types.BPS;
            }
        }

        if (rfqNet > vaultOut) {
            IERC20(p.tokenIn).forceApprove(address(rfq), p.amountIn);
            amountOut = rfq.settle(p.quote, p.quoteSig, msg.sender, to);
            venue = Types.Venue.Rfq;
        } else if (vaultOut > 0) {
            amountOut = _vaultSwapAt(vault, buyToken, p.amountIn, to);
            venue = Types.Venue.Vault;
        } else {
            revert NoLiquidity();
        }
    }

    function _vaultSwap(address base, bool buyToken, uint256 amountIn, address to) internal returns (uint256) {
        address vault = factory.vaultOf(base);
        if (vault == address(0)) revert NoLiquidity();
        return _vaultSwapAt(vault, buyToken, amountIn, to);
    }

    function _vaultSwapAt(address vault, bool buyToken, uint256 amountIn, address to) internal returns (uint256) {
        IERC20(buyToken ? quoteToken : address(AnchorVault(vault).token())).forceApprove(vault, amountIn);
        return AnchorVault(vault).swap(buyToken, amountIn, to);
    }
}
