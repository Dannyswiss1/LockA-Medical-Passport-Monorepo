// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IHealthcarePaymentToken is IERC20 {
    // Registry references
    function patientRegistry() external view returns (address);
    function providerRegistry() external view returns (address);
    function consentManager() external view returns (address);
    function recordRegistry() external view returns (address);

    // Payment functions
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function transferWithValidation(
        address to,
        uint256 amount,
        bytes memory validationData
    ) external;

    // Voucher functions
    function issueVoucher(
        address patient,
        uint256 amount,
        uint256 expirationTime
    ) external;
    function redeemVoucher(uint256 voucherId) external;

    // Subsidy functions
    function createSubsidyPool(
        uint256 amount,
        address[] memory eligiblePatients
    ) external;
    function claimSubsidy(uint256 poolId) external;

    // Escrow functions
    function createEscrow(
        address provider,
        uint256 amount,
        uint256 releaseTime
    ) external;
    function releaseEscrow(uint256 escrowId) external;

    // Access control
    function setRegistryAddresses(
        address _patientRegistry,
        address _providerRegistry,
        address _consentManager,
        address _recordRegistry
    ) external;
}
