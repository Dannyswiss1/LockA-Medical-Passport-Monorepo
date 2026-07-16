// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IConsentAccessManager
/// @author LockA Medical
/// @notice External interface for ConsentAccessManager — consumed by the
///         orchestrator for cross-contract consent validation.
interface IConsentAccessManager {

    // ── Enums ─────────────────────────────────────────────────────────────

    enum AccessStatus { Pending, Approved, Rejected, Revoked, Expired }

    // ── View helpers ──────────────────────────────────────────────────────

    /// @notice Returns true iff the provider has an active, non-expired Approved
    ///         access grant for the given patient passport.
    function hasActiveAccess(bytes32 passportId, bytes32 providerId) external view returns (bool);

    /// @notice Returns the current status of an access permission.
    function getAccessStatus(bytes32 accessId) external view returns (AccessStatus);

    /// @notice Returns all accessIds for a given passportId.
    function getPatientAccessIds(bytes32 passportId) external view returns (bytes32[] memory);

    /// @notice Returns all accessIds for a given providerId.
    function getProviderAccessIds(bytes32 providerId) external view returns (bytes32[] memory);
}
