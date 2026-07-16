// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IPatientPassportRegistry} from "./IPatientPassportRegistry.sol";
import {IProviderRegistry}        from "./IProviderRegistry.sol";
import {IConsentAccessManager}    from "./IConsentAccessManager.sol";
import {IHealthcarePaymentToken}  from "./IHealthcarePaymentToken.sol";

/**
 * @title  ILockAOrchestrator
 * @author LockA Medical
 * @notice External interface for LockAOrchestrator — exposes composite cross-registry
 *         validation queries and the new payment-layer integration points.
 *
 * @dev    Consumed by off-chain tooling, tests, and any future satellite contracts
 *         that need to call the orchestrator without importing the full implementation.
 *
 *         Payment additions (v2):
 *         ─ {validatePaymentEligibility}  — patient active + provider verified + consent active.
 *         ─ {getPaymentSummary}           — aggregated payment + escrow status for a patient.
 *         ─ {setPaymentToken}             — admin registers the HealthcarePaymentToken address.
 */
interface ILockAOrchestrator {

    // =========================================================================
    //  Structs — existing composite results
    // =========================================================================

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

    // =========================================================================
    //  Structs — payment layer additions (v2)
    // =========================================================================

    /**
     * @notice Aggregated payment eligibility check result.
     * @dev    Returned by {validatePaymentEligibility}.
     */
    struct PaymentEligibility {
        bool isEligible;        // true iff all three sub-checks pass
        bool patientActive;     // passport is Active
        bool providerVerified;  // provider is Verified
        bool hasConsent;        // active consent exists between patient and provider
    }

    /**
     * @notice Aggregated financial summary for a patient passport.
     * @dev    Returned by {getPaymentSummary}.
     */
    struct PatientPaymentSummary {
        bytes32 passportId;
        uint256 totalPaymentsMade;      // count of direct payments
        uint256 activeVoucherCount;     // vouchers in Active status
        uint256 pendingEscrowCount;     // escrows in Funded or Claimed status
        uint256 settledEscrowCount;     // escrows in Approved or Settled status
    }

    // =========================================================================
    //  Events
    // =========================================================================

    event RegistryAddressesUpdated(
        address indexed patientRegistry,
        address indexed providerRegistry,
        address indexed recordRegistry,
        address consentManager,
        address zkVerifier
    );

    /// @notice Emitted when the payment token address is registered or updated.
    event PaymentTokenUpdated(address indexed paymentToken);

    // =========================================================================
    //  Admin
    // =========================================================================

    /**
     * @notice Updates all five core registry references.
     * @param _patientRegistry  New PatientPassportRegistry address.
     * @param _providerRegistry New ProviderRegistry address.
     * @param _recordRegistry   New MedicalRecordRegistry address.
     * @param _consentManager   New ConsentAccessManager address.
     * @param _zkVerifier       New LockAZKVerifier address.
     */
    function setRegistryAddresses(
        address _patientRegistry,
        address _providerRegistry,
        address _recordRegistry,
        address _consentManager,
        address _zkVerifier
    ) external;

    /**
     * @notice Registers or updates the HealthcarePaymentToken address.
     * @dev    Owner-only. Pass address(0) to detach the payment layer.
     * @param _paymentToken Address of the deployed HealthcarePaymentToken.
     */
    function setPaymentToken(address _paymentToken) external;

    // =========================================================================
    //  Composite Validation — existing
    // =========================================================================

    /// @notice Returns true iff passport is Active and has a valid ZK identity claim.
    function validatePatient(bytes32 passportId) external view returns (bool);

    /// @notice Returns true iff provider is Verified and has a valid ZK license claim.
    function validateProvider(bytes32 providerId) external view returns (bool);

    /// @notice Returns true iff patient is active, provider is verified, and consent exists.
    function validateRecordAccess(
        bytes32 passportId,
        bytes32 providerId
    ) external view returns (bool);

    /// @notice Returns true iff the record is valid and its issuing provider is still verified.
    function validateRecordIntegrity(bytes32 recordId) external view returns (bool);

    /// @notice Performs all four validations in a single call.
    function validateFullInteraction(
        bytes32 passportId,
        bytes32 providerId,
        bytes32 recordId
    ) external view returns (InteractionValidation memory);

    // =========================================================================
    //  Cross-Registry Lookups — existing
    // =========================================================================

    /// @notice Returns the aggregated patient summary.
    function getPatientSummary(bytes32 passportId) external view returns (PatientSummary memory);

    /// @notice Returns the aggregated provider summary.
    function getProviderSummary(bytes32 providerId) external view returns (ProviderSummary memory);

    /// @notice Returns the aggregated access summary.
    function getAccessSummary(bytes32 accessId) external view returns (AccessSummary memory);

    // =========================================================================
    //  Payment Layer — new in v2
    // =========================================================================

    /**
     * @notice Validates whether a patient-provider payment can proceed.
     * @dev    Checks: passport active + provider verified + active consent.
     *         Does NOT check token balances (that is the ERC-20 layer's concern).
     *
     * @param passportId  Patient's passport ID.
     * @param providerId  Provider's registry ID.
     * @return result     Struct with individual flag breakdown.
     */
    function validatePaymentEligibility(
        bytes32 passportId,
        bytes32 providerId
    ) external view returns (PaymentEligibility memory result);

    /**
     * @notice Returns an aggregated financial summary for a patient.
     * @dev    Queries HealthcarePaymentToken for counts; returns zeroes if the
     *         payment token has not been registered.
     *
     * @param passportId  Patient's passport ID.
     * @return summary    Aggregated payment summary struct.
     */
    function getPatientPaymentSummary(bytes32 passportId)
        external view returns (PatientPaymentSummary memory summary);

    /**
     * @notice Returns true iff a payment token has been registered with the orchestrator.
     */
    function hasPaymentToken() external view returns (bool);
}
