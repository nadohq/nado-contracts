// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../clearinghouse/IClearinghouse.sol";
import "../../libraries/RiskHelper.sol";

interface IProductEngine {
    event AddProduct(uint32 productId);
    event PriceQuery(uint32 productId);

    enum EngineType {
        SPOT,
        PERP
    }

    enum HealthType {
        INITIAL,
        MAINTENANCE,
        PNL
    }

    struct ProductDelta {
        uint32 productId;
        bytes32 subaccount;
        int128 amountDelta;
        int128 vQuoteDelta;
    }

    struct CoreRisk {
        int128 amount;
        int128 price;
        int128 longWeight;
    }

    function initialize(
        address _clearinghouse,
        address _offchainExchange,
        address _quote,
        address _endpoint,
        address _admin
    ) external;

    function getHealthContribution(
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) external returns (int128);

    function getCoreRisk(
        bytes32 subaccount,
        uint32 productId,
        IProductEngine.HealthType healthType
    ) external returns (IProductEngine.CoreRisk memory);

    function updateProduct(bytes calldata txn) external;

    function getClearinghouse() external view returns (address);

    function getProductIds() external view returns (uint32[] memory);

    function getRisk(uint32 productId)
        external
        returns (RiskHelper.Risk memory);

    function getEngineType() external pure returns (IProductEngine.EngineType);

    function updatePrice(uint32 productId, int128 priceX18) external;
}
