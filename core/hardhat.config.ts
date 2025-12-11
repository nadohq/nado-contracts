/**
 * @type import('hardhat/config').HardhatUserConfig
 */
import '@nomicfoundation/hardhat-chai-matchers';
import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-etherscan';
import '@nomiclabs/hardhat-solhint';
import '@openzeppelin/hardhat-upgrades';
import '@typechain/hardhat';
import 'dotenv/config';
import 'hardhat-deploy';
import 'solidity-coverage';
import 'hardhat-gas-reporter';
import 'hardhat-contract-sizer';
import 'hardhat-abi-exporter';
import { HardhatUserConfig } from 'hardhat/config';

// Custom tasks
import './tasks';

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.13',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  defaultNetwork: 'localhost',
  networks: {
    localhost: {
      url: 'http://127.0.0.1:8545',
    },
    test: {
      chainId: 763373,
      url: 'https://rpc-gel-sepolia.inkonchain.com',
      accounts: [], // Add your private keys here or use env variables
    },
    prod: {
      chainId: 57073,
      url: 'https://rpc-gel.inkonchain.com',
      accounts: [], // Add your private keys here or use env variables
    },
  },
  etherscan: {
    apiKey: {
      test: process.env.BLOCKSCOUT_API_KEY_TEST!,
      prod: process.env.BLOCKSCOUT_API_KEY_PROD!,
    },
    customChains: [
      {
        network: 'test',
        chainId: 763373,
        urls: {
          apiURL: 'https://explorer-sepolia.inkonchain.com/api',
          browserURL: 'https://explorer-sepolia.inkonchain.com',
        },
      },
      {
        network: 'prod',
        chainId: 57073,
        urls: {
          apiURL: 'https://explorer.inkonchain.com/api',
          browserURL: 'https://explorer.inkonchain.com',
        },
      },
    ],
  },
  contractSizer: {
    runOnCompile: true,
  },
  abiExporter: {
    path: './abis',
    runOnCompile: true,
    clear: true,
    flat: true,
    spacing: 2,
  },
  gasReporter: {
    onlyCalledMethods: true,
    showTimeSpent: true,
  },
  mocha: {
    timeout: 1000000000,
  },
};

export default config;
