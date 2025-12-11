// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/engine/IProductEngine.sol";

abstract contract ClearinghouseStorage {
    using MathSD21x18 for int128;

    // Each clearinghouse has a quote ERC20
    address internal quote;
    address internal clearinghouse;
    address internal clearinghouseLiq;

    // product ID -> engine address
    mapping(uint32 => IProductEngine) internal productToEngine;
    // Type to engine address
    mapping(IProductEngine.EngineType => IProductEngine) internal engineByType;
    // Supported engine types
    IProductEngine.EngineType[] internal supportedEngines;

    int128 internal insurance;

    int128 internal lastLiquidationFees;

    uint256 internal spreads;

    address internal withdrawPool;

    function getLiqPriceX18(uint32 productId, int128 amount)
        internal
        returns (int128, int128)
    {
        RiskHelper.Risk memory risk = IProductEngine(productToEngine[productId])
            .getRisk(productId);
        int128 penaltyX18 = (RiskHelper._getWeightX18(
            risk,
            amount,
            IProductEngine.HealthType.MAINTENANCE
        ) - ONE) / 5;
        if (penaltyX18.abs() < MIN_NON_SPREAD_LIQ_PENALTY_X18) {
            if (penaltyX18 < 0) {
                penaltyX18 = -MIN_NON_SPREAD_LIQ_PENALTY_X18;
            } else {
                penaltyX18 = MIN_NON_SPREAD_LIQ_PENALTY_X18;
            }
        }
        return (risk.priceX18.mul(ONE + penaltyX18), risk.priceX18);
    }

    function getSpreadLiqPriceX18(
        uint32 spotId,
        uint32 perpId,
        int128 amount
    )
        internal
        returns (
            int128,
            int128,
            int128
        )
    {
        RiskHelper.Risk memory spotRisk = IProductEngine(
            productToEngine[spotId]
        ).getRisk(spotId);
        RiskHelper.Risk memory perpRisk = IProductEngine(
            productToEngine[perpId]
        ).getRisk(perpId);

        int128 penaltyX18;
        if (amount >= 0) {
            penaltyX18 =
                (ONE -
                    RiskHelper._getWeightX18(
                        perpRisk,
                        amount,
                        IProductEngine.HealthType.MAINTENANCE
                    )) /
                10;
        } else {
            penaltyX18 =
                (RiskHelper._getWeightX18(
                    spotRisk,
                    amount,
                    IProductEngine.HealthType.MAINTENANCE
                ) - ONE) /
                10;
        }
        if (penaltyX18.abs() < MIN_SPREAD_LIQ_PENALTY_X18) {
            if (penaltyX18 < 0) {
                penaltyX18 = -MIN_SPREAD_LIQ_PENALTY_X18;
            } else {
                penaltyX18 = MIN_SPREAD_LIQ_PENALTY_X18;
            }
        }

        if (amount > 0) {
            return (
                spotRisk.priceX18.mul(ONE - penaltyX18),
                spotRisk.priceX18,
                perpRisk.priceX18
            );
        } else {
            return (
                spotRisk.priceX18.mul(ONE + penaltyX18),
                spotRisk.priceX18,
                perpRisk.priceX18
            );
        }
    }
}
