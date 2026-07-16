import React, { useState, useEffect } from 'react';
import {
  generateLicenseHash, truncateBytes32, truncateAddress,
  getProviderStatusLabel, getAccessStatusLabel,
  statusToBadgeClass, isZeroBytes32, isValidAddress, parseContractError, dateToTimestamp
} from '../utils/helpers.js';
import { ProviderTypes, RecordScopes } from '../utils/constants.js';
import { LoadingCard, InfoRow, CopyableHash } from './PatientPortal.jsx';
import { ethers } from 'ethers';

export function ProviderPortal({ account, contracts, toast }) {
  const [tab, setTab] = useState('profile');

  if (!account) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8">
        <div className="glass rounded-xl p-12 text-center">
          <div className="text-4xl mb-4">✚</div>
          <h2 className="text-lg font-semibold text-white mb-2">Connect Wallet to Access Provider Portal</h2>
          <p className="text-slate-400 text-sm">Please connect your MetaMask wallet.</p>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto px-4 py-8 animate-fade-in">
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-white mb-1">Provider Portal</h1>
        <p className="text-slate-400 text-sm">Manage your healthcare provider registration and patient access</p>
      </div>
      <div className="flex gap-2 mb-6 flex-wrap">
        {[
          { id: 'profile',  label: 'My Profile' },
          { id: 'register', label: 'Register' },
          { id: 'records',  label: 'Issued Records' },
          { id: 'request',  label: 'Request Access' },
          { id: 'access',   label: 'My Access Requests' },
        ].map(t => (
          <button key={t.id} onClick={() => setTab(t.id)} className={`tab-btn ${tab === t.id ? 'active' : ''}`}>
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'profile'  && <ProviderProfile account={account} contracts={contracts} toast={toast} />}
      {tab === 'register' && <RegisterProvider account={account} contracts={contracts} toast={toast} onRegistered={() => setTab('profile')} />}
      {tab === 'records'  && <IssuedRecords account={account} contracts={contracts} toast={toast} />}
      {tab === 'request'  && <RequestAccess account={account} contracts={contracts} toast={toast} />}
      {tab === 'access'   && <ProviderAccessRequests account={account} contracts={contracts} toast={toast} />}
    </div>
  );
}

// ── Provider Profile ──────────────────────────────────────
function ProviderProfile({ account, contracts, toast }) {
  const [loading, setLoading]       = useState(true);
  const [providerId, setProviderId] = useState(null);
  const [status, setStatus]         = useState(null);
  const [isVerified, setIsVerified] = useState(false);

  useEffect(() => { load(); }, [account]);

  async function load() {
    setLoading(true);
    try {
      const pid = await contracts.getProviderIdByWallet(account);
      if (!isZeroBytes32(pid)) {
        setProviderId(pid);
        const [s, v] = await Promise.all([contracts.getProviderStatus(pid), contracts.isProviderVerified(pid)]);
        setStatus(Number(s));
        setIsVerified(v);
      } else { setProviderId(null); }
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setLoading(false); }
  }

  if (loading) return <LoadingCard />;
  if (!providerId) return (
    <div className="glass rounded-xl p-8 text-center">
      <div className="text-4xl mb-4">✚</div>
      <h3 className="text-lg font-semibold text-white mb-2">Not Registered as Provider</h3>
      <p className="text-slate-400 text-sm">Register as a healthcare provider to issue records and request patient access.</p>
    </div>
  );

  return (
    <div className="glass rounded-xl p-6">
      <div className="section-header">Provider Profile</div>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <InfoRow label="Provider ID" value={truncateBytes32(providerId)} mono copyValue={providerId} />
        <InfoRow label="Wallet" value={truncateAddress(account)} mono copyValue={account} />
        <div>
          <div className="text-xs text-slate-500 mb-1">Status</div>
          <span className={`badge ${statusToBadgeClass(status, 'provider')}`}>
            <span className="w-1.5 h-1.5 rounded-full inline-block"
              style={{ background: status === 1 ? '#10b981' : status === 0 ? '#f59e0b' : '#ef4444' }}></span>
            {getProviderStatusLabel(status)}
          </span>
        </div>
        <div>
          <div className="text-xs text-slate-500 mb-1">Verification</div>
          <span className={`badge ${isVerified ? 'badge-green' : 'badge-amber'}`}>
            {isVerified ? '✓ Verified' : '⏳ Pending Verification'}
          </span>
        </div>
      </div>
      {!isVerified && (
        <div className="mt-4 p-3 rounded-lg" style={{ background: 'rgba(245,158,11,0.08)', border: '1px solid rgba(245,158,11,0.2)' }}>
          <p className="text-amber-300 text-sm">Your registration is pending admin verification. You'll be able to issue records once verified.</p>
        </div>
      )}
    </div>
  );
}

// ── Register Provider ─────────────────────────────────────
function RegisterProvider({ account, contracts, toast, onRegistered }) {
  const [providerType, setProviderType] = useState(0);
  const [licenseInput, setLicenseInput] = useState('');
  const [licenseHash, setLicenseHash]   = useState('');
  const [country, setCountry]           = useState('');
  const [loading, setLoading]           = useState(false);
  const [autoGenerated, setAutoGenerated] = useState(false);

  function handleAutoGenerateLicense() {
    setLicenseHash(generateLicenseHash(licenseInput || `${account}-${Date.now()}`));
    setAutoGenerated(true);
  }

  async function handleRegister() {
    if (!licenseHash || !ethers.isHexString(licenseHash, 32)) { toast.error('Invalid license hash'); return; }
    if (!country.trim()) { toast.error('Country is required'); return; }
    setLoading(true);
    try {
      const receipt = await contracts.registerProvider(providerType, licenseHash, country.trim());
      toast.success('Provider registered! Awaiting admin verification.', { title: 'Registered!', txHash: receipt?.hash || receipt?.transactionHash });
      onRegistered();
    } catch (err) { toast.error(parseContractError(err), { title: 'Registration Failed' }); }
    finally { setLoading(false); }
  }

  return (
    <div className="glass rounded-xl p-6 max-w-xl">
      <div className="section-header">Register as Healthcare Provider</div>
      <p className="text-sm text-slate-400 mb-6">Register your healthcare organization on-chain. Your registration will be reviewed by an admin before activation.</p>
      <div className="space-y-4">
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Provider Type</label>
          <select className="input-field" value={providerType} onChange={e => setProviderType(Number(e.target.value))}>
            {ProviderTypes.map(t => <option key={t.value} value={t.value}>{t.label}</option>)}
          </select>
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">License Number</label>
          <div className="flex gap-2 mb-2">
            <input type="text" className="input-field flex-1" placeholder="Enter license number or ID"
              value={licenseInput} onChange={e => setLicenseInput(e.target.value)} />
            <button onClick={handleAutoGenerateLicense} className="btn-secondary px-3 py-2 rounded-lg text-xs flex-shrink-0">Generate Hash</button>
          </div>
          <input type="text" className="input-field" placeholder="0x... license hash (bytes32)"
            value={licenseHash} onChange={e => { setLicenseHash(e.target.value); setAutoGenerated(false); }} />
          {autoGenerated && <p className="text-xs text-green-400 mt-1">✓ Hash generated from license input</p>}
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Country</label>
          <input type="text" className="input-field" placeholder="e.g. United States, Germany, Brazil"
            value={country} onChange={e => setCountry(e.target.value)} />
        </div>
        <button onClick={handleRegister} disabled={loading || !licenseHash || !country}
          className="btn-primary w-full py-3 rounded-lg text-sm flex items-center justify-center gap-2">
          {loading ? <><span className="spinner"></span>Registering…</> : '✚ Register Provider'}
        </button>
      </div>
    </div>
  );
}

// ── Issued Records ────────────────────────────────────────
function IssuedRecords({ account, contracts, toast }) {
  const [loading, setLoading]           = useState(true);
  const [recordIds, setRecordIds]       = useState([]);
  const [recordDetails, setRecordDetails] = useState({});
  const [providerId, setProviderId]     = useState(null);
  const [updatingStatus, setUpdatingStatus] = useState({});

  useEffect(() => { load(); }, [account]);

  async function load() {
    setLoading(true);
    try {
      const pid = await contracts.getProviderIdByWallet(account);
      if (isZeroBytes32(pid)) { setLoading(false); return; }
      setProviderId(pid);
      const ids = await contracts.getProviderRecordIds(pid);
      setRecordIds(ids);
      const details = {};
      for (const rid of ids) {
        try {
          const [status, passportId, isValid] = await Promise.all([
            contracts.getRecordStatus(rid),
            contracts.getRecordPassportId(rid),
            contracts.isRecordValid(rid),
          ]);
          details[rid] = { status: Number(status), passportId, isValid };
        } catch (_) {}
      }
      setRecordDetails(details);
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setLoading(false); }
  }

  async function handleUpdateStatus(recordId, newStatus) {
    setUpdatingStatus(prev => ({ ...prev, [recordId]: true }));
    try {
      await contracts.updateRecordStatus(recordId, newStatus);
      toast.success('Record status updated!');
      await load();
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setUpdatingStatus(prev => ({ ...prev, [recordId]: false })); }
  }

  if (loading) return <LoadingCard />;
  if (!providerId) return (
    <div className="glass rounded-xl p-8 text-center"><p className="text-slate-400">Register as a provider first.</p></div>
  );

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="text-sm text-slate-400">{recordIds.length} record{recordIds.length !== 1 ? 's' : ''} issued</div>
        <button onClick={load} className="btn-secondary text-xs px-3 py-1.5 rounded-lg">Refresh</button>
      </div>
      {recordIds.length === 0 ? (
        <div className="glass rounded-xl p-8 text-center"><p className="text-slate-400">No records issued yet.</p></div>
      ) : recordIds.map(rid => {
        const d = recordDetails[rid] || {};
        return (
          <div key={rid} className="glass rounded-xl p-5">
            <div className="flex items-start justify-between gap-3 flex-wrap mb-3">
              <div className="flex-1 min-w-0">
                <div className="text-xs text-slate-500 mb-1">Record ID</div>
                <CopyableHash value={rid} />
              </div>
              <span className={`badge ${d.status === 0 ? 'badge-green' : d.status === 1 ? 'badge-cyan' : 'badge-red'}`}>
                {d.status === 0 ? 'Active' : d.status === 1 ? 'Amended' : 'Revoked'}
              </span>
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-xs mb-4">
              <div><span className="text-slate-500">Patient: </span><span className="font-mono text-slate-300">{truncateBytes32(d.passportId)}</span></div>
              <div><span className="text-slate-500">Valid: </span><span className={d.isValid ? 'text-green-400' : 'text-red-400'}>{d.isValid ? '✓ Yes' : '✗ No'}</span></div>
            </div>
            {d.status === 0 && (
              <div className="flex gap-2 flex-wrap">
                <button onClick={() => handleUpdateStatus(rid, 1)} disabled={updatingStatus[rid]}
                  className="btn-secondary text-xs px-3 py-1.5 rounded-lg">
                  {updatingStatus[rid] ? <span className="spinner" style={{ width: 12, height: 12 }}></span> : 'Mark Amended'}
                </button>
                <button onClick={() => handleUpdateStatus(rid, 2)} disabled={updatingStatus[rid]}
                  className="btn-danger text-xs px-3 py-1.5 rounded-lg">
                  Revoke Record
                </button>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ── Request Access ────────────────────────────────────────
function RequestAccess({ account, contracts, toast }) {
  const [passportIdInput, setPassportIdInput] = useState('');
  const [patientWallet, setPatientWallet]     = useState('');
  const [recordScope, setRecordScope]         = useState(0);
  const [expiryDate, setExpiryDate]           = useState('');
  const [loading, setLoading]                 = useState(false);
  const [providerId, setProviderId]           = useState(null);
  const [isVerified, setIsVerified]           = useState(false);

  useEffect(() => {
    async function checkProvider() {
      try {
        const pid = await contracts.getProviderIdByWallet(account);
        if (!isZeroBytes32(pid)) {
          setProviderId(pid);
          setIsVerified(await contracts.isProviderVerified(pid));
        }
      } catch (_) {}
    }
    if (account) checkProvider();
  }, [account]);

  async function handleRequestAccess() {
    if (!passportIdInput || !ethers.isHexString(passportIdInput, 32)) { toast.error('Invalid passport ID'); return; }
    if (!isValidAddress(patientWallet)) { toast.error('Invalid patient wallet address'); return; }
    if (!expiryDate) { toast.error('Expiry date is required'); return; }
    const expiresAt = dateToTimestamp(expiryDate);
    if (expiresAt <= Math.floor(Date.now() / 1000)) { toast.error('Expiry date must be in the future'); return; }
    if (!providerId) { toast.error('You must be a registered provider'); return; }
    setLoading(true);
    try {
      const receipt = await contracts.requestAccess(passportIdInput, providerId, patientWallet, recordScope, expiresAt);
      toast.success('Access request submitted! Awaiting patient approval.', { title: 'Request Sent', txHash: receipt?.hash || receipt?.transactionHash });
      setPassportIdInput('');
      setPatientWallet('');
      setExpiryDate('');
    } catch (err) { toast.error(parseContractError(err), { title: 'Request Failed' }); }
    finally { setLoading(false); }
  }

  return (
    <div className="glass rounded-xl p-6 max-w-xl">
      <div className="section-header">Request Patient Data Access</div>
      {!isVerified && (
        <div className="mb-5 p-3 rounded-lg" style={{ background: 'rgba(245,158,11,0.08)', border: '1px solid rgba(245,158,11,0.2)' }}>
          <p className="text-amber-300 text-sm">⚠ Only verified providers can request patient access. Ensure your account is verified.</p>
        </div>
      )}
      <p className="text-sm text-slate-400 mb-6">Request access to a patient's medical records. The patient must approve your request before you can view their data.</p>
      <div className="space-y-4">
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Patient Passport ID</label>
          <input type="text" className="input-field" placeholder="0x... patient passport ID (bytes32)"
            value={passportIdInput} onChange={e => setPassportIdInput(e.target.value)} />
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Patient Wallet Address</label>
          <input type="text" className="input-field" placeholder="0x... patient wallet address"
            value={patientWallet} onChange={e => setPatientWallet(e.target.value)} />
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Record Scope</label>
          <select className="input-field" value={recordScope} onChange={e => setRecordScope(Number(e.target.value))}>
            {RecordScopes.map(s => <option key={s.value} value={s.value}>{s.label}</option>)}
          </select>
        </div>
        <div>
          <label className="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2 block">Access Expiry</label>
          <input type="datetime-local" className="input-field"
            value={expiryDate} onChange={e => setExpiryDate(e.target.value)}
            min={new Date(Date.now() + 60000).toISOString().slice(0, 16)} />
        </div>
        {providerId && (
          <div className="p-3 rounded-lg" style={{ background: 'rgba(59,130,246,0.06)', border: '1px solid rgba(59,130,246,0.15)' }}>
            <div className="text-xs text-slate-500 mb-1">Your Provider ID (auto-filled)</div>
            <div className="font-mono text-xs text-blue-300 truncate">{providerId}</div>
          </div>
        )}
        <button onClick={handleRequestAccess} disabled={loading || !passportIdInput || !patientWallet || !expiryDate}
          className="btn-primary w-full py-3 rounded-lg text-sm flex items-center justify-center gap-2">
          {loading ? <><span className="spinner"></span>Submitting…</> : '⊞ Request Access'}
        </button>
      </div>
    </div>
  );
}

// ── Provider Access Requests ──────────────────────────────
function ProviderAccessRequests({ account, contracts, toast }) {
  const [loading, setLoading]           = useState(true);
  const [providerId, setProviderId]     = useState(null);
  const [accessIds, setAccessIds]       = useState([]);
  const [accessDetails, setAccessDetails] = useState({});
  const [actionLoading, setActionLoading] = useState({});

  useEffect(() => { load(); }, [account]);

  async function load() {
    setLoading(true);
    try {
      const pid = await contracts.getProviderIdByWallet(account);
      if (isZeroBytes32(pid)) { setLoading(false); return; }
      setProviderId(pid);
      const ids = await contracts.getProviderAccessIds(pid);
      setAccessIds(ids);
      const details = {};
      for (const aid of ids) {
        try { details[aid] = { status: Number(await contracts.getAccessStatus(aid)) }; } catch (_) {}
      }
      setAccessDetails(details);
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setLoading(false); }
  }

  async function handleRevoke(accessId) {
    setActionLoading(prev => ({ ...prev, [accessId]: true }));
    try {
      await contracts.revokeAccess(accessId);
      toast.success('Access revoked');
      await load();
    } catch (err) { toast.error(parseContractError(err)); }
    finally { setActionLoading(prev => ({ ...prev, [accessId]: false })); }
  }

  if (loading) return <LoadingCard />;
  if (!providerId) return (
    <div className="glass rounded-xl p-8 text-center"><p className="text-slate-400">Register as a provider first.</p></div>
  );

  const statusLabels  = { 0: 'Pending', 1: 'Approved', 2: 'Rejected', 3: 'Revoked', 4: 'Expired' };
  const badgeClasses  = { 0: 'badge-amber', 1: 'badge-green', 2: 'badge-red', 3: 'badge-gray', 4: 'badge-gray' };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="text-sm text-slate-400">{accessIds.length} access request{accessIds.length !== 1 ? 's' : ''}</div>
        <button onClick={load} className="btn-secondary text-xs px-3 py-1.5 rounded-lg">Refresh</button>
      </div>
      {accessIds.length === 0 ? (
        <div className="glass rounded-xl p-8 text-center"><p className="text-slate-400">No access requests found.</p></div>
      ) : accessIds.map(aid => {
        const d = accessDetails[aid] || {};
        return (
          <div key={aid} className="glass rounded-xl p-5">
            <div className="flex items-start justify-between gap-3 flex-wrap mb-3">
              <div className="flex-1 min-w-0">
                <div className="text-xs text-slate-500 mb-1">Access ID</div>
                <CopyableHash value={aid} />
              </div>
              <span className={`badge ${badgeClasses[d.status] || 'badge-gray'}`}>
                {statusLabels[d.status] || 'Unknown'}
              </span>
            </div>
            {d.status === 1 && (
              <button onClick={() => handleRevoke(aid)} disabled={actionLoading[aid]}
                className="btn-amber text-xs px-3 py-1.5 rounded-lg flex items-center gap-1">
                {actionLoading[aid] ? <><span className="spinner" style={{ width: 12, height: 12 }}></span>Revoking…</> : '⊘ Revoke Access'}
              </button>
            )}
          </div>
        );
      })}
    </div>
  );
}
