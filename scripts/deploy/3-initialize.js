async function main() {
  const vaultAddress = '0xA34276e30c4b793c4f6A5Bf77D3973B510CE63e3';
  const strategyAddress = '0x39f2E23fBc5Cd4D4597cCeca5614745ACB355bf9';

  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');
  const vault = Vault.attach(vaultAddress);
  const options = {gasPrice: 400000000000, gasLimit: 9000000};

  await vault.initialize(strategyAddress, options);
  console.log('Vault initialized');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
