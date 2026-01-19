# Fix: 100% Fund Loss in `burnNlp` due to Minimum Fee (Issue #11)

## Vulnerability Analysis
The `Clearinghouse.burnNlp` function enforced a minimum hardcoded fee of `ONE` (10^18 units), equivalent to $1.00 USD. This meant that any user attempting to burn an NLP amount worth less than $1.00 would have their entire transaction value consumed by the fee, resulting in a 100% loss.

```solidity
// Previous logic
int128 burnFee = MathHelper.max(ONE, quoteAmount / 1000);
```

## Implemented Fix
Removed the artificial `MathHelper.max(ONE, ...)` constraint. The fee is now strictly proportional (0.1% or `quoteAmount / 1000`), ensuring that small transactions are treated fairly and not drained.

```solidity
// New logic
int128 burnFee = quoteAmount / 1000;
```

## Verification
- Confirmed valid compilation with `npx hardhat compile`.
- Logic analysis: A $0.01 burn now incurs a ~$0.00001 fee instead of $1.00.

Resolves: #11
