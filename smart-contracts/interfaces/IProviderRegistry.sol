// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IProviderRegistry
/// @author LockA Medical
/// @notice External interface for ProviderRegistry — consumed by the
///         orchestrator and sibling contracts for cross-contract validation.
interface IProviderRegistry {

    // ── Enums ─────────────────────────────────────────────────────────────

    enum ProviderStatus { Pending, Verified, Suspended, Revoked }

    // ── View helpers ──────────────────────────────────────────────────────

    /// @notice Returns true iff the provider exists AND is Verified.
    function isProviderVerified(bytes32 providerId) external view returns (bool);

    /// @notice Returns the current status of a provider (reverts if not found).
    function getProviderStatus(bytes32 providerId) external view returns (ProviderStatus);

    /// @notice Returns the wallet address of a given provider.
    function getProviderWallet(bytes32 providerId) external view returns (address);

    /// @notice Returns the providerId registered to a wallet (bytes32(0) if none).
    function getProviderIdByWallet(address wallet) external view returns (bytes32);

    /// @notice Returns true iff `wallet` owns a Verified provider registration.
    function isWalletVerifiedProvider(address wallet) external view returns (bool);
}
