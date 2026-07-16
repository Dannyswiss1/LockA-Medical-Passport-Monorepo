import React, { useState } from 'react';
import { Navbar } from './components/Navbar.jsx';
import { Dashboard } from './components/Dashboard.jsx';
import { PatientPortal } from './components/PatientPortal.jsx';
import { ProviderPortal } from './components/ProviderPortal.jsx';
import { MedicalRecords } from './components/MedicalRecords.jsx';
import { Toast, useToast } from './components/Toast.jsx';
import { useWeb3 } from './hooks/useWeb3.js';
import { useContracts } from './hooks/useContracts.js';
import { getContractAddresses, saveContractAddresses, DEFAULT_ADDRESSES } from './utils/constants.js';

export default function App() {
  const [page, setPage] = useState('dashboard');
  const { toasts, toast, removeToast } = useToast();
  const web3 = useWeb3();
  const contracts = useContracts(web3.provider, web3.signer);
  const sharedProps = { account: web3.account, provider: web3.provider, signer: web3.signer, contracts, toast };

  return (
    <div className="min-h-screen" style={{ background: 'linear-gradient(135deg,#050810 0%,#0a0f1e 50%,#050c1a 100%)' }}>
      <Navbar
        account={web3.account} isConnecting={web3.isConnecting} isCorrectNetwork={web3.isCorrectNetwork}
        chainId={web3.chainId} onConnect={web3.connect} onDisconnect={web3.disconnect}
        onSwitchNetwork={web3.switchNetwork} currentPage={page} onNavigate={setPage}
      />
      <main className="pb-16">
        {page === 'dashboard' && <Dashboard {...sharedProps} onNavigate={setPage} />}
        {page === 'patient'   && <PatientPortal {...sharedProps} />}
        {page === 'provider'  && <ProviderPortal {...sharedProps} />}
        {page === 'records'   && <MedicalRecords {...sharedProps} />}
        {page === 'admin'     && <AdminPanel toast={toast} />}
      </main>
      <Toast toasts={toasts} removeToast={removeToast} />
    </div>
  );
}

function AdminPanel({ toast }) {
  const [addresses, setAddresses] = useState(() => getContractAddresses());
  const [saving, setSaving] = useState(false);
  const contractDocs = {
    PatientPassportRegistry: 'Manages patient health passport identities',
    ProviderRegistry: 'Manages healthcare provider registrations',
    MedicalRecordRegistry: 'Stores encrypted medical record hashes on-chain',
    ConsentAccessManager: 'Controls patient consent and provider data access',
  };
  function handleSave() {
    setSaving(true);
    try { saveContractAddresses(addresses); toast.success('Addresses saved! Reload the page for changes to take effect.', { title: 'Saved', duration: 6000 }); }
    catch { toast.error('Failed to save'); } finally { setSaving(false); }
  }
  function handleReset() { setAddresses({ ...DEFAULT_ADDRESSES }); saveContractAddresses(DEFAULT_ADDRESSES); toast.info('Addresses reset to defaults'); }
  return (
    <div className="max-w-3xl mx-auto px-4 py-8 animate-fade-in">
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-white mb-1">Admin Panel</h1>
        <p className="text-slate-400 text-sm">Configure deployed contract addresses — stored in browser localStorage</p>
      </div>
      <div className="glass rounded-xl p-6 mb-6">
        <div className="section-header">Contract Addresses</div>
        <div className="space-y-5 mt-4">
          {Object.keys(DEFAULT_ADDRESSES).map(key => (
            <div key={key}>
              <label className="text-xs font-semibold text-slate-300 uppercase tracking-wide mb-1 block">{key}</label>
              <p className="text-xs text-slate-500 mb-2">{contractDocs[key]}</p>
              <input type="text" className="input-field font-mono text-sm"
                placeholder="0x0000000000000000000000000000000000000000"
                value={addresses[key] || ''} spellCheck={false}
                onChange={e => setAddresses(prev => ({ ...prev, [key]: e.target.value }))} />
            </div>
          ))}
        </div>
        <div className="flex gap-3 mt-6">
          <button onClick={handleSave} disabled={saving} className="btn-primary px-5 py-2.5 rounded-lg text-sm flex items-center gap-2">
            {saving ? <><span className="spinner"></span>Saving…</> : <>
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7"/></svg>
              Save Addresses
            </>}
          </button>
          <button onClick={handleReset} className="btn-secondary px-5 py-2.5 rounded-lg text-sm">Reset to Defaults</button>
        </div>
      </div>
      <div className="glass rounded-xl p-5">
        <div className="flex items-start gap-3">
          <svg className="w-5 h-5 text-blue-400 flex-shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
          <div>
            <p className="text-blue-300 font-semibold text-sm mb-2">How to configure</p>
            <ol className="text-slate-400 text-xs space-y-1 list-decimal list-inside">
              <li>Deploy the 4 smart contracts to Base Sepolia via Remix</li>
              <li>Copy each deployed contract address from the transaction receipt</li>
              <li>Paste the addresses above and click Save</li>
              <li>Reload the page — the DApp will connect to your contracts</li>
            </ol>
            <a href="https://sepolia.basescan.org" target="_blank" rel="noopener noreferrer" className="text-blue-400 text-xs hover:text-blue-300 mt-2 inline-block">Open Base Sepolia Explorer ↗</a>
          </div>
        </div>
      </div>
    </div>
  );
}
