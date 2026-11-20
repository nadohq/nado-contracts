import { expect } from 'chai';
import { ethers } from 'hardhat';
import { BigNumber } from 'ethers';

describe('DirectDepositV1 & BaseWithdrawPool Tests', () => {
  let deployer: any;
  let mockEndpoint: any;
  let mockSpotEngine: any;
  let mockClearinghouse: any;
  let mockToken: any;
  let directDeposit: any;
  let withdrawPool: any;

  const subaccount = ethers.utils.formatBytes32String('subaccount1');

  beforeEach(async () => {
    [deployer] = await ethers.getSigners();

    const MockEndpoint = await ethers.getContractFactory('MockEndpointForDeposit');
    mockEndpoint = await MockEndpoint.deploy();

    const MockSpotEngine = await ethers.getContractFactory('MockSpotEngineForDeposit');
    mockSpotEngine = await MockSpotEngine.deploy();

    const MockClearinghouse = await ethers.getContractFactory('MockClearinghouseForWithdraw');
    mockClearinghouse = await MockClearinghouse.deploy();
    await mockClearinghouse.setSpotEngine(mockSpotEngine.address);

    const MockToken = await ethers.getContractFactory('MockNonStandardERC20');
    mockToken = await MockToken.deploy();

    await mockSpotEngine.setProduct(1, mockToken.address, ethers.utils.parseEther('0.001'));

    const DirectDeposit = await ethers.getContractFactory('DirectDepositV1');
    directDeposit = await DirectDeposit.deploy(
      mockEndpoint.address,
      mockSpotEngine.address,
      subaccount,
      deployer.address
    );

    const WithdrawPool = await ethers.getContractFactory('TestWithdrawPool');
    withdrawPool = await WithdrawPool.deploy();
    await withdrawPool.initialize(mockClearinghouse.address, deployer.address);
  });

  describe('DirectDepositV1', () => {
    it('successfully credits deposit with non-standard ERC20 (no boolean return on approve)', async () => {
      const depositAmount = BigNumber.from('1000000'); // 1 token with 6 decimals
      await mockToken.mint(directDeposit.address, depositAmount);

      await directDeposit.creditDeposit();

      expect(await mockEndpoint.lastSubaccount()).to.equal(subaccount);
      expect(await mockEndpoint.lastProductId()).to.equal(1);
      expect(await mockEndpoint.lastAmount()).to.equal(depositAmount);
      expect(await mockToken.allowance(directDeposit.address, mockEndpoint.address)).to.equal(depositAmount);
    });

    it('successfully resets allowance when non-zero allowance exists on non-standard token', async () => {
      // First deposit
      const depositAmount1 = BigNumber.from('500000');
      await mockToken.mint(directDeposit.address, depositAmount1);
      await directDeposit.creditDeposit();

      // Second deposit: existing allowance > 0, mockToken will revert if not reset to 0 first
      const depositAmount2 = BigNumber.from('800000');
      await mockToken.mint(directDeposit.address, depositAmount2);
      await directDeposit.creditDeposit();

      const expectedTotal = depositAmount1.add(depositAmount2);
      expect(await mockEndpoint.lastAmount()).to.equal(expectedTotal);
      expect(await mockToken.allowance(directDeposit.address, mockEndpoint.address)).to.equal(expectedTotal);
    });

    it('reverts when token balance exceeds uint128', async () => {
      const overflowAmount = BigNumber.from(2).pow(128); // type(uint128).max + 1
      await mockToken.mint(directDeposit.address, overflowAmount);

      await expect(directDeposit.creditDeposit()).to.be.revertedWith('Deposit amount exceeds uint128');
    });
  });

  describe('BaseWithdrawPool: fastWithdrawalFeeAmount', () => {
    it('calculates fee properly for normal amount', async () => {
      const amount = BigNumber.from('10000000'); // 10 USDC
      const fee = await withdrawPool.fastWithdrawalFeeAmount(mockToken.address, 1, amount);
      expect(fee).to.be.gt(0);
    });

    it('reverts with conversion overflow (CO) when amount exceeds INT128_MAX', async () => {
      const int128Max = BigNumber.from(2).pow(127).sub(1);
      const invalidAmount = int128Max.add(1);

      await expect(withdrawPool.fastWithdrawalFeeAmount(mockToken.address, 1, invalidAmount)).to.be.revertedWith('CO');
    });

    it('reverts with conversion overflow (CO) when amount * multiplier overflows int128', async () => {
      // 0 decimals -> multiplier = 10^18
      await mockToken.setDecimals(0);
      // Let amount be INT128_MAX / 10^17, so amount * 10^18 > INT128_MAX
      const int128Max = BigNumber.from(2).pow(127).sub(1);
      const largeAmount = int128Max.div(BigNumber.from(10).pow(17));

      await expect(withdrawPool.fastWithdrawalFeeAmount(mockToken.address, 1, largeAmount)).to.be.revertedWith('CO');
    });
  });
});
