import { task, types } from 'hardhat/config';

task('verify-contract')
  .addParam('address', 'Address of contract to verify', undefined, types.string)
  .addOptionalParam('name', 'Name of contract (for display)', undefined, types.string)
  .setAction(async (taskArgs, hre) => {
    const { address, name } = taskArgs;
    const displayName = name || address;

    // For upgradeable contracts, verify the implementation
    let implAddress: string | undefined;
    try {
      implAddress = await hre.upgrades.erc1967.getImplementationAddress(address);
      console.log(`Found implementation at ${implAddress} for proxy ${address}`);
    } catch (e) {
      console.log(`${displayName} is not a proxy, verifying directly`);
    }

    const addressToVerify = implAddress || address;
    const contractType = implAddress ? 'implementation' : 'contract';

    console.log(`Verifying ${displayName} ${contractType} at address ${addressToVerify}`);
    try {
      await hre.run('verify:verify', {
        address: addressToVerify,
        constructorArguments: [],
      });
      console.log(`✓ Successfully verified ${displayName} ${contractType}`);
    } catch (e: any) {
      if (e.message?.includes('Already Verified') || e.message?.includes('already verified')) {
        console.log(`✓ ${displayName} ${contractType} was already verified`);
      } else {
        console.log(`✗ Failed to verify ${displayName} ${contractType}:`);
        console.log(`  Error: ${e.message || e}`);
      }
    }
  });
