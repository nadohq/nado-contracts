// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/engine/ISpotEngine.sol";
import "./BaseEngine.sol";

abstract contract SpotEngineState is ISpotEngine, BaseEngine {
    using MathSD21x18 for int128;

    mapping(uint32 => Config) internal configs;
    mapping(uint32 => State) internal states;
    mapping(uint32 => mapping(bytes32 => BalanceNormalized)) internal balances;
    mapping(bytes32 => NlpLockedBalanceQueue) internal nlpLockedBalanceQueues;

    function _updateBalanceNormalized(
        State memory state,
        BalanceNormalized memory balance,
        int128 balanceDelta
    ) internal pure {
        if (balance.amountNormalized > 0) {
            state.totalDepositsNormalized -= balance.amountNormalized;
        } else {
            state.totalBorrowsNormalized += balance.amountNormalized;
        }

        int128 cumulativeMultiplierX18;
        if (balance.amountNormalized > 0) {
            cumulativeMultiplierX18 = state.cumulativeDepositsMultiplierX18;
        } else {
            cumulativeMultiplierX18 = state.cumulativeBorrowsMultiplierX18;
        }

        int128 newAmount = balance.amountNormalized.mul(
            cumulativeMultiplierX18
        ) + balanceDelta;

        if (newAmount > 0) {
            cumulativeMultiplierX18 = state.cumulativeDepositsMultiplierX18;
        } else {
            cumulativeMultiplierX18 = state.cumulativeBorrowsMultiplierX18;
        }

        balance.amountNormalized = newAmount.div(cumulativeMultiplierX18);

        if (balance.amountNormalized > 0) {
            state.totalDepositsNormalized += balance.amountNormalized;
        } else {
            state.totalBorrowsNormalized -= balance.amountNormalized;
        }
    }

    function _updateState(
        uint32 productId,
        State memory state,
        uint128 dt
    ) internal {
        int128 borrowRateMultiplierX18;
        int128 totalDeposits = state.totalDepositsNormalized.mul(
            state.cumulativeDepositsMultiplierX18
        );
        int128 totalBorrows = state.totalBorrowsNormalized.mul(
            state.cumulativeBorrowsMultiplierX18
        );
        int128 utilizationRatioX18 = totalBorrows.div(totalDeposits);
        int128 minDepositRateX18;
        {
            Config memory config = configs[productId];

            // annualized borrower rate
            int128 borrowerRateX18 = config.interestFloorX18;
            if (utilizationRatioX18 == 0) {
                // setting borrowerRateX18 to 0 here has the property that
                // adding a product at the beginning of time and not using it until time T
                // results in the same state as adding the product at time T
                borrowerRateX18 = 0;
            } else if (utilizationRatioX18 < config.interestInflectionUtilX18) {
                borrowerRateX18 += config
                    .interestSmallCapX18
                    .mul(utilizationRatioX18)
                    .div(config.interestInflectionUtilX18);
            } else {
                borrowerRateX18 +=
                    config.interestSmallCapX18 +
                    config.interestLargeCapX18.mul(
                        (
                            (utilizationRatioX18 -
                                config.interestInflectionUtilX18).div(
                                    ONE - config.interestInflectionUtilX18
                                )
                        )
                    );
            }

            // convert to per second
            borrowerRateX18 = borrowerRateX18.div(
                MathSD21x18.fromInt(31536000)
            );
            borrowRateMultiplierX18 = (ONE + borrowerRateX18).pow(int128(dt));
            minDepositRateX18 = config.minDepositRateX18;
        }

        // if we don't take fees into account, the liquidity, which is
        // (deposits - borrows) should remain the same after updating state.

        // For simplicity, we use `tb`, `cbm`, `td`, and `cdm` for
        // `totalBorrowsNormalized`, `cumulativeBorrowsMultiplier`,
        // `totalDepositsNormalized`, and `cumulativeDepositsMultiplier`

        // before the updating, the liquidity is (td * cdm - tb * cbm)
        // after the updating, the liquidity is
        // (td * cdm * depositRateMultiplier - tb * cbm * borrowRateMultiplier)
        // so we can get
        // depositRateMultiplier = utilization * (borrowRateMultiplier - 1) + 1

        int128 totalDepositRateX18 = utilizationRatioX18.mul(
            borrowRateMultiplierX18 - ONE
        );

        // deduct protocol fees
        int128 realizedDepositRateX18 = totalDepositRateX18.mul(
            ONE - INTEREST_FEE_FRACTION
        );

        // pass fees balance change
        int128 feesAmt = totalDeposits.mul(
            totalDepositRateX18 - realizedDepositRateX18
        );

        state.cumulativeBorrowsMultiplierX18 = state
            .cumulativeBorrowsMultiplierX18
            .mul(borrowRateMultiplierX18);

        int128 depositRateMultiplierX18 = ONE + realizedDepositRateX18;

        state.cumulativeDepositsMultiplierX18 = state
            .cumulativeDepositsMultiplierX18
            .mul(depositRateMultiplierX18);

        if (feesAmt != 0) {
            BalanceNormalized memory feesAccBalance = balances[productId][
                FEES_ACCOUNT
            ];
            _updateBalanceNormalized(state, feesAccBalance, feesAmt);
            _setBalanceAndUpdateBitmap(productId, FEES_ACCOUNT, feesAccBalance);
        }

        // apply the min deposit rate
        if (minDepositRateX18 != 0) {
            int128 minDepositRatePerSecondX18 = minDepositRateX18.div(
                MathSD21x18.fromInt(31536000)
            );
            int128 minDepositRateMultiplierX18 = (ONE +
                minDepositRatePerSecondX18).pow(int128(dt));

            state.cumulativeBorrowsMultiplierX18 = state
                .cumulativeBorrowsMultiplierX18
                .mul(minDepositRateMultiplierX18);

            state.cumulativeDepositsMultiplierX18 = state
                .cumulativeDepositsMultiplierX18
                .mul(minDepositRateMultiplierX18);

            depositRateMultiplierX18 = depositRateMultiplierX18.mul(
                minDepositRateMultiplierX18
            );
            borrowRateMultiplierX18 = borrowRateMultiplierX18.mul(
                minDepositRateMultiplierX18
            );
        }

        emit InterestPayment(
            productId,
            dt,
            depositRateMultiplierX18,
            borrowRateMultiplierX18,
            feesAmt
        );
    }

    function balanceNormalizedToBalance(
        State memory state,
        BalanceNormalized memory balance
    ) internal pure returns (Balance memory) {
        int128 cumulativeMultiplierX18;
        if (balance.amountNormalized > 0) {
            cumulativeMultiplierX18 = state.cumulativeDepositsMultiplierX18;
        } else {
            cumulativeMultiplierX18 = state.cumulativeBorrowsMultiplierX18;
        }

        return Balance(balance.amountNormalized.mul(cumulativeMultiplierX18));
    }

    function _setState(uint32 productId, State memory state) internal {
        states[productId] = state;
        _productUpdate(productId);
    }

    function _setBalanceAndUpdateBitmap(
        uint32 productId,
        bytes32 subaccount,
        BalanceNormalized memory balance
    ) internal {
        balances[productId][subaccount] = balance;
        bool hasBalance = balance.amountNormalized != 0;
        _setProductBit(subaccount, productId, hasBalance);
        _balanceUpdate(productId, subaccount);
    }

    function _balanceUpdate(uint32 productId, bytes32 subaccount)
        internal
        virtual
        override
    {
        (State memory state, Balance memory balance) = getStateAndBalance(
            productId,
            subaccount
        );
        int128 cumulativeMultiplierX18;
        if (balance.amount > 0) {
            cumulativeMultiplierX18 = state.cumulativeDepositsMultiplierX18;
        } else {
            cumulativeMultiplierX18 = state.cumulativeBorrowsMultiplierX18;
        }
        emit SpotBalance(
            subaccount,
            productId,
            balance.amount,
            cumulativeMultiplierX18
        );
    }

    // TODO: maybe combine the next two functions
    // probably also need some protection where quote state must
    // be fetched through getQuoteState
    function getStateAndBalance(uint32 productId, bytes32 subaccount)
        public
        view
        returns (State memory, Balance memory)
    {
        State memory state = states[productId];
        BalanceNormalized memory balance = balances[productId][subaccount];
        return (state, balanceNormalizedToBalance(state, balance));
    }

    function getBalance(uint32 productId, bytes32 subaccount)
        public
        view
        returns (Balance memory)
    {
        State memory state = states[productId];
        BalanceNormalized memory balance = balances[productId][subaccount];
        return balanceNormalizedToBalance(state, balance);
    }

    function _getBalance(uint32 productId, bytes32 subaccount)
        internal
        view
        override
        returns (int128, int128)
    {
        return (getBalance(productId, subaccount).amount, 0);
    }

    function updateStates(uint128 dt) external onlyEndpoint {
        State memory quoteState;
        require(dt < 7 * SECONDS_PER_DAY, ERR_INVALID_TIME);
        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            if (productId == NLP_PRODUCT_ID) {
                continue;
            }
            State memory state = states[productId];
            if (productId == QUOTE_PRODUCT_ID) {
                quoteState = state;
            }
            if (state.totalDepositsNormalized == 0) {
                continue;
            }
            _updateState(productId, state, dt);
            _setState(productId, state);
        }
    }

    function tryUnlockNlpBalance(bytes32 subaccount)
        public
        returns (Balance memory)
    {
        NlpLockedBalanceQueue storage queue = nlpLockedBalanceQueues[
            subaccount
        ];
        while (
            queue.unlockedUpTo < queue.balanceCount &&
            queue.balances[queue.unlockedUpTo].unlockedAt <= getOracleTime()
        ) {
            // we can unlock this balance
            queue.unlockedBalanceSum.amount += queue
                .balances[queue.unlockedUpTo]
                .balance
                .amount;
            delete queue.balances[queue.unlockedUpTo];
            queue.unlockedUpTo++;
        }

        return queue.unlockedBalanceSum;
    }
}
