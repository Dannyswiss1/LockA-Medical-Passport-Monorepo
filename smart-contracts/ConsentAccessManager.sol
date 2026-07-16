// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IPatientPassportRegistry.sol";
import "./interfaces/IProviderRegistry.sol";
import "./interfaces/IConsentAccessManager.sol";

/**
 * @title ConsentAccessManager
 * @author LockA Medical
 * @notice Controls who can access what patient records, for how long, and under what conditions.
 *         Creates an on-chain consent trail for patient data access permissions.
 * @dev Implements {IConsentAccessManager}. Performs DIRECT cross-contract validation:
 *      - Calls {IPatientPassportRegistry-isPassportActive} to confirm the patient exists
 *        and is active before creating an access request.
 *      - Calls {IProviderRegistry-isProviderVerified} to confirm the provider is
 *        verified before creating an access request.
 *      - Calls {IPatientPassportRegistry-getPassportWallet} to validate the
 *        patientWallet parameter matches the registered passport wallet.
 *      - Calls {IProviderRegistry-getProviderWallet} to validate msg.sender is the
 *        registered wallet for the given providerId.
 *
 *      Security model:
 *        - Only verified providers can request access for active patients.
 *        - Only the patient's registered wallet can approve or reject requests.
 *        - Only the patient or admin can revoke an approved access.
 *        - All state-changing functions protected by {ReentrancyGuard} and {Pausable}.
 *
 *      Deployed on: Base (Ethereum L2)
 */
contract ConsentAccessManager is IConsentAccessManager, Ownable, ReentrancyGuard, Pausable {

    // ──────────────────────────────────────────────────────────────────────
    //  Enums
    // ──────────────────────────────────────────────────────────────────────

    enum RecordScope {
        AllRecords,
        LabResultsOnly,
        PrescriptionsOnly,
        VaccinationRecordsOnly,
        EmergencySummaryOnly,
        InsuranceDataOnly
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────────────────────────────

    struct AccessPermission {
        bytes32 accessId;
        bytes32 passportId;
        bytes32 providerId;
        address patientWallet;
        address providerWallet;
        RecordScope recordScope;
        AccessStatus status;
        uint256 expiresAt;
        uint256 createdAt;
        uint256 respondedAt;
        uint256 revokedAt;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────────────

    error AccessNotFound(bytes32 accessId);
    error Unauthorised(address caller);
    error InvalidAccessStatus(bytes32 accessId, AccessStatus current, AccessStatus expected);
    error ZeroAddressNotAllowed();
    error InvalidPassportId();
    error InvalidProviderId();
    error InvalidExpiry(uint256 expiresAt);
    error AccessAlreadyExpired(bytes32 accessId);
    /// @notice Thrown when the patient passport is not active (cross-contract validation failure).
    error PassportNotActive(bytes32 passportId);
    /// @notice Thrown when the provider is not verified (cross-contract validation failure).
    error ProviderNotVerified(bytes32 providerId);
    /// @notice Thrown when patientWallet does not match the passport's registered wallet.
    error PatientWalletMismatch(bytes32 passportId, address provided, address registered);
    /// @notice Thrown when msg.sender is not the registered wallet for providerId.
    error CallerNotRegisteredProvider(address caller, bytes32 providerId);

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────

    event AccessRequested(
        bytes32 indexed accessId,
        bytes32 indexed passportId,
        bytes32 indexed providerId,
        RecordScope recordScope,
        uint256 createdAt
    );
    event AccessApproved(
        bytes32 indexed accessId,
        bytes32 indexed passportId,
        uint256 expiresAt,
        uint256 approvedAt
    );
    event AccessRejected(bytes32 indexed accessId, bytes32 indexed passportId, uint256 rejectedAt);
    event AccessRevoked(bytes32 indexed accessId, bytes32 indexed passportId, uint256 revokedAt);
    event RegistryAddressesUpdated(address indexed patientRegistry, address indexed providerRegistry);

    // ──────────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────────

    uint256 private _nonce;

    mapping(bytes32 => AccessPermission) private _permissions;
    mapping(bytes32 => bytes32[])         private _patientPermissions;
    mapping(bytes32 => bytes32[])         private _providerPermissions;

    /// @notice Direct reference to PatientPassportRegistry for cross-contract validation.
    IPatientPassportRegistry public patientRegistry;

    /// @notice Direct reference to ProviderRegistry for cross-contract validation.
    IProviderRegistry public providerRegistry;

    // ──────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier accessExists(bytes32 accessId) {
        if (_permissions[accessId].createdAt == 0) revert AccessNotFound(accessId);
        _;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @param _patientRegistry  Address of the deployed PatientPassportRegistry
     *                          (0x4fd6EB270CbF4C430E38f6559DaBA77555a648C7).
     * @param _providerRegistry Address of the deployed ProviderRegistry
     *                          (0x0f5D06446D3544dE1fB37090d9Bf58988Afb2c09).
     * @param _initialOwner     The address that will be set as the contract owner
     *                          (0xb5E7F33d44e91cD31f1581BA5F8694777Bea13C9).
     */
    constructor(
        address _patientRegistry,
        address _providerRegistry,
        address _initialOwner
    ) Ownable(_initialOwner) {
        if (_patientRegistry == address(0) || _providerRegistry == address(0) || _initialOwner == address(0))
            revert ZeroAddressNotAllowed();
        patientRegistry  = IPatientPassportRegistry(_patientRegistry);
        providerRegistry = IProviderRegistry(_providerRegistry);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Admin — Registry Addresses
    // ──────────────────────────────────────────────────────────────────────

    function setRegistryAddresses(
        address _patientRegistry,
        address _providerRegistry
    ) external onlyOwner {
        if (_patientRegistry == address(0) || _providerRegistry == address(0))
            revert ZeroAddressNotAllowed();
        patientRegistry  = IPatientPassportRegistry(_patientRegistry);
        providerRegistry = IProviderRegistry(_providerRegistry);
        emit RegistryAddressesUpdated(_patientRegistry, _providerRegistry);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Access Request Lifecycle
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Allows a verified provider to request access to an active patient's records.
     * @dev Performs direct cross-contract validation:
     *      1. Confirms passportId is active via PatientPassportRegistry.
     *      2. Confirms providerId is verified via ProviderRegistry.
     *      3. Confirms msg.sender is the registered wallet for providerId.
     *      4. Confirms patientWallet matches the registered wallet for passportId.
     *
     * @param passportId   The patient's passport ID.
     * @param providerId   The requesting provider's ID.
     * @param patientWallet The patient's wallet address (must match registered wallet).
     * @param recordScope  The scope of records being requested.
     * @return accessId    The unique identifier for the newly created access request.
     */
    function request_access(
        bytes32 passportId,
        bytes32 providerId,
        address patientWallet,
        RecordScope recordScope
    ) external whenNotPaused nonReentrant returns (bytes32 accessId) {
        if (passportId == bytes32(0))    revert InvalidPassportId();
        if (providerId == bytes32(0))    revert InvalidProviderId();
        if (patientWallet == address(0)) revert ZeroAddressNotAllowed();

        // ── Cross-contract: patient must be active ────────────────────────
        if (!patientRegistry.isPassportActive(passportId))
            revert PassportNotActive(passportId);

        // ── Cross-contract: provider must be verified ─────────────────────
        if (!providerRegistry.isProviderVerified(providerId))
            revert ProviderNotVerified(providerId);

        // ── Cross-contract: caller must be the registered provider wallet ──
        address registeredProviderWallet = providerRegistry.getProviderWallet(providerId);
        if (msg.sender != registeredProviderWallet)
            revert CallerNotRegisteredProvider(msg.sender, providerId);

        // ── Cross-contract: patientWallet must match registered passport wallet ──
        address registeredPatientWallet = patientRegistry.getPassportWallet(passportId);
        if (patientWallet != registeredPatientWallet)
            revert PatientWalletMismatch(passportId, patientWallet, registeredPatientWallet);

        accessId = keccak256(abi.encodePacked(passportId, providerId, block.timestamp, _nonce++));

        _permissions[accessId] = AccessPermission({
            accessId:      accessId,
            passportId:    passportId,
            providerId:    providerId,
            patientWallet: patientWallet,
            providerWallet: msg.sender,
            recordScope:   recordScope,
            status:        AccessStatus.Pending,
            expiresAt:     0,
            createdAt:     block.timestamp,
            respondedAt:   0,
            revokedAt:     0
        });

        _patientPermissions[passportId].push(accessId);
        _providerPermissions[providerId].push(accessId);

        emit AccessRequested(accessId, passportId, providerId, recordScope, block.timestamp);
    }

    /**
     * @notice Allows the patient to approve a pending access request.
     * @param accessId  The access request ID.
     * @param expiresAt Unix timestamp when access expires (must be > block.timestamp).
     */
    function approve_access(
        bytes32 accessId,
        uint256 expiresAt
    ) external whenNotPaused nonReentrant accessExists(accessId) {
        AccessPermission storage perm = _permissions[accessId];
        if (msg.sender != perm.patientWallet) revert Unauthorised(msg.sender);
        if (perm.status != AccessStatus.Pending)
            revert InvalidAccessStatus(accessId, perm.status, AccessStatus.Pending);
        if (expiresAt <= block.timestamp) revert InvalidExpiry(expiresAt);

        perm.status      = AccessStatus.Approved;
        perm.expiresAt   = expiresAt;
        perm.respondedAt = block.timestamp;

        emit AccessApproved(accessId, perm.passportId, expiresAt, block.timestamp);
    }

    /**
     * @notice Allows the patient to reject a pending access request.
     */
    function reject_access(bytes32 accessId) external whenNotPaused nonReentrant accessExists(accessId) {
        AccessPermission storage perm = _permissions[accessId];
        if (msg.sender != perm.patientWallet) revert Unauthorised(msg.sender);
        if (perm.status != AccessStatus.Pending)
            revert InvalidAccessStatus(accessId, perm.status, AccessStatus.Pending);

        perm.status      = AccessStatus.Rejected;
        perm.respondedAt = block.timestamp;

        emit AccessRejected(accessId, perm.passportId, block.timestamp);
    }

    /**
     * @notice Revokes an approved access grant.
     * @dev Callable by the patient or the contract owner.
     */
    function revoke_access(bytes32 accessId) external whenNotPaused nonReentrant accessExists(accessId) {
        AccessPermission storage perm = _permissions[accessId];
        if (msg.sender != perm.patientWallet && msg.sender != owner())
            revert Unauthorised(msg.sender);
        if (perm.status != AccessStatus.Approved)
            revert InvalidAccessStatus(accessId, perm.status, AccessStatus.Approved);

        perm.status   = AccessStatus.Revoked;
        perm.revokedAt = block.timestamp;

        emit AccessRevoked(accessId, perm.passportId, block.timestamp);
    }

    /**
     * @notice Marks an approved but time-expired permission as Expired.
     * @dev Callable by anyone — permissionless expiry sweep.
     */
    function mark_expired(bytes32 accessId) external nonReentrant accessExists(accessId) {
        AccessPermission storage perm = _permissions[accessId];
        if (perm.status != AccessStatus.Approved)
            revert InvalidAccessStatus(accessId, perm.status, AccessStatus.Approved);
        if (perm.expiresAt == 0 || block.timestamp <= perm.expiresAt)
            revert AccessAlreadyExpired(accessId);

        perm.status = AccessStatus.Expired;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — View (IConsentAccessManager implementation)
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc IConsentAccessManager
    function hasActiveAccess(bytes32 passportId, bytes32 providerId) external view override returns (bool) {
        bytes32[] storage ids = _patientPermissions[passportId];
        for (uint256 i = 0; i < ids.length; i++) {
            AccessPermission storage p = _permissions[ids[i]];
            if (p.providerId == providerId &&
                p.status == AccessStatus.Approved &&
                (p.expiresAt == 0 || block.timestamp <= p.expiresAt)) {
                return true;
            }
        }
        return false;
    }

    /// @inheritdoc IConsentAccessManager
    function getAccessStatus(bytes32 accessId) external view override accessExists(accessId) returns (AccessStatus) {
        return _permissions[accessId].status;
    }

    /// @inheritdoc IConsentAccessManager
    function getPatientAccessIds(bytes32 passportId) external view override returns (bytes32[] memory) {
        return _patientPermissions[passportId];
    }

    /// @inheritdoc IConsentAccessManager
    function getProviderAccessIds(bytes32 providerId) external view override returns (bytes32[] memory) {
        return _providerPermissions[providerId];
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Full Permission Getter
    // ──────────────────────────────────────────────────────────────────────

    function get_permission(bytes32 accessId) external view accessExists(accessId) returns (AccessPermission memory) {
        return _permissions[accessId];
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Emergency
    // ──────────────────────────────────────────────────────────────────────

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
