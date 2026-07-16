// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Interfaces
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title IENS
 * @notice Minimal interface for the ENS Registry contract.
 * @dev On Base Mainnet the registry lives at
 *      `0xb94704422c2a1e396835a571837aa5ae53285a95`.
 *      On Base Sepolia the registry lives at
 *      `0x1493b2567056c2181630115660571e0a067c2C2c`.
 */
interface IENS {
    /// @notice Returns the owner of the given ENS node.
    function owner(bytes32 node) external view returns (address);

    /// @notice Returns the resolver contract for the given ENS node.
    function resolver(bytes32 node) external view returns (address);
}

/**
 * @title IENSResolver
 * @notice Minimal interface for an ENS Resolver contract.
 * @dev On Base Mainnet the L2 Resolver lives at
 *      `0xC6d566A56A1aFf6508b41f6c90ff131615583BCD`.
 */
interface IENSResolver {
    /// @notice Returns the Ethereum address associated with an ENS node.
    function addr(bytes32 node) external view returns (address);

    /// @notice Returns the canonical ENS name associated with a node.
    function name(bytes32 node) external view returns (string memory);
}

/**
 * @title IReverseRegistrar
 * @notice Minimal interface for the ENS Reverse Registrar contract.
 * @dev On Base Mainnet: `0x79EA96012eEa67A83431F1701B3dFa14f7d322E2`.
 *      On Base Sepolia: `0xa0A8401ECF248a9375a0a71C4dedc263dA18dCd7`.
 */
interface IReverseRegistrar {
    /// @notice Returns the ENS reverse-record node for a given address.
    function node(address addr) external pure returns (bytes32);
}

// ─────────────────────────────────────────────────────────────────────────────
//  ENSResolverHelper
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title ENSResolverHelper
 * @author LockA Medical
 * @notice Shared ENS / Basename resolution utility for the LockA Medical
 *         platform on Base chain.
 *
 * @dev This is a **dedicated, standalone helper contract** — it is NOT a
 *      patient registry or provider registry itself. Its sole responsibility
 *      is to translate between:
 *        - human-readable Basenames  (e.g. "alice.base.eth")
 *        - ENS namehash nodes        (bytes32)
 *        - Ethereum wallet addresses (address)
 *
 *      Both {PatientPassportRegistry} and {ProviderRegistry} hold a reference
 *      to a single deployed instance of this contract and call it to:
 *        1. Resolve a Basename → address  (forward resolution)
 *        2. Resolve an address → Basename (reverse resolution)
 *        3. Compute the namehash of a Basename string
 *        4. Check whether an address has any registered Basename
 *
 *      ── Why a separate contract? ────────────────────────────────────────────
 *      ENS infrastructure addresses (registry, resolver, reverse registrar)
 *      are network-specific and may change. Centralising the ENS logic here
 *      means only one contract needs to be updated if Base changes its ENS
 *      infrastructure, rather than updating every registry contract.
 *
 *      ── Base Basename notes ─────────────────────────────────────────────────
 *      Base uses its own ENS-compatible infrastructure for "Basenames"
 *      (*.base.eth). The relevant on-chain addresses are:
 *
 *        Network        │ ENS Registry                               │ L2 Resolver                                │ Reverse Registrar
 *        ───────────────┼────────────────────────────────────────────┼────────────────────────────────────────────┼──────────────────────────────────────────
 *        Base Mainnet   │ 0xb94704422c2a1e396835a571837aa5ae53285a95 │ 0xC6d566A56A1aFf6508b41f6c90ff131615583BCD │ 0x79EA96012eEa67A83431F1701B3dFa14f7d322E2
 *        Base Sepolia   │ 0x1493b2567056c2181630115660571e0a067c2C2c │ 0x6533C94869D28fAA8dF77cc63f9e2b2D6Cf6eB3 │ 0xa0A8401ECF248a9375a0a71C4dedc263dA18dCd7
 *
 *      ── Namehash algorithm ──────────────────────────────────────────────────
 *      ENS uses the EIP-137 namehash algorithm:
 *        namehash("")         = 0x000…0
 *        namehash("eth")      = keccak256(namehash("") ++ keccak256("eth"))
 *        namehash("base.eth") = keccak256(namehash("eth") ++ keccak256("base"))
 *        namehash("alice.base.eth") = keccak256(namehash("base.eth") ++ keccak256("alice"))
 *
 *      This contract implements {computeNamehash} on-chain so callers never
 *      need to pre-compute the node off-chain.
 *
 *      ── Security ────────────────────────────────────────────────────────────
 *      - Only the contract owner can update the ENS infrastructure addresses.
 *      - Resolution functions are view-only and never mutate state.
 *      - Errors are thrown (not silent failures) so callers can handle them.
 *
 *      Deployed on: Base (Ethereum L2)
 */
contract ENSResolverHelper is Ownable {
    // ──────────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────────

    /// @notice The ENS Registry contract (network-specific).
    IENS public ensRegistry;

    /// @notice The default ENS Resolver (Base L2 Resolver).
    IENSResolver public defaultResolver;

    /// @notice The ENS Reverse Registrar used to compute reverse-record nodes.
    IReverseRegistrar public reverseRegistrar;

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when the ENS infrastructure addresses are updated.
     * @param ensRegistry      New ENS Registry address.
     * @param defaultResolver  New default resolver address.
     * @param reverseRegistrar New reverse registrar address.
     * @param updatedBy        The admin who performed the update.
     */
    event ENSAddressesUpdated(
        address indexed ensRegistry,
        address indexed defaultResolver,
        address indexed reverseRegistrar,
        address updatedBy
    );

    // ──────────────────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a zero address is supplied where it is not allowed.
    error ZeroAddressNotAllowed();

    /// @notice Thrown when forward resolution of an ENS node fails.
    error ENSResolutionFailed(bytes32 node);

    /// @notice Thrown when an address has no reverse ENS record.
    error NoReverseRecord(address addr);

    // ──────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploys the ENSResolverHelper with the network's ENS addresses.
     * @param _ensRegistry      Address of the ENS Registry on the target network.
     * @param _defaultResolver  Address of the default ENS Resolver.
     * @param _reverseRegistrar Address of the ENS Reverse Registrar.
     * @param _owner            Address that will be granted the admin (owner) role.
     *
     * @dev Pass the Base Mainnet or Base Sepolia addresses from the table in
     *      the contract-level natspec above. All three addresses must be
     *      non-zero; the owner must also be non-zero.
     */
    constructor(
        address _ensRegistry,
        address _defaultResolver,
        address _reverseRegistrar,
        address _owner
    ) Ownable(_owner) {
        if (
            _ensRegistry == address(0) ||
            _defaultResolver == address(0) ||
            _reverseRegistrar == address(0) ||
            _owner == address(0)
        ) {
            revert ZeroAddressNotAllowed();
        }

        ensRegistry = IENS(_ensRegistry);
        defaultResolver = IENSResolver(_defaultResolver);
        reverseRegistrar = IReverseRegistrar(_reverseRegistrar);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Admin — Update ENS Infrastructure Addresses
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates the ENS infrastructure addresses.
     * @dev Only callable by the contract owner. Useful when Base upgrades its
     *      ENS contracts or when migrating between testnets.
     * @param _ensRegistry      New ENS Registry address.
     * @param _defaultResolver  New default resolver address.
     * @param _reverseRegistrar New reverse registrar address.
     *
     * Emits an {ENSAddressesUpdated} event.
     */
    function setENSAddresses(
        address _ensRegistry,
        address _defaultResolver,
        address _reverseRegistrar
    ) external onlyOwner {
        if (
            _ensRegistry == address(0) ||
            _defaultResolver == address(0) ||
            _reverseRegistrar == address(0)
        ) {
            revert ZeroAddressNotAllowed();
        }

        ensRegistry = IENS(_ensRegistry);
        defaultResolver = IENSResolver(_defaultResolver);
        reverseRegistrar = IReverseRegistrar(_reverseRegistrar);

        emit ENSAddressesUpdated(
            _ensRegistry,
            _defaultResolver,
            _reverseRegistrar,
            msg.sender
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Pure — Namehash Computation (EIP-137)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Computes the EIP-137 namehash of a dot-separated ENS name.
     * @dev Iterates over labels from right to left (TLD first), hashing each
     *      label with the accumulated node:
     *        node = keccak256(abi.encodePacked(node, keccak256(label)))
     *      The empty string produces the zero node (bytes32(0)).
     *
     * @param name The full ENS name string, e.g. "alice.base.eth".
     * @return node The EIP-137 namehash.
     */
    function computeNamehash(string memory name) public pure returns (bytes32 node) {
        node = bytes32(0);
        bytes memory nameBytes = bytes(name);
        uint256 len = nameBytes.length;

        if (len == 0) {
            return node;
        }

        // Count labels
        uint256 labelCount = 1;
        for (uint256 i = 0; i < len; i++) {
            if (nameBytes[i] == ".") {
                labelCount++;
            }
        }

        // Store label start positions and lengths
        uint256[] memory starts = new uint256[](labelCount);
        uint256[] memory lengths = new uint256[](labelCount);
        uint256 idx = 0;
        uint256 start = 0;
        for (uint256 i = 0; i <= len; i++) {
            if (i == len || nameBytes[i] == ".") {
                starts[idx] = start;
                lengths[idx] = i - start;
                idx++;
                start = i + 1;
            }
        }

        // Hash from rightmost label (TLD) to leftmost label
        for (uint256 i = labelCount; i > 0; i--) {
            uint256 s = starts[i - 1];
            uint256 l = lengths[i - 1];
            bytes memory label = new bytes(l);
            for (uint256 j = 0; j < l; j++) {
                label[j] = nameBytes[s + j];
            }
            node = keccak256(abi.encodePacked(node, keccak256(label)));
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    //  View — Forward Resolution (Basename → Address)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Resolves a Basename string to its registered wallet address.
     * @dev Computes the namehash, looks up the resolver in the ENS Registry,
     *      then calls `addr(node)` on that resolver. Falls back to
     *      {defaultResolver} if the registry returns address(0).
     *
     * @param name The Basename string, e.g. "alice.base.eth".
     * @return resolvedAddress The wallet address registered under that name.
     *
     * Reverts with {ENSResolutionFailed} if resolution returns address(0).
     */
    function resolveNameToAddress(
        string memory name
    ) external view returns (address resolvedAddress) {
        bytes32 node = computeNamehash(name);
        resolvedAddress = _resolveNode(node);
    }

    /**
     * @notice Resolves a pre-computed ENS namehash node to its wallet address.
     * @param node The EIP-137 namehash of the ENS name.
     * @return resolvedAddress The wallet address registered under that node.
     *
     * Reverts with {ENSResolutionFailed} if resolution returns address(0).
     */
    function resolveNodeToAddress(
        bytes32 node
    ) external view returns (address resolvedAddress) {
        resolvedAddress = _resolveNode(node);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  View — Reverse Resolution (Address → Basename)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Resolves a wallet address to its registered Basename string.
     * @dev Uses the Reverse Registrar to compute the reverse-record node,
     *      then calls `name(reverseNode)` on the default resolver.
     *
     * @param addr The wallet address to look up.
     * @return ensName The Basename string, e.g. "alice.base.eth".
     *
     * Reverts with {NoReverseRecord} if the address has no reverse record.
     */
    function resolveAddressToName(
        address addr
    ) external view returns (string memory ensName) {
        bytes32 reverseNode = reverseRegistrar.node(addr);
        ensName = defaultResolver.name(reverseNode);

        if (bytes(ensName).length == 0) {
            revert NoReverseRecord(addr);
        }
    }

    /**
     * @notice Returns true if `addr` has a registered Basename (reverse record).
     * @dev Does NOT revert — returns false if the address has no reverse record.
     *      Safe to call in try/catch patterns from registry contracts.
     *
     * @param addr The wallet address to check.
     * @return hasName True if a non-empty reverse record exists.
     */
    function hasENSName(address addr) external view returns (bool hasName) {
        bytes32 reverseNode = reverseRegistrar.node(addr);
        string memory ensName = defaultResolver.name(reverseNode);
        hasName = bytes(ensName).length > 0;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Internal Helpers
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @dev Internal forward resolution: namehash node → address.
     *      Looks up the resolver from the ENS Registry; falls back to the
     *      default resolver if none is set for the node.
     */
    function _resolveNode(bytes32 node) internal view returns (address resolved) {
        address resolverAddr = ensRegistry.resolver(node);

        IENSResolver resolverContract;
        if (resolverAddr == address(0)) {
            resolverContract = defaultResolver;
        } else {
            resolverContract = IENSResolver(resolverAddr);
        }

        resolved = resolverContract.addr(node);

        if (resolved == address(0)) {
            revert ENSResolutionFailed(node);
        }
    }
}
