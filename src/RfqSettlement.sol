// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "./libraries/Types.sol";

/// @title RfqSettlement
/// @notice Atomic settlement of maker quotes. Makers sign EIP-712 quotes off-chain for free; the winning
///         quote settles here in one transaction: input to the maker, output to the trader, fee to the
///         collector. Assets move directly between maker and taker wallets; nothing rests here.
/// @dev Every fill is bounded by the market's oracle band, so a compromised maker key can at worst fill
///      inside the band, the same worst case as an aggressive but honest maker. Quote cancellation is
///      never pausable. Smart-account makers are supported through EIP-1271.
contract RfqSettlement is EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "MakerQuote(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,"
        "address taker,uint40 expiry,uint256 nonce)"
    );

    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleRouter public immutable oracle;
    VaultFactory public immutable factory;
    address public immutable feeCollector;
    address public immutable quoteToken;

    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    event RfqFilled(
        address indexed maker,
        address indexed taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 netOut,
        uint256 fee,
        uint256 mid
    );
    event NonceCancelled(address indexed maker, uint256 nonce);

    error NotRouter();
    error QuoteExpired();
    error WrongTaker();
    error NonceAlreadyUsed();
    error BadSignature();
    error QuoteAssetRequired();
    error MarketNotListed();
    error MarketHalted();
    error BandExceeded(uint256 implied, uint256 mid);
    error ZeroAmount();
    error ZeroAddress();

    modifier onlyRouter() {
        if (msg.sender != factory.router()) revert NotRouter();
        _;
    }

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        IOracleRouter oracle_,
        VaultFactory factory_,
        address feeCollector_
    ) EIP712("MirageFi", "1") {
        if (
            address(params_) == address(0) || address(eligibility_) == address(0) || address(oracle_) == address(0)
                || feeCollector_ == address(0)
        ) revert ZeroAddress();
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        factory = factory_;
        feeCollector = feeCollector_;
        quoteToken = factory_.quoteToken();
    }

    function quoteDigest(Types.MakerQuote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH, q.maker, q.tokenIn, q.tokenOut, q.amountIn, q.amountOut, q.taker, q.expiry, q.nonce
                )
            )
        );
    }

    /// @notice Settle a maker quote for `taker`, delivering the output to `to`. Router only: the router
    ///         has already checked the taker's eligibility and holds the input asset.
    function settle(Types.MakerQuote calldata q, bytes calldata signature, address taker, address to)
        external
        onlyRouter
        returns (uint256 netOut)
    {
        if (q.amountIn == 0 || q.amountOut == 0) revert ZeroAmount();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (q.taker != address(0) && q.taker != taker) revert WrongTaker();
        if (nonceUsed[q.maker][q.nonce]) revert NonceAlreadyUsed();
        nonceUsed[q.maker][q.nonce] = true;

        if (!SignatureChecker.isValidSignatureNow(q.maker, quoteDigest(q), signature)) revert BadSignature();
        eligibility.requireRole(q.maker, Roles.MAKER);

        // Exactly one leg is the quote asset; the other names the market whose guards apply.
        bool buyBase = q.tokenIn == quoteToken;
        if (buyBase == (q.tokenOut == quoteToken)) revert QuoteAssetRequired();
        address base = buyBase ? q.tokenOut : q.tokenIn;

        uint256 mid = _bandCheckedMid(base, buyBase ? q.amountIn : q.amountOut, buyBase ? q.amountOut : q.amountIn);

        uint256 fee;
        if (buyBase) {
            // The fee is deducted from the quote-token leg; makers quote gross and price it in.
            fee = q.amountIn * params.feeParams().rfqFeeBps / Types.BPS;
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, q.maker, q.amountIn - fee);
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, feeCollector, fee);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, to, q.amountOut);
            netOut = q.amountOut;
        } else {
            fee = q.amountOut * params.feeParams().rfqFeeBps / Types.BPS;
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, q.maker, q.amountIn);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, to, q.amountOut - fee);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, feeCollector, fee);
            netOut = q.amountOut - fee;
        }

        emit RfqFilled(q.maker, taker, q.tokenIn, q.tokenOut, q.amountIn, netOut, fee, mid);
    }

    /// @notice Invalidate quotes by nonce. Callable by the maker at any time, pause or no pause, and
    ///         reachable through the L1 delayed inbox against a censoring sequencer.
    function cancel(uint256[] calldata nonces) external {
        for (uint256 i = 0; i < nonces.length; i++) {
            // Skip nonces already consumed or cancelled, so the event stream records only real state
            // changes and never a "cancellation" of a quote that had already settled.
            if (nonceUsed[msg.sender][nonces[i]]) continue;
            nonceUsed[msg.sender][nonces[i]] = true;
            emit NonceCancelled(msg.sender, nonces[i]);
        }
    }

    /// @dev The same halt conditions as the vault path, plus the hard band: whatever a maker signed,
    ///      a fill more than the band away from the guarded mid does not settle.
    function _bandCheckedMid(address base, uint256 quoteAmount, uint256 baseAmount) internal view returns (uint256) {
        IParamController.MarketConfig memory mkt = params.marketConfig(base);
        if (!mkt.enabled) revert MarketNotListed();
        IOracleRouter.Quote memory oq = oracle.quote(base);
        if (oq.paused || oq.stale || oq.sequencerGrace) revert MarketHalted();

        uint256 implied = quoteAmount * 10 ** oracle.tokenDecimals(base) / baseAmount;
        uint256 diff = implied > oq.price ? implied - oq.price : oq.price - implied;
        if (diff * Types.BPS / oq.price > params.tierConfig(mkt.tier).oracleBandBps) {
            revert BandExceeded(implied, oq.price);
        }
        return oq.price;
    }
}
