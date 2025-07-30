/**
 * @type import('hardhat/config').HardhatUserConfig
 */
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-solhint";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "dotenv/config";
import "hardhat-deploy";
import "solidity-coverage";
import { HardhatUserConfig } from "hardhat/config";

// Custom tasks
import "./tasks";
import { env } from "./env";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.13",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  defaultNetwork: env.defaultNetwork ?? "local",
  networks: {
    local: {
      chainId: 1337,
      // Automine for testing, periodic mini
      mining: {
        auto: !env.automineInterval,
        interval: env.automineInterval,
      },
      allowUnlimitedContractSize: true,
      url: "http://0.0.0.0:8545",
    },
    hardhat: {
      chainId: 1337,
    }
  },
  paths: {
    tests: "./tests",
  }
};

export default config;
