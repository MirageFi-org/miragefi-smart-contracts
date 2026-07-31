// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IEligibilityAdapter} from "../interfaces/IEligibilityRegistry.sol";
import {IParamController} from "../interfaces/IParamController.sol";

/// @title NativeAttestationAdapter
/// @notice A self-contained attestation store with EAS-compatible semantics, used where an EAS deployment
///         is not yet available (Robinhood Chain testnet). Attestations carry role, jurisdiction class,
///         investor class and expiry. No personal data is stored. Issuers are whitelisted through the
///         ParamController and may be KYC providers or their signing services.
contract NativeAttestationAdapter is IEligibilityAdapter {
    struct Attestation {
        bytes32 uid;
        address issuer;
        bytes2 jurisdictionClass;
        uint8 investorClass;
        uint64 issuedAt;
        uint64 expiry;
        bool revoked;
    }

    IParamController public immutable params;
    uint256 public nonce;

    mapping(address => mapping(bytes32 => Attestation)) internal _attestations;

    event Attested(
        address indexed account,
        bytes32 indexed role,
        bytes32 uid,
        address indexed issuer,
        bytes2 jurisdictionClass,
        uint8 investorClass,
        uint64 expiry
    );
    event Revoked(address indexed account, bytes32 indexed role, bytes32 uid, address indexed issuer);

    error NotIssuer();
    error BadExpiry();
    error NotAttested();

    modifier onlyIssuer() {
        if (!params.attestationIssuer(msg.sender)) revert NotIssuer();
        _;
    }

    constructor(IParamController params_) {
        params = params_;
    }

    /// @notice Issue or renew an attestation. Renewal overwrites the previous record.
    function attest(address account, bytes32 role, bytes2 jurisdictionClass, uint8 investorClass, uint64 expiry)
        external
        onlyIssuer
        returns (bytes32 uid)
    {
        if (expiry <= block.timestamp) revert BadExpiry();
        uid = keccak256(abi.encodePacked(account, role, msg.sender, ++nonce, block.chainid));
        _attestations[account][role] = Attestation({
            uid: uid,
            issuer: msg.sender,
            jurisdictionClass: jurisdictionClass,
            investorClass: investorClass,
            issuedAt: uint64(block.timestamp),
            expiry: expiry,
            revoked: false
        });
        emit Attested(account, role, uid, msg.sender, jurisdictionClass, investorClass, expiry);
    }

    /// @notice Revoke immediately. Any whitelisted issuer may revoke, so a compromised issuer can be overridden.
    function revoke(address account, bytes32 role) external onlyIssuer {
        Attestation storage a = _attestations[account][role];
        // Revoking a record that was never issued would write a ghost entry and emit a zero uid,
        // polluting the audit trail; an issuer typo should fail loudly instead.
        if (a.uid == bytes32(0)) revert NotAttested();
        a.revoked = true;
        emit Revoked(account, role, a.uid, msg.sender);
    }

    function isEligible(address account, bytes32 role) external view override returns (bool) {
        Attestation storage a = _attestations[account][role];
        return a.uid != bytes32(0) && !a.revoked && a.expiry > block.timestamp && params.attestationIssuer(a.issuer);
    }

    function attestationOf(address account, bytes32 role) external view override returns (bytes32 uid, uint64 expiry) {
        Attestation storage a = _attestations[account][role];
        return (a.uid, a.expiry);
    }

    function attestation(address account, bytes32 role) external view returns (Attestation memory) {
        return _attestations[account][role];
    }
}
