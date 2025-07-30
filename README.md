# Nado Protocol

This repository contains the smart contract implementations for the Nado Protocol ecosystem.

## Project Structure

The repository is organized into two main projects:

- **[nado-contracts/core](./core)**: EVM implementation of Nado core functionality
- **[nado-contracts/lba](./lba)**: Nado LBA (Liquidity Bootstrap Auction) contracts

## Requirements

- Node.js >=16
- [Yarn](https://yarnpkg.com/)

## Getting Started

Each project has its own setup and development commands. Navigate to the respective directories for project-specific instructions:

```
# For Nado EVM Core Contracts
cd nado-contracts/core
yarn install
yarn compile

# For Nado LBA Contracts
cd nado-contracts/lba
yarn install
# Follow the .env setup instructions
```

## Available Commands

### Core Contracts

- `yarn compile`: Compile Nado EVM contracts
- See project-specific README for more details

### LBA Contracts

- `yarn lint`: Run prettier & SolHint
- `yarn contracts:force-compile`: Compile contracts and generate TS bindings + ABIs
- `yarn run-local-node`: Run a persistent local Hardhat node for testing
- See project-specific README for more details

## Further Documentation

For more detailed information about each project, please refer to their respective README files.