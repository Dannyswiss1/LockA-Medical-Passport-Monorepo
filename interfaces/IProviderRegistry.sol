// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IProviderRegistry
 * @notice Interface for the ProviderRegistry contract used by {LockAZKVerifier}.
 * @dev Implement this interface in the concrete ProviderRegistry contract.
 */
interface IProviderRegistry {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a new provider is registered.
     * @param provider The address of the registered provider.
     */
    event ProviderRegistered(address indexed provider);

    /**
     * @notice Emitted when an existing provider is removed.
     * @param provider The address of the removed provider.
     */
    event ProviderRemoved(address indexed provider);

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Checks whether `provider` is currently registered.
     * @param provider The address to query.
     * @return True if registered, false otherwise.
     */
    function isRegistered(address provider) external view returns (bool);

    /**
     * @notice Returns the total number of registered providers.
     * @return The provider count.
     */
    function providerCount() external view returns (uint256);
}
