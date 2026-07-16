// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// ── OpenZeppelin ──────────────────────────────────────────────────────────────
import {AccessControl}    from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20}            from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable}    from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable}    from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit}      from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuard}  from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20}        from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ── LockA interfaces ──────────────────────────────────────────────────────────
import {IPatientPassportRegistry} from "./interfaces/IPatientPassportRegistry.sol";
import {IProviderRegistry}        from "./interfaces/IProviderRegistry.sol";
import {IConsentAccessManager}    from "./interfaces/IConsentAccessManager.sol";
import {IMedicalRecordRegistry}   from "./interfaces/IMedicalRecordRegistry.sol";

/**
 * @title  HealthcarePaymentToken
 * @author LockA Medical
 * @notice ERC-20 payment and settlement layer for the LockA Medical platform on Base.
 *
 * @dev    This contract is the financial backbone of the LockA ecosystem and handles
 *         four distinct payment primitives:
 *
 *         ── 1. Direct Payments ───────────────────────────────────────────────
 *         Patient-to-provider payments validated against live registry state.
 *         Every payment is linked to a passportId, a providerId, and optionally
 *         a recordId so that the full clinical + financial audit trail is on-chain.
 *
 *         ── 2. Health Vouchers ───────────────────────────────────────────────
 *         Time-locked or condition-gated token grants issued to specific patients.
 *         Vouchers can be:
 *           • Time-locked  — redeemable only after `unlocksAt`.
 *           • Consent-gated — redeemable only when the patient has active consent
 *             with a specific provider (verified via ConsentAccessManager).
 *           • Record-gated  — redeemable only when a linked medical record exists
 *             and is valid (verified via MedicalRecordRegistry).
 *         Unredeemed vouchers can be revoked by SUBSIDY_MANAGER_ROLE.
 *
 *         ── 3. Subsidy Programs ──────────────────────────────────────────────
 *         Admin-minted token grants earmarked for a specific purpose (e.g., a
 *         national vaccination drive).  Each subsidy tracks its own budget cap,
 *         amount disbursed, and expiry.  Subsidy disbursements create vouchers
 *         for the beneficiary patient.
 *
 *         ── 4. Insurance Escrow & Settlement ─────────────────────────────────
 *         Multi-party escrow for insurance claim settlement:
 *           a. Insurer deposits tokens into escrow against a claim.
 *           b. Provider submits the claim (linked to a medical record).
 *           c. Insurer approves → tokens released to provider.
 *              Insurer disputes → arbitrator (ARBITRATOR_ROLE) adjudicates.
 *              Expired without approval → patient may reclaim.
 *
 *         ── Registry Integration ─────────────────────────────────────────────
 *         Every state-changing operation cross-validates against:
 *           • PatientPassportRegistry  — passport must be Active.
 *           • ProviderRegistry         — provider must be Verified.
 *           • ConsentAccessManager     — active consent required for certain ops.
 *           • MedicalRecordRegistry    — record must be valid for record-gated ops.
 *
 *         ── Role Hierarchy ───────────────────────────────────────────────────
 *         DEFAULT_ADMIN_ROLE  — full control; grants / revokes all other roles.
 *         PAUSER_ROLE         — can pause / unpause the token.
 *         MINTER_ROLE         — can mint tokens (used by subsidy programs).
 *         SUBSIDY_MANAGER_ROLE— can create / fund subsidy programs and disburse.
 *         ARBITRATOR_ROLE     — can resolve disputed insurance escrow claims.
 *
 *         ── Security ─────────────────────────────────────────────────────────
 *         • All state-changing functions are nonReentrant + whenNotPaused.
 *         • ERC-2612 permit support for gasless approvals.
 *         • SafeERC20 used for any future token-in-token operations.
 *         • Custom errors (no string revert reasons) for gas efficiency.
 *
 *         Deployed on: Base (Ethereum L2)
 */
contract HealthcarePaymentToken is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    AccessControl,
    ERC20Permit,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // =========================================================================
    //  Roles
    // =========================================================================

    /// @notice Can pause / unpause the token contract.
    bytes32 public constant PAUSER_ROLE          = keccak256("PAUSER_ROLE");

    /// @notice Can mint new tokens (subsidy programs, insurance top-ups).
    bytes32 public constant MINTER_ROLE          = keccak256("MINTER_ROLE");

    /// @notice Can create subsidy programs and disburse subsidy vouchers.
    bytes32 public constant SUBSIDY_MANAGER_ROLE = keccak256("SUBSIDY_MANAGER_ROLE");

    /// @notice Can adjudicate disputed insurance escrow claims.
    bytes32 public constant ARBITRATOR_ROLE      = keccak256("ARBITRATOR_ROLE");

    // =========================================================================
    //  Enums
    // =========================================================================

    /// @notice Lifecycle state of a health voucher.
    enum VoucherStatus {
        Active,    // issued, not yet redeemed or revoked
        Redeemed,  // patient has claimed the tokens
        Revoked,   // admin revoked before redemption
        Expired    // past expiresAt without redemption
    }

    /// @notice Condition type governing when a voucher may be redeemed.
    enum VoucherCondition {
        TimeLocked,      // redeemable after `unlocksAt`
        ConsentRequired, // redeemable when active consent exists with `conditionProviderId`
        RecordRequired   // redeemable when a valid record `conditionRecordId` exists
    }

    /// @notice Lifecycle state of an insurance escrow.
    enum EscrowStatus {
        Funded,    // insurer deposited, awaiting provider claim submission
        Claimed,   // provider submitted claim, awaiting insurer approval
        Approved,  // insurer approved; tokens sent to provider
        Disputed,  // claim disputed; awaiting arbitrator
        Settled,   // arbitrator resolved
        Reclaimed  // patient reclaimed after timeout
    }

    // =========================================================================
    //  Structs
    // =========================================================================

    /**
     * @notice A direct payment record linking a patient, provider, and optional record.
     */
    struct Payment {
        bytes32 paymentId;
        bytes32 passportId;    // payer (patient)
        bytes32 providerId;    // payee (provider)
        bytes32 recordId;      // optional — links payment to a medical record
        address patientWallet;
        address providerWallet;
        uint256 amount;
        uint256 paidAt;
        string  memo;          // off-chain reference (e.g., invoice number)
    }

    /**
     * @notice A health voucher granting tokens to a patient under certain conditions.
     */
    struct Voucher {
        bytes32       voucherId;
        bytes32       passportId;        // beneficiary patient
        bytes32       subsidyId;         // originating subsidy (bytes32(0) for ad-hoc)
        uint256       amount;
        VoucherStatus status;
        VoucherCondition condition;
        uint256       unlocksAt;         // for TimeLocked
        bytes32       conditionProviderId; // for ConsentRequired
        bytes32       conditionRecordId;   // for RecordRequired
        uint256       issuedAt;
        uint256       expiresAt;         // 0 = no expiry
    }

    /**
     * @notice A subsidy program budget managed by SUBSIDY_MANAGER_ROLE.
     */
    struct SubsidyProgram {
        bytes32 subsidyId;
        string  name;
        uint256 budgetCap;       // maximum tokens that may be disbursed
        uint256 disbursed;       // tokens disbursed so far
        uint256 startsAt;
        uint256 endsAt;          // 0 = open-ended
        bool    active;
    }

    /**
     * @notice An insurance escrow for a claim between patient, provider, and insurer.
     */
    struct InsuranceEscrow {
        bytes32      escrowId;
        bytes32      passportId;    // patient
        bytes32      providerId;    // healthcare provider submitting the claim
        bytes32      recordId;      // linked medical record (optional)
        address      patientWallet;
        address      providerWallet;
        address      insurerWallet; // insurer who funded the escrow
        uint256      amount;
        EscrowStatus status;
        uint256      fundedAt;
        uint256      claimedAt;
        uint256      settledAt;
        uint256      timeoutAt;     // patient may reclaim after this timestamp
        string       claimReference; // off-chain claim ID
        // multi-party approval tracking
        bool         providerApproved;
        bool         insurerApproved;
        address      arbitratorDecision; // address(0) = not yet decided
    }

    // =========================================================================
    //  State
    // =========================================================================

    uint256 private _nonce;

    // ── Registry references ───────────────────────────────────────────────
    IPatientPassportRegistry public patientRegistry;
    IProviderRegistry        public providerRegistry;
    IConsentAccessManager    public consentManager;
    IMedicalRecordRegistry   public recordRegistry;

    // ── Payments ──────────────────────────────────────────────────────────
    mapping(bytes32 => Payment)   private _payments;
    /// @dev passportId → list of paymentIds
    mapping(bytes32 => bytes32[]) private _patientPayments;
    /// @dev providerId → list of paymentIds
    mapping(bytes32 => bytes32[]) private _providerPayments;
    /// @dev recordId   → paymentId (one payment per record)
    mapping(bytes32 => bytes32)   private _recordPayment;

    // ── Vouchers ──────────────────────────────────────────────────────────
    mapping(bytes32 => Voucher)   private _vouchers;
    /// @dev passportId → list of voucherIds
    mapping(bytes32 => bytes32[]) private _patientVouchers;

    // ── Subsidy Programs ──────────────────────────────────────────────────
    mapping(bytes32 => SubsidyProgram) private _subsidies;
    bytes32[] private _subsidyIds;

    // ── Insurance Escrow ─────────────────────────────────────────────────
    mapping(bytes32 => InsuranceEscrow) private _escrows;
    /// @dev passportId → list of escrowIds
    mapping(bytes32 => bytes32[]) private _patientEscrows;
    /// @dev providerId → list of escrowIds
    mapping(bytes32 => bytes32[]) private _providerEscrows;
    /// @dev insurerWallet → list of escrowIds
    mapping(address => bytes32[]) private _insurerEscrows;

    // =========================================================================
    //  Events
    // =========================================================================

    // ── Token admin ───────────────────────────────────────────────────────
    event RegistryAddressesUpdated(
        address indexed patientRegistry,
        address indexed providerRegistry,
        address indexed consentManager,
        address recordRegistry
    );

    // ── Payments ──────────────────────────────────────────────────────────
    /**
     * @notice Emitted when a patient pays a provider directly.
     * @param paymentId    Unique payment identifier.
     * @param passportId   Patient's passport ID.
     * @param providerId   Provider's registry ID.
     * @param recordId     Linked medical record (bytes32(0) if none).
     * @param amount       Token amount transferred.
     */
    event PaymentMade(
        bytes32 indexed paymentId,
        bytes32 indexed passportId,
        bytes32 indexed providerId,
        bytes32         recordId,
        uint256         amount,
        uint256         paidAt
    );

    // ── Vouchers ──────────────────────────────────────────────────────────
    /**
     * @notice Emitted when a new health voucher is issued to a patient.
     */
    event VoucherIssued(
        bytes32 indexed voucherId,
        bytes32 indexed passportId,
        bytes32 indexed subsidyId,
        VoucherCondition condition,
        uint256          amount,
        uint256          issuedAt
    );

    /**
     * @notice Emitted when a patient successfully redeems a voucher.
     */
    event VoucherRedeemed(
        bytes32 indexed voucherId,
        bytes32 indexed passportId,
        uint256         amount,
        uint256         redeemedAt
    );

    /**
     * @notice Emitted when a voucher is administratively revoked.
     */
    event VoucherRevoked(
        bytes32 indexed voucherId,
        bytes32 indexed passportId,
        address indexed revokedBy,
        uint256         revokedAt
    );

    // ── Subsidy Programs ──────────────────────────────────────────────────
    /**
     * @notice Emitted when a new subsidy program is created.
     */
    event SubsidyProgramCreated(
        bytes32 indexed subsidyId,
        string          name,
        uint256         budgetCap,
        uint256         startsAt,
        uint256         endsAt
    );

    /**
     * @notice Emitted when a subsidy program budget is topped up.
     */
    event SubsidyProgramFunded(
        bytes32 indexed subsidyId,
        uint256         additionalBudget,
        uint256         newBudgetCap
    );

    /**
     * @notice Emitted when a subsidy program is deactivated.
     */
    event SubsidyProgramDeactivated(bytes32 indexed subsidyId);

    // ── Insurance Escrow ─────────────────────────────────────────────────
    /**
     * @notice Emitted when an insurer funds a new escrow.
     */
    event EscrowFunded(
        bytes32 indexed escrowId,
        bytes32 indexed passportId,
        bytes32 indexed providerId,
        address         insurerWallet,
        uint256         amount,
        uint256         fundedAt
    );

    /**
     * @notice Emitted when a provider submits a claim against an escrow.
     */
    event EscrowClaimed(
        bytes32 indexed escrowId,
        bytes32 indexed providerId,
        string          claimReference,
        uint256         claimedAt
    );

    /**
     * @notice Emitted when an insurer approves a claim and tokens are released.
     */
    event EscrowApproved(
        bytes32 indexed escrowId,
        address indexed insurerWallet,
        address indexed providerWallet,
        uint256         amount,
        uint256         approvedAt
    );

    /**
     * @notice Emitted when a claim is disputed by the insurer.
     */
    event EscrowDisputed(
        bytes32 indexed escrowId,
        address indexed disputedBy,
        uint256         disputedAt
    );

    /**
     * @notice Emitted when an arbitrator settles a disputed escrow.
     */
    event EscrowSettled(
        bytes32 indexed escrowId,
        address indexed arbitrator,
        address indexed recipient,
        uint256         amount,
        uint256         settledAt
    );

    /**
     * @notice Emitted when a patient reclaims escrow funds after timeout.
     */
    event EscrowReclaimed(
        bytes32 indexed escrowId,
        bytes32 indexed passportId,
        address indexed patientWallet,
        uint256         amount,
        uint256         reclaimedAt
    );

    // =========================================================================
    //  Errors
    // =========================================================================

    // ── Registry validation ───────────────────────────────────────────────
    error PassportNotActive(bytes32 passportId);
    error ProviderNotVerified(bytes32 providerId);
    error NoActiveConsent(bytes32 passportId, bytes32 providerId);
    error RecordNotValid(bytes32 recordId);

    // ── Identity / ownership ──────────────────────────────────────────────
    error CallerNotPatientWallet(address caller, bytes32 passportId);
    error CallerNotProviderWallet(address caller, bytes32 providerId);
    error CallerNotInsurerWallet(address caller, bytes32 escrowId);
    error ZeroAddressNotAllowed();

    // ── Payments ──────────────────────────────────────────────────────────
    error InvalidPassportId();
    error InvalidProviderId();
    error InvalidAmount();
    error RecordAlreadyLinkedToPayment(bytes32 recordId);

    // ── Vouchers ──────────────────────────────────────────────────────────
    error VoucherNotFound(bytes32 voucherId);
    error VoucherNotActive(bytes32 voucherId, VoucherStatus current);
    error VoucherLocked(bytes32 voucherId, uint256 unlocksAt);
    error VoucherExpired(bytes32 voucherId);
    error VoucherConditionNotMet(bytes32 voucherId);
    error CallerNotVoucherBeneficiary(address caller, bytes32 voucherId);

    // ── Subsidy Programs ──────────────────────────────────────────────────
    error SubsidyNotFound(bytes32 subsidyId);
    error SubsidyNotActive(bytes32 subsidyId);
    error SubsidyExpired(bytes32 subsidyId);
    error SubsidyBudgetExceeded(bytes32 subsidyId, uint256 requested, uint256 remaining);
    error InvalidSubsidyDates();

    // ── Insurance Escrow ─────────────────────────────────────────────────
    error EscrowNotFound(bytes32 escrowId);
    error InvalidEscrowStatus(bytes32 escrowId, EscrowStatus current, EscrowStatus expected);
    error EscrowTimeoutNotReached(bytes32 escrowId, uint256 timeoutAt);
    error InvalidTimeout();
    error InvalidClaimReference();

    // =========================================================================
    //  Modifiers
    // =========================================================================

    /// @dev Validates that a passport exists and is Active in the registry.
    modifier onlyActivePassport(bytes32 passportId) {
        if (passportId == bytes32(0)) revert InvalidPassportId();
        if (!patientRegistry.isPassportActive(passportId)) revert PassportNotActive(passportId);
        _;
    }

    /// @dev Validates that a provider exists and is Verified in the registry.
    modifier onlyVerifiedProvider(bytes32 providerId) {
        if (providerId == bytes32(0)) revert InvalidProviderId();
        if (!providerRegistry.isProviderVerified(providerId)) revert ProviderNotVerified(providerId);
        _;
    }

    /// @dev Ensures msg.sender is the registered wallet for the given passport.
    modifier onlyPatientWallet(bytes32 passportId) {
        address registered = patientRegistry.getPassportWallet(passportId);
        if (msg.sender != registered) revert CallerNotPatientWallet(msg.sender, passportId);
        _;
    }

    /// @dev Ensures msg.sender is the registered wallet for the given provider.
    modifier onlyProviderWallet(bytes32 providerId) {
        address registered = providerRegistry.getProviderWallet(providerId);
        if (msg.sender != registered) revert CallerNotProviderWallet(msg.sender, providerId);
        _;
    }

    // =========================================================================
    //  Constructor
    // =========================================================================

    /**
     * @param defaultAdmin      Address granted DEFAULT_ADMIN_ROLE.
     * @param pauser            Address granted PAUSER_ROLE.
     * @param minter            Address granted MINTER_ROLE.
     * @param subsidyManager    Address granted SUBSIDY_MANAGER_ROLE.
     * @param arbitrator        Address granted ARBITRATOR_ROLE.
     * @param _patientRegistry  Deployed PatientPassportRegistry address.
     * @param _providerRegistry Deployed ProviderRegistry address.
     * @param _consentManager   Deployed ConsentAccessManager address.
     * @param _recordRegistry   Deployed MedicalRecordRegistry address.
     */
    constructor(
        address defaultAdmin,
        address pauser,
        address minter,
        address subsidyManager,
        address arbitrator,
        address _patientRegistry,
        address _providerRegistry,
        address _consentManager,
        address _recordRegistry
    )
        ERC20("HealthcarePaymentToken", "HLTH")
        ERC20Permit("HealthcarePaymentToken")
    {
        if (
            defaultAdmin      == address(0) ||
            pauser            == address(0) ||
            minter            == address(0) ||
            subsidyManager    == address(0) ||
            arbitrator        == address(0) ||
            _patientRegistry  == address(0) ||
            _providerRegistry == address(0) ||
            _consentManager   == address(0) ||
            _recordRegistry   == address(0)
        ) revert ZeroAddressNotAllowed();

        _grantRole(DEFAULT_ADMIN_ROLE,  defaultAdmin);
        _grantRole(PAUSER_ROLE,         pauser);
        _grantRole(MINTER_ROLE,         minter);
        _grantRole(SUBSIDY_MANAGER_ROLE, subsidyManager);
        _grantRole(ARBITRATOR_ROLE,     arbitrator);

        patientRegistry  = IPatientPassportRegistry(_patientRegistry);
        providerRegistry = IProviderRegistry(_providerRegistry);
        consentManager   = IConsentAccessManager(_consentManager);
        recordRegistry   = IMedicalRecordRegistry(_recordRegistry);
    }

    // =========================================================================
    //  Admin — Token
    // =========================================================================

    /**
     * @notice Pauses all token transfers and payment operations.
     * @dev Requires PAUSER_ROLE.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     * @dev Requires PAUSER_ROLE.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Mints tokens to `to`. Used for subsidy programs and insurance pools.
     * @dev Requires MINTER_ROLE.
     * @param to     Recipient address.
     * @param amount Token amount (18 decimals).
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert InvalidAmount();
        _mint(to, amount);
    }

    // =========================================================================
    //  Admin — Registry References
    // =========================================================================

    /**
     * @notice Updates all four registry contract references.
     * @dev Requires DEFAULT_ADMIN_ROLE. Useful after a registry upgrade.
     * @param _patientRegistry  New PatientPassportRegistry address.
     * @param _providerRegistry New ProviderRegistry address.
     * @param _consentManager   New ConsentAccessManager address.
     * @param _recordRegistry   New MedicalRecordRegistry address.
     */
    function setRegistryAddresses(
        address _patientRegistry,
        address _providerRegistry,
        address _consentManager,
        address _recordRegistry
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            _patientRegistry  == address(0) ||
            _providerRegistry == address(0) ||
            _consentManager   == address(0) ||
            _recordRegistry   == address(0)
        ) revert ZeroAddressNotAllowed();

        patientRegistry  = IPatientPassportRegistry(_patientRegistry);
        providerRegistry = IProviderRegistry(_providerRegistry);
        consentManager   = IConsentAccessManager(_consentManager);
        recordRegistry   = IMedicalRecordRegistry(_recordRegistry);

        emit RegistryAddressesUpdated(
            _patientRegistry,
            _providerRegistry,
            _consentManager,
            _recordRegistry
        );
    }

    // =========================================================================
    //  Section 1 — Direct Patient-to-Provider Payments
    // =========================================================================

    /**
     * @notice Transfers HLTH tokens from the patient's wallet to the provider's wallet.
     *
     * @dev    Cross-contract checks performed:
     *         1. passportId must be Active (PatientPassportRegistry).
     *         2. providerId must be Verified (ProviderRegistry).
     *         3. msg.sender must be the registered wallet for passportId.
     *         4. If recordId is non-zero, the record must be valid (MedicalRecordRegistry)
     *            and must not already have a linked payment.
     *
     * @param passportId   Patient's passport ID.
     * @param providerId   Provider's registry ID.
     * @param recordId     Optional — medical record this payment relates to (bytes32(0) to omit).
     * @param amount       Token amount to transfer (must be > 0).
     * @param memo         Off-chain reference string (e.g., invoice number).
     * @return paymentId   The unique identifier of the recorded payment.
     */
    function payProvider(
        bytes32 passportId,
        bytes32 providerId,
        bytes32 recordId,
        uint256 amount,
        string calldata memo
    )
        external
        nonReentrant
        whenNotPaused
        onlyActivePassport(passportId)
        onlyVerifiedProvider(providerId)
        onlyPatientWallet(passportId)
        returns (bytes32 paymentId)
    {
        if (amount == 0) revert InvalidAmount();

        // Optional record validation
        if (recordId != bytes32(0)) {
            if (!recordRegistry.isRecordValid(recordId)) revert RecordNotValid(recordId);
            if (_recordPayment[recordId] != bytes32(0))
                revert RecordAlreadyLinkedToPayment(recordId);
        }

        address providerWallet = providerRegistry.getProviderWallet(providerId);

        paymentId = keccak256(
            abi.encodePacked(passportId, providerId, block.timestamp, _nonce++)
        );

        _payments[paymentId] = Payment({
            paymentId:     paymentId,
            passportId:    passportId,
            providerId:    providerId,
            recordId:      recordId,
            patientWallet: msg.sender,
            providerWallet: providerWallet,
            amount:        amount,
            paidAt:        block.timestamp,
            memo:          memo
        });

        _patientPayments[passportId].push(paymentId);
        _providerPayments[providerId].push(paymentId);
        if (recordId != bytes32(0)) _recordPayment[recordId] = paymentId;

        // Token transfer: patient → provider
        _transfer(msg.sender, providerWallet, amount);

        emit PaymentMade(paymentId, passportId, providerId, recordId, amount, block.timestamp);
    }

    // =========================================================================
    //  Section 2 — Health Vouchers
    // =========================================================================

    /**
     * @notice Issues a time-locked health voucher to a patient.
     * @dev    Requires SUBSIDY_MANAGER_ROLE. Mints tokens into this contract as escrow.
     *         The voucher is redeemable by the patient after `unlocksAt`.
     *
     * @param passportId  Beneficiary patient's passport ID.
     * @param subsidyId   Originating subsidy program (bytes32(0) for ad-hoc).
     * @param amount      Token amount to lock in the voucher.
     * @param unlocksAt   Unix timestamp after which the voucher may be redeemed.
     * @param expiresAt   Unix timestamp after which the voucher expires (0 = none).
     * @return voucherId  The unique identifier of the issued voucher.
     */
    function issueTimeLockVoucher(
        bytes32 passportId,
        bytes32 subsidyId,
        uint256 amount,
        uint256 unlocksAt,
        uint256 expiresAt
    )
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        onlyActivePassport(passportId)
        returns (bytes32 voucherId)
    {
        if (amount == 0) revert InvalidAmount();
        if (unlocksAt <= block.timestamp) revert VoucherLocked(bytes32(0), unlocksAt);

        voucherId = _createVoucher(
            passportId,
            subsidyId,
            amount,
            VoucherCondition.TimeLocked,
            unlocksAt,
            bytes32(0),
            bytes32(0),
            expiresAt
        );
    }

    /**
     * @notice Issues a consent-gated voucher: redeemable when the patient has active
     *         consent with `conditionProviderId`.
     * @dev    Requires SUBSIDY_MANAGER_ROLE.
     *
     * @param passportId           Beneficiary patient's passport ID.
     * @param subsidyId            Originating subsidy (bytes32(0) for ad-hoc).
     * @param amount               Token amount.
     * @param conditionProviderId  Provider that must have active consent with the patient.
     * @param expiresAt            Expiry timestamp (0 = none).
     * @return voucherId           Unique voucher identifier.
     */
    function issueConsentGatedVoucher(
        bytes32 passportId,
        bytes32 subsidyId,
        uint256 amount,
        bytes32 conditionProviderId,
        uint256 expiresAt
    )
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        onlyActivePassport(passportId)
        onlyVerifiedProvider(conditionProviderId)
        returns (bytes32 voucherId)
    {
        if (amount == 0) revert InvalidAmount();

        voucherId = _createVoucher(
            passportId,
            subsidyId,
            amount,
            VoucherCondition.ConsentRequired,
            0,
            conditionProviderId,
            bytes32(0),
            expiresAt
        );
    }

    /**
     * @notice Issues a record-gated voucher: redeemable when a specific medical record
     *         is valid in MedicalRecordRegistry.
     * @dev    Requires SUBSIDY_MANAGER_ROLE.
     *
     * @param passportId          Beneficiary patient's passport ID.
     * @param subsidyId           Originating subsidy (bytes32(0) for ad-hoc).
     * @param amount              Token amount.
     * @param conditionRecordId   Record that must be valid before redemption.
     * @param expiresAt           Expiry timestamp (0 = none).
     * @return voucherId          Unique voucher identifier.
     */
    function issueRecordGatedVoucher(
        bytes32 passportId,
        bytes32 subsidyId,
        uint256 amount,
        bytes32 conditionRecordId,
        uint256 expiresAt
    )
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        onlyActivePassport(passportId)
        returns (bytes32 voucherId)
    {
        if (amount == 0) revert InvalidAmount();
        if (conditionRecordId == bytes32(0)) revert RecordNotValid(conditionRecordId);

        voucherId = _createVoucher(
            passportId,
            subsidyId,
            amount,
            VoucherCondition.RecordRequired,
            0,
            bytes32(0),
            conditionRecordId,
            expiresAt
        );
    }

    /**
     * @notice Redeems a voucher, transferring the locked tokens to the patient's wallet.
     * @dev    Only the patient wallet registered to the voucher's passportId may call this.
     *         All voucher conditions are validated at redemption time.
     *
     * @param voucherId  The voucher to redeem.
     */
    function redeemVoucher(bytes32 voucherId)
        external
        nonReentrant
        whenNotPaused
    {
        Voucher storage v = _vouchers[voucherId];
        if (v.issuedAt == 0) revert VoucherNotFound(voucherId);
        if (v.status != VoucherStatus.Active) revert VoucherNotActive(voucherId, v.status);

        // Expiry check
        if (v.expiresAt != 0 && block.timestamp > v.expiresAt) {
            v.status = VoucherStatus.Expired;
            revert VoucherExpired(voucherId);
        }

        // Caller must be the patient wallet
        address patientWallet = patientRegistry.getPassportWallet(v.passportId);
        if (msg.sender != patientWallet) revert CallerNotVoucherBeneficiary(msg.sender, voucherId);

        // Passport still active
        if (!patientRegistry.isPassportActive(v.passportId))
            revert PassportNotActive(v.passportId);

        // Condition checks
        if (v.condition == VoucherCondition.TimeLocked) {
            if (block.timestamp < v.unlocksAt)
                revert VoucherLocked(voucherId, v.unlocksAt);
        } else if (v.condition == VoucherCondition.ConsentRequired) {
            if (!consentManager.hasActiveAccess(v.passportId, v.conditionProviderId))
                revert VoucherConditionNotMet(voucherId);
        } else if (v.condition == VoucherCondition.RecordRequired) {
            if (!recordRegistry.isRecordValid(v.conditionRecordId))
                revert VoucherConditionNotMet(voucherId);
        }

        v.status = VoucherStatus.Redeemed;

        // Transfer escrowed tokens from contract to patient wallet
        _transfer(address(this), patientWallet, v.amount);

        emit VoucherRedeemed(voucherId, v.passportId, v.amount, block.timestamp);
    }

    /**
     * @notice Revokes an unredeemed voucher, returning the tokens to the contract treasury.
     * @dev    Requires SUBSIDY_MANAGER_ROLE. Tokens remain in the contract balance.
     *
     * @param voucherId  The voucher to revoke.
     */
    function revokeVoucher(bytes32 voucherId)
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
        nonReentrant
    {
        Voucher storage v = _vouchers[voucherId];
        if (v.issuedAt == 0) revert VoucherNotFound(voucherId);
        if (v.status != VoucherStatus.Active) revert VoucherNotActive(voucherId, v.status);

        v.status = VoucherStatus.Revoked;

        emit VoucherRevoked(voucherId, v.passportId, msg.sender, block.timestamp);
    }

    // =========================================================================
    //  Section 3 — Subsidy Programs
    // =========================================================================

    /**
     * @notice Creates a new subsidy program with a budget cap.
     * @dev    Requires SUBSIDY_MANAGER_ROLE. Does NOT mint tokens; the budget is
     *         tracked separately and consumed when vouchers are issued via
     *         {disburseSubsidy}.
     *
     * @param name       Human-readable program name.
     * @param budgetCap  Maximum total tokens that may be disbursed.
     * @param startsAt   Unix timestamp when the program becomes active.
     * @param endsAt     Unix timestamp when the program expires (0 = open-ended).
     * @return subsidyId Unique identifier of the new program.
     */
    function createSubsidyProgram(
        string calldata name,
        uint256 budgetCap,
        uint256 startsAt,
        uint256 endsAt
    )
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
        whenNotPaused
        returns (bytes32 subsidyId)
    {
        if (budgetCap == 0) revert InvalidAmount();
        if (endsAt != 0 && endsAt <= startsAt) revert InvalidSubsidyDates();

        subsidyId = keccak256(abi.encodePacked("SUBSIDY", name, block.timestamp, _nonce++));

        _subsidies[subsidyId] = SubsidyProgram({
            subsidyId:  subsidyId,
            name:       name,
            budgetCap:  budgetCap,
            disbursed:  0,
            startsAt:   startsAt,
            endsAt:     endsAt,
            active:     true
        });

        _subsidyIds.push(subsidyId);

        emit SubsidyProgramCreated(subsidyId, name, budgetCap, startsAt, endsAt);
    }

    /**
     * @notice Increases the budget cap of an existing subsidy program and mints
     *         additional tokens to the contract treasury to back the extra budget.
     * @dev    Requires SUBSIDY_MANAGER_ROLE + MINTER_ROLE (caller must hold both).
     *
     * @param subsidyId        Program to fund.
     * @param additionalBudget Additional token amount to add to the cap.
     */
    function fundSubsidyProgram(bytes32 subsidyId, uint256 additionalBudget)
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
    {
        SubsidyProgram storage s = _subsidies[subsidyId];
        if (s.startsAt == 0) revert SubsidyNotFound(subsidyId);
        if (!s.active)       revert SubsidyNotActive(subsidyId);
        if (additionalBudget == 0) revert InvalidAmount();

        s.budgetCap += additionalBudget;

        // Mint the backing tokens into this contract
        _mint(address(this), additionalBudget);

        emit SubsidyProgramFunded(subsidyId, additionalBudget, s.budgetCap);
    }

    /**
     * @notice Deactivates a subsidy program (no further disbursements allowed).
     * @dev    Requires SUBSIDY_MANAGER_ROLE.
     *
     * @param subsidyId Program to deactivate.
     */
    function deactivateSubsidyProgram(bytes32 subsidyId)
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
    {
        SubsidyProgram storage s = _subsidies[subsidyId];
        if (s.startsAt == 0) revert SubsidyNotFound(subsidyId);
        if (!s.active)       revert SubsidyNotActive(subsidyId);

        s.active = false;
        emit SubsidyProgramDeactivated(subsidyId);
    }

    /**
     * @notice Disburses tokens from a subsidy program to a patient via a time-locked
     *         voucher.  The voucher unlocks immediately (unlocksAt = block.timestamp)
     *         so the patient can redeem right away unless a future unlock is desired.
     *
     * @dev    Requires SUBSIDY_MANAGER_ROLE. Deducts from the program's remaining budget.
     *         Tokens are already in the contract (minted by {fundSubsidyProgram}).
     *
     * @param subsidyId   Program to draw from.
     * @param passportId  Beneficiary patient.
     * @param amount      Token amount to disburse.
     * @param unlocksAt   Earliest redemption timestamp (use block.timestamp for immediate).
     * @param expiresAt   Expiry timestamp (0 = none).
     * @return voucherId  Voucher created for the patient.
     */
    function disburseSubsidy(
        bytes32 subsidyId,
        bytes32 passportId,
        uint256 amount,
        uint256 unlocksAt,
        uint256 expiresAt
    )
        external
        onlyRole(SUBSIDY_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        onlyActivePassport(passportId)
        returns (bytes32 voucherId)
    {
        SubsidyProgram storage s = _subsidies[subsidyId];
        if (s.startsAt == 0)                          revert SubsidyNotFound(subsidyId);
        if (!s.active)                                revert SubsidyNotActive(subsidyId);
        if (s.endsAt != 0 && block.timestamp > s.endsAt) revert SubsidyExpired(subsidyId);
        if (amount == 0)                              revert InvalidAmount();

        uint256 remaining = s.budgetCap - s.disbursed;
        if (amount > remaining) revert SubsidyBudgetExceeded(subsidyId, amount, remaining);

        s.disbursed += amount;

        // Tokens are already in the contract from fundSubsidyProgram; just create voucher
        voucherId = _createVoucher(
            passportId,
            subsidyId,
            amount,
            VoucherCondition.TimeLocked,
            unlocksAt == 0 ? block.timestamp : unlocksAt,
            bytes32(0),
            bytes32(0),
            expiresAt
        );
    }

    // =========================================================================
    //  Section 4 — Insurance Escrow & Settlement
    // =========================================================================

    /**
     * @notice Insurer deposits tokens into escrow for a specific patient-provider claim.
     *
     * @dev    The insurer must have approved this contract to spend `amount` tokens
     *         (or use ERC-2612 permit).  Both the patient passport and provider must
     *         be valid at deposit time.
     *
     * @param passportId      Patient's passport ID.
     * @param providerId      Provider's registry ID.
     * @param recordId        Linked medical record (bytes32(0) if not yet created).
     * @param amount          Token amount to lock in escrow.
     * @param timeoutDuration Seconds from now after which the patient may reclaim if
     *                        the claim is not approved (minimum 1 day).
     * @param claimReference  Off-chain insurance claim reference string.
     * @return escrowId       Unique identifier of the new escrow.
     */
    function fundEscrow(
        bytes32 passportId,
        bytes32 providerId,
        bytes32 recordId,
        uint256 amount,
        uint256 timeoutDuration,
        string calldata claimReference
    )
        external
        nonReentrant
        whenNotPaused
        onlyActivePassport(passportId)
        onlyVerifiedProvider(providerId)
        returns (bytes32 escrowId)
    {
        if (amount == 0)                          revert InvalidAmount();
        if (timeoutDuration < 1 days)             revert InvalidTimeout();
        if (bytes(claimReference).length == 0)    revert InvalidClaimReference();

        // Optional record validation
        if (recordId != bytes32(0)) {
            if (!recordRegistry.isRecordValid(recordId)) revert RecordNotValid(recordId);
        }

        address patientWallet  = patientRegistry.getPassportWallet(passportId);
        address providerWallet = providerRegistry.getProviderWallet(providerId);

        escrowId = keccak256(
            abi.encodePacked(passportId, providerId, msg.sender, block.timestamp, _nonce++)
        );

        _escrows[escrowId] = InsuranceEscrow({
            escrowId:          escrowId,
            passportId:        passportId,
            providerId:        providerId,
            recordId:          recordId,
            patientWallet:     patientWallet,
            providerWallet:    providerWallet,
            insurerWallet:     msg.sender,
            amount:            amount,
            status:            EscrowStatus.Funded,
            fundedAt:          block.timestamp,
            claimedAt:         0,
            settledAt:         0,
            timeoutAt:         block.timestamp + timeoutDuration,
            claimReference:    claimReference,
            providerApproved:  false,
            insurerApproved:   false,
            arbitratorDecision: address(0)
        });

        _patientEscrows[passportId].push(escrowId);
        _providerEscrows[providerId].push(escrowId);
        _insurerEscrows[msg.sender].push(escrowId);

        // Pull tokens from insurer into this contract
        IERC20(address(this)).safeTransferFrom(msg.sender, address(this), amount);

        emit EscrowFunded(escrowId, passportId, providerId, msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Provider submits a claim against a funded escrow.
     * @dev    Only the registered wallet for the escrow's providerId may call this.
     *         Optionally links or updates the escrow's recordId.
     *
     * @param escrowId        The escrow to claim against.
     * @param claimReference  Updated off-chain claim reference (pass empty string to keep existing).
     */
    function submitClaim(bytes32 escrowId, string calldata claimReference)
        external
        nonReentrant
        whenNotPaused
    {
        InsuranceEscrow storage e = _escrows[escrowId];
        if (e.fundedAt == 0) revert EscrowNotFound(escrowId);
        if (e.status != EscrowStatus.Funded)
            revert InvalidEscrowStatus(escrowId, e.status, EscrowStatus.Funded);

        // Caller must be the provider wallet
        address providerWallet = providerRegistry.getProviderWallet(e.providerId);
        if (msg.sender != providerWallet)
            revert CallerNotProviderWallet(msg.sender, e.providerId);

        e.status        = EscrowStatus.Claimed;
        e.claimedAt     = block.timestamp;
        e.providerApproved = true;
        if (bytes(claimReference).length > 0) e.claimReference = claimReference;

        emit EscrowClaimed(escrowId, e.providerId, e.claimReference, block.timestamp);
    }

    /**
     * @notice Insurer approves a submitted claim, releasing tokens to the provider.
     * @dev    Only the insurer wallet that funded the escrow may call this.
     *
     * @param escrowId  The escrow to approve.
     */
    function approveEscrow(bytes32 escrowId)
        external
        nonReentrant
        whenNotPaused
    {
        InsuranceEscrow storage e = _escrows[escrowId];
        if (e.fundedAt == 0) revert EscrowNotFound(escrowId);
        if (e.status != EscrowStatus.Claimed)
            revert InvalidEscrowStatus(escrowId, e.status, EscrowStatus.Claimed);
        if (msg.sender != e.insurerWallet)
            revert CallerNotInsurerWallet(msg.sender, escrowId);

        e.status         = EscrowStatus.Approved;
        e.insurerApproved = true;
        e.settledAt      = block.timestamp;

        // Release tokens to provider
        _transfer(address(this), e.providerWallet, e.amount);

        emit EscrowApproved(escrowId, msg.sender, e.providerWallet, e.amount, block.timestamp);
    }

    /**
     * @notice Insurer disputes a submitted claim, freezing the escrow for arbitration.
     * @dev    Only the insurer wallet that funded the escrow may call this.
     *
     * @param escrowId  The escrow to dispute.
     */
    function disputeEscrow(bytes32 escrowId)
        external
        nonReentrant
        whenNotPaused
    {
        InsuranceEscrow storage e = _escrows[escrowId];
        if (e.fundedAt == 0) revert EscrowNotFound(escrowId);
        if (e.status != EscrowStatus.Claimed)
            revert InvalidEscrowStatus(escrowId, e.status, EscrowStatus.Claimed);
        if (msg.sender != e.insurerWallet)
            revert CallerNotInsurerWallet(msg.sender, escrowId);

        e.status = EscrowStatus.Disputed;

        emit EscrowDisputed(escrowId, msg.sender, block.timestamp);
    }

    /**
     * @notice Arbitrator settles a disputed escrow, directing funds to either the
     *         provider or the insurer (refund).
     * @dev    Requires ARBITRATOR_ROLE.
     *
     * @param escrowId    The disputed escrow to settle.
     * @param toProvider  If true, tokens go to the provider; if false, refunded to insurer.
     */
    function settleEscrow(bytes32 escrowId, bool toProvider)
        external
        onlyRole(ARBITRATOR_ROLE)
        nonReentrant
    {
        InsuranceEscrow storage e = _escrows[escrowId];
        if (e.fundedAt == 0) revert EscrowNotFound(escrowId);
        if (e.status != EscrowStatus.Disputed)
            revert InvalidEscrowStatus(escrowId, e.status, EscrowStatus.Disputed);

        e.status             = EscrowStatus.Settled;
        e.settledAt          = block.timestamp;
        e.arbitratorDecision = msg.sender;

        address recipient = toProvider ? e.providerWallet : e.insurerWallet;
        _transfer(address(this), recipient, e.amount);

        emit EscrowSettled(escrowId, msg.sender, recipient, e.amount, block.timestamp);
    }

    /**
     * @notice Patient reclaims escrowed tokens after the timeout has elapsed and
     *         the claim was never approved.
     * @dev    Callable by the patient wallet when status is Funded or Claimed and
     *         `timeoutAt` has passed.
     *
     * @param escrowId  The escrow to reclaim.
     */
    function reclaimEscrow(bytes32 escrowId)
        external
        nonReentrant
        whenNotPaused
    {
        InsuranceEscrow storage e = _escrows[escrowId];
        if (e.fundedAt == 0) revert EscrowNotFound(escrowId);

        bool reclaimable = (e.status == EscrowStatus.Funded || e.status == EscrowStatus.Claimed);
        if (!reclaimable)
            revert InvalidEscrowStatus(escrowId, e.status, EscrowStatus.Funded);

        if (block.timestamp < e.timeoutAt)
            revert EscrowTimeoutNotReached(escrowId, e.timeoutAt);

        // Caller must be the patient wallet
        address patientWallet = patientRegistry.getPassportWallet(e.passportId);
        if (msg.sender != patientWallet)
            revert CallerNotPatientWallet(msg.sender, e.passportId);

        e.status    = EscrowStatus.Reclaimed;
        e.settledAt = block.timestamp;

        // Return tokens to patient
        _transfer(address(this), patientWallet, e.amount);

        emit EscrowReclaimed(escrowId, e.passportId, patientWallet, e.amount, block.timestamp);
    }

    // =========================================================================
    //  View — Payments
    // =========================================================================

    /**
     * @notice Returns full details of a payment record.
     * @param paymentId  The payment identifier.
     */
    function getPayment(bytes32 paymentId) external view returns (Payment memory) {
        return _payments[paymentId];
    }

    /**
     * @notice Returns all payment IDs for a given patient passport.
     * @param passportId  Patient's passport ID.
     */
    function getPatientPaymentIds(bytes32 passportId)
        external view returns (bytes32[] memory)
    {
        return _patientPayments[passportId];
    }

    /**
     * @notice Returns all payment IDs for a given provider.
     * @param providerId  Provider's registry ID.
     */
    function getProviderPaymentIds(bytes32 providerId)
        external view returns (bytes32[] memory)
    {
        return _providerPayments[providerId];
    }

    /**
     * @notice Returns the paymentId linked to a medical record (bytes32(0) if none).
     * @param recordId  Medical record ID.
     */
    function getRecordPaymentId(bytes32 recordId) external view returns (bytes32) {
        return _recordPayment[recordId];
    }

    // =========================================================================
    //  View — Vouchers
    // =========================================================================

    /**
     * @notice Returns full details of a voucher.
     * @param voucherId  The voucher identifier.
     */
    function getVoucher(bytes32 voucherId) external view returns (Voucher memory) {
        return _vouchers[voucherId];
    }

    /**
     * @notice Returns all voucher IDs for a given patient passport.
     * @param passportId  Patient's passport ID.
     */
    function getPatientVoucherIds(bytes32 passportId)
        external view returns (bytes32[] memory)
    {
        return _patientVouchers[passportId];
    }

    // =========================================================================
    //  View — Subsidy Programs
    // =========================================================================

    /**
     * @notice Returns full details of a subsidy program.
     * @param subsidyId  The subsidy program identifier.
     */
    function getSubsidyProgram(bytes32 subsidyId)
        external view returns (SubsidyProgram memory)
    {
        return _subsidies[subsidyId];
    }

    /**
     * @notice Returns all subsidy program IDs.
     */
    function getAllSubsidyIds() external view returns (bytes32[] memory) {
        return _subsidyIds;
    }

    /**
     * @notice Returns the remaining budget for a subsidy program.
     * @param subsidyId  The subsidy program identifier.
     */
    function getSubsidyRemainingBudget(bytes32 subsidyId)
        external view returns (uint256 remaining)
    {
        SubsidyProgram storage s = _subsidies[subsidyId];
        if (s.startsAt == 0) revert SubsidyNotFound(subsidyId);
        remaining = s.budgetCap - s.disbursed;
    }

    // =========================================================================
    //  View — Insurance Escrow
    // =========================================================================

    /**
     * @notice Returns full details of an insurance escrow.
     * @param escrowId  The escrow identifier.
     */
    function getEscrow(bytes32 escrowId) external view returns (InsuranceEscrow memory) {
        return _escrows[escrowId];
    }

    /**
     * @notice Returns all escrow IDs for a given patient passport.
     * @param passportId  Patient's passport ID.
     */
    function getPatientEscrowIds(bytes32 passportId)
        external view returns (bytes32[] memory)
    {
        return _patientEscrows[passportId];
    }

    /**
     * @notice Returns all escrow IDs for a given provider.
     * @param providerId  Provider's registry ID.
     */
    function getProviderEscrowIds(bytes32 providerId)
        external view returns (bytes32[] memory)
    {
        return _providerEscrows[providerId];
    }

    /**
     * @notice Returns all escrow IDs funded by a given insurer wallet.
     * @param insurerWallet  Insurer's wallet address.
     */
    function getInsurerEscrowIds(address insurerWallet)
        external view returns (bytes32[] memory)
    {
        return _insurerEscrows[insurerWallet];
    }

    // =========================================================================
    //  Internal Helpers
    // =========================================================================

    /**
     * @dev Creates a voucher record and mints the backing tokens into this contract.
     *      Called by all `issue*Voucher` and `disburseSubsidy` functions.
     */
    function _createVoucher(
        bytes32          passportId,
        bytes32          subsidyId,
        uint256          amount,
        VoucherCondition condition,
        uint256          unlocksAt,
        bytes32          conditionProviderId,
        bytes32          conditionRecordId,
        uint256          expiresAt
    ) internal returns (bytes32 voucherId) {
        voucherId = keccak256(
            abi.encodePacked(passportId, subsidyId, block.timestamp, _nonce++)
        );

        _vouchers[voucherId] = Voucher({
            voucherId:           voucherId,
            passportId:          passportId,
            subsidyId:           subsidyId,
            amount:              amount,
            status:              VoucherStatus.Active,
            condition:           condition,
            unlocksAt:           unlocksAt,
            conditionProviderId: conditionProviderId,
            conditionRecordId:   conditionRecordId,
            issuedAt:            block.timestamp,
            expiresAt:           expiresAt
        });

        _patientVouchers[passportId].push(voucherId);

        // Mint tokens into this contract to back the voucher
        _mint(address(this), amount);

        emit VoucherIssued(voucherId, passportId, subsidyId, condition, amount, block.timestamp);
    }

    // =========================================================================
    //  Required Overrides
    // =========================================================================

    /**
     * @dev Resolves the diamond-inheritance conflict between ERC20 and ERC20Pausable.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
}
