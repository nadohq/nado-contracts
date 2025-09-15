// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./common/Constants.sol";
import "./interfaces/clearinghouse/IClearinghouseLiq.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IOffchainExchange.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./EndpointGated.sol";
import "./interfaces/IEndpoint.sol";
import "./ClearinghouseStorage.sol";

contract ClearinghouseLiq is
    EndpointGated,
    ClearinghouseStorage,
    IClearinghouseLiq
{
    using MathSD21x18 for int128;

    function getHealthFromClearinghouse(
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) internal returns (int128 health) {
        return IClearinghouse(clearinghouse).getHealth(subaccount, healthType);
    }

    function isUnderInitial(bytes32 subaccount) public returns (bool) {
        // Weighted initial health with limit orders < 0
        return
            getHealthFromClearinghouse(
                subaccount,
                IProductEngine.HealthType.INITIAL
            ) < 0;
    }

    function isAboveInitial(bytes32 subaccount) public returns (bool) {
        // Weighted initial health with limit orders < 0
        return
            getHealthFromClearinghouse(
                subaccount,
                IProductEngine.HealthType.INITIAL
            ) > 0;
    }

    function isUnderMaintenance(bytes32 subaccount) internal returns (bool) {
        // Weighted maintenance health < 0
        return
            getHealthFromClearinghouse(
                subaccount,
                IProductEngine.HealthType.MAINTENANCE
            ) < 0;
    }

    // perform all checks related to asserting liquidation amounts
    // 1. check that the liquidation reduces position without going across 0
    // 2. if perp or basis: check that it is a multiple of the size increment
    // 3. if spot or basis (liabilty): check that the liquidatee + insurance
    //    has enough quote funds to actually pay back the liability
    function _assertLiquidationAmount(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        require(txn.amount != 0, ERR_NOT_LIQUIDATABLE_AMT);
        uint32 spotId = 0;
        uint32 perpId = 0;
        for (uint256 mask = spreads; mask != 0; mask >>= 16) {
            uint32 low = uint32(mask & 0xFF);
            uint32 high = uint32((mask & 0xFF00) >> 8);
            bool hit = false;
            if (txn.isEncodedSpread) {
                hit = (txn.productId == ((high << 16) | low));
            } else {
                hit = (txn.productId == low || txn.productId == high);
            }
            if (hit) {
                spotId = low;
                perpId = high;
                break;
            }
        }
        address engine = txn.isEncodedSpread
            ? address(0)
            : address(productToEngine[txn.productId]);
        require(
            txn.isEncodedSpread || engine != address(0),
            ERR_INVALID_LIQUIDATION_PARAMS
        );
        if (spotId == 0 || perpId == 0) {
            // the given product is outside spreads
            require(!txn.isEncodedSpread, ERR_INVALID_LIQUIDATION_PARAMS);
            if (engine == address(spotEngine)) {
                spotId = txn.productId;
            } else {
                perpId = txn.productId;
            }
        }

        int128 spotAmount;
        int128 perpAmount;
        int128 basisAmount;
        int128 perpSizeIncrement;
        if (spotId != 0) {
            spotAmount = spotEngine.getBalance(spotId, txn.liquidatee).amount;
        }
        if (perpId != 0) {
            perpAmount = perpEngine.getBalance(perpId, txn.liquidatee).amount;
            perpSizeIncrement = IOffchainExchange(
                IEndpoint(getEndpoint()).getOffchainExchange()
            ).getSizeIncrement(perpId);
        }
        if (spotId != 0 && perpId != 0) {
            // the given product is inside spreads, we need to deduct basis amount
            if ((spotAmount > 0) != (perpAmount > 0)) {
                if (spotAmount > 0) {
                    basisAmount = MathHelper.min(spotAmount, -perpAmount);
                } else {
                    basisAmount = MathHelper.max(spotAmount, -perpAmount);
                }
            }
            basisAmount -= basisAmount % perpSizeIncrement;
            spotAmount -= basisAmount;
            perpAmount += basisAmount;
        }

        int128 maxLiquidatable;
        if (txn.isEncodedSpread) {
            require(
                txn.amount % perpSizeIncrement == 0,
                ERR_INVALID_LIQUIDATION_AMOUNT
            );
            require(
                spotEngine.getRisk(spotId).longWeightInitialX18 != 0,
                ERR_INVALID_PRODUCT
            );
            if (basisAmount >= 0) {
                maxLiquidatable = basisAmount;
            } else {
                (int128 liquidationPrice, , ) = getSpreadLiqPriceX18(
                    spotId,
                    perpId,
                    basisAmount
                );
                ISpotEngine.Balance memory quoteBalance = spotEngine.getBalance(
                    QUOTE_PRODUCT_ID,
                    txn.liquidatee
                );
                int128 maxBuy = (quoteBalance.amount + insurance).div(
                    liquidationPrice
                );
                maxBuy = MathHelper.max(maxBuy + 1, 0);
                maxLiquidatable = MathHelper.max(-maxBuy, basisAmount);
            }
        } else if (engine == address(spotEngine)) {
            require(
                spotEngine.getRisk(spotId).longWeightInitialX18 != 0,
                ERR_INVALID_PRODUCT
            );
            if (spotAmount >= 0) {
                maxLiquidatable = spotAmount;
            } else {
                (int128 liquidationPrice, ) = getLiqPriceX18(
                    txn.productId,
                    txn.amount
                );
                ISpotEngine.Balance memory quoteBalance = spotEngine.getBalance(
                    QUOTE_PRODUCT_ID,
                    txn.liquidatee
                );
                int128 maxBuy = (quoteBalance.amount + insurance).div(
                    liquidationPrice
                );
                maxBuy = MathHelper.max(maxBuy + 1, 0);
                maxLiquidatable = MathHelper.max(spotAmount, -maxBuy);
            }
        } else {
            require(
                txn.amount % perpSizeIncrement == 0,
                ERR_INVALID_LIQUIDATION_AMOUNT
            );
            maxLiquidatable = perpAmount;
        }

        if (txn.amount >= 0) {
            require(maxLiquidatable >= txn.amount, ERR_NOT_LIQUIDATABLE_AMT);
        } else {
            require(maxLiquidatable <= txn.amount, ERR_NOT_LIQUIDATABLE_AMT);
        }
    }

    function _assertCanLiquidateLiability(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        // ensure:
        // 1. no positive spot balances
        // 2. no perp balances outside spread
        uint256 perpsInSpread = 0;
        for (uint256 mask = spreads; mask != 0; mask >>= 16) {
            uint32 spotId = uint32(mask & 0xFF);
            uint32 perpId = uint32(mask & 0xFF00) >> 8;
            ISpotEngine.Balance memory spotBalance = spotEngine.getBalance(
                spotId,
                txn.liquidatee
            );
            require(spotBalance.amount <= 0, ERR_NOT_LIQUIDATABLE_LIABILITIES);
            IPerpEngine.Balance memory perpBalance = perpEngine.getBalance(
                perpId,
                txn.liquidatee
            );
            // either perp amount is 0 or it is positive and it is part of a spread
            if (perpBalance.amount >= 0) {
                if (perpBalance.amount > 0) {
                    require(
                        spotBalance.amount < 0 &&
                            spotBalance.amount.abs() >=
                            perpBalance.amount.abs(),
                        ERR_NOT_LIQUIDATABLE_LIABILITIES
                    );
                }
                perpsInSpread |= 1 << perpId;
            } else {
                revert(ERR_NOT_LIQUIDATABLE_LIABILITIES);
            }
        }
        uint32[] memory spotIds = spotEngine.getProductIds();
        uint32[] memory perpIds = perpEngine.getProductIds();
        require(spotIds[0] == QUOTE_PRODUCT_ID);
        for (uint32 i = 1; i < spotIds.length; ++i) {
            uint32 spotId = spotIds[i];
            if (spotEngine.getRisk(spotId).longWeightInitialX18 == 0) {
                continue;
            }
            ISpotEngine.Balance memory balance = spotEngine.getBalance(
                spotId,
                txn.liquidatee
            );
            require(balance.amount <= 0, ERR_NOT_LIQUIDATABLE_LIABILITIES);
        }
        for (uint32 i = 0; i < perpIds.length; ++i) {
            uint32 perpId = perpIds[i];
            if ((perpsInSpread & (1 << perpId)) != 0) {
                continue;
            }
            IPerpEngine.Balance memory balance = perpEngine.getBalance(
                perpId,
                txn.liquidatee
            );
            require(balance.amount == 0, ERR_NOT_LIQUIDATABLE_LIABILITIES);
        }
    }

    function _settlePnlAgainstLiquidator(
        IEndpoint.LiquidateSubaccount calldata txn,
        uint32 perpId,
        int128 pnl,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        perpEngine.updateBalance(perpId, txn.liquidatee, 0, -pnl);
        perpEngine.updateBalance(perpId, txn.sender, 0, pnl);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.liquidatee, pnl);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.sender, -pnl);
    }

    struct FinalizeVars {
        uint32[] spotIds;
        uint32[] perpIds;
        int128 insurance;
        bool canLiquidateMore;
    }

    function _finalizeSubaccount(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal returns (bool) {
        if (txn.productId != type(uint32).max) {
            return false;
        }
        // check whether the subaccount can be finalized:
        // - all perps positions have closed
        // - all spread positions have closed
        // - all spot assets have closed
        // - all positive pnls have been settled

        FinalizeVars memory v;

        v.spotIds = spotEngine.getProductIds();
        v.perpIds = perpEngine.getProductIds();

        require(v.spotIds[0] == QUOTE_PRODUCT_ID);

        // all spot assets (except USDC) must be closed out
        for (uint32 i = 1; i < v.spotIds.length; ++i) {
            uint32 spotId = v.spotIds[i];
            if (spotEngine.getRisk(spotId).longWeightInitialX18 == 0) {
                continue;
            }
            ISpotEngine.Balance memory balance = spotEngine.getBalance(
                spotId,
                txn.liquidatee
            );
            require(balance.amount <= 0, ERR_NOT_FINALIZABLE_SUBACCOUNT);
        }

        for (uint32 i = 0; i < v.perpIds.length; ++i) {
            uint32 perpId = v.perpIds[i];
            IPerpEngine.Balance memory balance = perpEngine.getBalance(
                perpId,
                txn.liquidatee
            );
            require(balance.amount == 0, ERR_NOT_FINALIZABLE_SUBACCOUNT);
        }

        ISpotEngine.Balance memory quoteBalance = spotEngine.getBalance(
            QUOTE_PRODUCT_ID,
            txn.liquidatee
        );

        v.insurance = insurance;
        v.insurance -= lastLiquidationFees;
        v.canLiquidateMore = (quoteBalance.amount + v.insurance) > 0;

        // settle all negative pnl until quote balance becomes 0
        for (uint32 i = 0; i < v.perpIds.length; ++i) {
            uint32 perpId = v.perpIds[i];
            IPerpEngine.Balance memory balance = perpEngine.getBalance(
                perpId,
                txn.liquidatee
            );
            if (balance.vQuoteBalance > 0) {
                _settlePnlAgainstLiquidator(
                    txn,
                    perpId,
                    balance.vQuoteBalance,
                    spotEngine,
                    perpEngine
                );
            }
        }

        for (uint32 i = 0; i < v.perpIds.length; ++i) {
            uint32 perpId = v.perpIds[i];
            IPerpEngine.Balance memory balance = perpEngine.getBalance(
                perpId,
                txn.liquidatee
            );
            if (balance.vQuoteBalance < 0 && quoteBalance.amount > 0) {
                int128 canSettle = MathHelper.max(
                    balance.vQuoteBalance,
                    -quoteBalance.amount
                );
                _settlePnlAgainstLiquidator(
                    txn,
                    perpId,
                    canSettle,
                    spotEngine,
                    perpEngine
                );
                quoteBalance.amount += canSettle;
            }
        }

        if (v.canLiquidateMore) {
            for (uint32 i = 1; i < v.spotIds.length; ++i) {
                uint32 spotId = v.spotIds[i];
                ISpotEngine.Balance memory balance = spotEngine.getBalance(
                    spotId,
                    txn.liquidatee
                );
                if (spotEngine.getRisk(spotId).longWeightInitialX18 == 0) {
                    continue;
                }
                require(balance.amount == 0, ERR_NOT_FINALIZABLE_SUBACCOUNT);
            }
        }

        v.insurance = perpEngine.socializeSubaccount(
            txn.liquidatee,
            v.insurance
        );

        // we can assure that quoteBalance must be non positive, because if quoteBalance.amount > 0,
        // there must be 1) no negative pnl in perps, and 2) no liabilities in spot after above actions.
        // however, in this case the liquidatee must be healthy and cannot pass the health check at
        // the beginning.
        int128 insuranceCover = MathHelper.min(
            v.insurance,
            -quoteBalance.amount
        );
        if (insuranceCover > 0) {
            v.insurance -= insuranceCover;
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.liquidatee,
                insuranceCover
            );
        }
        if (v.insurance <= 0) {
            spotEngine.socializeSubaccount(txn.liquidatee);
        }
        v.insurance += lastLiquidationFees;
        insurance = v.insurance;
        return true;
    }

    function _settlePositivePerpPnl(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        uint32[] memory productIds = perpEngine.getProductIds();
        for (uint32 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            int128 positionPnl = perpEngine.getPositionPnl(
                productId,
                txn.liquidatee
            );
            if (positionPnl > 0) {
                _settlePnlAgainstLiquidator(
                    txn,
                    productId,
                    positionPnl,
                    spotEngine,
                    perpEngine
                );
            }
        }
    }

    struct LiquidationVars {
        int128 liquidationPriceX18;
        int128 liquidationPayment;
        int128 oraclePriceX18;
        int128 oraclePriceX18Perp;
        int128 liquidationFees;
    }

    function _handleLiquidationPayment(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        LiquidationVars memory v;
        address engine = txn.isEncodedSpread
            ? address(0)
            : address(productToEngine[txn.productId]);

        if (txn.isEncodedSpread) {
            uint32 spotId = txn.productId & 0xFFFF;
            uint32 perpId = txn.productId >> 16;
            (
                v.liquidationPriceX18,
                v.oraclePriceX18,
                v.oraclePriceX18Perp
            ) = getSpreadLiqPriceX18(spotId, perpId, txn.amount);

            v.liquidationPayment = v.liquidationPriceX18.mul(txn.amount);

            v.liquidationFees = (v.oraclePriceX18 - v.liquidationPriceX18)
                .mul(LIQUIDATION_FEE_FRACTION)
                .mul(txn.amount);

            // transfer spot at the calculated liquidation price
            spotEngine.updateBalance(spotId, txn.liquidatee, -txn.amount);
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.liquidatee,
                v.liquidationPayment
            );
            spotEngine.updateBalance(spotId, txn.sender, txn.amount);
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.sender,
                -v.liquidationPayment - v.liquidationFees
            );

            v.liquidationPayment = v.oraclePriceX18Perp.mul(txn.amount);
            perpEngine.updateBalance(
                perpId,
                txn.liquidatee,
                txn.amount,
                -v.liquidationPayment
            );

            perpEngine.updateBalance(
                perpId,
                txn.sender,
                -txn.amount,
                v.liquidationPayment
            );

            if (txn.amount < 0) {
                insurance = spotEngine.updateQuoteFromInsurance(
                    txn.liquidatee,
                    insurance
                );
            }
        } else if (engine == address(spotEngine)) {
            (v.liquidationPriceX18, v.oraclePriceX18) = getLiqPriceX18(
                txn.productId,
                txn.amount
            );

            v.liquidationPayment = v.liquidationPriceX18.mul(txn.amount);
            v.liquidationFees = (v.oraclePriceX18 - v.liquidationPriceX18)
                .mul(LIQUIDATION_FEE_FRACTION)
                .mul(txn.amount);

            spotEngine.updateBalance(
                txn.productId,
                txn.liquidatee,
                -txn.amount
            );

            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.liquidatee,
                v.liquidationPayment
            );

            spotEngine.updateBalance(txn.productId, txn.sender, txn.amount);

            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.sender,
                -v.liquidationPayment - v.liquidationFees
            );

            if (txn.amount < 0) {
                insurance = spotEngine.updateQuoteFromInsurance(
                    txn.liquidatee,
                    insurance
                );
            }
        } else {
            (v.liquidationPriceX18, v.oraclePriceX18) = getLiqPriceX18(
                txn.productId,
                txn.amount
            );
            v.liquidationPayment = v.liquidationPriceX18.mul(txn.amount);
            v.liquidationFees = (v.oraclePriceX18 - v.liquidationPriceX18)
                .mul(LIQUIDATION_FEE_FRACTION)
                .mul(txn.amount);
            perpEngine.updateBalance(
                txn.productId,
                txn.liquidatee,
                -txn.amount,
                v.liquidationPayment
            );
            perpEngine.updateBalance(
                txn.productId,
                txn.sender,
                txn.amount,
                -v.liquidationPayment
            );
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.sender,
                -v.liquidationFees
            );
        }

        // it's ok to let initial health become 0
        require(!isAboveInitial(txn.liquidatee), ERR_LIQUIDATED_TOO_MUCH);
        require(
            txn.sender == N_ACCOUNT || !isUnderInitial(txn.sender),
            ERR_SUBACCT_HEALTH
        );

        insurance += v.liquidationFees;

        // if insurance is not enough for making a subaccount healthy, we should
        // use all insurance to buy its liabilities, then socialize the subaccount
        // however, after the first step, insurance funds will be refilled a little bit
        // which blocks the second step, so we keep the fees of the last liquidation and
        // do not use this part in socialization to unblock it.
        lastLiquidationFees = v.liquidationFees;

        emit Liquidation(
            txn.sender,
            txn.liquidatee,
            txn.productId,
            txn.isEncodedSpread,
            txn.amount,
            v.liquidationPayment
        );
    }

    function liquidateSubaccountImpl(IEndpoint.LiquidateSubaccount calldata txn)
        external
    {
        require(!RiskHelper.isIsolatedSubaccount(txn.sender), ERR_UNAUTHORIZED);
        require(txn.sender != txn.liquidatee, ERR_UNAUTHORIZED);
        require(isUnderMaintenance(txn.liquidatee), ERR_NOT_LIQUIDATABLE);
        require(
            txn.liquidatee != X_ACCOUNT && txn.liquidatee != N_ACCOUNT,
            ERR_NOT_LIQUIDATABLE
        );
        require(
            txn.productId != QUOTE_PRODUCT_ID,
            ERR_INVALID_LIQUIDATION_PARAMS
        );

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        if (_finalizeSubaccount(txn, spotEngine, perpEngine)) {
            if (RiskHelper.isIsolatedSubaccount(txn.liquidatee)) {
                IOffchainExchange(
                    IEndpoint(getEndpoint()).getOffchainExchange()
                ).tryCloseIsolatedSubaccount(txn.liquidatee);
            }
            return;
        }

        if (
            (txn.amount < 0) &&
            (txn.isEncodedSpread ||
                address(productToEngine[txn.productId]) == address(spotEngine))
        ) {
            // when it's spread or spot liquidation, we need to make sure the liquidatee has
            // enough quote to buyback the liquidated amount.
            _assertCanLiquidateLiability(txn, spotEngine, perpEngine);
            _settlePositivePerpPnl(txn, spotEngine, perpEngine);
        }

        _assertLiquidationAmount(txn, spotEngine, perpEngine);

        // beyond this point, we can be sure that we can liquidate the entire
        // liquidation amount knowing that the insurance fund will remain solvent
        // subsequently we can just blast the remainder of the liquidation and
        // cover the quote balance from the insurance fund at the end
        _handleLiquidationPayment(txn, spotEngine, perpEngine);
    }
}
