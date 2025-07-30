// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./common/Constants.sol";
import "./common/Errors.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./BaseEngine.sol";
import "./PerpEngineState.sol";

contract PerpEngine is PerpEngineState {
    using MathSD21x18 for int128;

    function initialize(
        address _clearinghouse,
        address _offchainExchange,
        address,
        address _endpoint,
        address _admin
    ) external {
        _initialize(_clearinghouse, _offchainExchange, _endpoint, _admin);
    }

    function getEngineType() external pure returns (EngineType) {
        return EngineType.PERP;
    }

    /**
     * Actions
     */

    /// @notice adds a new product with default parameters
    function addOrUpdateProduct(
        uint32 productId,
        int128 sizeIncrement,
        int128 minSize,
        RiskHelper.RiskStore calldata riskStore
    ) public onlyOwner {
        bool isNewProduct = _addOrUpdateProduct(
            productId,
            QUOTE_PRODUCT_ID,
            sizeIncrement,
            minSize,
            riskStore
        );

        if (isNewProduct) {
            _setState(
                productId,
                State({
                    cumulativeFundingLongX18: 0,
                    cumulativeFundingShortX18: 0,
                    availableSettle: 0,
                    openInterest: 0
                })
            );
        }
    }

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta,
        int128 vQuoteDelta
    ) external {
        // Only a market book can apply deltas
        _assertInternal();
        State memory state = states[productId];
        Balance memory balance = balances[productId][subaccount];

        _updateBalance(state, balance, amountDelta, vQuoteDelta);

        _setBalanceAndUpdateBitmap(productId, subaccount, balance);
        _setState(productId, state);
    }

    function settlePnl(bytes32 subaccount, uint256 productIds)
        external
        returns (int128)
    {
        _assertInternal();
        int128 totalSettled = 0;

        while (productIds != 0) {
            uint32 productId = uint32(productIds & ((1 << 32) - 1));
            // otherwise it means the product is a spot.
            if (productId % 2 == 0) {
                (
                    int128 canSettle,
                    State memory state,
                    Balance memory balance
                ) = getSettlementState(productId, subaccount);

                state.availableSettle -= canSettle;
                balance.vQuoteBalance -= canSettle;

                totalSettled += canSettle;

                _setState(productId, state);
                _setBalanceAndUpdateBitmap(productId, subaccount, balance);
            }
            productIds >>= 32;
        }
        return totalSettled;
    }

    function calculatePositionPnl(Balance memory balance, uint32 productId)
        internal
        returns (int128 positionPnl)
    {
        int128 priceX18 = _risk(productId).priceX18;
        positionPnl = priceX18.mul(balance.amount) + balance.vQuoteBalance;
        emit PriceQuery(productId);
    }

    function getPositionPnl(uint32 productId, bytes32 subaccount)
        external
        returns (int128)
    {
        (, Balance memory balance) = getStateAndBalance(productId, subaccount);

        return calculatePositionPnl(balance, productId);
    }

    function getSettlementState(uint32 productId, bytes32 subaccount)
        public
        returns (
            int128 availableSettle,
            State memory state,
            Balance memory balance
        )
    {
        (state, balance) = getStateAndBalance(productId, subaccount);

        availableSettle = MathHelper.min(
            calculatePositionPnl(balance, productId),
            state.availableSettle
        );
    }

    function socializeSubaccount(bytes32 subaccount, int128 insurance)
        external
        returns (int128)
    {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        uint32[] memory _productIds = getProductIds();
        for (uint128 i = 0; i < _productIds.length; ++i) {
            uint32 productId = _productIds[i];
            (State memory state, Balance memory balance) = getStateAndBalance(
                productId,
                subaccount
            );
            if (balance.vQuoteBalance < 0) {
                int128 insuranceCover = MathHelper.min(
                    insurance,
                    -balance.vQuoteBalance
                );
                insurance -= insuranceCover;
                balance.vQuoteBalance += insuranceCover;
                state.availableSettle += insuranceCover;

                // actually socialize if still not enough
                if (balance.vQuoteBalance < 0) {
                    // socialize across all other participants
                    int128 fundingPerShare = -balance.vQuoteBalance.div(
                        state.openInterest
                    ) / 2;
                    state.cumulativeFundingLongX18 += fundingPerShare;
                    state.cumulativeFundingShortX18 -= fundingPerShare;
                    balance.vQuoteBalance = 0;
                }
                _setState(productId, state);
                _setBalanceAndUpdateBitmap(productId, subaccount, balance);
            }
        }
        return insurance;
    }

    function manualAssert(int128[] calldata openInterests) external view {
        for (uint128 i = 0; i < openInterests.length; ++i) {
            uint32 productId = productIds[i];
            require(
                states[productId].openInterest == openInterests[i],
                ERR_DSYNC
            );
        }
    }
}
