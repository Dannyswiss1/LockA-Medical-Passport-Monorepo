// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IProviderRegistry.sol";

/**
 * @title LockAZKVerifier
 * @notice Verifies zero-knowledge proofs for the Lock protocol, with an
 *         on-chain reference to the canonical ProviderRegistry.
 * @dev Inherits OpenZeppelin {Ownable} for access-controlled administration.
 *      All privileged state mutations emit events so off-chain indexers can
 *      track configuration changes without re-reading storage.
 */
contract LockAZKVerifier is Ownable {
    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    /// @notice The provider registry used to validate proof providers.
    IProviderRegistry private _providerRegistry;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted whenever the provider registry address is updated.
     * @param providerRegistry The new provider registry address.
     */
    event ProviderRegistryUpdated(address indexed providerRegistry);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a zero address is supplied where a contract is expected.
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Initialises the verifier with an initial owner and provider registry.
     * @dev Reverts with {ZeroAddress} if either argument is the zero address.
     * @param initialOwner  Address that will own this contract (passed to {Ownable}).
     * @param providerRegistry Address of the {IProviderRegistry} implementation.
     */
    constructor(
        address initialOwner,
        address providerRegistry
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (providerRegistry == address(0)) revert ZeroAddress();

        _providerRegistry = IProviderRegistry(providerRegistry);
        emit ProviderRegistryUpdated(providerRegistry);
    }

    // -------------------------------------------------------------------------
    // Admin – setters
    // -------------------------------------------------------------------------

    /**
     * @notice Replaces the provider registry with a new implementation.
     * @dev Only callable by the contract owner.
     *      Reverts with {ZeroAddress} if `providerRegistry` is the zero address.
     * @param providerRegistry Address of the new {IProviderRegistry} implementation.
     */
    function setProviderRegistry(
        address providerRegistry
    ) external onlyOwner {
        if (providerRegistry == address(0)) revert ZeroAddress();

        _providerRegistry = IProviderRegistry(providerRegistry);
        emit ProviderRegistryUpdated(providerRegistry);
    }

    // -------------------------------------------------------------------------
    // Views – getters
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the address of the current provider registry.
     * @return The address of the {IProviderRegistry} implementation.
     */
    function providerRegistry() external view returns (address) {
        return address(_providerRegistry);
    }
}
