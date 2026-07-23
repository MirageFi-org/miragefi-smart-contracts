// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IEligibilityAdapter
/// @notice Policy engine behind the registry. EAS, ONCHAINID or Chainlink ACE can implement this.
interface IEligibilityAdapter {
    function isEligible(address account, bytes32 role) external view returns (bool);
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}

/// @title IEligibilityRegistry
/// @notice Checked on every swap, deposit, RFQ settlement and vault share transfer. Withdrawal is never
///         gated: exiting a vault is a property of holding shares, not a permission.
interface IEligibilityRegistry {
    error NotEligible(address account, bytes32 role);

    function isEligible(address account, bytes32 role) external view returns (bool);
    function requireRole(address account, bytes32 role) external view;
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}
