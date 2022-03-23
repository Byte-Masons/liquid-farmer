async function main() {
  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');

  const wantAddress = '0x9C775D3D66167685B2A3F4567B548567D2875350';
  const tokenName = 'FTM-DEUS Spirit LiquidV2 Crypt';
  const tokenSymbol = 'rf-FTM-DEUS-l-s';
  const depositFee = 0;
  const tvlCap = ethers.constants.MaxUint256;
  const options = {gasPrice: 200000000000, gasLimit: 9000000};

  const vault = await Vault.deploy(wantAddress, tokenName, tokenSymbol, depositFee, tvlCap, options);

  await vault.deployed();
  console.log('Vault deployed to:', vault.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
