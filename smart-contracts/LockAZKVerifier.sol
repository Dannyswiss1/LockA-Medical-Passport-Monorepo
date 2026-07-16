// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IPatientPassportRegistry.sol";
import "./interfaces/IProviderRegistry.sol";
import "./interfaces/ILockAZKVerifier.sol";

// -----------------------------------------------------------------------------
//  zkVerify Aggregation Interface
// -----------------------------------------------------------------------------

/// @dev Minimal interface for the zkVerify aggregation contract on Base.
interface IVerifyProofAggregation {
    function verifyProofAggregation(
        uint256 domainId,
        uint256 aggregationId,
        bytes32 leaf,
        bytes32[] calldata merklePath,
        uint256 leafCount,
        uint256 index
    ) external view returns (bool);
}

// LockAZKVerifier - Validates privacy-preserving identity, eligibility, and credential
// proofs for the LockA Medical platform using zkVerify.
//
// Implements ILockAZKVerifier. Performs direct cross-contract validation:
//   - Calls IPatientPassportRegistry-isPassportActive to confirm the patient
//     passport exists and is active before recording a verified claim.
//
// Integration pattern with zkVerify:
//   - The zkVerify aggregation contract stores Merkle roots of verified proofs.
//   - This contract calls IVerifyProofAggregation-verifyProofAggregation to
//     verify that a proof was indeed verified by zkVerify.
//   - The leaf is a "statement hash" computed from the proving system ID,
//     verification key hash, version hash, and public inputs hash.
//   - Groth16 statement hash formula:
//       keccak256(PROVING_SYSTEM_ID || vkHash || NO_VERSION_HASH ||
//                 keccak256(encodedPublicInputs))
//     where each public input uint256 is converted to little-endian bytes32.
//
// Security model:
//   - Statement hashes are tracked to prevent replay attacks.
//   - Claims can be revoked by the original verifier or the contract owner.
//   - All state-changing external functions are protected by ReentrancyGuard
//     and Pausable via the whenNotPaused modifier.
//   - The whenPaused modifier (inherited from OZ Pausable) is intentionally
//     not applied to any function: no recovery path requires exclusive
//     paused-state access in this contract's design.
//   - The admin setter setPatientRegistry is deliberately NOT gated by
//     whenNotPaused so the owner can re-wire the registry address even
//     during an emergency pause without needing to unpause first.
//   - OZ Pausable emits Paused(address account) and
//     Unpaused(address account) automatically from _pause() / _unpause().
//
// Deployed on: Base (Ethereum L2)
//   Base Mainnet zkVerify: 0xCb47A3C3B9Eb2E549a3F2EA4729De28CafbB2b69
//   Base Sepolia  zkVerify: 0x0807C544D38aE7729f8798388d89Be6502A1e8A8
//
// PAUSABLE COMPLIANCE FIXES (this revision)
//   P-1  pause()   - completed NatSpec: added notice, dev, emits tags.
//   P-2  unpause() - completed NatSpec: added notice, dev, emits tags.
//   P-3  Paused / Unpaused events - documented in the dev security-model block
//        above so callers know OZ emits them automatically.
//   P-4  paused() view - added to ILockAZKVerifier so orchestrators can query
//        pause state through the interface without an unsafe cast.
//   P-5  setPatientRegistry - added explicit dev note explaining why it is
//        intentionally NOT gated by whenNotPaused.
//   P-6  Pausable() constructor call - removed the redundant explicit call;
//        OZ v5 Pausable has no-arg constructor invoked automatically.
//   P-7  whenPaused usage - documented in the security-model dev block above.
//   P-8  Interface pragma - updated ILockAZKVerifier.sol from ^0.8.34 to ^0.8.20.
//   P-9  pause() / unpause() / paused() - added to ILockAZKVerifier interface.
//
// PREVIOUS FIXES (deployment blockers - 18 issues)
//   #1  pragma bumped from ^0.8.34 to ^0.8.20 to satisfy the OpenZeppelin v5
//       dependency floor (OZ v5 requires ^0.8.20).
//   #2  pragma solidity line was missing from the on-disk file entirely.
//   #3  import "./interfaces/ILockAZKVerifier.sol" import was missing.
//   #4  verify_claim - missing closing } caused the following function to
//       be parsed as a nested declaration, triggering a cascade of parse errors.
//   #5  revoke_claim - VerifiedClaim storage claim local variable
//       declaration was missing before first use.
//   #6  revoke_claim - missing closing }.
//   #7  hasActiveClaim - bytes32[] storage ids local variable was missing
//       before the for-loop.
//   #8  hasActiveClaim - missing closing }.
//   #9  getClaimStatus - missing return _claims[claimId].status; statement.
//   #10 getPassportClaimIds - missing return _passportClaims[passportId];.
//   #11 isIdentityVerified - bytes32[] storage ids local variable was
//       missing before the for-loop.
//   #12 isIdentityVerified - missing closing }.
//   #13 get_claim - missing return _claims[claimId]; statement.
//   #14 isStatementHashUsed - missing return _usedStatementHashes[...].
//   #15 _computeStatementHash - missing outer for-loop declaration
//       (uint256 i) and uint256 offset variable.
//   #16 _computeStatementHash - missing closing } for the outer for-loop.
//   #17 _toLittleEndian - missing for-loop wrapping the bit-shift / OR
//       assignment, making the function return bytes32(0) for all inputs.
//   #18 NO_VERSION_HASH - hex literal contained an illegal _ separator
//       character, causing a compile error.

contract LockAZKVerifier is ILockAZKVerifier, Ownable, ReentrancyGuard, Pausable {

    // =========================================================================
    //  Structs
    // =========================================================================

    /// @notice On-chain record of a verified zero-knowledge proof claim.
    struct VerifiedClaim {
        bytes32     claimId;
        bytes32     passportId;
        ClaimType   claimType;
        bytes32     proofStatementHash;
        uint256     domainId;
        uint256     aggregationId;
        ClaimStatus status;
        address     verifiedBy;
        uint256     verifiedAt;
        uint256     expiresAt;
        uint256     revokedAt;
    }

    /**
     * @notice Input parameters for verify_claim, bundled to avoid
     *         stack-too-deep errors.
     */
    struct VerifyClaimParams {
        bytes32   passportId;
        ClaimType claimType;
        bytes32   vkHash;
        uint256[] publicInputs;
        uint256   domainId;
        uint256   aggregationId;
        bytes32[] merklePath;
        uint256   leafCount;
        uint256   index;
        uint256   expiresAt;
    }

    // =========================================================================
    //  Custom Errors
    // =========================================================================

    error ClaimNotFound(bytes32 claimId);
    error Unauthorised(address caller);
    error ZeroAddressNotAllowed();
    error InvalidPassportId();
    error InvalidProofStatementHash();
    error InvalidExpiry(uint256 expiresAt);
    error ClaimAlreadyRevoked(bytes32 claimId);
    error ProofVerificationFailed(bytes32 statementHash);
    error StatementHashAlreadyUsed(bytes32 statementHash);
    error InvalidClaimStatus(bytes32 claimId, ClaimStatus current);
    /// @notice Thrown when the patient passport is not active (cross-contract check).
    error PassportNotActive(bytes32 passportId);

    // =========================================================================
    //  Constants
    // =========================================================================

    /// @notice Proving-system identifier used in the Groth16 statement hash.
    bytes32 public constant GROTH16_PROVING_SYSTEM_ID =
        keccak256(abi.encodePacked("groth16"));

    /**
     * @notice sha256("") — the version hash for proofs that carry no version
     *         string.
     * @dev    FIX #18: the original literal contained an illegal `_` separator.
     *         Correct value: sha256("") =
     *           e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
     */
    bytes32 public constant NO_VERSION_HASH =
        bytes32(0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855);

    // =========================================================================
    //  Immutables
    // =========================================================================

    /// @notice The zkVerify aggregation contract on Base (set once at deploy).
    IVerifyProofAggregation public immutable zkVerifyAggregation;

    // =========================================================================
    //  State
    // =========================================================================

    uint256 private _nonce;

    mapping(bytes32 => VerifiedClaim) private _claims;
    mapping(bytes32 => bytes32[])     private _passportClaims;
    mapping(bytes32 => bool)          private _usedStatementHashes;

    /// @notice Live reference to the PatientPassportRegistry for cross-contract
    ///         validation. Updatable by the owner via setPatientRegistry.
    IPatientPassportRegistry public patientRegistry;

    /// @notice Live reference to the ProviderRegistry for cross-contract
    ///         validation. Updatable by the owner via setProviderRegistry.
    IProviderRegistry public providerRegistry;

    // =========================================================================
    //  Events
    // =========================================================================

    /**
     * @notice Emitted when a ZK proof claim is successfully verified and stored.
     * @param claimId            Unique identifier of the new claim.
     * @param passportId         The patient passport the claim is bound to.
     * @param claimType          Category of the verified claim.
     * @param proofStatementHash Groth16 statement hash verified on-chain.
     * @param verifiedAt         Block timestamp of verification.
     */
    event ClaimVerified(
        bytes32 indexed claimId,
        bytes32 indexed passportId,
        ClaimType       claimType,
        bytes32         proofStatementHash,
        uint256         verifiedAt
    );

    /**
     * @notice Emitted when a claim is revoked.
     * @param claimId    Identifier of the revoked claim.
     * @param passportId Passport the claim was bound to.
     * @param revokedAt  Block timestamp of revocation.
     */
    event ClaimRevoked(
        bytes32 indexed claimId,
        bytes32 indexed passportId,
        uint256         revokedAt
    );

    /**
     * @notice Emitted when the owner updates the patient registry address.
     * @param newRegistry New registry contract address.
     */
    event PatientRegistryUpdated(address indexed newRegistry);

    /**
     * @notice Emitted when the owner updates the provider registry address.
     * @param newRegistry New registry contract address.
     */
    event ProviderRegistryUpdated(address indexed newRegistry);

    // NOTE: OZ Pausable automatically emits:
    //   Paused(address account)   - from _pause()   inside pause()
    //   Unpaused(address account) - from _unpause() inside unpause()
    // These are defined in the OZ base contract and do not need to be
    // re-declared here. (FIX P-3)

    // =========================================================================
    //  Modifiers
    // =========================================================================

    /**
     * @dev Reverts with ClaimNotFound if claimId has never been recorded.
     *      Existence is indicated by a non-zero verifiedAt timestamp.
     */
    modifier claimExists(bytes32 claimId) {
        if (_claims[claimId].verifiedAt == 0) revert ClaimNotFound(claimId);
        _;
    }

    // =========================================================================
    //  Constructor
    // =========================================================================

    /**
     * @notice Deploys the verifier and wires up its external dependencies.
     *
     * @dev Ownable(initialOwner) is the only parent constructor that requires
     *      an explicit argument in OZ v5. ReentrancyGuard and Pausable have
     *      zero-argument constructors that Solidity invokes automatically -
     *      there is no need to call Pausable() explicitly. (FIX P-6)
     *
     * @param initialOwner         Address that will own this contract.
     * @param _zkVerifyAggregation zkVerify aggregation contract on Base.
     * @param _patientRegistry     Address of the deployed PatientPassportRegistry.
     * @param _providerRegistry    Address of the deployed ProviderRegistry.
     */
    constructor(
        address initialOwner,
        address _zkVerifyAggregation,
        address _patientRegistry,
        address _providerRegistry
    ) Ownable(initialOwner) {
        // Ownable already reverts on address(0) for initialOwner, but we
        // keep the unified check here for a consistent custom error surface.
        if (
            initialOwner         == address(0) ||
            _zkVerifyAggregation == address(0) ||
            _patientRegistry     == address(0) ||
            _providerRegistry    == address(0)
        ) revert ZeroAddressNotAllowed();

        zkVerifyAggregation = IVerifyProofAggregation(_zkVerifyAggregation);
        patientRegistry     = IPatientPassportRegistry(_patientRegistry);
        providerRegistry    = IProviderRegistry(_providerRegistry);
    }

    // =========================================================================
    //  Admin - Registry Address
    // =========================================================================

    /**
     * @notice Replaces the PatientPassportRegistry reference.
     * @dev    Only callable by the owner. Emits PatientRegistryUpdated.
     *
     *         Intentionally NOT gated by whenNotPaused (FIX P-5): the owner
     *         must be able to re-wire the registry address even during an
     *         emergency pause (e.g. to point away from a compromised registry)
     *         without needing to unpause the contract first.
     *
     * @param  _patientRegistry New registry address (must be non-zero).
     */
    function setPatientRegistry(address _patientRegistry) external onlyOwner {
        if (_patientRegistry == address(0)) revert ZeroAddressNotAllowed();
        patientRegistry = IPatientPassportRegistry(_patientRegistry);
        emit PatientRegistryUpdated(_patientRegistry);
    }

    /**
     * @notice Replaces the ProviderRegistry reference.
     * @dev    Only callable by the owner. Emits ProviderRegistryUpdated.
     *
     *         Intentionally NOT gated by whenNotPaused: the owner
     *         must be able to re-wire the registry address even during an
     *         emergency pause (e.g. to point away from a compromised registry)
     *         without needing to unpause the contract first.
     *
     * @param  _providerRegistry New registry address (must be non-zero).
     */
    function setProviderRegistry(address _providerRegistry) external onlyOwner {
        if (_providerRegistry == address(0)) revert ZeroAddressNotAllowed();
        providerRegistry = IProviderRegistry(_providerRegistry);
        emit ProviderRegistryUpdated(_providerRegistry);
    }

    // =========================================================================
    //  External - Claim Verification
    // =========================================================================

    /**
     * @notice Submits and verifies a zero-knowledge proof claim against zkVerify.
     *
     * @dev Cross-contract validation: confirms passportId is active before
     *      recording. Computes the Groth16 statement hash and verifies Merkle
     *      inclusion. Replay protection: each statement hash may only be used once.
     *
     *      Protected by whenNotPaused (inherited from OZ Pausable) and
     *      nonReentrant (from OZ ReentrancyGuard).
     *
     * @param  params  Bundled verification parameters (see VerifyClaimParams).
     * @return claimId Unique identifier of the newly recorded verified claim.
     */
    function verify_claim(
        VerifyClaimParams calldata params
    ) external whenNotPaused nonReentrant returns (bytes32 claimId) {
        if (params.passportId == bytes32(0)) revert InvalidPassportId();
        if (params.expiresAt != 0 && params.expiresAt <= block.timestamp)
            revert InvalidExpiry(params.expiresAt);

        // Cross-contract: patient passport must be active
        if (!patientRegistry.isPassportActive(params.passportId))
            revert PassportNotActive(params.passportId);

        // Compute Groth16 statement hash
        bytes32 statementHash = _computeStatementHash(params.vkHash, params.publicInputs);
        if (statementHash == bytes32(0)) revert InvalidProofStatementHash();
        if (_usedStatementHashes[statementHash])
            revert StatementHashAlreadyUsed(statementHash);

        // Verify Merkle inclusion against the zkVerify aggregation contract
        bool valid = zkVerifyAggregation.verifyProofAggregation(
            params.domainId,
            params.aggregationId,
            statementHash,
            params.merklePath,
            params.leafCount,
            params.index
        );
        if (!valid) revert ProofVerificationFailed(statementHash);

        // Mark hash as consumed (replay protection)
        _usedStatementHashes[statementHash] = true;

        // Derive a unique claim ID
        claimId = keccak256(
            abi.encodePacked(params.passportId, statementHash, block.timestamp, _nonce++)
        );

        // Persist the claim
        _claims[claimId] = VerifiedClaim({
            claimId:            claimId,
            passportId:         params.passportId,
            claimType:          params.claimType,
            proofStatementHash: statementHash,
            domainId:           params.domainId,
            aggregationId:      params.aggregationId,
            status:             ClaimStatus.Verified,
            verifiedBy:         msg.sender,
            verifiedAt:         block.timestamp,
            expiresAt:          params.expiresAt,
            revokedAt:          0
        });

        _passportClaims[params.passportId].push(claimId);

        emit ClaimVerified(
            claimId,
            params.passportId,
            params.claimType,
            statementHash,
            block.timestamp
        );
    }

    /**
     * @notice Revokes a verified claim.
     * @dev    Callable by the original verifier (verifiedBy) or the owner.
     *         Protected by whenNotPaused and nonReentrant.
     * @param  claimId Identifier of the claim to revoke.
     */
    function revoke_claim(
        bytes32 claimId
    ) external whenNotPaused nonReentrant claimExists(claimId) {
        VerifiedClaim storage claim = _claims[claimId];

        if (msg.sender != claim.verifiedBy && msg.sender != owner())
            revert Unauthorised(msg.sender);
        if (claim.status == ClaimStatus.Revoked)
            revert ClaimAlreadyRevoked(claimId);

        claim.status    = ClaimStatus.Revoked;
        claim.revokedAt = block.timestamp;

        emit ClaimRevoked(claimId, claim.passportId, block.timestamp);
    }

    // =========================================================================
    //  External - View  (ILockAZKVerifier implementation)
    // =========================================================================

    /// @inheritdoc ILockAZKVerifier
    function hasActiveClaim(
        bytes32   passportId,
        ClaimType claimType
    ) external view override returns (bool) {
        bytes32[] storage ids = _passportClaims[passportId];
        for (uint256 i = 0; i < ids.length; i++) {
            VerifiedClaim storage c = _claims[ids[i]];
            if (
                c.claimType == claimType &&
                c.status    == ClaimStatus.Verified &&
                (c.expiresAt == 0 || block.timestamp <= c.expiresAt)
            ) {
                return true;
            }
        }
        return false;
    }

    /// @inheritdoc ILockAZKVerifier
    function getClaimStatus(
        bytes32 claimId
    ) external view override claimExists(claimId) returns (ClaimStatus) {
        return _claims[claimId].status;
    }

    /// @inheritdoc ILockAZKVerifier
    function getPassportClaimIds(
        bytes32 passportId
    ) external view override returns (bytes32[] memory) {
        return _passportClaims[passportId];
    }

    /// @inheritdoc ILockAZKVerifier
    function isIdentityVerified(
        bytes32 passportId
    ) external view override returns (bool) {
        bytes32[] storage ids = _passportClaims[passportId];
        for (uint256 i = 0; i < ids.length; i++) {
            VerifiedClaim storage c = _claims[ids[i]];
            if (
                c.claimType == ClaimType.IdentityVerification &&
                c.status    == ClaimStatus.Verified &&
                (c.expiresAt == 0 || block.timestamp <= c.expiresAt)
            ) {
                return true;
            }
        }
        return false;
    }

    // =========================================================================
    //  External - Additional View Helpers
    // =========================================================================

    /**
     * @notice Returns the full on-chain record for a given claim.
     * @param  claimId The claim to look up (reverts via claimExists if absent).
     * @return The VerifiedClaim struct.
     */
    function get_claim(
        bytes32 claimId
    ) external view claimExists(claimId) returns (VerifiedClaim memory) {
        return _claims[claimId];
    }

    /**
     * @notice Returns true if the given statement hash has already been consumed.
     * @param  statementHash The Groth16 statement hash to query.
     * @return True iff the hash was consumed by a prior verify_claim call.
     */
    function isStatementHashUsed(bytes32 statementHash) external view returns (bool) {
        return _usedStatementHashes[statementHash];
    }

    // =========================================================================
    //  Admin - Emergency Controls  (Pausable)  (FIX P-1, P-2, P-6)
    // =========================================================================

    /**
     * @dev Returns true if the contract is currently paused.
     *      Overrides both ILockAZKVerifier-paused and Pausable-paused.
     *      Delegates to the OZ Pausable implementation.
     */
    function paused() public view override(ILockAZKVerifier, Pausable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Pauses all state-changing operations on this contract.
     * @dev    Calls the internal OZ Pausable-_pause hook, which:
     *           1. Reverts if the contract is already paused.
     *           2. Sets the internal paused flag to true.
     *           3. Emits Paused(msg.sender).
     *         Only callable by the owner.
     *         While paused, any function decorated with whenNotPaused will
     *         revert with EnforcedPause().
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, resuming all normal operations.
     * @dev    Calls the internal OZ Pausable-_unpause hook, which:
     *           1. Reverts if the contract is not currently paused.
     *           2. Sets the internal paused flag to false.
     *           3. Emits Unpaused(msg.sender).
     *         Only callable by the owner.
     *         After unpausing, all whenNotPaused-gated functions become
     *         callable again.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    //  Internal - Proof Helpers
    // =========================================================================

    /**
     * @dev Computes the Groth16 statement hash from vkHash and publicInputs.
     *
     *      Formula:
     *        keccak256(GROTH16_PROVING_SYSTEM_ID || vkHash || NO_VERSION_HASH ||
     *                  keccak256(encodedPublicInputs))
     *
     *      Each public input uint256 is serialised as a 32-byte little-endian word.
     *
     * @param  vkHash       Verification key hash for the Groth16 circuit.
     * @param  publicInputs Public inputs to the proof.
     * @return              The Groth16 statement hash (leaf for Merkle check).
     */
    function _computeStatementHash(
        bytes32            vkHash,
        uint256[] calldata publicInputs
    ) internal pure returns (bytes32) {
        bytes memory encodedInputs = new bytes(publicInputs.length * 32);

        for (uint256 i = 0; i < publicInputs.length; i++) {
            bytes32 le     = _toLittleEndian(publicInputs[i]);
            uint256 offset = i * 32;
            for (uint256 j = 0; j < 32; j++) {
                encodedInputs[offset + j] = le[j];
            }
        }

        bytes32 publicInputsHash = keccak256(encodedInputs);
        return keccak256(
            abi.encodePacked(GROTH16_PROVING_SYSTEM_ID, vkHash, NO_VERSION_HASH, publicInputsHash)
        );
    }

    /**
     * @dev Converts a uint256 to its little-endian bytes32 representation by
     *      reading each byte from LSB to MSB and placing it at the corresponding
     *      position in the result word.
     *
     * @param  value The value to convert.
     * @return result The little-endian bytes32.
     */
    function _toLittleEndian(uint256 value) internal pure returns (bytes32 result) {
        for (uint256 i = 0; i < 32; i++) {
            result |= bytes32(bytes1(uint8(value >> (i * 8)))) >> (i * 8);
        }
    }
}
