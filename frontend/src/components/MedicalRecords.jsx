import React, { useState, useEffect } from 'react';
import {
  truncateBytes32, getRecordStatusLabel,
  statusToBadgeClass, isZeroBytes32, parseContractError
} from '../utils/helpers.js';
import { RecordTypes } from '../utils/constants.js';
import { LoadingCard, CopyableHash } from './PatientPortal.jsx';
import { ethers } from 'ethers';

export function MedicalRecords({ account, contracts, toast }) {
  const [tab, setTab] = useState('add');

  return (
    <div className="max-w-7xl mx-auto px-4 py-8 animate-fade-in">
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-white mb-1">Medical Records</h1>
        <p className="text-slate-400 text-sm">Add, lookup, and verify tamper-proof medical records on-chain</p>
      </div>
      <div className="flex gap-2 mb-6 flex-wrap">
        {[
          { id: 'add',    label: 'Add Record' },
          { id: 'lookup', label: 'Lookup Record' },
          { id: 'verify', label: 'Verify Hash' },
        ].map(t => (
          <button key={t.id} onClick={() => setTab(t.id)} className={`tab-btn ${tab === t.id ? 'active' : ''}`}>
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'add'    && <AddRecord account={account} contracts={contracts} toast={toast} />}
      {tab === 'lookup' && <LookupRecord contracts={contracts} toast={toast} />}
      {tab === 'verify' && <VerifyHash contracts={contracts} toast={toast} />}
    </div>
  );
}

// ── Add Record ────────────────────────────────────────────
function AddRecord({ account, contracts, toast }) {
  const [passportId, setPassportId]           = useState('');
  const [providerId, setProviderId]           = useState('');
  const [autoProviderId, setAutoProviderId]   = useState('');
  const [recordType, setRecordType]           = useState(0);
  const [encryptedFileHash, setEncryptedFileHash] = useState('');
  const [storagePointerHash, setStoragePointerHash] = useState('');
  const [loading, setLoading]                 = useState(false);
  const [isVerifiedProvider, setIsVerifiedProvider] = useState(false);

  useEffect(() => {
    if (!account) return;
    async function checkProvider() {
      try {
        const verified = await contracts.isWalletVerifiedProvider(account);
        setIsVerifiedProvider(verified);
        if (verified) {
          const pid = await contracts.getProviderIdByWallet(account);
          if (!isZeroBytes32(pid)) { setAutoProviderId(pid); setProviderId(pid); }
        }
      } catch (_) {}
    }
    checkProvider();
  }, [account]);

  function handleAutoGenerateHashes() {
    setEncryptedFileHash(ethers.id(`encrypted-${Date.now()}-${Math.random()}`));
    setStoragePointerHash(ethers.id(`storage-${Date.now()}-${Math.random()}`));
  }

  async function handleAddRecord() {
    if (!passportId || !ethers.isHexString(passportId, 32))           { toast.error('Invalid passport ID'); return; }
    if (!providerId || !ethers.isHexString(providerId, 32))           { toast.error('Invalid provider ID'); return; }
    if (!encryptedFileHash || !ethers.isHexString(encryptedFileHash, 32)) { toast.error('Invalid encrypted file hash'); return; }
    if (!storagePointerHash || !ethers.isHexString(storagePointerHash, 32)) { toast.error('Invalid storage pointer hash'); return; }
    setLoading(true);
    try {
      const receipt = await contracts.addRecord(passportId, providerId, recordType, encryptedFileHash, storagePointerHash);
      toast.success('Medical record added to blockchain!', { title: 'Record Added', txHash: receipt?.hash || receipt?.transactionHash });
      setPassportId('');
      setEncryptedFileHash('');
      setStoragePointerHash('');
    } catch (err) { toast.error(parseContractError(err), { title: 'Failed to Add Record' }); }
    finally { setLoading(false); }
  }

  if (!account) return (
    <div className="glass rounded-xl p-8 text-center">
      <p className="text-slate-400">Connect your wallet to add medical records.</p>
    </div>
  );

  return (
    <div className="glass rounded-xl p-6 max-w-xl">
      <div className="section-header">Add Medical Record</div>
      {!isVerifiedProvider && (
        <div className="mb-5 p-3 rounded-lg" style={{ background: 'rgba(245,158,11,0.08)', border: '1px solid rgba(245,158,11,0.2)' }}>
          <p className="text-amber-300 text-sm">⚠ Only verified healthcare providers can add medical records.</p>
        </div>
      )}
      <p className="text-sm text-slate-400 mb-6">Medical records store encrypted file hashes on-chain. Actual files are stored off-chain (IPFS/secure storage), with only the hash anchored to the blockchain.</p>
      <div className="space-y-4">
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Patient Passport ID</label>
          <input type="text" className="input-field" placeholder="0x... patient passport ID (bytes32)"
            value={passportId} onChange={e => setPassportId(e.target.value)} />
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Provider ID</label>
          {autoProviderId && <div className="text-xs text-green-400 mb-1">✓ Auto-filled from your verified provider account</div>}
          <input type="text" className="input-field" placeholder="0x... provider ID (bytes32)"
            value={providerId} onChange={e => setProviderId(e.target.value)} />
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Record Type</label>
          <select className="input-field" value={recordType} onChange={e => setRecordType(Number(e.target.value))}>
            {RecordTypes.map(t => <option key={t.value} value={t.value}>{t.label}</option>)}
          </select>
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">
            Encrypted File Hash <span className="text-slate-600 font-normal">(keccak256 of encrypted file)</span>
          </label>
          <input type="text" className="input-field" placeholder="0x... encrypted file hash (bytes32)"
            value={encryptedFileHash} onChange={e => setEncryptedFileHash(e.target.value)} />
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">
            Storage Pointer Hash <span className="text-slate-600 font-normal">(hash of IPFS CID or storage URL)</span>
          </label>
          <div className="flex gap-2">
            <input type="text" className="input-field flex-1" placeholder="0x... storage pointer hash (bytes32)"
              value={storagePointerHash} onChange={e => setStoragePointerHash(e.target.value)} />
            <button onClick={handleAutoGenerateHashes} className="btn-secondary px-3 py-2 rounded-lg text-xs flex-shrink-0">
              Generate Test
            </button>
          </div>
          <p className="text-xs text-slate-500 mt-1">Use "Generate Test" to create placeholder hashes for testing.</p>
        </div>
        <button onClick={handleAddRecord}
          disabled={loading || !passportId || !providerId || !encryptedFileHash || !storagePointerHash}
          className="btn-primary w-full py-3 rounded-lg text-sm flex items-center justify-center gap-2">
          {loading ? <><span className="spinner"></span>Adding Record…</> : '⊞ Add Medical Record'}
        </button>
      </div>
    </div>
  );
}

// ── Lookup Record ─────────────────────────────────────────
function LookupRecord({ contracts, toast }) {
  const [recordId, setRecordId] = useState('');
  const [loading, setLoading]   = useState(false);
  const [result, setResult]     = useState(null);

  async function handleLookup() {
    if (!recordId || !ethers.isHexString(recordId, 32)) { toast.error('Invalid record ID — must be a 32-byte hex string'); return; }
    setLoading(true);
    setResult(null);
    try {
      const [status, passportId, providerId, isValid] = await Promise.all([
        contracts.getRecordStatus(recordId),
        contracts.getRecordPassportId(recordId),
        contracts.getRecordProviderId(recordId),
        contracts.isRecordValid(recordId),
      ]);
      setResult({ recordId, status: Number(status), passportId, providerId, isValid });
    } catch (err) { toast.error(parseContractError(err), { title: 'Lookup Failed' }); }
    finally { setLoading(false); }
  }

  return (
    <div className="space-y-4 max-w-xl">
      <div className="glass rounded-xl p-6">
        <div className="section-header">Lookup Record by ID</div>
        <div className="flex gap-3">
          <input type="text" className="input-field flex-1" placeholder="0x... record ID (bytes32)"
            value={recordId} onChange={e => setRecordId(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && handleLookup()} />
          <button onClick={handleLookup} disabled={loading || !recordId}
            className="btn-primary px-4 py-2 rounded-lg text-sm flex items-center gap-2 flex-shrink-0">
            {loading ? <span className="spinner"></span> : (
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
              </svg>
            )}
            {loading ? 'Searching…' : 'Lookup'}
          </button>
        </div>
      </div>

      {result && (
        <div className="glass rounded-xl p-6 animate-slide-up">
          <div className="section-header">Record Details</div>
          <div className="space-y-3">
            <LookupRow label="Record ID" value={truncateBytes32(result.recordId)} mono copyValue={result.recordId} />
            <LookupRow label="Patient Passport ID" value={truncateBytes32(result.passportId)} mono copyValue={result.passportId} />
            <LookupRow label="Provider ID" value={truncateBytes32(result.providerId)} mono copyValue={result.providerId} />
            <div className="flex items-center justify-between py-2 border-b border-blue-900/20">
              <span className="text-xs text-slate-400">Status</span>
              <span className={`badge ${statusToBadgeClass(result.status, 'record')}`}>
                {getRecordStatusLabel(result.status)}
              </span>
            </div>
            <div className="flex items-center justify-between py-2">
              <span className="text-xs text-slate-400">Validity</span>
              <span className={`badge ${result.isValid ? 'badge-green' : 'badge-red'}`}>
                {result.isValid ? '✓ Valid' : '✗ Invalid'}
              </span>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Verify Hash ───────────────────────────────────────────
function VerifyHash({ contracts, toast }) {
  const [recordId, setRecordId] = useState('');
  const [fileHash, setFileHash] = useState('');
  const [loading, setLoading]   = useState(false);
  const [result, setResult]     = useState(null); // null | 'valid' | 'invalid'

  async function handleVerify() {
    if (!recordId || !ethers.isHexString(recordId, 32)) { toast.error('Invalid record ID'); return; }
    if (!fileHash  || !ethers.isHexString(fileHash, 32))  { toast.error('Invalid file hash'); return; }
    setLoading(true);
    setResult(null);
    try {
      const ok = await contracts.verifyRecordHash(recordId, fileHash);
      setResult(ok ? 'valid' : 'invalid');
    } catch (err) { toast.error(parseContractError(err), { title: 'Verification Failed' }); }
    finally { setLoading(false); }
  }

  return (
    <div className="glass rounded-xl p-6 max-w-xl">
      <div className="section-header">Verify Record File Hash</div>
      <p className="text-sm text-slate-400 mb-6">
        Prove that a file corresponds to an on-chain record by verifying its keccak256 hash against the stored encrypted file hash.
      </p>
      <div className="space-y-4">
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Record ID</label>
          <input type="text" className="input-field" placeholder="0x... record ID (bytes32)"
            value={recordId} onChange={e => setRecordId(e.target.value)} />
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">File Hash to Verify</label>
          <input type="text" className="input-field" placeholder="0x... keccak256 of the encrypted file (bytes32)"
            value={fileHash} onChange={e => setFileHash(e.target.value)} />
          <p className="text-xs text-slate-500 mt-1">Compute keccak256 of the encrypted file content and paste it here.</p>
        </div>
        <button onClick={handleVerify} disabled={loading || !recordId || !fileHash}
          className="btn-primary w-full py-3 rounded-lg text-sm flex items-center justify-center gap-2">
          {loading ? <><span className="spinner"></span>Verifying…</> : '🔍 Verify Hash'}
        </button>

        {result === 'valid' && (
          <div className="p-4 rounded-xl flex items-center gap-3 animate-slide-up"
            style={{ background: 'rgba(16,185,129,0.08)', border: '1px solid rgba(16,185,129,0.3)' }}>
            <svg className="w-6 h-6 text-green-400 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <div>
              <p className="text-green-400 font-semibold text-sm">Hash Verified ✓</p>
              <p className="text-slate-400 text-xs mt-0.5">The file hash matches the on-chain record. This file is authentic and unmodified.</p>
            </div>
          </div>
        )}

        {result === 'invalid' && (
          <div className="p-4 rounded-xl flex items-center gap-3 animate-slide-up"
            style={{ background: 'rgba(239,68,68,0.08)', border: '1px solid rgba(239,68,68,0.3)' }}>
            <svg className="w-6 h-6 text-red-400 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <div>
              <p className="text-red-400 font-semibold text-sm">Hash Mismatch ✗</p>
              <p className="text-slate-400 text-xs mt-0.5">The file hash does NOT match the on-chain record. The file may have been tampered with or you provided the wrong file.</p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ── Shared lookup row ─────────────────────────────────────
function LookupRow({ label, value, mono, copyValue }) {
  const [copied, setCopied] = useState(false);
  async function handleCopy() {
    if (!copyValue) return;
    try { await navigator.clipboard.writeText(copyValue); } catch (_) {}
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }
  return (
    <div className="flex items-center justify-between py-2 border-b border-blue-900/20">
      <span className="text-xs text-slate-400 flex-shrink-0 mr-4">{label}</span>
      <div className="flex items-center gap-2 min-w-0">
        <span className={`text-xs text-slate-200 truncate ${mono ? 'font-mono' : ''}`}>{value}</span>
        {copyValue && (
          <button onClick={handleCopy} className="text-slate-600 hover:text-blue-400 transition-colors flex-shrink-0">
            {copied
              ? <svg className="w-3 h-3 text-green-400" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7"/></svg>
              : <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
            }
          </button>
        )}
      </div>
    </div>
  );
}
