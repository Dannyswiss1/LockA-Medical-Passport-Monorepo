// ENSResolverHelper deployment script - Base Sepolia
console.log("Script started");

async function main() {
  // 1. Load the compiled artifact via Remix fileManager plugin
  console.log("Loading artifact...");
  const artifactJson = await remix.call('fileManager', 'readFile', 'artifacts/ENSResolverHelper.json');
  const artifact = JSON.parse(artifactJson);
  const abi      = artifact.abi;
  const bytecode = artifact.data.bytecode.object;
  console.log("Artifact loaded. ABI entries:", abi.length);

  // 2. Set up provider & signer via MetaMask (injected)
  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer   = await provider.getSigner();
  console.log("Signer address:", await signer.getAddress());

  // 3. Constructor arguments
  const _ensRegistry      = "0x1493b2567056c2181630115660571e0a067c2C2c";
  const _defaultResolver  = "0x6533C94869D28fAA8dF77cc63f9e2b2D6Cf6eB3";
  const _reverseRegistrar = "0xa0A8401ECF248a9375a0a71C4dedc263dA18dCd7";
  const _owner            = "0xb5e7f33d44e91cd31f1581ba5f8694777bea13c9";

  // 4. Deploy with gasLimit 1_500_000
  const factory  = new ethers.ContractFactory(abi, bytecode, signer);
  console.log("Deploying ENSResolverHelper on Base Sepolia...");

  const contract = await factory.deploy(
    _ensRegistry,
    _defaultResolver,
    _reverseRegistrar,
    _owner,
    { gasLimit: 1500000 }
  );

  console.log("Transaction sent. Hash:", contract.deploymentTransaction().hash);
  console.log("Waiting for confirmation...");

  await contract.waitForDeployment();

  const deployedAddress = await contract.getAddress();
  console.log("ENSResolverHelper deployed successfully at:", deployedAddress);
}

main().catch(error => {
  console.error("Deployment failed:");
  console.error("  message:", error.message);
  console.error("  code:",    error.code);
  console.error("  data:",    error.data);
  console.error("  reason:",  error.reason);
});
