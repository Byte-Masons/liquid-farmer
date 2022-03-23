async function main() {
  const vaultAddress = '0x1c7AC81E72E40Ff1866b41aE89519b2758699bf0';
  const strategyAddress = '0xdCCc02Cb88f0fbD2D737ab8AB62F1641D37231bC';

  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');
  const vault = Vault.attach(vaultAddress);
  const options = {gasPrice: 200000000000, gasLimit: 9000000};

  await vault.initialize(strategyAddress, options);
  console.log('Vault initialized');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
