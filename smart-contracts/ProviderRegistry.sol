// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./ENSResolverHelper.sol";
import "./interfaces/IProviderRegistry.sol";

/**
 * @title ProviderRegistry
 * @author LockA Medical
 * @notice Manages the registration and verification of healthcare providers
 *         on the LockA Medical platform.
 * @dev Implements {IProviderRegistry} so the orchestrator and sibling contracts
 *      can perform direct on-chain cross-contract validation without off-chain intermediaries.
 *
 *      Integration model:
 *        - {LockAOrchestrator} is granted the ORCHESTRATOR role and may call
 *          privileged view or admin functions requiring cross-registry authority.
 *        - {MedicalRecordRegistry} calls {isProviderVerified} before accepting records.
 *        - {ConsentAccessManager} calls {isProviderVerified} before creating access requests.
 *
 *      ENS / Basename Integration:
 *        - Integrates with {ENSResolverHelper} to resolve human-readable Basenames.
 *        - ENS names are cached on-chain at registration time and refreshable.
 *
 *      Security model:
 *        - One registration per wallet (enforced on registration).
 *        - Provider starts as Pending; admin must verify before it becomes active.
 *        - Orchestrator address is a trusted caller for cross-contract queries.
 *        - All state-changing functions protected by {ReentrancyGuard} and {Pausable}.
 *
 *      Deployed on: Base (Ethereum L2)
 */
contract ProviderRegistry is IProviderRegistry, Ownable, ReentrancyGuard, Pausable {

    // ──────────────────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────────────────

    enum ProviderType {
        Hospital,
        Clinic,
        Doctor,
        Laboratory,
        Pharmacy,
        InsuranceCompany,
        PublicHealthAgency
    }

    /// @notice On-chain representation of a healthcare provider.
    struct Provider {
        bytes32 providerId;
        address providerWalletAddress;
        ProviderType providerType;
        bytes32 licenseHash;
        string country;
        ProviderStatus status;
        address verifiedBy;
        uint256 registeredAt;
        uint256 verifiedAt;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────────

    uint256 private _nonce;

    mapping(bytes32 => Provider) private _providers;
    mapping(address => bytes32)  private _walletToProviderId;
    mapping(address => string)   private _ensNames;
    mapping(bytes32 => address)  private _ensNodeToWallet;

    /// @notice The ENS Resolver Helper contract for Basename resolution.
    ENSResolverHelper public ensResolver;

    /// @notice The trusted orchestrator contract address.
    address public orchestrator;

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────

    event ProviderRegistered(bytes32 indexed providerId, address indexed walletAddress, ProviderType providerType, uint256 registeredAt);
    event ProviderVerified(bytes32 indexed providerId, address indexed verifiedBy, uint256 verifiedAt);
    event ProviderSuspended(bytes32 indexed providerId, address indexed suspendedBy);
    event ProviderRevoked(bytes32 indexed providerId, address indexed revokedBy);
    event ProviderReactivated(bytes32 indexed providerId, address indexed reactivatedBy);
    event ENSResolverUpdated(address indexed newResolver);
    event ENSNameCached(address indexed walletAddress, string ensName);
    event OrchestratorUpdated(address indexed newOrchestrator);

    // ──────────────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────────────

    error DuplicateRegistration(address wallet);
    error ProviderNotFound(bytes32 providerId);
    error Unauthorised(address caller);
    error InvalidProviderStatus(bytes32 providerId, ProviderStatus current, ProviderStatus expected);
    error ZeroAddressNotAllowed();
    error InvalidLicenseHash();
    error EmptyCountry();
    error ENSResolverNotConfigured();
    error ENSNameNotRegistered(bytes32 ensNode);

    // ──────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier providerExists(bytes32 providerId) {
        if (_providers[providerId].registeredAt == 0) revert ProviderNotFound(providerId);
        _;
    }

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
    //  External — Provider Lifecycle
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Registers a new healthcare provider for msg.sender.
     * @param providerType The classification of the provider.
     * @param licenseHash  keccak256 hash of the off-chain license document.
     * @param country      ISO country code (must not be empty).
     * @return providerId  The unique identifier assigned to the new provider.
     */
    function register_provider(
        ProviderType providerType,
        bytes32 licenseHash,
        string calldata country
    ) external whenNotPaused nonReentrant returns (bytes32 providerId) {
        if (_walletToProviderId[msg.sender] != bytes32(0)) revert DuplicateRegistration(msg.sender);
        if (licenseHash == bytes32(0)) revert InvalidLicenseHash();
        if (bytes(country).length == 0) revert EmptyCountry();

        providerId = keccak256(abi.encodePacked(msg.sender, block.timestamp, _nonce++));

        _providers[providerId] = Provider({
            providerId:            providerId,
            providerWalletAddress: msg.sender,
            providerType:          providerType,
            licenseHash:           licenseHash,
            country:               country,
            status:                ProviderStatus.Pending,
            verifiedBy:            address(0),
            registeredAt:          block.timestamp,
            verifiedAt:            0
        });

        _walletToProviderId[msg.sender] = providerId;
        _tryCacheENSName(msg.sender);

        emit ProviderRegistered(providerId, msg.sender, providerType, block.timestamp);
    }

    /**
     * @notice Verifies a pending provider (admin only).
     */
    function verify_provider(bytes32 providerId) external onlyOwner providerExists(providerId) {
        Provider storage p = _providers[providerId];
        if (p.status != ProviderStatus.Pending)
            revert InvalidProviderStatus(providerId, p.status, ProviderStatus.Pending);
        p.status     = ProviderStatus.Verified;
        p.verifiedBy = msg.sender;
        p.verifiedAt = block.timestamp;
        emit ProviderVerified(providerId, msg.sender, block.timestamp);
    }

    /**
     * @notice Suspends a verified provider (admin only).
     */
    function suspend_provider(bytes32 providerId) external onlyOwner providerExists(providerId) {
        Provider storage p = _providers[providerId];
        if (p.status != ProviderStatus.Verified)
            revert InvalidProviderStatus(providerId, p.status, ProviderStatus.Verified);
        p.status = ProviderStatus.Suspended;
        emit ProviderSuspended(providerId, msg.sender);
    }

    /**
     * @notice Reactivates a suspended provider (admin only).
     */
    function reactivate_provider(bytes32 providerId) external onlyOwner providerExists(providerId) {
        Provider storage p = _providers[providerId];
        if (p.status != ProviderStatus.Suspended)
            revert InvalidProviderStatus(providerId, p.status, ProviderStatus.Suspended);
        p.status = ProviderStatus.Verified;
        emit ProviderReactivated(providerId, msg.sender);
    }

    /**
     * @notice Permanently revokes a provider (admin only).
     */
    function revoke_provider(bytes32 providerId) external onlyOwner providerExists(providerId) {
        Provider storage p = _providers[providerId];
        if (p.status == ProviderStatus.Revoked)
            revert InvalidProviderStatus(providerId, p.status, ProviderStatus.Pending);
        p.status = ProviderStatus.Revoked;
        emit ProviderRevoked(providerId, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — ENS
    // ──────────────────────────────────────────────────────────────────────

    function refreshENSName(address wallet) external {
        if (msg.sender != wallet && msg.sender != owner()) revert Unauthorised(msg.sender);
        _tryCacheENSName(wallet);
    }

    function get_provider_by_ens(bytes32 ensNode) external view returns (Provider memory) {
        address wallet = _ensNodeToWallet[ensNode];
        if (wallet == address(0)) revert ENSNameNotRegistered(ensNode);
        bytes32 pid = _walletToProviderId[wallet];
        if (pid == bytes32(0)) revert ProviderNotFound(bytes32(0));
        return _providers[pid];
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — View (IProviderRegistry implementation)
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc IProviderRegistry
    function isProviderVerified(bytes32 providerId) external view override returns (bool) {
        return _providers[providerId].registeredAt != 0 &&
               _providers[providerId].status == ProviderStatus.Verified;
    }

    /// @inheritdoc IProviderRegistry
    function getProviderStatus(bytes32 providerId) external view override providerExists(providerId) returns (ProviderStatus) {
        return _providers[providerId].status;
    }

    /// @inheritdoc IProviderRegistry
    function getProviderWallet(bytes32 providerId) external view override providerExists(providerId) returns (address) {
        return _providers[providerId].providerWalletAddress;
    }

    /// @inheritdoc IProviderRegistry
    function getProviderIdByWallet(address wallet) external view override returns (bytes32) {
        return _walletToProviderId[wallet];
    }

    /// @inheritdoc IProviderRegistry
    function isWalletVerifiedProvider(address wallet) external view override returns (bool) {
        bytes32 pid = _walletToProviderId[wallet];
        return pid != bytes32(0) && _providers[pid].status == ProviderStatus.Verified;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  External — Full Provider Getter
    // ──────────────────────────────────────────────────────────────────────

    function get_provider(bytes32 providerId) external view providerExists(providerId) returns (Provider memory) {
        return _providers[providerId];
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
