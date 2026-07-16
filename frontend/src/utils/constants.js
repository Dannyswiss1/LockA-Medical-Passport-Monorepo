// ============================================================
// CONTRACT ADDRESSES — configurable via Admin Panel / localStorage
// ============================================================
export const DEFAULT_ADDRESSES = {
  PatientPassportRegistry: '0x0000000000000000000000000000000000000000',
  ProviderRegistry: '0x0000000000000000000000000000000000000000',
  MedicalRecordRegistry: '0x0000000000000000000000000000000000000000',
  ConsentAccessManager: '0x0000000000000000000000000000000000000000',
};

export const LS_KEY = 'locka_contract_addresses';

export function getContractAddresses() {
  try {
    const stored = localStorage.getItem(LS_KEY);
    if (stored) return { ...DEFAULT_ADDRESSES, ...JSON.parse(stored) };
  } catch (_) {}
  return { ...DEFAULT_ADDRESSES };
}

export function saveContractAddresses(addresses) {
  localStorage.setItem(LS_KEY, JSON.stringify(addresses));
}

export const TARGET_CHAIN_ID = 84532;
export const TARGET_CHAIN_HEX = '0x14a34';
export const NETWORK_NAME = 'Base Sepolia';

// ============================================================
// ENUMS
// ============================================================
export const PassportStatus = { 0: 'Active', 1: 'Suspended', 2: 'Revoked' };
export const ProviderStatus = { 0: 'Pending', 1: 'Verified', 2: 'Suspended', 3: 'Revoked' };
export const RecordStatus = { 0: 'Active', 1: 'Amended', 2: 'Revoked' };
export const AccessStatus = { 0: 'Pending', 1: 'Approved', 2: 'Rejected', 3: 'Revoked', 4: 'Expired' };

export const ProviderTypes = [
  { value: 0, label: 'Hospital' },
  { value: 1, label: 'Clinic' },
  { value: 2, label: 'Doctor' },
  { value: 3, label: 'Laboratory' },
  { value: 4, label: 'Pharmacy' },
  { value: 5, label: 'Insurance Company' },
  { value: 6, label: 'Public Health Agency' },
];

export const RecordTypes = [
  { value: 0, label: 'Lab Result' },
  { value: 1, label: 'Prescription' },
  { value: 2, label: 'Diagnosis' },
  { value: 3, label: 'Vaccination' },
  { value: 4, label: 'Surgery Report' },
  { value: 5, label: 'Allergy Record' },
  { value: 6, label: 'Insurance Record' },
  { value: 7, label: 'Medical Summary' },
];

export const RecordScopes = [
  { value: 0, label: 'All Records' },
  { value: 1, label: 'Lab Results Only' },
  { value: 2, label: 'Prescriptions Only' },
  { value: 3, label: 'Vaccination Records Only' },
  { value: 4, label: 'Emergency Summary Only' },
  { value: 5, label: 'Insurance Data Only' },
];

// ============================================================
// ABIs
// ============================================================
export const PATIENT_PASSPORT_ABI = [
  "function registerPatient(bytes32 publicIdentityHash, address recoveryAddress) external",
  "function getPassportIdByWallet(address wallet) external view returns (bytes32)",
  "function isPassportActive(bytes32 passportId) external view returns (bool)",
  "function getPassportStatus(bytes32 passportId) external view returns (uint8)",
  "function getPassportWallet(bytes32 passportId) external view returns (address)",
  "function isWalletRegistered(address wallet) external view returns (bool)",
  "function updateRecoveryAddress(bytes32 passportId, address newRecoveryAddress) external",
  "function suspendPassport(bytes32 passportId) external",
  "function reactivatePassport(bytes32 passportId) external",
  "event PatientRegistered(bytes32 indexed passportId, address indexed wallet)",
  "event PassportStatusChanged(bytes32 indexed passportId, uint8 newStatus)",
];

export const PROVIDER_REGISTRY_ABI = [
  "function register_provider(uint8 providerType, bytes32 licenseHash, string calldata country) external",
  "function getProviderIdByWallet(address wallet) external view returns (bytes32)",
  "function isProviderVerified(bytes32 providerId) external view returns (bool)",
  "function getProviderStatus(bytes32 providerId) external view returns (uint8)",
  "function getProviderWallet(bytes32 providerId) external view returns (address)",
  "function isWalletVerifiedProvider(address wallet) external view returns (bool)",
  "function verify_provider(bytes32 providerId) external",
  "function suspend_provider(bytes32 providerId) external",
  "function reactivate_provider(bytes32 providerId) external",
  "event ProviderRegistered(bytes32 indexed providerId, address indexed wallet, uint8 providerType)",
  "event ProviderStatusChanged(bytes32 indexed providerId, uint8 newStatus)",
];

export const MEDICAL_RECORD_ABI = [
  "function add_record(bytes32 passportId, bytes32 providerId, uint8 recordType, bytes32 encryptedFileHash, bytes32 storagePointerHash) external",
  "function getPatientRecordIds(bytes32 passportId) external view returns (bytes32[])",
  "function getProviderRecordIds(bytes32 providerId) external view returns (bytes32[])",
  "function getRecordStatus(bytes32 recordId) external view returns (uint8)",
  "function getRecordPassportId(bytes32 recordId) external view returns (bytes32)",
  "function getRecordProviderId(bytes32 recordId) external view returns (bytes32)",
  "function isRecordValid(bytes32 recordId) external view returns (bool)",
  "function verify_record_hash(bytes32 recordId, bytes32 fileHash) external view returns (bool)",
  "function update_record_status(bytes32 recordId, uint8 newStatus) external",
  "event RecordAdded(bytes32 indexed recordId, bytes32 indexed passportId, bytes32 indexed providerId, uint8 recordType)",
  "event RecordStatusChanged(bytes32 indexed recordId, uint8 newStatus)",
];

export const CONSENT_ACCESS_ABI = [
  "function request_access(bytes32 passportId, bytes32 providerId, address patientWallet, uint8 recordScope, uint256 expiresAt) external",
  "function approve_access(bytes32 accessId) external",
  "function reject_access(bytes32 accessId) external",
  "function revoke_access(bytes32 accessId) external",
  "function getPatientAccessIds(bytes32 passportId) external view returns (bytes32[])",
  "function getProviderAccessIds(bytes32 providerId) external view returns (bytes32[])",
  "function hasActiveAccess(bytes32 passportId, bytes32 providerId) external view returns (bool)",
  "function getAccessStatus(bytes32 accessId) external view returns (uint8)",
  "event AccessRequested(bytes32 indexed accessId, bytes32 indexed passportId, bytes32 indexed providerId)",
  "event AccessStatusChanged(bytes32 indexed accessId, uint8 newStatus)",
];
