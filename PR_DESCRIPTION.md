# Fix: Critical Security Vulnerability in `createIsolatedSubaccount` (Issue #10)

## Vulnerability Analysis
The function `createIsolatedSubaccount` allowed transferring margin from a parent account to a new isolated subaccount **without checking if the parent account remained solvent**. This inconsistency (compared to other functions like `mistNlp` or `burnNlp`) created a potential fund-draining vector where a user could move funds out of an under-collateralized position.

## Implemented Fix

### 1. Explicit Health Check
Added a critical `require` statement at the end of `createIsolatedSubaccount` to verify the parent account's health immediately after the balance update:

```solidity
require(isHealthy(txn.order.sender), ERR_SUBACCT_HEALTH);
```

### 2. Updated `isHealthy` Helper
The `isHealthy` function in `OffchainExchange.sol` was previously a dummy stub returning `true` and marked as `view`.
- **Change**: Removed the `view` modifier.
- **Reason**: The actual health check relies on `clearinghouse.getHealth()`, which emits events (`PriceQuery`) and is therefore state-changing (non-view).
- **Implementation**: Connected `isHealthy` to `clearinghouse.getHealth(..., IProductEngine.HealthType.INITIAL)`.

## Verification
- Confirmed that `npx hardhat compile` succeeds with these changes.
- The logic now strictly enforces solvency for the parent account during isolated subaccount creation, consistent with the protocol's risk management standards.

Resolves: #10
