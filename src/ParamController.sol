// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IParamController} from "./interfaces/IParamController.sol";
import {Types} from "./libraries/Types.sol";

/// @title ParamController
/// @notice Holds every tunable protocol parameter behind a timelock. Every change emits an event.
/// @dev Governance flow: `schedule(calls, rationale)` -> wait `delay` -> `execute(calls, salt)`.
///      Setters are `onlySelf`, so they can only run through `execute`. During bootstrap the owner may
///      call setters directly; `finishBootstrap()` is irreversible and locks the controller to the timelock.
///      The guardian can only pause swaps. Nothing here can move funds or gate a vault withdrawal.
contract ParamController is IParamController {
    // ---------------------------------------------------------------------
    // Governance state
    // ---------------------------------------------------------------------

    address public override owner;
    address public override guardian;
    address public pendingOwner;
    uint256 public delay;
    bool public bootstrapped;

    struct Operation {
        uint64 eta;
        bool executed;
        bool cancelled;
        bytes32 rationale;
    }

    mapping(bytes32 => Operation) public operations;

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------

    mapping(uint8 => TierConfig) internal _tiers;
    mapping(address => MarketConfig) internal _markets;
    mapping(address => bool) public override attestationIssuer;
    address public override eligibilityAdapter;
    bool public override swapsPaused;

    RegimeParams internal _regimeParams;
    RiskParams internal _riskParams;
    FeeParams internal _feeParams;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event OperationScheduled(bytes32 indexed id, uint64 eta, bytes32 rationale, bytes[] calls);
    event OperationExecuted(bytes32 indexed id);
    event OperationCancelled(bytes32 indexed id);
    event ParamChanged(bytes32 indexed key, bytes32 indexed subject, bytes value);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event GuardianChanged(address indexed guardian);
    event DelayChanged(uint256 delay);
    event BootstrapFinished();
    event EmergencyPause(bool swapsPaused, address indexed by);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotGuardian();
    error NotSelf();
    error NotPendingOwner();
    error AlreadyBootstrapped();
    error OperationExists();
    error OperationNotReady();
    error OperationNotFound();
    error CallFailed(uint256 index, bytes reason);
    error InvalidBps();
    error InvalidTier();
    error DelayTooShort();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Setters run through `execute` once bootstrapped; the owner may call them directly before that.
    modifier onlySelf() {
        if (bootstrapped) {
            if (msg.sender != address(this)) revert NotSelf();
        } else {
            if (msg.sender != owner && msg.sender != address(this)) revert NotOwner();
        }
        _;
    }

    constructor(address owner_, address guardian_, uint256 delay_) {
        // A zero guardian just means no guardian; a zero owner is a controller nobody can ever govern.
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        guardian = guardian_;
        delay = delay_;
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
        emit DelayChanged(delay_);
    }

    // ---------------------------------------------------------------------
    // Timelock
    // ---------------------------------------------------------------------

    function operationId(bytes[] calldata calls, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(calls, salt));
    }

    /// @notice Schedule a batch of setter calls. `rationale` is the hash of the published rationale.
    function schedule(bytes[] calldata calls, bytes32 salt, bytes32 rationale) external onlyOwner returns (bytes32 id) {
        id = operationId(calls, salt);
        // A cancelled batch may be scheduled again under the same salt; only a pending or executed
        // operation holds its id.
        if (operations[id].eta != 0 && !operations[id].cancelled) revert OperationExists();
        uint64 eta = uint64(block.timestamp + delay);
        operations[id] = Operation({eta: eta, executed: false, cancelled: false, rationale: rationale});
        emit OperationScheduled(id, eta, rationale, calls);
    }

    /// @notice Execute a scheduled batch once its timelock has elapsed.
    function execute(bytes[] calldata calls, bytes32 salt) external onlyOwner {
        bytes32 id = operationId(calls, salt);
        Operation storage op = operations[id];
        if (op.eta == 0 || op.cancelled || op.executed) revert OperationNotFound();
        if (block.timestamp < op.eta) revert OperationNotReady();
        op.executed = true;
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory reason) = address(this).call(calls[i]);
            if (!ok) revert CallFailed(i, reason);
        }
        emit OperationExecuted(id);
    }

    function cancel(bytes32 id) external onlyOwner {
        Operation storage op = operations[id];
        if (op.eta == 0 || op.executed || op.cancelled) revert OperationNotFound();
        op.cancelled = true;
        emit OperationCancelled(id);
    }

    /// @notice Lock the controller to the timelock. Irreversible.
    function finishBootstrap() external onlyOwner {
        if (bootstrapped) revert AlreadyBootstrapped();
        bootstrapped = true;
        emit BootstrapFinished();
    }

    // ---------------------------------------------------------------------
    // Ownership and guardian
    // ---------------------------------------------------------------------

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setGuardian(address guardian_) external onlySelf {
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    function setDelay(uint256 delay_) external onlySelf {
        if (bootstrapped && delay_ < 1 hours) revert DelayTooShort();
        delay = delay_;
        emit DelayChanged(delay_);
    }

    // ---------------------------------------------------------------------
    // Emergency pause: swaps only. Deposits, withdrawals and RFQ cancellation are never pausable.
    // The guardian can only engage the pause; clearing it is an owner action.
    // ---------------------------------------------------------------------

    function setPaused(bool swaps) external {
        if (msg.sender != guardian && msg.sender != owner && msg.sender != address(this)) revert NotGuardian();
        // The guardian's power is one-way: it can stop trading instantly but never restart it, so a
        // compromised guardian key cannot lift a pause in the middle of an incident.
        if (!swaps && msg.sender == guardian) revert NotOwner();
        swapsPaused = swaps;
        emit EmergencyPause(swaps, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Setters (timelocked)
    // ---------------------------------------------------------------------

    function setTierConfig(uint8 tier, TierConfig calldata cfg) external onlySelf {
        if (tier == 0) revert InvalidTier();
        // The oracle band is the outer bound: base spread plus full skew must fit inside it, the
        // inventory band must leave a target on both sides, and nothing may exceed 100%.
        if (
            cfg.oracleBandBps > Types.BPS || cfg.inventoryBandBps > Types.TARGET_RATIO_BPS
                || (cfg.enabled && cfg.inventoryBandBps == 0)
                || uint256(cfg.baseHalfSpreadBps) + cfg.maxSkewBps > cfg.oracleBandBps
        ) revert InvalidBps();
        _tiers[tier] = cfg;
        emit ParamChanged("tier", bytes32(uint256(tier)), abi.encode(cfg));
    }

    function setMarketConfig(address token, MarketConfig calldata cfg) external onlySelf {
        if (cfg.enabled && !_tiers[cfg.tier].enabled) revert InvalidTier();
        _markets[token] = cfg;
        emit ParamChanged("market", bytes32(uint256(uint160(token))), abi.encode(cfg));
    }

    function setRegimeParams(RegimeParams calldata p) external onlySelf {
        // Session multipliers widen spreads and shrink clips, never the reverse.
        if (
            p.extendedSpreadMulBps < Types.BPS || p.closedSpreadMulBps < p.extendedSpreadMulBps
                || p.extendedClipMulBps > Types.BPS || p.closedClipMulBps > p.extendedClipMulBps
        ) revert InvalidBps();
        _regimeParams = p;
        emit ParamChanged("regimeParams", bytes32(0), abi.encode(p));
    }

    function setRiskParams(RiskParams calldata p) external onlySelf {
        _riskParams = p;
        emit ParamChanged("riskParams", bytes32(0), abi.encode(p));
    }

    function setFeeParams(FeeParams calldata p) external onlySelf {
        if (p.swapFeeBps > Types.BPS || p.rfqFeeBps > Types.BPS || p.spreadShareBps > Types.BPS) revert InvalidBps();
        _feeParams = p;
        emit ParamChanged("feeParams", bytes32(0), abi.encode(p));
    }

    function setAttestationIssuer(address issuer, bool ok) external onlySelf {
        attestationIssuer[issuer] = ok;
        emit ParamChanged("attestationIssuer", bytes32(uint256(uint160(issuer))), abi.encode(ok));
    }

    function setEligibilityAdapter(address adapter) external onlySelf {
        eligibilityAdapter = adapter;
        emit ParamChanged("eligibilityAdapter", bytes32(uint256(uint160(adapter))), "");
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function tierConfig(uint8 tier) external view override returns (TierConfig memory) {
        return _tiers[tier];
    }

    function marketConfig(address token) external view override returns (MarketConfig memory) {
        return _markets[token];
    }

    function regimeParams() external view override returns (RegimeParams memory) {
        return _regimeParams;
    }

    function riskParams() external view override returns (RiskParams memory) {
        return _riskParams;
    }

    function feeParams() external view override returns (FeeParams memory) {
        return _feeParams;
    }
}
