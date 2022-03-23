async function main() {
  const vaultAddress = '0xD9fd0cC7d27c51C102Aac42B486b92285B41BD5b';
  const strategyAddress = '0x8038313F74D3491e9F0829Ad51b236728B680C72';

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
