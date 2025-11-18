// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/IOffchainExchange.sol";
import "./interfaces/IEndpoint.sol";
import "./EndpointGated.sol";

abstract contract BaseEngine is IProductEngine, EndpointGated {
    using MathSD21x18 for int128;

    IClearinghouse internal _clearinghouse;
    uint32[] internal productIds;

    mapping(address => bool) internal canApplyDeltas;

    // subaccount -> bitmapIndex -> bitmapChunk
    mapping(bytes32 => mapping(uint32 => uint256)) internal nonZeroBalances;

    bytes32 internal constant RISK_STORAGE = keccak256("nado.protocol.risk");

    event BalanceUpdate(uint32 productId, bytes32 subaccount);
    event ProductUpdate(uint32 productId);

    // solhint-disable-next-line no-empty-blocks
    function _productUpdate(uint32 productId) internal virtual {}

    struct Uint256Slot {
        uint256 value;
    }

    struct RiskStoreMappingSlot {
        mapping(uint32 => RiskHelper.RiskStore) value;
    }

    function _risk() internal pure returns (RiskStoreMappingSlot storage r) {
        bytes32 slot = RISK_STORAGE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r.slot := slot
        }
    }

    function _risk(uint32 productId)
        internal
        returns (RiskHelper.Risk memory r)
    {
        RiskHelper.RiskStore memory s = _risk().value[productId];
        r.longWeightInitialX18 = int128(s.longWeightInitial) * 1e9;
        r.shortWeightInitialX18 = int128(s.shortWeightInitial) * 1e9;
        r.longWeightMaintenanceX18 = int128(s.longWeightMaintenance) * 1e9;
        r.shortWeightMaintenanceX18 = int128(s.shortWeightMaintenance) * 1e9;
        r.priceX18 = s.priceX18;
    }

    function getRisk(uint32 productId)
        external
        returns (RiskHelper.Risk memory)
    {
        return _risk(productId);
    }

    function _getBalance(uint32 productId, bytes32 subaccount)
        internal
        view
        virtual
        returns (int128, int128);

    function _getMaxProductId() internal view returns (uint32) {
        return productIds[productIds.length - 1];
    }

    function _getBitmapChunk(bytes32 subaccount, uint32 bitmapIndex)
        internal
        view
        virtual
        returns (uint256)
    {
        return nonZeroBalances[subaccount][bitmapIndex];
    }

    function _setProductBit(
        bytes32 subaccount,
        uint32 productId,
        bool hasBalance
    ) internal {
        if (hasBalance) {
            nonZeroBalances[subaccount][productId / 256] |= (1 <<
                (productId % 256));
        } else {
            nonZeroBalances[subaccount][productId / 256] &= ~(1 <<
                (productId % 256));
        }
    }

    function _hasProductBit(bytes32 subaccount, uint32 productId)
        internal
        view
        returns (bool)
    {
        return
            (nonZeroBalances[subaccount][productId / 256] &
                (1 << (productId % 256))) != 0;
    }

    function getHealthContribution(
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) public returns (int128 health) {
        uint32 maxBitmapIndex = _getMaxProductId() / 256;

        for (
            uint32 bitmapIndex = 0;
            bitmapIndex <= maxBitmapIndex;
            bitmapIndex++
        ) {
            uint256 bitmapChunk = _getBitmapChunk(subaccount, bitmapIndex);
            if (bitmapChunk == 0) {
                continue;
            }

            health += _processBitmapChunk(
                bitmapChunk,
                bitmapIndex,
                subaccount,
                healthType
            );
        }
    }

    function _processBitmapChunk(
        uint256 bitmapChunk,
        uint32 bitmapIndex,
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) internal returns (int128 health) {
        uint32 productId = bitmapIndex * 256;
        while (bitmapChunk != 0) {
            if (bitmapChunk & 1 != 0) {
                health += _calculateProductHealth(
                    productId,
                    subaccount,
                    healthType
                );
            }
            bitmapChunk >>= 1;
            productId++;
        }
    }

    function _calculateProductHealth(
        uint32 productId,
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) internal returns (int128 health) {
        RiskHelper.Risk memory risk = _risk(productId);
        (int128 amount, int128 quoteAmount) = _getBalance(
            productId,
            subaccount
        );
        int128 weight = RiskHelper._getWeightX18(risk, amount, healthType);
        health += quoteAmount;

        if (amount != 0) {
            if (weight == 2 * ONE) {
                return -INF;
            }
            health += amount.mul(weight).mul(risk.priceX18);
            emit PriceQuery(productId);
        }
    }

    function getCoreRisk(
        bytes32 subaccount,
        uint32 productId,
        IProductEngine.HealthType healthType
    ) external returns (IProductEngine.CoreRisk memory) {
        RiskHelper.Risk memory risk = _risk(productId);
        (int128 amount, ) = _getBalance(productId, subaccount);
        return
            IProductEngine.CoreRisk(
                amount,
                risk.priceX18,
                RiskHelper._getWeightX18(risk, 1, healthType)
            );
    }

    function _balanceUpdate(uint32 productId, bytes32 subaccount)
        internal
        virtual
    {} // solhint-disable-line no-empty-blocks

    function _assertInternal() internal view virtual {
        require(canApplyDeltas[msg.sender], ERR_UNAUTHORIZED);
    }

    function _initialize(
        address _clearinghouseAddr,
        address _offchainExchangeAddr,
        address _endpointAddr,
        address _admin
    ) internal initializer {
        __Ownable_init();
        setEndpoint(_endpointAddr);
        transferOwnership(_admin);

        _clearinghouse = IClearinghouse(_clearinghouseAddr);

        canApplyDeltas[_endpointAddr] = true;
        canApplyDeltas[_clearinghouseAddr] = true;
        canApplyDeltas[_offchainExchangeAddr] = true;
    }

    function getClearinghouse() external view returns (address) {
        return address(_clearinghouse);
    }

    function getProductIds() public view returns (uint32[] memory) {
        return productIds;
    }

    function _addOrUpdateProduct(
        uint32 productId,
        uint32 quoteId,
        int128 sizeIncrement,
        int128 minSize,
        RiskHelper.RiskStore memory riskStore
    ) internal returns (bool isNewProduct) {
        require(
            riskStore.longWeightInitial <= riskStore.longWeightMaintenance &&
                riskStore.longWeightMaintenance <= 10**9 &&
                riskStore.shortWeightInitial >=
                riskStore.shortWeightMaintenance &&
                riskStore.shortWeightMaintenance >= 10**9,
            ERR_BAD_PRODUCT_CONFIG
        );

        // product id is in ascending order
        if (
            productIds.length == 0 ||
            productId > productIds[productIds.length - 1]
        ) {
            productIds.push(productId);
            _clearinghouse.registerProduct(productId);
            isNewProduct = true;
        }

        if (isNewProduct) {
            IEndpoint(getEndpoint()).setInitialPrice(
                productId,
                riskStore.priceX18
            );
        } else {
            riskStore.priceX18 = _risk().value[productId].priceX18;
        }
        _risk().value[productId] = riskStore;
        _exchange().updateMarket(productId, quoteId, sizeIncrement, minSize);

        emit AddOrUpdateProduct(productId);
    }

    function _exchange() internal view returns (IOffchainExchange) {
        return
            IOffchainExchange(IEndpoint(getEndpoint()).getOffchainExchange());
    }

    function updatePrice(uint32 productId, int128 priceX18) external virtual {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);
        _risk().value[productId].priceX18 = priceX18;
    }

    function updateRisk(uint32 productId, RiskHelper.RiskStore memory riskStore)
        external
        onlyOwner
    {
        require(
            riskStore.longWeightInitial <= riskStore.longWeightMaintenance &&
                riskStore.shortWeightInitial >=
                riskStore.shortWeightMaintenance,
            ERR_BAD_PRODUCT_CONFIG
        );

        _risk().value[productId] = riskStore;
    }
}
