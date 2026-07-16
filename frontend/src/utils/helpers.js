import { ethers } from 'ethers';
import {
  PassportStatus, ProviderStatus, RecordStatus, AccessStatus,
  ProviderTypes, RecordTypes, RecordScopes
} from './constants.js';

// ── bytes32 Utilities ─────────────────────────────────────
export function strToBytes32(str) {
  if (!str) return ethers.ZeroHash;
  try {
    if (/^0x[0-9a-fA-F]{64}$/.test(str)) return str;
    return ethers.id(str);
  } catch (_) { return ethers.ZeroHash; }
}

export function encodeBytes32(str) {
  if (!str) return ethers.ZeroHash;
  try {
    if (/^0x[0-9a-fA-F]{64}$/.test(str)) return str;
    if (str.length <= 31) return ethers.encodeBytes32String(str);
    return ethers.id(str);
  } catch (_) {
    try { return ethers.id(str); } catch (_) { return ethers.ZeroHash; }
  }
}

export function generateIdentityHash(walletAddress, salt = '') {
  const input = `${walletAddress.toLowerCase()}-${salt || Date.now()}`;
  return ethers.id(input);
}

export function generateLicenseHash(licenseStr) {
  return ethers.id(licenseStr || `license-${Date.now()}`);
}

export function truncateBytes32(hex, chars = 8) {
  if (!hex || hex === ethers.ZeroHash) return '—';
  return `${hex.slice(0, chars + 2)}...${hex.slice(-chars)}`;
}

export function truncateAddress(addr, chars = 6) {
  if (!addr) return '—';
  return `${addr.slice(0, chars + 2)}...${addr.slice(-chars)}`;
}

export async function copyToClipboard(text) {
  try { await navigator.clipboard.writeText(text); return true; }
  catch (_) { return false; }
}

// ── Status Formatters ─────────────────────────────────────
export function getPassportStatusLabel(status) { return PassportStatus[status] ?? 'Unknown'; }
export function getProviderStatusLabel(status)  { return ProviderStatus[status]  ?? 'Unknown'; }
export function getRecordStatusLabel(status)    { return RecordStatus[status]    ?? 'Unknown'; }
export function getAccessStatusLabel(status)    { return AccessStatus[status]    ?? 'Unknown'; }

export function getProviderTypeLabel(type) { return ProviderTypes.find(t => t.value === type)?.label ?? `Type ${type}`; }
export function getRecordTypeLabel(type)   { return RecordTypes.find(t => t.value === type)?.label   ?? `Type ${type}`; }
export function getRecordScopeLabel(scope) { return RecordScopes.find(s => s.value === scope)?.label ?? `Scope ${scope}`; }

export function statusToBadgeClass(status, type = 'passport') {
  if (type === 'passport') {
    if (status === 0) return 'badge-green';
    if (status === 1) return 'badge-amber';
    return 'badge-red';
  }
  if (type === 'provider') {
    if (status === 1) return 'badge-green';
    if (status === 0) return 'badge-amber';
    return 'badge-red';
  }
  if (type === 'record') {
    if (status === 0) return 'badge-green';
    if (status === 1) return 'badge-cyan';
    return 'badge-red';
  }
  if (type === 'access') {
    if (status === 1) return 'badge-green';
    if (status === 0) return 'badge-amber';
    if (status === 2) return 'badge-red';
    return 'badge-gray';
  }
  return 'badge-gray';
}

// ── Date Utilities ────────────────────────────────────────
export function formatTimestamp(ts) {
  if (!ts) return '—';
  try {
    const n = typeof ts === 'bigint' ? Number(ts) : ts;
    if (n === 0) return '—';
    return new Date(n * 1000).toLocaleDateString('en-US', {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit'
    });
  } catch (_) { return '—'; }
}

export function dateToTimestamp(dateStr) {
  if (!dateStr) return 0;
  return Math.floor(new Date(dateStr).getTime() / 1000);
}

export function timestampToDateInput(ts) {
  if (!ts) return '';
  const n = typeof ts === 'bigint' ? Number(ts) : ts;
  return new Date(n * 1000).toISOString().slice(0, 16);
}

// ── Error Parsing ─────────────────────────────────────────
export function parseContractError(error) {
  if (!error) return 'An unknown error occurred';
  const msg = error?.reason || error?.message || String(error);
  if (msg.includes('user rejected') || msg.includes('User denied')) return 'Transaction rejected by user';
  if (msg.includes('insufficient funds')) return 'Insufficient funds for gas';
  if (msg.includes('nonce')) return 'Nonce error — please refresh and retry';
  if (msg.includes('already registered')) return 'This wallet is already registered';
  if (msg.includes('not registered')) return 'Wallet is not registered';
  if (msg.includes('not active') || msg.includes('not Active')) return 'Passport/Provider is not active';
  if (msg.includes('not verified')) return 'Provider is not verified';
  if (msg.includes('access denied') || msg.includes('Unauthorized')) return 'Unauthorized: insufficient permissions';
  if (msg.includes('invalid address')) return 'Invalid address provided';
  if (msg.includes('execution reverted')) {
    const inner = msg.match(/execution reverted: (.+)/)?.[1];
    return inner ? `Contract error: ${inner}` : 'Transaction reverted by contract';
  }
  if (msg.length > 120) return msg.slice(0, 120) + '…';
  return msg;
}

// ── Validation ────────────────────────────────────────────
export function isValidAddress(addr) {
  try { return ethers.isAddress(addr); } catch (_) { return false; }
}

export function isValidBytes32(hex) {
  return /^0x[0-9a-fA-F]{64}$/.test(hex);
}

export function isZeroAddress(addr) {
  if (!addr) return true;
  return addr === '0x0000000000000000000000000000000000000000';
}

export function isZeroBytes32(hex) {
  if (!hex) return true;
  return hex === ethers.ZeroHash || hex === '0x' + '0'.repeat(64);
}
