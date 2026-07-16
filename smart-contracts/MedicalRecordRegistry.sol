// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IPatientPassportRegistry.sol";
import "./interfaces/IProviderRegistry.sol";
import "./interfaces/IMedicalRecordRegistry.sol";

/**
 * @title MedicalRecordRegistry
 * @author LockA Medical
 * @notice Registers cryptographic proofs of medical records on-chain.
 * @dev Implements {IMedicalRecordRegistry}. Performs DIRECT cross-contract validation:
 *      - Calls {IPatientPassportRegistry-isPassportActive} to confirm the patient exists
 *        and is active before accepting a new record.
 *      - Calls {IProviderRegistry-isProviderVerified} to confirm the provider is
 *        verified before accepting a new record.
 *
 *      The actual encrypted medical file is stored off-chain (e.g., IPFS / cloud).
 *      The blockchain stores a hash of the encrypted file and a hash of the storage
 *      pointer, enabling tamper-proof verification without exposing sensitive data.
 *
 *      Security model:
 *        - Only verified providers (confirmed via direct call to ProviderRegistry) can
 *          add records for active patients (confirmed via direct call to PatientPassportRegistry).
 *        - Only the original provider wallet or the contract owner can update record status.
 *        - All state-changing functions protected by {ReentrancyGuard} and {Pausable}.
 *
 *      Deployed on: Base (Ethereum L2)
 */
contract MedicalRecordRegistry is IMedicalRecordRegistry, Ownable, ReentrancyGuard, Pausable {

    // ──────────────────────────────────────────────────────────────────────
    //  Enums
    // ──────────────────────────────────────────────────────────────────────

    enum RecordType {
        LabResult,
        Prescription,
        Diagnosis,
        Vaccination,
        SurgeryReport,
        AllergyRecord,
        InsuranceRecord,
        MedicalSummary
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────────────────────────────

    struct MedicalRecord {
        bytes32 recordId;
        bytes32 passportId;
        bytes32 providerId;
        address providerWallet;
        RecordType recordType;
        bytes32 encryptedFileHash;
        bytes32 storagePointerHash;
        RecordStatus status;
        uint256 issuedAt;
        uint256 updatedAt;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────────────

    error RecordNotFound(bytes32 recordId);
    error Unauthorised(address caller);
    error InvalidRecordStatus(bytes32 recordId, RecordStatus current, RecordStatus expected);
    error ZeroAddressNotAllowed();
    error InvalidPassportId();
    error InvalidProviderId();
    error InvalidFileHash();
    error InvalidStoragePointer();
    error RecordAlreadyRevoked(bytes32 recordId);
    /// @notice Thrown when the patient passport is not active (cross-contract validation failure).
    error PassportNotActive(bytes32 passportId);
    /// @notice Thrown when the provider is not verified (cross-contract validation failure).
    error ProviderNotVerified(bytes32 providerId);
    /// @notice Thrown when the caller's wallet does not match the registered provider.
    error CallerNotRegisteredProvider(address caller, bytes32 providerId);

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────

    event RecordAdded(
        bytes32 indexed recordId,
        bytes32 indexed passportId,
        bytes32 indexed providerId,
        RecordType recordType,
        uint256 issuedAt
    );
    event RecordStatusUpdated(
        bytes32 indexed recordId,
        RecordStatus oldStatus,
        RecordStatus newStatus,
        uint256 updatedAt
    );
    event RegistryAddressesUpdated(address indexed patientRegistry, address indexed providerRegistry);

    // ──────────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────────

    uint256 private _nonce;

    mapping(bytes32 => MedicalRecord) private _records;
    mapping(bytes32 => bytes32[])     private _patientRecords;
    mapping(bytes32 => bytes32[])     private _providerRecords;

    /// @notice Direct reference to PatientPassportRegistry for cross-contract validation.
    IPatientPassportRegistry public patientRegistry;

    /// @notice Direct reference to ProviderRegistry for cross-contract validation.
    IProviderRegistry public providerRegistry;

    // ──────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier recordExists(bytes32 recordId) {
        if (_records[recordId].issuedAt == 0) revert RecordNotFound(recordId);
        _;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @param initialOwner     The address that will be set as the contract owner.
     * @param _patientRegistry Address of the deployed PatientPassportRegistry.
     * @param _providerRegistry Address of the deployed ProviderRegistry.
     */
    constructor(
        address initialOwner,
        address _patientRegistry,
        address _providerRegistry
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || _patientRegistry == address(0) || _providerRegistry == address(0))
            revert ZeroAddressNotAllowed();
        patientRegistry  = IPatientPassportRegistry(_patientRegistry);
        providerRegistry = IProviderRegistry(_providerRegistry);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Admin — Registry Addresses
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates the cross-contract registry references (owner only).
     */
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
    //  External — Record Management
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Registers a new medical record proof on-chain.
     * @dev Performs direct cross-contract validation:
     *      1. Confirms passportId is active via PatientPassportRegistry.
     *      2. Confirms providerId is verified via ProviderRegistry.
     *      3. Confirms msg.sender is the registered wallet for providerId.
     *
     * @param passportId         The patient's passport ID.
     * @param providerId         The provider's ID who created the record.
     * @param recordType         Classification of the medical record.
     * @param encryptedFileHash  keccak256 hash of the encrypted medical file.
     * @param storagePointerHash keccak256 hash of the off-chain storage pointer.
     * @return recordId The unique identifier assigned to the new record.
     */
    function add_record(
        bytes32 passportId,
        bytes32 providerId,
        RecordType recordType,
        bytes32 encryptedFileHash,
        bytes32 storagePointerHash
    ) external whenNotPaused nonReentrant returns (bytes32 recordId) {
        if (passportId == bytes32(0))        revert InvalidPassportId();
        if (providerId == bytes32(0))        revert InvalidProviderId();
        if (encryptedFileHash == bytes32(0)) revert InvalidFileHash();
        if (storagePointerHash == bytes32(0)) revert InvalidStoragePointer();

        // ── Cross-contract: patient must be active ────────────────────────
        if (!patientRegistry.isPassportActive(passportId))
            revert PassportNotActive(passportId);

        // ── Cross-contract: provider must be verified ─────────────────────
        if (!providerRegistry.isProviderVerified(providerId))
            revert ProviderNotVerified(providerId);

        // ── Cross-contract: caller must be the registered provider wallet ──
        address providerWallet = providerRegistry.getProviderWallet(providerId);
        if (msg.sender != providerWallet)
            revert CallerNotRegisteredProvider(msg.sender, providerId);

        recordId = keccak256(abi.encodePacked(passportId, providerId, block.timestamp, _nonce++));

        _records[recordId] = MedicalRecord({
            recordId:          recordId,
            passportId:        passportId,
            providerId:        providerId,
            providerWallet:    msg.sender,
            recordType:        recordType,
            encryptedFileHash: encryptedFileHash,
            storagePointerHash: storagePointerHash,
            status:            RecordStatus.Active,
            issuedAt:          block.timestamp,
            updatedAt:         0
        });

        _patientRecords[passportId].push(recordId);
        _providerRecords[providerId].push(recordId);

        emit RecordAdded(recordId, passportId, providerId, recordType, block.timestamp);
    }

    /**
     * @notice Updates the lifecycle status of an existing medical record.
     * @dev Valid transitions: Active→Amended, Active→Revoked, Amended→Revoked.
     *      Only the original provider wallet or the contract owner may call this.
     */
    function update_record_status(
        bytes32 recordId,
        RecordStatus newStatus
    ) external whenNotPaused nonReentrant recordExists(recordId) {
        MedicalRecord storage record = _records[recordId];

        if (msg.sender != record.providerWallet && msg.sender != owner())
            revert Unauthorised(msg.sender);
        if (record.status == RecordStatus.Revoked)
            revert RecordAlreadyRevoked(recordId);

        if (record.status == RecordStatus.Active) {
            if (newStatus != RecordStatus.Amended && newStatus != RecordStatus.Revoked)
                revert InvalidRecordStatus(recordId, record.status, newStatus);
        } else if (record.status == RecordStatus.Amended) {
            if (newStatus != RecordStatus.Revoked)
                revert InvalidRecordStatus(recordId, record.status, newStatus);
        } else {
            revert InvalidRecordStatus(recordId, record.status, newStatus);
        }

        RecordStatus oldStatus = record.status;
        record.status    = newStatus;
        record.updatedAt = block.timestamp;

        emit RecordStatusUpdated(recordId, oldStatus, newStatus, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — View (IMedicalRecordRegistry implementation)
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc IMedicalRecordRegistry
    function isRecordValid(bytes32 recordId) external view override returns (bool) {
        RecordStatus s = _records[recordId].status;
        return _records[recordId].issuedAt != 0 &&
               (s == RecordStatus.Active || s == RecordStatus.Amended);
    }

    /// @inheritdoc IMedicalRecordRegistry
    function getRecordStatus(bytes32 recordId) external view override recordExists(recordId) returns (RecordStatus) {
        return _records[recordId].status;
    }

    /// @inheritdoc IMedicalRecordRegistry
    function getRecordPassportId(bytes32 recordId) external view override recordExists(recordId) returns (bytes32) {
        return _records[recordId].passportId;
    }

    /// @inheritdoc IMedicalRecordRegistry
    function getRecordProviderId(bytes32 recordId) external view override recordExists(recordId) returns (bytes32) {
        return _records[recordId].providerId;
    }

    /// @inheritdoc IMedicalRecordRegistry
    function getPatientRecordIds(bytes32 passportId) external view override returns (bytes32[] memory) {
        return _patientRecords[passportId];
    }

    /// @inheritdoc IMedicalRecordRegistry
    function getProviderRecordIds(bytes32 providerId) external view override returns (bytes32[] memory) {
        return _providerRecords[providerId];
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Full Record Getter + Verification
    // ──────────────────────────────────────────────────────────────────────

    function get_record(bytes32 recordId) external view recordExists(recordId) returns (MedicalRecord memory) {
        return _records[recordId];
    }

    /**
     * @notice Verifies whether a given file hash matches the stored encrypted file hash.
     */
    function verify_record_hash(bytes32 recordId, bytes32 fileHash) external view recordExists(recordId) returns (bool) {
        return _records[recordId].encryptedFileHash == fileHash;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Emergency
    // ──────────────────────────────────────────────────────────────────────

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
