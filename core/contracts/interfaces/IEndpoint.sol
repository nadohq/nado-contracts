// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./clearinghouse/IClearinghouse.sol";

interface IEndpoint {
    event SubmitTransactions();
    event PriceQuery(uint32 productId);

    // events that we parse transactions into
    enum TransactionType {
        LiquidateSubaccount,
        DepositCollateral,
        WithdrawCollateral,
        SpotTick,
        UpdatePrice,
        SettlePnl,
        MatchOrders,
        DepositInsurance,
        ExecuteSlowMode,
        DumpFees,
        PerpTick,
        ManualAssert,
        UpdateProduct,
        LinkSigner,
        UpdateFeeTier,
        TransferQuote,
        RebalanceXWithdraw,
        AssertCode,
        WithdrawInsurance,
        CreateIsolatedSubaccount,
        DelistProduct,
        MintNlp,
        BurnNlp,
        MatchOrdersWithAmount,
        UpdateTierFeeRates,
        AddNlpPool,
        UpdateNlpPool,
        DeleteNlpPool
    }

    struct UpdateProduct {
        address engine;
        bytes tx;
    }

    enum LiquidationMode {
        SPREAD,
        SPOT,
        PERP
    }

    struct LiquidateSubaccount {
        bytes32 sender;
        bytes32 liquidatee;
        uint32 productId;
        bool isEncodedSpread;
        int128 amount;
        uint64 nonce;
    }

    struct SignedLiquidateSubaccount {
        LiquidateSubaccount tx;
        bytes signature;
    }

    struct DepositCollateral {
        bytes32 sender;
        uint32 productId;
        uint128 amount;
    }

    struct SignedDepositCollateral {
        DepositCollateral tx;
        bytes signature;
    }

    struct WithdrawCollateral {
        bytes32 sender;
        uint32 productId;
        uint128 amount;
        uint64 nonce;
    }

    struct SignedWithdrawCollateral {
        WithdrawCollateral tx;
        bytes signature;
    }

    struct MintNlp {
        bytes32 sender;
        uint128 quoteAmount;
        uint64 nonce;
    }

    struct SignedMintNlp {
        MintNlp tx;
        bytes signature;
        int128 oraclePriceX18;
        int128[] nlpPoolRebalanceX18;
    }

    struct BurnNlp {
        bytes32 sender;
        uint128 nlpAmount;
        uint64 nonce;
    }

    struct SignedBurnNlp {
        BurnNlp tx;
        bytes signature;
        int128 oraclePriceX18;
        int128[] nlpPoolRebalanceX18;
    }

    struct AddNlpPool {
        address owner;
        uint128 balanceWeightX18;
    }

    struct UpdateNlpPool {
        uint64 poolId;
        address owner;
        uint128 balanceWeightX18;
    }

    struct DeleteNlpPool {
        uint64 poolId;
    }

    struct LinkSigner {
        bytes32 sender;
        bytes32 signer;
        uint64 nonce;
    }

    struct SignedLinkSigner {
        LinkSigner tx;
        bytes signature;
    }

    struct PerpTick {
        uint128 time;
        int128[] avgPriceDiffs;
    }

    struct SpotTick {
        uint128 time;
    }

    struct ManualAssert {
        int128[] openInterests;
        int128[] totalDeposits;
        int128[] totalBorrows;
    }

    struct AssertCode {
        string[] contractNames;
        bytes32[] codeHashes;
    }

    struct WithdrawInsurance {
        uint128 amount;
        address sendTo;
    }

    struct DelistProduct {
        uint32 productId;
        int128 priceX18;
        bytes32[] subaccounts;
    }

    struct Rebate {
        bytes32[] subaccounts;
        int128[] amounts;
    }

    struct UpdateFeeTier {
        address user;
        uint32 newTier;
    }

    struct UpdateTierFeeRates {
        uint32 tier;
        uint32 productId;
        int128 makerRateX18;
        int128 takerRateX18;
    }

    struct RebalanceXWithdraw {
        uint32 productId;
        uint128 amount;
        address sendTo;
    }

    struct UpdatePrice {
        uint32 productId;
        int128 priceX18;
    }

    struct SettlePnl {
        bytes32[] subaccounts;
        uint256[] productIds;
    }

    struct Order {
        bytes32 sender;
        int128 priceX18;
        int128 amount;
        uint64 expiration;
        uint64 nonce;
        uint128 appendix;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
    }

    struct MatchOrders {
        uint32 productId;
        SignedOrder taker;
        SignedOrder maker;
    }

    struct MatchOrdersWithAmount {
        MatchOrders matchOrders;
        int128 takerAmountDelta;
    }

    struct MatchOrdersWithSigner {
        MatchOrders matchOrders;
        address takerLinkedSigner;
        address makerLinkedSigner;
        int128 takerAmountDelta;
    }

    struct DepositInsurance {
        uint128 amount;
    }

    struct SlowModeTx {
        uint64 executableAt;
        address sender;
        bytes tx;
    }

    struct SlowModeConfig {
        uint64 timeout;
        uint64 txCount;
        uint64 txUpTo;
    }

    struct TransferQuote {
        bytes32 sender;
        bytes32 recipient;
        uint128 amount;
        uint64 nonce;
    }

    struct SignedTransferQuote {
        TransferQuote tx;
        bytes signature;
    }

    struct CreateIsolatedSubaccount {
        Order order;
        uint32 productId;
        bytes signature;
    }

    struct NlpPool {
        uint64 poolId;
        bytes32 subaccount;
        address owner;
        uint128 balanceWeightX18;
    }

    function depositCollateral(
        bytes12 subaccountName,
        uint32 productId,
        uint128 amount
    ) external;

    function depositCollateralWithReferral(
        bytes12 subaccountName,
        uint32 productId,
        uint128 amount,
        string calldata referralCode
    ) external;

    function depositCollateralWithReferral(
        bytes32 subaccount,
        uint32 productId,
        uint128 amount,
        string calldata referralCode
    ) external;

    function submitSlowModeTransaction(bytes calldata transaction) external;

    function getTime() external view returns (uint128);

    function getSequencer() external view returns (address);

    function getNonce(address sender) external view returns (uint64);

    function getOffchainExchange() external view returns (address);

    function getPriceX18(uint32 productId) external returns (int128);

    function getNlpPools() external view returns (NlpPool[] memory);
}
