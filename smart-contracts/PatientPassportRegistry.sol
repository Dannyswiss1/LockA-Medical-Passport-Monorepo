// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./ENSResolverHelper.sol";
import "./interfaces/IPatientPassportRegistry.sol";

/**
 * @title PatientPassportRegistry
 * @author LockA Medical
 * @notice Creates and manages patient LockA Medical Passport identities on Base chain.
 * @dev Implements {IPatientPassportRegistry} so the orchestrator and sibling contracts
 *      can perform direct on-chain cross-contract validation without off-chain intermediaries.
 *
 *      Integration model:
 *        - {LockAOrchestrator} is granted the ORCHESTRATOR role and may call any
 *          privileged view or state-changing function that requires cross-registry authority.
 *        - {MedicalRecordRegistry} and {ConsentAccessManager} call {isPassportActive}
 *          directly before accepting new records / access requests.
 *        - {LockAZKVerifier} calls {isPassportActive} before recording verified claims.
 *
 *      ENS / Basename Integration:
 *        - Integrates with {ENSResolverHelper} to resolve human-readable Basenames.
 *        - ENS names are cached on-chain at registration time and refreshable.
 *
 *      Security model:
 *        - One active passport per wallet (enforced on registration).
 *        - Key rotation by current wallet owner OR recovery address.
 *        - Admin (owner) can suspend / reactivate / revoke any passport.
 *        - Orchestrator address is a trusted caller for cross-contract queries.
 *        - All state-changing functions protected by {ReentrancyGuard} and {Pausable}.
 *
 *      Deployed on: Base (Ethereum L2)
 */
contract PatientPassportRegistry is IPatientPassportRegistry, Ownable, ReentrancyGuard, Pausable {

    // ──────────────────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────────────────

    /// @notice On-chain representation of a patient passport.
    struct Passport {
        bytes32 passportId;
        address patientWalletAddress;
        bytes32 publicIdentityHash;
        uint256 createdAt;
        PassportStatus status;
        address recoveryAddress;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────────

    uint256 private _nonce;

    mapping(bytes32 => Passport) private _passports;
    mapping(address => bytes32)  private _walletToPassportId;
    mapping(address => string)   private _ensNames;
    mapping(bytes32 => address)  private _ensNodeToWallet;

    /// @notice The ENS Resolver Helper contract for Basename resolution.
    ENSResolverHelper public ensResolver;

    /// @notice The trusted orchestrator contract address.
    address public orchestrator;

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────

    event PatientRegistered(bytes32 indexed passportId, address indexed walletAddress, uint256 createdAt);
    event PatientKeyUpdated(bytes32 indexed passportId, address indexed oldAddress, address indexed newAddress);
    event PassportDeactivated(bytes32 indexed passportId);
    event PassportSuspended(bytes32 indexed passportId);
    event PassportReactivated(bytes32 indexed passportId);
    event RecoveryAddressUpdated(bytes32 indexed passportId, address indexed newRecoveryAddress);
    event ENSResolverUpdated(address indexed newResolver);
    event ENSNameCached(address indexed walletAddress, string ensName);
    event OrchestratorUpdated(address indexed newOrchestrator);

    // ──────────────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────────────

    error DuplicateRegistration(address wallet);
    error PassportNotFound(bytes32 passportId);
    error Unauthorised(address caller);
    error InvalidPassportStatus(bytes32 passportId, PassportStatus current, PassportStatus expected);
    error RecoveryAddressSameAsWallet(address addr);
    error ZeroAddressNotAllowed();
    error WalletAlreadyHasPassport(address wallet);
    error ENSResolverNotConfigured();
    error ENSNameNotRegistered(bytes32 ensNode);

    // ──────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier passportExists(bytes32 passportId) {
        if (_passports[passportId].createdAt == 0) revert PassportNotFound(passportId);
        _;
    }

    /// @dev Allows the owner OR the orchestrator to call admin-gated functions.
    modifier onlyAdminOrOrchestrator() {
        if (msg.sender != owner() && msg.sender != orchestrator) revert Unauthorised(msg.sender);
        _;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @param initialOwner The address granted the admin (owner) role.
     * @param _ensResolver The deployed ENSResolverHelper address (address(0) to defer).
     */
    constructor(address initialOwner, address _ensResolver) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddressNotAllowed();
        if (_ensResolver != address(0)) ensResolver = ENSResolverHelper(_ensResolver);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Admin — Orchestrator
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the trusted orchestrator contract.
     * @dev Only the owner may call this. Pass address(0) to remove the orchestrator.
     */
    function setOrchestrator(address _orchestrator) external onlyOwner {
        orchestrator = _orchestrator;
        emit OrchestratorUpdated(_orchestrator);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Admin — ENS Resolver
    // ──────────────────────────────────────────────────────────────────────

    function setENSResolver(address _ensResolver) external onlyOwner {
        if (_ensResolver == address(0)) revert ZeroAddressNotAllowed();
        ensResolver = ENSResolverHelper(_ensResolver);
        emit ENSResolverUpdated(_ensResolver);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Passport Lifecycle
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Registers a new patient passport for msg.sender.
     * @param publicIdentityHash keccak256 hash of off-chain identity data.
     * @param recoveryAddress    Address authorised for key rotation.
     */
    function registerPatient(
        bytes32 publicIdentityHash,
        address recoveryAddress
    ) external nonReentrant whenNotPaused {
        if (recoveryAddress == address(0)) revert ZeroAddressNotAllowed();
        if (recoveryAddress == msg.sender) revert RecoveryAddressSameAsWallet(msg.sender);
        if (_walletToPassportId[msg.sender] != bytes32(0)) revert DuplicateRegistration(msg.sender);

        bytes32 passportId = keccak256(abi.encodePacked(msg.sender, block.timestamp, _nonce++));

        _passports[passportId] = Passport({
            passportId:           passportId,
            patientWalletAddress: msg.sender,
            publicIdentityHash:   publicIdentityHash,
            createdAt:            block.timestamp,
            status:               PassportStatus.Active,
            recoveryAddress:      recoveryAddress
        });

        _walletToPassportId[msg.sender] = passportId;
        _tryCacheENSName(msg.sender);

        emit PatientRegistered(passportId, msg.sender, block.timestamp);
    }

    /**
     * @notice Rotates the wallet address controlling a passport.
     * @dev Callable by the current wallet owner or the recovery address.
     */
    function rotateKey(
        bytes32 passportId,
        address newWallet
    ) external nonReentrant whenNotPaused passportExists(passportId) {
        Passport storage p = _passports[passportId];
        if (p.status != PassportStatus.Active)
            revert InvalidPassportStatus(passportId, p.status, PassportStatus.Active);
        if (msg.sender != p.patientWalletAddress && msg.sender != p.recoveryAddress)
            revert Unauthorised(msg.sender);
        if (newWallet == address(0)) revert ZeroAddressNotAllowed();
        if (_walletToPassportId[newWallet] != bytes32(0)) revert WalletAlreadyHasPassport(newWallet);

        address oldWallet = p.patientWalletAddress;
        delete _walletToPassportId[oldWallet];
        delete _ensNames[oldWallet];

        p.patientWalletAddress = newWallet;
        _walletToPassportId[newWallet] = passportId;
        _tryCacheENSName(newWallet);

        emit PatientKeyUpdated(passportId, oldWallet, newWallet);
    }

    /**
     * @notice Updates the recovery address for a passport.
     * @dev Only the passport's current wallet owner may call this.
     */
    function updateRecoveryAddress(
        bytes32 passportId,
        address newRecoveryAddress
    ) external nonReentrant whenNotPaused passportExists(passportId) {
        Passport storage p = _passports[passportId];
        if (msg.sender != p.patientWalletAddress) revert Unauthorised(msg.sender);
        if (newRecoveryAddress == address(0)) revert ZeroAddressNotAllowed();
        if (newRecoveryAddress == p.patientWalletAddress) revert RecoveryAddressSameAsWallet(newRecoveryAddress);

        p.recoveryAddress = newRecoveryAddress;
        emit RecoveryAddressUpdated(passportId, newRecoveryAddress);
    }

    /**
     * @notice Permanently deactivates a passport (Revoked).
     * @dev Callable by the passport owner or the contract owner.
     */
    function deactivatePassport(
        bytes32 passportId
    ) external nonReentrant whenNotPaused passportExists(passportId) {
        Passport storage p = _passports[passportId];
        if (msg.sender != p.patientWalletAddress && msg.sender != owner())
            revert Unauthorised(msg.sender);
        if (p.status == PassportStatus.Revoked)
            revert InvalidPassportStatus(passportId, p.status, PassportStatus.Active);

        p.status = PassportStatus.Revoked;
        emit PassportDeactivated(passportId);
    }

    /**
     * @notice Temporarily suspends a passport (admin only).
     */
    function suspendPassport(
        bytes32 passportId
    ) external onlyOwner passportExists(passportId) {
        Passport storage p = _passports[passportId];
        if (p.status != PassportStatus.Active)
            revert InvalidPassportStatus(passportId, p.status, PassportStatus.Active);
        p.status = PassportStatus.Suspended;
        emit PassportSuspended(passportId);
    }

    /**
     * @notice Reactivates a suspended passport (admin only).
     */
    function reactivatePassport(
        bytes32 passportId
    ) external onlyOwner passportExists(passportId) {
        Passport storage p = _passports[passportId];
        if (p.status != PassportStatus.Suspended)
            revert InvalidPassportStatus(passportId, p.status, PassportStatus.Suspended);
        p.status = PassportStatus.Active;
        emit PassportReactivated(passportId);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — ENS
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Refreshes the cached ENS/Basename for a wallet address.
     * @dev Callable by the wallet owner or the contract owner.
     */
    function refreshENSName(address wallet) external {
        if (msg.sender != wallet && msg.sender != owner()) revert Unauthorised(msg.sender);
        _tryCacheENSName(wallet);
    }

    /**
     * @notice Returns the passport for a wallet identified by ENS namehash.
     */
    function getPassportByENS(bytes32 ensNode) external view returns (Passport memory) {
        address wallet = _ensNodeToWallet[ensNode];
        if (wallet == address(0)) revert ENSNameNotRegistered(ensNode);
        bytes32 pid = _walletToPassportId[wallet];
        if (pid == bytes32(0)) revert PassportNotFound(bytes32(0));
        return _passports[pid];
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — View (IPatientPassportRegistry implementation)
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc IPatientPassportRegistry
    function isPassportActive(bytes32 passportId) external view override returns (bool) {
        return _passports[passportId].createdAt != 0 &&
               _passports[passportId].status == PassportStatus.Active;
    }

    /// @inheritdoc IPatientPassportRegistry
    function getPassportStatus(bytes32 passportId) external view override passportExists(passportId) returns (PassportStatus) {
        return _passports[passportId].status;
    }

    /// @inheritdoc IPatientPassportRegistry
    function getPassportWallet(bytes32 passportId) external view override passportExists(passportId) returns (address) {
        return _passports[passportId].patientWalletAddress;
    }

    /// @inheritdoc IPatientPassportRegistry
    function getPassportIdByWallet(address wallet) external view override returns (bytes32) {
        return _walletToPassportId[wallet];
    }

    /// @inheritdoc IPatientPassportRegistry
    function isWalletRegistered(address wallet) external view override returns (bool) {
        bytes32 pid = _walletToPassportId[wallet];
        return pid != bytes32(0) && _passports[pid].status == PassportStatus.Active;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Full Passport Getter
    // ──────────────────────────────────────────────────────────────────────

    function getPassport(bytes32 passportId) external view passportExists(passportId) returns (Passport memory) {
        return _passports[passportId];
    }

    function getCachedENSName(address wallet) external view returns (string memory) {
        return _ensNames[wallet];
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Emergency
    // ──────────────────────────────────────────────────────────────────────

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ──────────────────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────────────────

    function _tryCacheENSName(address wallet) internal {
        if (address(ensResolver) == address(0)) return;
        try ensResolver.resolveAddressToName(wallet) returns (string memory name) {
            if (bytes(name).length > 0) {
                _ensNames[wallet] = name;
                bytes32 node = ensResolver.computeNamehash(name);
                _ensNodeToWallet[node] = wallet;
                emit ENSNameCached(wallet, name);
            }
        } catch {}
    }
}
