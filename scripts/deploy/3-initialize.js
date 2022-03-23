async function main() {
  const vaultAddress = '0x152b01927AcD3d7073051C3b869974A82596a414';
  const strategyAddress = '0xe6C5AA6540FB66F8fDaC0aB45bBF8677c8741Db7';

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
