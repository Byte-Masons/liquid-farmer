async function main() {
  const vaultAddress = '0xF38B0fc0e117A3775517B60a60bD6Ab234Ce6bCa';
  const strategyAddress = '0x294C5F913ac1F90E97aEBfDf4f296ed8198D22d9';

  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');
  const vault = Vault.attach(vaultAddress);

  await vault.initialize(strategyAddress);
  console.log('Vault initialized');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
