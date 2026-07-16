// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IMedicalRecordRegistry
/// @author LockA Medical
/// @notice External interface for MedicalRecordRegistry — consumed by the
///         orchestrator for cross-contract queries.
interface IMedicalRecordRegistry {

    // ── Enums ─────────────────────────────────────────────────────────────

    enum RecordStatus { Active, Amended, Revoked }

    // ── View helpers ──────────────────────────────────────────────────────

    /// @notice Returns true iff the record exists and is Active or Amended.
    function isRecordValid(bytes32 recordId) external view returns (bool);

    /// @notice Returns the current status of a record.
    function getRecordStatus(bytes32 recordId) external view returns (RecordStatus);

    /// @notice Returns the passportId associated with a record.
    function getRecordPassportId(bytes32 recordId) external view returns (bytes32);

    /// @notice Returns the providerId associated with a record.
    function getRecordProviderId(bytes32 recordId) external view returns (bytes32);

    /// @notice Returns all recordIds for a given passportId.
    function getPatientRecordIds(bytes32 passportId) external view returns (bytes32[] memory);

    /// @notice Returns all recordIds issued by a given providerId.
    function getProviderRecordIds(bytes32 providerId) external view returns (bytes32[] memory);
}
