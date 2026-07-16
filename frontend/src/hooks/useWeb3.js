import { useState, useEffect, useCallback, useRef } from 'react';
import { ethers } from 'ethers';
import { TARGET_CHAIN_ID, TARGET_CHAIN_HEX, NETWORK_NAME } from '../utils/constants.js';

// EIP-6963 multi-wallet detection with window.ethereum fallback
async function detectProvider() {
  return new Promise((resolve) => {
    if (window.ethereum) { resolve(window.ethereum); return; }
    const timeout = setTimeout(() => resolve(null), 500);
    window.addEventListener('eip6963:announceProvider', (event) => {
      clearTimeout(timeout);
      resolve(event.detail.provider);
    }, { once: true });
    window.dispatchEvent(new Event('eip6963:requestProvider'));
  });
}

export function useWeb3() {
  const [account, setAccount] = useState(null);
  const [provider, setProvider] = useState(null);
  const [signer, setSigner] = useState(null);
  const [chainId, setChainId] = useState(null);
  const [isConnecting, setIsConnecting] = useState(false);
  const [error, setError] = useState(null);
  const rawProviderRef = useRef(null);

  const isCorrectNetwork = chainId === TARGET_CHAIN_ID;

  const setupProvider = useCallback(async (rawProvider) => {
    try {
      const ethersProvider = new ethers.BrowserProvider(rawProvider);
      const network = await ethersProvider.getNetwork();
      const signerInstance = await ethersProvider.getSigner();
      const address = await signerInstance.getAddress();

      rawProviderRef.current = rawProvider;
      setProvider(ethersProvider);
      setSigner(signerInstance);
      setAccount(address);
      setChainId(Number(network.chainId));
      setError(null);
      return { provider: ethersProvider, signer: signerInstance, address };
    } catch (err) {
      setError('Failed to setup provider');
      throw err;
    }
  }, []);

  const connect = useCallback(async () => {
    setIsConnecting(true);
    setError(null);
    try {
      const rawProvider = window.__qdapp_getProvider
        ? await window.__qdapp_getProvider()
        : (window.ethereum || await detectProvider());

      if (!rawProvider) {
        throw new Error('No wallet found. Install MetaMask or another Web3 wallet, then refresh.');
      }

      await rawProvider.request({ method: 'eth_requestAccounts' });
      await setupProvider(rawProvider);
    } catch (err) {
      const msg = err?.message || 'Failed to connect wallet';
      if (msg.includes('rejected') || msg.includes('denied')) {
        setError('Connection rejected by user');
      } else {
        setError(msg);
      }
    } finally {
      setIsConnecting(false);
    }
  }, [setupProvider]);

  const disconnect = useCallback(() => {
    setAccount(null);
    setProvider(null);
    setSigner(null);
    setChainId(null);
    rawProviderRef.current = null;
    setError(null);
  }, []);

  const switchNetwork = useCallback(async () => {
    const rawProvider = rawProviderRef.current;
    if (!rawProvider) return;
    try {
      await rawProvider.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: TARGET_CHAIN_HEX }],
      });
    } catch (switchError) {
      if (switchError.code === 4902) {
        try {
          await rawProvider.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId: TARGET_CHAIN_HEX,
              chainName: 'Base Sepolia Testnet',
              nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
              rpcUrls: ['https://sepolia.base.org'],
              blockExplorerUrls: ['https://sepolia.basescan.org'],
            }],
          });
        } catch (addError) {
          setError('Failed to add Base Sepolia network');
        }
      } else {
        setError('Failed to switch network');
      }
    }
  }, []);

  // Listen for account/chain changes
  useEffect(() => {
    const rawProvider = rawProviderRef.current || window.ethereum;
    if (!rawProvider) return;

    const onAccounts = (accounts) => {
      if (accounts.length === 0) disconnect();
      else setupProvider(rawProvider);
    };
    const onChain = () => setupProvider(rawProvider);

    rawProvider.on?.('accountsChanged', onAccounts);
    rawProvider.on?.('chainChanged', onChain);

    return () => {
      rawProvider.removeListener?.('accountsChanged', onAccounts);
      rawProvider.removeListener?.('chainChanged', onChain);
    };
  }, [account, setupProvider, disconnect]);

  // Auto-connect if already authorized
  useEffect(() => {
    async function tryAutoConnect() {
      const rawProvider = window.__qdapp_getProvider
        ? await window.__qdapp_getProvider()
        : window.ethereum;
      if (!rawProvider) return;
      try {
        const accounts = await rawProvider.request({ method: 'eth_accounts' });
        if (accounts && accounts.length > 0) {
          await setupProvider(rawProvider);
        }
      } catch (_) {}
    }
    tryAutoConnect();
  }, [setupProvider]);

  return {
    account,
    provider,
    signer,
    chainId,
    isConnecting,
    isCorrectNetwork,
    error,
    connect,
    disconnect,
    switchNetwork,
    networkName: NETWORK_NAME,
    targetChainId: TARGET_CHAIN_ID,
  };
}
