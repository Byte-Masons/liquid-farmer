async function main() {
  const vaultAddress = '0x40b7E6Ae22bAb24F56D3Bce63Bb000556b68Dd63';
  const strategyAddress = '0x0f4F27643bE613399EFc925E8Eb69233b2A208AC';

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
