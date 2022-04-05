async function main() {
  const vaultAddress = '0x3182f7e68330141d3130228E6cfc44B96Bcf29C2';
  const strategyAddress = '0xc064001490b9bbecf8F00daD6c32B32974C948Ed';

  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');
  const vault = Vault.attach(vaultAddress);
  const options = {gasPrice: 170000000000, gasLimit: 9000000};

  await vault.initialize(strategyAddress, options);
  console.log('Vault initialized');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
