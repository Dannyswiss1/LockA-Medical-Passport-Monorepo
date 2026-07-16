// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IPatientPassportRegistry.sol";
import "./interfaces/IProviderRegistry.sol";
import "./interfaces/IMedicalRecordRegistry.sol";
import "./interfaces/IConsentAccessManager.sol";
import "./interfaces/ILockAZKVerifier.sol";

/**
 * @title LockAOrchestrator
 * @author LockA Medical
 * @notice Central orchestrator for the LockA Medical platform.
 *         Validates IDs across all registries and provides composite cross-registry
 *         queries that individual contracts cannot satisfy alone.
 *
 * @dev This contract holds references to all five core contracts and exposes:
 *
 *      ── Composite Validation Queries ────────────────────────────────────────
 *      1. {validatePatient}         — passport active + identity ZK claim verified.
 *      2. {validateProvider}        — provider verified + license ZK claim verified.
 *      3. {validateRecordAccess}    — patient active + provider verified + active consent.
 *      4. {validateRecordIntegrity} — record valid + issuing provider still verified.
 *      5. {validateFullInteraction} — all of the above in one call.
 *
 *      ── ID Cross-Registry Lookups ────────────────────────────────────────────
 *      6. {getPatientSummary}  — passport status + ZK identity claim status.
 *      7. {getProviderSummary} — provider status + ZK license claim status.
 *      8. {getAccessSummary}   — consent status + underlying passport/provider status.
 *
 *      ── Admin ────────────────────────────────────────────────────────────────
 *      - Owner can update any registry address (e.g., after an upgrade).
 *      - Owner can pause/unpause the orchestrator (does NOT affect sub-contracts).
 *
 *      Security model:
 *        - All validation functions are view-only; the orchestrator never mutates
 *          sub-contract state directly.
 *        - The orchestrator is registered as the trusted `orchestrator` address in
 *          PatientPassportRegistry and ProviderRegistry post-deployment.
 *        - ReentrancyGuard is included for future-proofing if state-changing
 *          orchestration functions are added.
 *
 *      Deployment order:
 *        1. ENSResolverHelper
 *        2. PatientPassportRegistry(owner, ensResolver)
 *        3. ProviderRegistry(owner, ensResolver)
 *        4. MedicalRecordRegistry(owner, patientRegistry, providerRegistry)
 *        5. ConsentAccessManager(owner, patientRegistry, providerRegistry)
 *        6. LockAZKVerifier(owner, zkVerifyAggregation, patientRegistry)
 *        7. LockAOrchestrator(owner, all 5 above)
 *        8. patientRegistry.setOrchestrator(orchestrator)
 *        9. providerRegistry.setOrchestrator(orchestrator)
 *
 *      Deployed on: Base (Ethereum L2)
 */
contract LockAOrchestrator is Ownable, ReentrancyGuard, Pausable {

    // ──────────────────────────────────────────────────────────────────────
    //  Registry References
    // ──────────────────────────────────────────────────────────────────────

    /// @notice The patient passport registry.
    IPatientPassportRegistry public patientRegistry;

    /// @notice The provider registry.
    IProviderRegistry public providerRegistry;

    /// @notice The medical record registry.
    IMedicalRecordRegistry public recordRegistry;

    /// @notice The consent access manager.
    IConsentAccessManager public consentManager;

    /// @notice The ZK verifier.
    ILockAZKVerifier public zkVerifier;

    // ──────────────────────────────────────────────────────────────────────
    //  Structs — Composite Results
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Aggregated status of a patient across all registries.
    struct PatientSummary {
        bytes32 passportId;
        IPatientPassportRegistry.PassportStatus passportStatus;
        bool isPassportActive;
        bool isIdentityZKVerified;
        bool hasInsuranceZKClaim;
    }

    /// @notice Aggregated status of a provider across all registries.
    struct ProviderSummary {
        bytes32 providerId;
        IProviderRegistry.ProviderStatus providerStatus;
        bool isVerified;
        bool hasLicenseZKClaim;
    }

    /// @notice Aggregated status of an access permission.
    struct AccessSummary {
        bytes32 accessId;
        IConsentAccessManager.AccessStatus accessStatus;
        bool isAccessActive;
        bool isPatientActive;
        bool isProviderVerified;
    }

    /// @notice Result of a full interaction validation.
    struct InteractionValidation {
        bool isValid;
        bool patientActive;
        bool patientIdentityVerified;
        bool providerVerified;
        bool hasConsent;
        bool recordValid;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────

    event RegistryAddressesUpdated(
        address indexed patientRegistry,
        address indexed providerRegistry,
        address indexed recordRegistry,
        address consentManager,
        address zkVerifier
    );

    // ──────────────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────────────

    error ZeroAddressNotAllowed();
    error InvalidPassportId();
    error InvalidProviderId();
    error InvalidRecordId();
    error InvalidAccessId();

    // ──────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @param initialOwner      The address that will be set as the contract owner.
     * @param _patientRegistry  Address of PatientPassportRegistry.
     * @param _providerRegistry Address of ProviderRegistry.
     * @param _recordRegistry   Address of MedicalRecordRegistry.
     * @param _consentManager   Address of ConsentAccessManager.
     * @param _zkVerifier       Address of LockAZKVerifier.
     */
    constructor(
        address initialOwner,
        address _patientRegistry,
        address _providerRegistry,
        address _recordRegistry,
        address _consentManager,
        address _zkVerifier
    ) Ownable(initialOwner) {
        if (
            initialOwner      == address(0) ||
            _patientRegistry  == address(0) ||
            _providerRegistry == address(0) ||
            _recordRegistry   == address(0) ||
            _consentManager   == address(0) ||
            _zkVerifier       == address(0)
        ) revert ZeroAddressNotAllowed();

        patientRegistry  = IPatientPassportRegistry(_patientRegistry);
        providerRegistry = IProviderRegistry(_providerRegistry);
        recordRegistry   = IMedicalRecordRegistry(_recordRegistry);
        consentManager   = IConsentAccessManager(_consentManager);
        zkVerifier       = ILockAZKVerifier(_zkVerifier);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Admin — Update Registry Addresses
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates all five registry references in one transaction.
     * @dev Only the owner can call this. Useful after contract upgrades.
     */
    function setRegistryAddresses(
        address _patientRegistry,
        address _providerRegistry,
        address _recordRegistry,
        address _consentManager,
        address _zkVerifier
    ) external onlyOwner {
        if (
            _patientRegistry  == address(0) ||
            _providerRegistry == address(0) ||
            _recordRegistry   == address(0) ||
            _consentManager   == address(0) ||
            _zkVerifier       == address(0)
        ) revert ZeroAddressNotAllowed();

        patientRegistry  = IPatientPassportRegistry(_patientRegistry);
        providerRegistry = IProviderRegistry(_providerRegistry);
        recordRegistry   = IMedicalRecordRegistry(_recordRegistry);
        consentManager   = IConsentAccessManager(_consentManager);
        zkVerifier       = ILockAZKVerifier(_zkVerifier);

        emit RegistryAddressesUpdated(
            _patientRegistry, _providerRegistry, _recordRegistry,
            _consentManager, _zkVerifier
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Composite ID Validation
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Validates a patient: passport active AND ZK identity claim verified.
     * @param passportId The patient's passport ID.
     * @return valid True iff the patient passes all checks.
     */
    function validatePatient(bytes32 passportId) external view whenNotPaused returns (bool valid) {
        if (passportId == bytes32(0)) revert InvalidPassportId();
        return patientRegistry.isPassportActive(passportId) &&
               zkVerifier.isIdentityVerified(passportId);
    }

    /**
     * @notice Validates a provider: provider verified AND ZK license claim active.
     * @param providerId The provider's ID.
     * @return valid True iff the provider passes all checks.
     */
    function validateProvider(bytes32 providerId) external view whenNotPaused returns (bool valid) {
        if (providerId == bytes32(0)) revert InvalidProviderId();
        bool providerVerified = providerRegistry.isProviderVerified(providerId);
        if (!providerVerified) return false;
        // Look up the provider's passport (if they have one) for ZK license claim
        address providerWallet = providerRegistry.getProviderWallet(providerId);
        bytes32 providerPassportId = patientRegistry.getPassportIdByWallet(providerWallet);
        bool hasLicenseClaim = providerPassportId != bytes32(0) &&
            zkVerifier.hasActiveClaim(providerPassportId, ILockAZKVerifier.ClaimType.ProviderLicenseValidity);
        // Provider is valid if verified; ZK license claim is a bonus check
        return providerVerified && hasLicenseClaim;
    }

    /**
     * @notice Validates that a provider has active consent to access a patient's records.
     * @dev Checks: patient active + provider verified + active approved consent grant.
     * @param passportId The patient's passport ID.
     * @param providerId The provider's ID.
     * @return valid True iff all three conditions are satisfied.
     */
    function validateRecordAccess(
        bytes32 passportId,
        bytes32 providerId
    ) external view whenNotPaused returns (bool valid) {
        if (passportId == bytes32(0)) revert InvalidPassportId();
        if (providerId == bytes32(0)) revert InvalidProviderId();
        return patientRegistry.isPassportActive(passportId) &&
               providerRegistry.isProviderVerified(providerId) &&
               consentManager.hasActiveAccess(passportId, providerId);
    }

    /**
     * @notice Validates the integrity of a medical record.
     * @dev Checks: record is valid (Active or Amended) + issuing provider still verified.
     * @param recordId The medical record ID.
     * @return valid True iff both conditions are satisfied.
     */
    function validateRecordIntegrity(bytes32 recordId) external view whenNotPaused returns (bool valid) {
        if (recordId == bytes32(0)) revert InvalidRecordId();
        if (!recordRegistry.isRecordValid(recordId)) return false;
        bytes32 providerId = recordRegistry.getRecordProviderId(recordId);
        return providerRegistry.isProviderVerified(providerId);
    }

    /**
     * @notice Full interaction validation: patient + provider + consent + record integrity.
     * @dev Combines all validation checks into one composite call.
     * @param passportId The patient's passport ID.
     * @param providerId The provider's ID.
     * @param recordId   The medical record ID (bytes32(0) to skip record check).
     * @return result    Detailed breakdown of each validation component.
     */
    function validateFullInteraction(
        bytes32 passportId,
        bytes32 providerId,
        bytes32 recordId
    ) external view whenNotPaused returns (InteractionValidation memory result) {
        if (passportId == bytes32(0)) revert InvalidPassportId();
        if (providerId == bytes32(0)) revert InvalidProviderId();

        result.patientActive           = patientRegistry.isPassportActive(passportId);
        result.patientIdentityVerified = zkVerifier.isIdentityVerified(passportId);
        result.providerVerified        = providerRegistry.isProviderVerified(providerId);
        result.hasConsent              = consentManager.hasActiveAccess(passportId, providerId);

        if (recordId != bytes32(0)) {
            result.recordValid = recordRegistry.isRecordValid(recordId) &&
                                 recordRegistry.getRecordPassportId(recordId) == passportId &&
                                 recordRegistry.getRecordProviderId(recordId) == providerId;
        } else {
            result.recordValid = true; // no record to validate
        }

        result.isValid = result.patientActive &&
                         result.providerVerified &&
                         result.hasConsent &&
                         result.recordValid;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Cross-Registry Summary Queries
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns an aggregated summary of a patient across all registries.
     * @param passportId The patient's passport ID.
     */
    function getPatientSummary(bytes32 passportId) external view returns (PatientSummary memory summary) {
        if (passportId == bytes32(0)) revert InvalidPassportId();

        summary.passportId             = passportId;
        summary.isPassportActive       = patientRegistry.isPassportActive(passportId);
        summary.isIdentityZKVerified   = zkVerifier.isIdentityVerified(passportId);
        summary.hasInsuranceZKClaim    = zkVerifier.hasActiveClaim(
            passportId, ILockAZKVerifier.ClaimType.InsuranceEligibility
        );

        if (summary.isPassportActive) {
            summary.passportStatus = patientRegistry.getPassportStatus(passportId);
        }
    }

    /**
     * @notice Returns an aggregated summary of a provider across all registries.
     * @param providerId The provider's ID.
     */
    function getProviderSummary(bytes32 providerId) external view returns (ProviderSummary memory summary) {
        if (providerId == bytes32(0)) revert InvalidProviderId();

        summary.providerId   = providerId;
        summary.isVerified   = providerRegistry.isProviderVerified(providerId);
        summary.providerStatus = providerRegistry.getProviderStatus(providerId);

        // Check ZK license claim via provider's own passport (if registered as patient)
        address providerWallet = providerRegistry.getProviderWallet(providerId);
        bytes32 providerPassportId = patientRegistry.getPassportIdByWallet(providerWallet);
        if (providerPassportId != bytes32(0)) {
            summary.hasLicenseZKClaim = zkVerifier.hasActiveClaim(
                providerPassportId, ILockAZKVerifier.ClaimType.ProviderLicenseValidity
            );
        }
    }

    /**
     * @notice Returns an aggregated summary of an access permission.
     * @param accessId  The access permission ID.
     * @param passportId The patient's passport ID (for cross-validation).
     * @param providerId The provider's ID (for cross-validation).
     */
    function getAccessSummary(
        bytes32 accessId,
        bytes32 passportId,
        bytes32 providerId
    ) external view returns (AccessSummary memory summary) {
        if (accessId == bytes32(0)) revert InvalidAccessId();

        summary.accessId        = accessId;
        summary.accessStatus    = consentManager.getAccessStatus(accessId);
        summary.isAccessActive  = consentManager.hasActiveAccess(passportId, providerId);
        summary.isPatientActive = patientRegistry.isPassportActive(passportId);
        summary.isProviderVerified = providerRegistry.isProviderVerified(providerId);
    }

    /**
     * @notice Returns all record IDs for a patient, with provider verification status.
     * @param passportId The patient's passport ID.
     * @return recordIds        Array of record IDs associated with the patient.
     * @return providerVerified Array of booleans indicating whether each record's
     *                          issuing provider is still verified.
     */
    function getPatientRecordsWithProviderStatus(bytes32 passportId)
        external view
        returns (bytes32[] memory recordIds, bool[] memory providerVerified)
    {
        if (passportId == bytes32(0)) revert InvalidPassportId();
        recordIds = recordRegistry.getPatientRecordIds(passportId);
        providerVerified = new bool[](recordIds.length);
        for (uint256 i = 0; i < recordIds.length; i++) {
            bytes32 pid = recordRegistry.getRecordProviderId(recordIds[i]);
            providerVerified[i] = providerRegistry.isProviderVerified(pid);
        }
    }

    /**
     * @notice Checks whether a provider currently has active consent for any of a
     *         patient's records and the patient is still active.
     * @param passportId The patient's passport ID.
     * @param providerId The provider's ID.
     * @return canAccess True iff the provider may access the patient's records right now.
     */
    function canProviderAccessPatient(
        bytes32 passportId,
        bytes32 providerId
    ) external view returns (bool canAccess) {
        return patientRegistry.isPassportActive(passportId) &&
               providerRegistry.isProviderVerified(providerId) &&
               consentManager.hasActiveAccess(passportId, providerId);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Emergency
    // ──────────────────────────────────────────────────────────────────────

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
