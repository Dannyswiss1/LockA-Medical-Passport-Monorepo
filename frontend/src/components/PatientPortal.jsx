import React, { useState, useEffect } from 'react';
import {
  generateIdentityHash, truncateBytes32, truncateAddress, copyToClipboard,
  getPassportStatusLabel, getAccessStatusLabel, getRecordScopeLabel,
  statusToBadgeClass, isZeroBytes32, isValidAddress, parseContractError
} from '../utils/helpers.js';
import { RecordScopes } from '../utils/constants.js';
import { ethers } from 'ethers';

export function PatientPortal({ account, contracts, toast }) {
  const [tab, setTab] = useState('passport');

  if (!account) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8">
        <div className="glass rounded-xl p-12 text-center">
          <div className="text-4xl mb-4">♥</div>
          <h2 className="text-lg font-semibold text-white mb-2">Connect Wallet to Access Patient Portal</h2>
          <p className="text-slate-400 text-sm">Please connect your MetaMask wallet.</p>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto px-4 py-8 animate-fade-in">
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-white mb-1">Patient Portal</h1>
        <p className="text-slate-400 text-sm">Manage your health passport, records, and consent</p>
      </div>
      <div className="flex gap-2 mb-6 flex-wrap">
        {[
          { id: 'passport', label: 'My Passport' },
          { id: 'register', label: 'Register' },
          { id: 'records',  label: 'My Records' },
          { id: 'consent',  label: 'Consent Management' },
        ].map(t => (
          <button key={t.id} onClick={() => setTab(t.id)} className={`tab-btn ${tab === t.id ? 'active' : ''}`}>
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'passport' && <PassportView account={account} contracts={contracts} toast={toast} />}
      {tab === 'register' && <RegisterPatient account={account} contracts={contracts} toast={toast} onRegistered={() => setTab('passport')} />}
      {tab === 'records'  && <MyRecords account={account} contracts={contracts} toast={toast} />}
      {tab === 'consent'  && <ConsentManagement account={account} contracts={contracts} toast={toast} />}
    </div>
  );
}

// ── Passport View ─────────────────────────────────────────
function PassportView({ account, contracts, toast }) {
  const [loading, setLoading]           = useState(true);
  const [passportId, setPassportId]     = useState(null);
  const [status, setStatus]             = useState(null);
  const [isRegistered, setIsRegistered] = useState(false);
  const [updatingRecovery, setUpdatingRecovery] = useState(false);
  const [newRecovery, setNewRecovery]   = useState('');

  useEffect(() => { load(); }, [account]);

  async function load() {
    setLoading(true);
    try {
      const registered = await contracts.isWalletRegistered(account);
      setIsRegistered(registered);
      if (registered) {
        const pid = await contracts.getPassportIdByWallet(account);
        setPassportId(pid);
        setStatus(Number(await contracts.getPassportStatus(pid)));
      }
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setLoading(false); }
  }

  async function handleUpdateRecovery() {
    if (!isValidAddress(newRecovery)) { toast.error('Invalid recovery address'); return; }
    setUpdatingRecovery(true);
    try {
      await contracts.updateRecoveryAddress(passportId, newRecovery);
      toast.success('Recovery address updated!', { title: 'Success' });
      setNewRecovery('');
    } catch (err) { toast.error(parseContractError(err), { title: 'Transaction Failed' }); }
    finally { setUpdatingRecovery(false); }
  }

  if (loading) return <LoadingCard />;
  if (!isRegistered) return (
    <div className="glass rounded-xl p-8 text-center">
      <div className="text-4xl mb-4">♥</div>
      <h3 className="text-lg font-semibold text-white mb-2">No Passport Found</h3>
      <p className="text-slate-400 text-sm">You haven't registered a patient passport yet. Go to the Register tab.</p>
    </div>
  );

  return (
    <div className="space-y-4">
      <div className="glass rounded-xl p-6">
        <div className="section-header">Passport Details</div>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <InfoRow label="Passport ID" value={truncateBytes32(passportId)} mono copyValue={passportId} />
          <InfoRow label="Wallet" value={truncateAddress(account)} mono copyValue={account} />
          <div>
            <div className="text-xs text-slate-500 mb-1">Status</div>
            <span className={`badge ${statusToBadgeClass(status, 'passport')}`}>
              <span className="w-1.5 h-1.5 rounded-full inline-block"
                style={{ background: status === 0 ? '#10b981' : status === 1 ? '#f59e0b' : '#ef4444' }}></span>
              {getPassportStatusLabel(status)}
            </span>
          </div>
          <InfoRow label="Network" value="Base Sepolia (Chain 84532)" />
        </div>
      </div>
      <div className="glass rounded-xl p-6">
        <div className="section-header">Recovery Address</div>
        <p className="text-sm text-slate-400 mb-4">Update the backup wallet that can recover your passport.</p>
        <div className="flex gap-3 flex-wrap">
          <input type="text" className="input-field flex-1 min-w-0"
            placeholder="0x... new recovery address"
            value={newRecovery} onChange={e => setNewRecovery(e.target.value)} />
          <button onClick={handleUpdateRecovery} disabled={updatingRecovery || !newRecovery}
            className="btn-primary px-4 py-2 rounded-lg text-sm flex items-center gap-2 flex-shrink-0">
            {updatingRecovery ? <><span className="spinner"></span>Updating…</> : 'Update Recovery'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── Register Patient ──────────────────────────────────────
function RegisterPatient({ account, contracts, toast, onRegistered }) {
  const [identityHash, setIdentityHash]       = useState('');
  const [recoveryAddress, setRecoveryAddress] = useState('');
  const [loading, setLoading]                 = useState(false);
  const [autoGenerated, setAutoGenerated]     = useState(false);

  function handleAutoGenerate() {
    setIdentityHash(generateIdentityHash(account));
    setAutoGenerated(true);
  }

  async function handleRegister() {
    if (!identityHash || !ethers.isHexString(identityHash, 32)) {
      toast.error('Invalid identity hash — must be a 32-byte hex string (0x...)'); return;
    }
    if (!isValidAddress(recoveryAddress)) { toast.error('Invalid recovery address'); return; }
    setLoading(true);
    try {
      const receipt = await contracts.registerPatient(identityHash, recoveryAddress);
      toast.success('Patient passport registered!', { title: 'Registered!', txHash: receipt?.hash || receipt?.transactionHash });
      onRegistered();
    } catch (err) { toast.error(parseContractError(err), { title: 'Registration Failed' }); }
    finally { setLoading(false); }
  }

  return (
    <div className="glass rounded-xl p-6 max-w-xl">
      <div className="section-header">Register Patient Passport</div>
      <p className="text-sm text-slate-400 mb-6">Create your decentralized health identity on the blockchain.</p>
      <div className="space-y-4">
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Public Identity Hash</label>
          <div className="flex gap-2">
            <input type="text" className="input-field flex-1" placeholder="0x... (32-byte hex)"
              value={identityHash} onChange={e => { setIdentityHash(e.target.value); setAutoGenerated(false); }} />
            <button onClick={handleAutoGenerate} className="btn-secondary px-3 py-2 rounded-lg text-xs flex-shrink-0">Auto-Generate</button>
          </div>
          {autoGenerated && <p className="text-xs text-green-400 mt-1">✓ Generated from your wallet address + timestamp</p>}
          <p className="text-xs text-slate-500 mt-1">A keccak256 hash that publicly identifies your passport without revealing personal data.</p>
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Recovery Address</label>
          <input type="text" className="input-field" placeholder="0x... recovery wallet address"
            value={recoveryAddress} onChange={e => setRecoveryAddress(e.target.value)} />
          <p className="text-xs text-slate-500 mt-1">A backup wallet that can recover your passport. Can be updated later.</p>
        </div>
        <button onClick={handleRegister} disabled={loading || !identityHash || !recoveryAddress}
          className="btn-primary w-full py-3 rounded-lg text-sm flex items-center justify-center gap-2">
          {loading ? <><span className="spinner"></span>Registering…</> : '♥ Register Patient Passport'}
        </button>
      </div>
    </div>
  );
}

// ── My Records ────────────────────────────────────────────
function MyRecords({ account, contracts, toast }) {
  const [loading, setLoading]           = useState(true);
  const [recordIds, setRecordIds]       = useState([]);
  const [recordDetails, setRecordDetails] = useState({});
  const [passportId, setPassportId]     = useState(null);
  const [verifyHash, setVerifyHash]     = useState({});
  const [verifyState, setVerifyState]   = useState({});

  useEffect(() => { load(); }, [account]);

  async function load() {
    setLoading(true);
    try {
      const registered = await contracts.isWalletRegistered(account);
      if (!registered) { setLoading(false); return; }
      const pid = await contracts.getPassportIdByWallet(account);
      setPassportId(pid);
      const ids = await contracts.getPatientRecordIds(pid);
      setRecordIds(ids);
      const details = {};
      for (const rid of ids) {
        try {
          const [status, providerId, isValid] = await Promise.all([
            contracts.getRecordStatus(rid),
            contracts.getRecordProviderId(rid),
            contracts.isRecordValid(rid),
          ]);
          details[rid] = { status: Number(status), providerId, isValid };
        } catch (_) {}
      }
      setRecordDetails(details);
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setLoading(false); }
  }

  async function handleVerifyHash(recordId) {
    const hash = verifyHash[recordId];
    if (!hash || !ethers.isHexString(hash, 32)) { toast.error('Enter a valid 32-byte hex hash'); return; }
    setVerifyState(prev => ({ ...prev, [recordId]: 'loading' }));
    try {
      const result = await contracts.verifyRecordHash(recordId, hash);
      setVerifyState(prev => ({ ...prev, [recordId]: result ? 'valid' : 'invalid' }));
    } catch (err) {
      setVerifyState(prev => ({ ...prev, [recordId]: 'error' }));
      toast.error(parseContractError(err));
    }
  }

  if (loading) return <LoadingCard />;
  if (!passportId) return (
    <div className="glass rounded-xl p-8 text-center">
      <p className="text-slate-400">Register a passport first to view your records.</p>
    </div>
  );

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="text-sm text-slate-400">{recordIds.length} record{recordIds.length !== 1 ? 's' : ''} found</div>
        <button onClick={load} className="btn-secondary text-xs px-3 py-1.5 rounded-lg">Refresh</button>
      </div>
      {recordIds.length === 0 ? (
        <div className="glass rounded-xl p-8 text-center">
          <p className="text-slate-400">No medical records found for your passport.</p>
        </div>
      ) : recordIds.map(rid => {
        const d = recordDetails[rid] || {};
        const vs = verifyState[rid];
        return (
          <div key={rid} className="glass rounded-xl p-5">
            <div className="flex items-start justify-between gap-4 flex-wrap mb-3">
              <div>
                <div className="text-xs text-slate-500 mb-1">Record ID</div>
                <CopyableHash value={rid} />
              </div>
              <span className={`badge ${statusToBadgeClass(d.status, 'record')}`}>
                {d.status === 0 ? 'Active' : d.status === 1 ? 'Amended' : 'Revoked'}
              </span>
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs mb-4">
              <div><span className="text-slate-500">Provider: </span><span className="font-mono text-slate-300">{truncateBytes32(d.providerId)}</span></div>
              <div><span className="text-slate-500">Valid: </span><span className={d.isValid ? 'text-green-400' : 'text-red-400'}>{d.isValid ? '✓ Yes' : '✗ No'}</span></div>
            </div>
            {/* Verify hash inline */}
            <div className="flex gap-2 flex-wrap items-center">
              <input type="text" className="input-field flex-1 text-xs py-1.5 min-w-0"
                placeholder="Verify file hash (0x...bytes32)"
                value={verifyHash[rid] || ''}
                onChange={e => setVerifyHash(prev => ({ ...prev, [rid]: e.target.value }))} />
              <button onClick={() => handleVerifyHash(rid)}
                disabled={vs === 'loading'}
                className="btn-secondary text-xs px-3 py-1.5 rounded-lg flex-shrink-0 flex items-center gap-1">
                {vs === 'loading' ? <><span className="spinner" style={{ width: 12, height: 12 }}></span>Checking…</> : 'Verify Hash'}
              </button>
              {vs === 'valid'   && <span className="badge badge-green text-xs">✓ Valid</span>}
              {vs === 'invalid' && <span className="badge badge-red text-xs">✗ Invalid</span>}
              {vs === 'error'   && <span className="badge badge-gray text-xs">Error</span>}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ── Consent Management ────────────────────────────────────
function ConsentManagement({ account, contracts, toast }) {
  const [loading, setLoading]         = useState(true);
  const [passportId, setPassportId]   = useState(null);
  const [accessIds, setAccessIds]     = useState([]);
  const [accessDetails, setAccessDetails] = useState({});
  const [actionLoading, setActionLoading] = useState({});

  useEffect(() => { load(); }, [account]);

  async function load() {
    setLoading(true);
    try {
      const registered = await contracts.isWalletRegistered(account);
      if (!registered) { setLoading(false); return; }
      const pid = await contracts.getPassportIdByWallet(account);
      setPassportId(pid);
      const ids = await contracts.getPatientAccessIds(pid);
      setAccessIds(ids);
      const details = {};
      for (const aid of ids) {
        try {
          const status = await contracts.getAccessStatus(aid);
          details[aid] = { status: Number(status) };
        } catch (_) {}
      }
      setAccessDetails(details);
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setLoading(false); }
  }

  async function handleAction(accessId, action) {
    setActionLoading(prev => ({ ...prev, [accessId]: action }));
    try {
      if (action === 'approve') await contracts.approveAccess(accessId);
      if (action === 'reject')  await contracts.rejectAccess(accessId);
      if (action === 'revoke')  await contracts.revokeAccess(accessId);
      toast.success(`Access ${action}d successfully!`);
      await load();
    } catch (err) { toast.error(parseContractError(err), { title: 'Action Failed' }); }
    finally { setActionLoading(prev => ({ ...prev, [accessId]: null })); }
  }

  if (loading) return <LoadingCard />;
  if (!passportId) return (
    <div className="glass rounded-xl p-8 text-center">
      <p className="text-slate-400">Register a passport first to manage consent.</p>
    </div>
  );

  const pending  = accessIds.filter(id => accessDetails[id]?.status === 0);
  const approved = accessIds.filter(id => accessDetails[id]?.status === 1);
  const others   = accessIds.filter(id => ![0, 1].includes(accessDetails[id]?.status));

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div className="text-sm text-slate-400">{accessIds.length} total access request{accessIds.length !== 1 ? 's' : ''}</div>
        <button onClick={load} className="btn-secondary text-xs px-3 py-1.5 rounded-lg">Refresh</button>
      </div>

      {accessIds.length === 0 && (
        <div className="glass rounded-xl p-8 text-center">
          <p className="text-slate-400">No access requests found for your passport.</p>
        </div>
      )}

      {pending.length > 0 && (
        <div>
          <div className="text-xs font-semibold text-amber-400 uppercase tracking-wide mb-3">
            ⏳ Pending ({pending.length})
          </div>
          <div className="space-y-3">
            {pending.map(aid => (
              <AccessCard key={aid} accessId={aid} detail={accessDetails[aid]}
                actionLoading={actionLoading[aid]}
                onApprove={() => handleAction(aid, 'approve')}
                onReject={() => handleAction(aid, 'reject')} />
            ))}
          </div>
        </div>
      )}

      {approved.length > 0 && (
        <div>
          <div className="text-xs font-semibold text-green-400 uppercase tracking-wide mb-3">
            ✓ Approved ({approved.length})
          </div>
          <div className="space-y-3">
            {approved.map(aid => (
              <AccessCard key={aid} accessId={aid} detail={accessDetails[aid]}
                actionLoading={actionLoading[aid]}
                onRevoke={() => handleAction(aid, 'revoke')} />
            ))}
          </div>
        </div>
      )}

      {others.length > 0 && (
        <div>
          <div className="text-xs font-semibold text-slate-500 uppercase tracking-wide mb-3">
            History ({others.length})
          </div>
          <div className="space-y-3">
            {others.map(aid => (
              <AccessCard key={aid} accessId={aid} detail={accessDetails[aid]} />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function AccessCard({ accessId, detail, actionLoading, onApprove, onReject, onRevoke }) {
  const status = detail?.status ?? null;
  const statusLabels = { 0: 'Pending', 1: 'Approved', 2: 'Rejected', 3: 'Revoked', 4: 'Expired' };
  const badgeClasses = { 0: 'badge-amber', 1: 'badge-green', 2: 'badge-red', 3: 'badge-gray', 4: 'badge-gray' };

  return (
    <div className="glass rounded-xl p-4">
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div className="flex-1 min-w-0">
          <div className="text-xs text-slate-500 mb-1">Access ID</div>
          <CopyableHash value={accessId} />
        </div>
        {status !== null && (
          <span className={`badge ${badgeClasses[status] || 'badge-gray'}`}>{statusLabels[status] || 'Unknown'}</span>
        )}
      </div>
      {(onApprove || onReject || onRevoke) && (
        <div className="flex gap-2 mt-3 flex-wrap">
          {onApprove && (
            <button onClick={onApprove} disabled={!!actionLoading}
              className="btn-green text-xs px-3 py-1.5 rounded-lg flex items-center gap-1">
              {actionLoading === 'approve' ? <><span className="spinner" style={{ width: 12, height: 12 }}></span>Approving…</> : '✓ Approve'}
            </button>
          )}
          {onReject && (
            <button onClick={onReject} disabled={!!actionLoading}
              className="btn-danger text-xs px-3 py-1.5 rounded-lg flex items-center gap-1">
              {actionLoading === 'reject' ? <><span className="spinner" style={{ width: 12, height: 12 }}></span>Rejecting…</> : '✗ Reject'}
            </button>
          )}
          {onRevoke && (
            <button onClick={onRevoke} disabled={!!actionLoading}
              className="btn-amber text-xs px-3 py-1.5 rounded-lg flex items-center gap-1">
              {actionLoading === 'revoke' ? <><span className="spinner" style={{ width: 12, height: 12 }}></span>Revoking…</> : '⊘ Revoke'}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

// ── Shared helpers ────────────────────────────────────────
export function InfoRow({ label, value, mono, copyValue }) {
  const [copied, setCopied] = useState(false);
  async function handleCopy() {
    if (!copyValue) return;
    await copyToClipboard(copyValue);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }
  return (
    <div>
      <div className="text-xs text-slate-500 mb-1">{label}</div>
      <div className="flex items-center gap-2">
        <span className={`text-sm text-slate-200 ${mono ? 'font-mono' : ''} truncate`}>{value}</span>
        {copyValue && (
          <button onClick={handleCopy} className="text-slate-600 hover:text-blue-400 transition-colors flex-shrink-0" title="Copy">
            {copied
              ? <svg className="w-3.5 h-3.5 text-green-400" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7"/></svg>
              : <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
            }
          </button>
        )}
      </div>
    </div>
  );
}

export function CopyableHash({ value }) {
  const [copied, setCopied] = useState(false);
  async function handleCopy() {
    await copyToClipboard(value);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }
  return (
    <div className="flex items-center gap-2">
      <span className="font-mono text-xs text-slate-300 truncate">{value}</span>
      <button onClick={handleCopy} className="text-slate-600 hover:text-blue-400 transition-colors flex-shrink-0">
        {copied
          ? <svg className="w-3.5 h-3.5 text-green-400" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7"/></svg>
          : <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
        }
      </button>
    </div>
  );
}

export function LoadingCard() {
  return (
    <div className="glass rounded-xl p-10 text-center">
      <div className="spinner mx-auto mb-3" style={{ width: 28, height: 28, borderWidth: 3 }}></div>
      <p className="text-slate-500 text-sm">Loading…</p>
    </div>
  );
}
