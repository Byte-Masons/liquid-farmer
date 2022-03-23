async function main() {
  const vaultAddress = '0x36F7Ed9A8ce0B5004b80079947823Fe189A10a3D';
  const strategyAddress = '0x90fC2baF56CaA94637f1Ea8CC3F59F55ae04ed8a';

  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');
  const vault = Vault.attach(vaultAddress);
  const options = {gasPrice: 300000000000, gasLimit: 9000000};

  await vault.initialize(strategyAddress, options);
  console.log('Vault initialized');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
