// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IPatientPassportRegistry
/// @author LockA Medical
/// @notice External interface for PatientPassportRegistry — consumed by the
///         orchestrator and sibling contracts for cross-contract validation.
interface IPatientPassportRegistry {

    // ── Enums ─────────────────────────────────────────────────────────────

    enum PassportStatus { Active, Suspended, Revoked }

    // ── View helpers ──────────────────────────────────────────────────────

    /// @notice Returns true iff the passport exists AND is Active.
    function isPassportActive(bytes32 passportId) external view returns (bool);

    /// @notice Returns the current status of a passport (reverts if not found).
    function getPassportStatus(bytes32 passportId) external view returns (PassportStatus);

    /// @notice Returns the wallet address that controls a given passport.
    function getPassportWallet(bytes32 passportId) external view returns (address);

    /// @notice Returns the passportId registered to a wallet (bytes32(0) if none).
    function getPassportIdByWallet(address wallet) external view returns (bytes32);

    /// @notice Returns true iff `wallet` owns an active passport.
    function isWalletRegistered(address wallet) external view returns (bool);
}
