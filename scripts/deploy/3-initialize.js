async function main() {
  const vaultAddress = '0xe040634Ce403341eB5BfF36B88A1Cd2dF665773a';
  const strategyAddress = '0x6E3e3e8824A4CB6FAbcBBe50705E595FD8FfD1F7';

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
