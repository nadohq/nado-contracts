# Contract Verification Guide

This document explains how to verify contracts on Ink Chain using the Hardhat verification tasks.

## Prerequisites

**IMPORTANT**: First time setup requires installing dependencies:
```bash
cd /path/to/nado-contracts/core
yarn install
```

This is a one-time setup. After dependencies are installed, you can run the verification commands.

### API Keys Setup

A `.env` file has been created with the Blockscout API keys. The verification script requires these environment variables:

- `BLOCKSCOUT_API_KEY_TEST` - For Ink Sepolia testnet
- `BLOCKSCOUT_API_KEY_PROD` - For Ink mainnet

The `.env` file is already configured. If you need to update the keys, edit `.env`:
```bash
# .env
BLOCKSCOUT_API_KEY_TEST=your-test-api-key
BLOCKSCOUT_API_KEY_PROD=your-prod-api-key
```

**Note**: The `.env` file is gitignored to keep API keys secure.

## Verifying a Single Contract

To verify a contract by its address:

```bash
yarn hardhat verify-contract --address <CONTRACT_ADDRESS> --network <NETWORK>
```

**Example:**
```bash
# Verify on prod (Ink mainnet)
yarn hardhat verify-contract \
  --address 0xD218103918C19D0A10cf35300E4CfAfbD444c5fE \
  --name Clearinghouse \
  --network prod

# Verify on test (Ink Sepolia)
yarn hardhat verify-contract \
  --address 0x1234... \
  --name SpotEngine \
  --network test
```

## How It Works

1. **Proxy Detection**: The script automatically detects if the address is a proxy contract
2. **Implementation Verification**: For proxies, it verifies the implementation contract (what you see in the explorer)
3. **Direct Verification**: For non-proxy contracts, it verifies the contract directly

## Networks

- `test`: Ink Sepolia testnet
- `prod`: Ink mainnet
- `localhost`: Local Hardhat node

## Parameters

- `--address` (required): Contract address to verify
- `--name` (optional): Display name for the contract
- `--network` (required): Network to verify on (`test`, `prod`, or `localhost`)

## Troubleshooting

### Already Verified
If the contract is already verified, you'll see:
```
✓ <ContractName> implementation was already verified
```

### Verification Failed
If verification fails, you'll see the error message. Common issues:
- Contract not found at the address
- Network configuration incorrect
- Blockscout API temporarily unavailable

### TypeScript Errors
If you see TypeScript errors, make sure all dependencies are installed:
```bash
yarn install
```

## Technical Details

- **Verifier**: Uses @nomiclabs/hardhat-etherscan plugin
- **Explorer**: Blockscout (Etherscan-compatible API)
- **Implementation Detection**: Uses OpenZeppelin's ERC1967 standard

## Support

For issues or questions, contact the contracts team.
