// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./common/Constants.sol";
import "./common/Errors.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./libraries/RiskHelper.sol";
import "./SpotEngineState.sol";

contract SpotEngine is SpotEngineState {
    using MathSD21x18 for int128;

    function initialize(
        address _clearinghouse,
        address _offchainExchange,
        address _quote,
        address _endpoint,
        address _admin
    ) external {
        _initialize(_clearinghouse, _offchainExchange, _endpoint, _admin);

        configs[QUOTE_PRODUCT_ID] = Config({
            token: _quote,
            interestInflectionUtilX18: 8e17, // .8
            interestFloorX18: 1e16, // .01
            interestSmallCapX18: 4e16, // .04
            interestLargeCapX18: ONE, // 1
            withdrawFeeX18: ONE, // 1
            minDepositRateX18: 0 // 0
        });
        _risk().value[QUOTE_PRODUCT_ID] = RiskHelper.RiskStore({
            longWeightInitial: 1e9,
            shortWeightInitial: 1e9,
            longWeightMaintenance: 1e9,
            shortWeightMaintenance: 1e9,
            priceX18: ONE
        });
        _setState(
            QUOTE_PRODUCT_ID,
            State({
                cumulativeDepositsMultiplierX18: ONE,
                cumulativeBorrowsMultiplierX18: ONE,
                totalDepositsNormalized: 0,
                totalBorrowsNormalized: 0
            })
        );
        productIds.push(QUOTE_PRODUCT_ID);
        emit AddProduct(QUOTE_PRODUCT_ID);
    }

    /**
     * View
     */

    function getEngineType() external pure returns (EngineType) {
        return EngineType.SPOT;
    }

    function getConfig(uint32 productId) external view returns (Config memory) {
        return configs[productId];
    }

    /**
     * Actions
     */

    /// @notice adds a new product with default parameters
    function addProduct(
        uint32 productId,
        uint32 quoteId,
        int128 sizeIncrement,
        int128 minSize,
        Config calldata config,
        RiskHelper.RiskStore calldata riskStore
    ) public onlyOwner {
        require(productId != QUOTE_PRODUCT_ID);
        _addProductForId(productId, quoteId, sizeIncrement, minSize, riskStore);

        configs[productId] = config;
        _setState(
            productId,
            State({
                cumulativeDepositsMultiplierX18: ONE,
                cumulativeBorrowsMultiplierX18: ONE,
                totalDepositsNormalized: 0,
                totalBorrowsNormalized: 0
            })
        );
    }

    function updateProduct(bytes calldata rawTxn) external onlyEndpoint {
        UpdateProductTx memory txn = abi.decode(rawTxn, (UpdateProductTx));
        RiskHelper.RiskStore memory riskStore = txn.riskStore;

        if (txn.productId != QUOTE_PRODUCT_ID) {
            require(
                riskStore.longWeightInitial <=
                    riskStore.longWeightMaintenance &&
                    riskStore.shortWeightInitial >=
                    riskStore.shortWeightMaintenance &&
                    configs[txn.productId].token == txn.config.token,
                ERR_BAD_PRODUCT_CONFIG
            );

            RiskHelper.RiskStore memory r = _risk().value[txn.productId];
            r.longWeightInitial = riskStore.longWeightInitial;
            r.shortWeightInitial = riskStore.shortWeightInitial;
            r.longWeightMaintenance = riskStore.longWeightMaintenance;
            r.shortWeightMaintenance = riskStore.shortWeightMaintenance;
            _risk().value[txn.productId] = r;

            _exchange().updateMarket(
                txn.productId,
                type(uint32).max,
                txn.sizeIncrement,
                txn.minSize
            );
        }

        configs[txn.productId] = txn.config;
    }

    function updateQuoteFromInsurance(bytes32 subaccount, int128 insurance)
        external
        returns (int128)
    {
        _assertInternal();
        State memory state = states[QUOTE_PRODUCT_ID];
        BalanceNormalized memory balanceNormalized = balances[QUOTE_PRODUCT_ID][
            subaccount
        ];
        int128 balanceAmount = balanceNormalizedToBalance(
            state,
            balanceNormalized
        ).amount;
        if (balanceAmount < 0) {
            int128 topUpAmount = MathHelper.max(
                MathHelper.min(insurance, -balanceAmount),
                0
            );
            insurance -= topUpAmount;
            _updateBalanceNormalized(state, balanceNormalized, topUpAmount);
        }
        _setState(QUOTE_PRODUCT_ID, state);
        _setBalanceAndUpdateBitmap(
            QUOTE_PRODUCT_ID,
            subaccount,
            balanceNormalized
        );
        return insurance;
    }

    function getNlpUnlockedBalance(bytes32 subaccount)
        external
        returns (Balance memory)
    {
        tryUnlockNlpBalance(subaccount);
        Balance memory balanceSum = nlpLockedBalanceQueues[subaccount]
            .unlockedBalanceSum;
        return balanceSum;
    }

    function handleNlpLockedBalance(bytes32 subaccount, int128 amountDelta)
        internal
    {
        _assertInternal();

        // N_ACCOUNT is not limited by lock period
        if (subaccount == N_ACCOUNT) return;

        tryUnlockNlpBalance(subaccount);
        if (amountDelta > 0) {
            NlpLockedBalanceQueue storage queue = nlpLockedBalanceQueues[
                subaccount
            ];
            queue.balances[queue.balanceCount] = NlpLockedBalance({
                balance: Balance({amount: amountDelta}),
                unlockedAt: getOracleTime() + NLP_LOCK_PERIOD
            });
            queue.balanceCount++;
        } else if (amountDelta < 0) {
            Balance memory balanceSum = nlpLockedBalanceQueues[subaccount]
                .unlockedBalanceSum;
            balanceSum.amount += amountDelta;
            nlpLockedBalanceQueues[subaccount].unlockedBalanceSum = balanceSum;
        }
    }

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta,
        int128 quoteDelta
    ) external {
        require(productId != QUOTE_PRODUCT_ID, ERR_INVALID_PRODUCT);
        _assertInternal();
        State memory state = states[productId];
        State memory quoteState = states[QUOTE_PRODUCT_ID];

        BalanceNormalized memory balance = balances[productId][subaccount];

        BalanceNormalized memory quoteBalance = balances[QUOTE_PRODUCT_ID][
            subaccount
        ];

        if (productId == NLP_PRODUCT_ID) {
            handleNlpLockedBalance(subaccount, amountDelta);
        }

        _updateBalanceNormalized(state, balance, amountDelta);
        _updateBalanceNormalized(quoteState, quoteBalance, quoteDelta);

        _setBalanceAndUpdateBitmap(productId, subaccount, balance);
        _setBalanceAndUpdateBitmap(QUOTE_PRODUCT_ID, subaccount, quoteBalance);

        _setState(productId, state);
        _setState(QUOTE_PRODUCT_ID, quoteState);
    }

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta
    ) external {
        _assertInternal();

        State memory state = states[productId];

        if (productId == NLP_PRODUCT_ID) {
            handleNlpLockedBalance(subaccount, amountDelta);
        }

        BalanceNormalized memory balance = balances[productId][subaccount];
        _updateBalanceNormalized(state, balance, amountDelta);

        _setBalanceAndUpdateBitmap(productId, subaccount, balance);
        _setState(productId, state);
    }

    // only check on withdraw -- ensure that users can't withdraw
    // funds that are in the Nado contract but not officially
    // 'deposited' into the Nado system and counted in balances
    // (i.e. if a user transfers tokens to the clearinghouse
    // without going through the standard deposit)
    function assertUtilization(uint32 productId) external view {
        (State memory _state, ) = getStateAndBalance(productId, X_ACCOUNT);
        int128 totalDeposits = _state.totalDepositsNormalized.mul(
            _state.cumulativeDepositsMultiplierX18
        );
        int128 totalBorrows = _state.totalBorrowsNormalized.mul(
            _state.cumulativeBorrowsMultiplierX18
        );
        require(totalDeposits >= totalBorrows, ERR_MAX_UTILIZATION);
    }

    function socializeSubaccount(bytes32 subaccount) external {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        uint32[] memory _productIds = getProductIds();
        for (uint128 i = 0; i < _productIds.length; ++i) {
            uint32 productId = _productIds[i];

            State memory state = states[productId];
            Balance memory balance = balanceNormalizedToBalance(
                state,
                balances[productId][subaccount]
            );
            if (balance.amount < 0) {
                int128 totalDeposited = state.totalDepositsNormalized.mul(
                    state.cumulativeDepositsMultiplierX18
                );

                state.cumulativeDepositsMultiplierX18 = (totalDeposited +
                    balance.amount).div(state.totalDepositsNormalized);

                require(state.cumulativeDepositsMultiplierX18 > 0);

                state.totalBorrowsNormalized += balance.amount.div(
                    state.cumulativeBorrowsMultiplierX18
                );

                _setBalanceAndUpdateBitmap(
                    productId,
                    subaccount,
                    BalanceNormalized({amountNormalized: 0})
                );
                _setState(productId, state);
            }
        }
    }

    function manualAssert(
        int128[] calldata totalDeposits,
        int128[] calldata totalBorrows
    ) external view {
        for (uint128 i = 0; i < totalDeposits.length; ++i) {
            uint32 productId = productIds[i];
            State memory state = states[productId];
            require(
                state.totalDepositsNormalized.mul(
                    state.cumulativeDepositsMultiplierX18
                ) == totalDeposits[i],
                ERR_DSYNC
            );
            require(
                state.totalBorrowsNormalized.mul(
                    state.cumulativeBorrowsMultiplierX18
                ) == totalBorrows[i],
                ERR_DSYNC
            );
        }
    }

    function getToken(uint32 productId) external view returns (address) {
        return address(configs[productId].token);
    }
}
