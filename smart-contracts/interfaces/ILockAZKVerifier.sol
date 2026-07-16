// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ILockAZKVerifier
/// @author LockA Medical
/// @notice External interface for LockAZKVerifier — consumed by the
///         orchestrator and tests for cross-contract ZK claim validation.
///
/// @dev    Pragma updated from ^0.8.34 → ^0.8.20 to align with the
///         implementing contract and the OpenZeppelin v5 minimum floor.
///         (FIX P-8)
///
///         pause() / unpause() / paused() are now declared here so that
///         orchestrators and test harnesses can call them through the
///         interface without an unsafe cast to the concrete type. (FIX P-9)
interface ILockAZKVerifier {

    // =========================================================================
    //  Enums
    // =========================================================================

    /// @notice Categories of zero-knowledge proof claims supported by the verifier.
    enum ClaimType {
        IdentityVerification,
        AgeEligibility,
        InsuranceEligibility,
        CredentialAuthenticity,
        ProviderLicenseValidity,
        MedicalClearance,
        PrescriptionAuthorization,
        DataIntegrity
    }

    /// @notice Lifecycle states of a recorded claim.
    enum ClaimStatus { Verified, Expired, Revoked }

    // =========================================================================
    //  View helpers — claim queries
    // =========================================================================

    /**
     * @notice Returns true iff the passport has at least one active,
     *         non-expired verified claim of the given type.
     * @param passportId The patient passport identifier.
     * @param claimType  The category of claim to check.
     */
    function hasActiveClaim(bytes32 passportId, ClaimType claimType) external view returns (bool);

    /**
     * @notice Returns the current status of a claim.
     * @param claimId The claim identifier.
     */
    function getClaimStatus(bytes32 claimId) external view returns (ClaimStatus);

    /**
     * @notice Returns all claimIds recorded for a given passport.
     * @param passportId The patient passport identifier.
     */
    function getPassportClaimIds(bytes32 passportId) external view returns (bytes32[] memory);

    /**
     * @notice Returns true iff a passport has a valid, non-expired
     *         IdentityVerification claim.
     * @param passportId The patient passport identifier.
     */
    function isIdentityVerified(bytes32 passportId) external view returns (bool);

    // =========================================================================
    //  View helpers — Pausable state  (FIX P-4, P-9)
    // =========================================================================

    /**
     * @notice Returns true if the contract is currently paused.
     * @dev    Delegates to OZ {Pausable-paused}. Exposed here so orchestrators
     *         and test harnesses can query pause state through this interface
     *         without casting to the concrete implementation type.
     */
    function paused() external view returns (bool);

    // =========================================================================
    //  Admin — Emergency Controls  (FIX P-9)
    // =========================================================================

    /**
     * @notice Pauses all state-changing operations.
     * @dev    Only callable by the contract owner.
     *         Emits `Paused(address account)` (from OZ {Pausable}).
     *         Reverts with `EnforcedPause()` if already paused.
     */
    function pause() external;

    /**
     * @notice Unpauses the contract, resuming all normal operations.
     * @dev    Only callable by the contract owner.
     *         Emits `Unpaused(address account)` (from OZ {Pausable}).
     *         Reverts with `ExpectedPause()` if not currently paused.
     */
    function unpause() external;
}
