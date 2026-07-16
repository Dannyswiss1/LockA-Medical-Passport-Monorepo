import { useCallback } from 'react';
import { ethers } from 'ethers';
import {
  PATIENT_PASSPORT_ABI,
  PROVIDER_REGISTRY_ABI,
  MEDICAL_RECORD_ABI,
  CONSENT_ACCESS_ABI,
  getContractAddresses,
} from '../utils/constants.js';
import { isZeroAddress } from '../utils/helpers.js';

function getContract(name, abiMap, signerOrProvider) {
  const addresses = getContractAddresses();
  const addr = addresses[name];
  if (!addr || isZeroAddress(addr)) return null;
  return new ethers.Contract(addr, abiMap[name], signerOrProvider);
}

const ABI_MAP = {
  PatientPassportRegistry: PATIENT_PASSPORT_ABI,
  ProviderRegistry:        PROVIDER_REGISTRY_ABI,
  MedicalRecordRegistry:   MEDICAL_RECORD_ABI,
  ConsentAccessManager:    CONSENT_ACCESS_ABI,
};

export function useContracts(provider, signer) {

  // ── PatientPassportRegistry ──────────────────────────────
  const registerPatient = useCallback(async (publicIdentityHash, recoveryAddress) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, signer);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return (await c.registerPatient(publicIdentityHash, recoveryAddress)).wait();
  }, [signer]);

  const getPassportIdByWallet = useCallback(async (wallet) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, provider);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return c.getPassportIdByWallet(wallet);
  }, [provider]);

  const isPassportActive = useCallback(async (passportId) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, provider);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return c.isPassportActive(passportId);
  }, [provider]);

  const getPassportStatus = useCallback(async (passportId) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, provider);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return c.getPassportStatus(passportId);
  }, [provider]);

  const isWalletRegistered = useCallback(async (wallet) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, provider);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return c.isWalletRegistered(wallet);
  }, [provider]);

  const updateRecoveryAddress = useCallback(async (passportId, newRecoveryAddress) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, signer);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return (await c.updateRecoveryAddress(passportId, newRecoveryAddress)).wait();
  }, [signer]);

  const suspendPassport = useCallback(async (passportId) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, signer);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return (await c.suspendPassport(passportId)).wait();
  }, [signer]);

  const reactivatePassport = useCallback(async (passportId) => {
    const c = getContract('PatientPassportRegistry', ABI_MAP, signer);
    if (!c) throw new Error('PatientPassportRegistry address not configured');
    return (await c.reactivatePassport(passportId)).wait();
  }, [signer]);

  // ── ProviderRegistry ─────────────────────────────────────
  const registerProvider = useCallback(async (providerType, licenseHash, country) => {
    const c = getContract('ProviderRegistry', ABI_MAP, signer);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return (await c.register_provider(providerType, licenseHash, country)).wait();
  }, [signer]);

  const getProviderIdByWallet = useCallback(async (wallet) => {
    const c = getContract('ProviderRegistry', ABI_MAP, provider);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return c.getProviderIdByWallet(wallet);
  }, [provider]);

  const isProviderVerified = useCallback(async (providerId) => {
    const c = getContract('ProviderRegistry', ABI_MAP, provider);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return c.isProviderVerified(providerId);
  }, [provider]);

  const getProviderStatus = useCallback(async (providerId) => {
    const c = getContract('ProviderRegistry', ABI_MAP, provider);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return c.getProviderStatus(providerId);
  }, [provider]);

  const isWalletVerifiedProvider = useCallback(async (wallet) => {
    const c = getContract('ProviderRegistry', ABI_MAP, provider);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return c.isWalletVerifiedProvider(wallet);
  }, [provider]);

  const verifyProvider = useCallback(async (providerId) => {
    const c = getContract('ProviderRegistry', ABI_MAP, signer);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return (await c.verify_provider(providerId)).wait();
  }, [signer]);

  const suspendProvider = useCallback(async (providerId) => {
    const c = getContract('ProviderRegistry', ABI_MAP, signer);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return (await c.suspend_provider(providerId)).wait();
  }, [signer]);

  const reactivateProvider = useCallback(async (providerId) => {
    const c = getContract('ProviderRegistry', ABI_MAP, signer);
    if (!c) throw new Error('ProviderRegistry address not configured');
    return (await c.reactivate_provider(providerId)).wait();
  }, [signer]);

  // ── MedicalRecordRegistry ────────────────────────────────
  const addRecord = useCallback(async (passportId, providerId, recordType, encryptedFileHash, storagePointerHash) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, signer);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return (await c.add_record(passportId, providerId, recordType, encryptedFileHash, storagePointerHash)).wait();
  }, [signer]);

  const getPatientRecordIds = useCallback(async (passportId) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, provider);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return c.getPatientRecordIds(passportId);
  }, [provider]);

  const getProviderRecordIds = useCallback(async (providerId) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, provider);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return c.getProviderRecordIds(providerId);
  }, [provider]);

  const getRecordStatus = useCallback(async (recordId) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, provider);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return c.getRecordStatus(recordId);
  }, [provider]);

  const getRecordPassportId = useCallback(async (recordId) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, provider);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return c.getRecordPassportId(recordId);
  }, [provider]);

  const getRecordProviderId = useCallback(async (recordId) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, provider);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return c.getRecordProviderId(recordId);
  }, [provider]);

  const isRecordValid = useCallback(async (recordId) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, provider);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return c.isRecordValid(recordId);
  }, [provider]);

  const verifyRecordHash = useCallback(async (recordId, fileHash) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, provider);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return c.verify_record_hash(recordId, fileHash);
  }, [provider]);

  const updateRecordStatus = useCallback(async (recordId, newStatus) => {
    const c = getContract('MedicalRecordRegistry', ABI_MAP, signer);
    if (!c) throw new Error('MedicalRecordRegistry address not configured');
    return (await c.update_record_status(recordId, newStatus)).wait();
  }, [signer]);

  // ── ConsentAccessManager ─────────────────────────────────
  const requestAccess = useCallback(async (passportId, providerId, patientWallet, recordScope, expiresAt) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, signer);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return (await c.request_access(passportId, providerId, patientWallet, recordScope, expiresAt)).wait();
  }, [signer]);

  const approveAccess = useCallback(async (accessId) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, signer);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return (await c.approve_access(accessId)).wait();
  }, [signer]);

  const rejectAccess = useCallback(async (accessId) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, signer);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return (await c.reject_access(accessId)).wait();
  }, [signer]);

  const revokeAccess = useCallback(async (accessId) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, signer);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return (await c.revoke_access(accessId)).wait();
  }, [signer]);

  const getPatientAccessIds = useCallback(async (passportId) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, provider);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return c.getPatientAccessIds(passportId);
  }, [provider]);

  const getProviderAccessIds = useCallback(async (providerId) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, provider);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return c.getProviderAccessIds(providerId);
  }, [provider]);

  const hasActiveAccess = useCallback(async (passportId, providerId) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, provider);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return c.hasActiveAccess(passportId, providerId);
  }, [provider]);

  const getAccessStatus = useCallback(async (accessId) => {
    const c = getContract('ConsentAccessManager', ABI_MAP, provider);
    if (!c) throw new Error('ConsentAccessManager address not configured');
    return c.getAccessStatus(accessId);
  }, [provider]);

  return {
    // PatientPassportRegistry
    registerPatient, getPassportIdByWallet, isPassportActive, getPassportStatus,
    isWalletRegistered, updateRecoveryAddress, suspendPassport, reactivatePassport,
    // ProviderRegistry
    registerProvider, getProviderIdByWallet, isProviderVerified, getProviderStatus,
    isWalletVerifiedProvider, verifyProvider, suspendProvider, reactivateProvider,
    // MedicalRecordRegistry
    addRecord, getPatientRecordIds, getProviderRecordIds, getRecordStatus,
    getRecordPassportId, getRecordProviderId, isRecordValid, verifyRecordHash, updateRecordStatus,
    // ConsentAccessManager
    requestAccess, approveAccess, rejectAccess, revokeAccess,
    getPatientAccessIds, getProviderAccessIds, hasActiveAccess, getAccessStatus,
  };
}
