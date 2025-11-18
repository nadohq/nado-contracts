// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IProductEngine.sol";
import "../../libraries/RiskHelper.sol";

interface IPerpEngine is IProductEngine {
    event FundingPayment(
        uint32 productId,
        uint128 dt,
        int128 openInterest,
        int128 payment
    );

    struct State {
        int128 cumulativeFundingLongX18;
        int128 cumulativeFundingShortX18;
        int128 availableSettle;
        int128 openInterest;
    }

    struct Balance {
        int128 amount;
        int128 vQuoteBalance;
        int128 lastCumulativeFundingX18;
    }

    function getStateAndBalance(uint32 productId, bytes32 subaccount)
        external
        view
        returns (State memory, Balance memory);

    function getBalance(uint32 productId, bytes32 subaccount)
        external
        view
        returns (Balance memory);

    function settlePnl(bytes32 subaccount, uint256 productIds)
        external
        returns (int128);

    function getSettlementState(uint32 productId, bytes32 subaccount)
        external
        returns (
            int128 availableSettle,
            State memory state,
            Balance memory balance
        );

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta,
        int128 vQuoteDelta
    ) external;

    function updateStates(uint128 dt, int128[] calldata avgPriceDiffs) external;

    function manualAssert(bytes[] calldata _states) external view;

    function getPositionPnl(uint32 productId, bytes32 subaccount)
        external
        returns (int128);

    function socializeSubaccount(bytes32 subaccount, int128 insurance)
        external
        returns (int128);
}
