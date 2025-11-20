// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./libraries/MathSD21x18.sol";
import "./common/Constants.sol";
import "./libraries/MathHelper.sol";
import "./libraries/RiskHelper.sol";
import "./interfaces/IOffchainExchange.sol";
import "./EndpointGated.sol";
import "./common/Errors.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/IEndpoint.sol";

contract OffchainExchange is
    IOffchainExchange,
    EndpointGated,
    EIP712Upgradeable
{
    using MathSD21x18 for int128;
    IClearinghouse internal clearinghouse;

    mapping(uint32 => MarketInfoStore) internal marketInfo;

    mapping(bytes32 => int128) public filledAmounts;

    ISpotEngine internal spotEngine;
    IPerpEngine internal perpEngine;

    // tier -> productId -> fee rates
    mapping(uint32 => mapping(uint32 => FeeRates)) internal feeRates;

    // address -> fee tiers
    mapping(address => uint32) internal feeTiers;
    mapping(address => bool) internal addressTouched;
    address[] internal customFeeAddresses;

    mapping(uint32 => uint32) internal quoteIds;

    // address -> mask (if the i-th bit is 1, it means the i-th iso subacc is being used)
    mapping(address => uint256) internal isolatedSubaccountsMask;

    // isolated subaccount -> subaccount
    mapping(bytes32 => bytes32) internal parentSubaccounts;

    // (subaccount, id) -> isolated subaccount
    mapping(bytes32 => mapping(uint256 => bytes32))
        internal isolatedSubaccounts;

    // which isolated subaccount does an isolated order create
    mapping(bytes32 => bytes32) internal digestToSubaccount;

    // how much margin does an isolated order require
    mapping(bytes32 => int128) internal digestToMargin;

    uint128 internal nonDefaultFeeTierMask;

    function getAllFeeTiers(address[] memory users)
        external
        view
        returns (uint32[] memory)
    {
        uint32[] memory tiers = new uint32[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            tiers[i] = feeTiers[users[i]];
        }
        return tiers;
    }

    function getCustomFeeAddresses(uint32 startAt, uint32 limit)
        external
        view
        returns (address[] memory)
    {
        uint32 endAt = startAt + limit;
        uint32 total = uint32(customFeeAddresses.length);
        if (endAt > total) {
            endAt = total;
        }
        if (startAt > total) {
            startAt = total;
        }
        address[] memory addresses = new address[](endAt - startAt);
        for (uint32 i = startAt; i < endAt; i++) {
            addresses[i - startAt] = customFeeAddresses[i];
        }
        return addresses;
    }

    // copied from EIP712Upgradeable
    bytes32 private constant _TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    function getMarketInfo(uint32 productId)
        public
        view
        returns (MarketInfo memory m)
    {
        MarketInfoStore memory market = marketInfo[productId];
        m.quoteId = quoteIds[productId];
        m.collectedFees = market.collectedFees;
        m.minSize = int128(market.minSize) * 1e9;
        m.sizeIncrement = int128(market.sizeIncrement) * 1e9;
        return m;
    }

    struct CallState {
        IPerpEngine perp;
        ISpotEngine spot;
        bool isPerp;
        uint32 productId;
    }

    function _getCallState(uint32 productId)
        internal
        view
        returns (CallState memory)
    {
        address engineAddr = clearinghouse.getEngineByProduct(productId);
        IPerpEngine perp = perpEngine;

        // don't read the spot engine from storage if its a perp engine
        if (engineAddr == address(perp)) {
            return
                CallState({
                    perp: IPerpEngine(engineAddr),
                    spot: ISpotEngine(address(0)),
                    isPerp: true,
                    productId: productId
                });
        } else {
            return
                CallState({
                    perp: IPerpEngine(address(0)),
                    spot: spotEngine,
                    isPerp: false,
                    productId: productId
                });
        }
    }

    function tryCloseIsolatedSubaccount(bytes32 subaccount) external virtual {
        require(
            msg.sender == getEndpoint() || msg.sender == address(clearinghouse),
            ERR_UNAUTHORIZED
        );
        _tryCloseIsolatedSubaccount(subaccount);
    }

    function _tryCloseIsolatedSubaccount(bytes32 subaccount) internal {
        uint32 productId = RiskHelper.getIsolatedProductId(subaccount);
        if (productId == 0) {
            return;
        }
        IPerpEngine.Balance memory balance = perpEngine.getBalance(
            productId,
            subaccount
        );
        if (balance.amount == 0) {
            uint8 id = RiskHelper.getIsolatedId(subaccount);
            address addr = address(uint160(bytes20(subaccount)));
            bytes32 parent = parentSubaccounts[subaccount];
            if (balance.vQuoteBalance != 0) {
                perpEngine.updateBalance(
                    productId,
                    subaccount,
                    0,
                    -balance.vQuoteBalance
                );
                perpEngine.updateBalance(
                    productId,
                    parent,
                    0,
                    balance.vQuoteBalance
                );
            }
            int128 quoteBalance = spotEngine
                .getBalance(QUOTE_PRODUCT_ID, subaccount)
                .amount;
            if (quoteBalance != 0) {
                spotEngine.updateBalance(
                    QUOTE_PRODUCT_ID,
                    subaccount,
                    -quoteBalance
                );
                spotEngine.updateBalance(
                    QUOTE_PRODUCT_ID,
                    parent,
                    quoteBalance
                );
            }
            isolatedSubaccountsMask[addr] &= ~uint256(0) ^ (1 << id);
            isolatedSubaccounts[parent][id] = bytes32(0);
            parentSubaccounts[subaccount] = bytes32(0);

            emit CloseIsolatedSubaccount(subaccount, parent);
        }
    }

    function _updateBalances(
        CallState memory callState,
        uint32 quoteId,
        bytes32 subaccount,
        int128 baseDelta,
        int128 quoteDelta
    ) internal {
        if (callState.isPerp) {
            callState.perp.updateBalance(
                callState.productId,
                subaccount,
                baseDelta,
                quoteDelta
            );
        } else {
            if (quoteId == QUOTE_PRODUCT_ID) {
                callState.spot.updateBalance(
                    callState.productId,
                    subaccount,
                    baseDelta,
                    quoteDelta
                );
            } else {
                callState.spot.updateBalance(
                    callState.productId,
                    subaccount,
                    baseDelta
                );
                callState.spot.updateBalance(quoteId, subaccount, quoteDelta);
            }
        }
    }

    function initialize(address _clearinghouse, address _endpoint)
        external
        initializer
    {
        __Ownable_init();
        setEndpoint(_endpoint);

        __EIP712_init("Nado", "0.0.1");
        clearinghouse = IClearinghouse(_clearinghouse);
        spotEngine = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        );
        perpEngine = IPerpEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        );
    }

    function requireEngine() internal virtual {
        require(
            msg.sender == address(spotEngine) ||
                msg.sender == address(perpEngine),
            "only engine can modify config"
        );
    }

    function updateMarket(
        uint32 productId,
        uint32 quoteId,
        int128 sizeIncrement,
        int128 minSize
    ) external {
        requireEngine();
        if (quoteId != type(uint32).max) {
            quoteIds[productId] = quoteId;
        }

        marketInfo[productId].minSize = int64(minSize / 1e9);
        marketInfo[productId].sizeIncrement = int64(sizeIncrement / 1e9);
    }

    function getSizeIncrement(uint32 productId) external view returns (int128) {
        return int128(marketInfo[productId].sizeIncrement) * 1e9;
    }

    function getMinSize(uint32 productId) external view returns (int128) {
        return int128(marketInfo[productId].minSize) * 1e9;
    }

    function getDigest(uint32 productId, IEndpoint.Order memory order)
        public
        view
        returns (bytes32)
    {
        string
            memory structType = "Order(bytes32 sender,int128 priceX18,int128 amount,uint64 expiration,uint64 nonce,uint128 appendix)";

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(structType)),
                order.sender,
                order.priceX18,
                order.amount,
                order.expiration,
                order.nonce,
                order.appendix
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                _TYPE_HASH,
                _EIP712NameHash(),
                _EIP712VersionHash(),
                block.chainid,
                address(uint160(productId))
            )
        );

        return ECDSAUpgradeable.toTypedDataHash(domainSeparator, structHash);
    }

    function _isPerp(IPerpEngine engine, uint32 productId)
        internal
        view
        returns (bool)
    {
        return clearinghouse.getEngineByProduct(productId) == address(engine);
    }

    function _checkSignature(
        bytes32 subaccount,
        bytes32 digest,
        address linkedSigner,
        bytes memory signature
    ) internal view virtual returns (bool) {
        address signer = ECDSA.recover(digest, signature);
        return
            (signer != address(0)) &&
            (signer == address(uint160(bytes20(subaccount))) ||
                signer == linkedSigner);
    }

    function _expired(uint64 expiration) internal view returns (bool) {
        return expiration <= getOracleTime();
    }

    /*
        | value   | reserved | trigger | reduce only | order type| isolated | version |
        | 64 bits | 50 bits  | 2 bits  | 1 bit       | 2 bits    | 1 bit    | 8 bits  |
    */

    function _isIsolated(uint128 appendix) internal pure returns (bool) {
        return ((appendix >> 8) & 1) == 1;
    }

    function _isolatedMargin(uint128 appendix) internal pure returns (uint128) {
        return (appendix >> 64) * (10**12);
    }

    function _isReduceOnly(uint128 appendix) internal pure returns (bool) {
        return ((appendix >> 11) & 1) == 1;
    }

    function _orderType(uint128 appendix) internal pure returns (uint128) {
        return (appendix >> 9) & 3;
    }

    function _isMakerOnly(uint128 appendix) internal pure returns (bool) {
        return _orderType(appendix) == 3;
    }

    function _isTakerOnly(uint128 appendix) internal pure returns (bool) {
        uint128 orderType = _orderType(appendix);
        return orderType == 1 || orderType == 2;
    }

    function _isTWAP(uint128 appendix) internal pure returns (bool) {
        uint128 trigger = (appendix >> 12) & 3;
        return trigger >= 2;
    }

    function orderVersion() public pure returns (uint128) {
        return 1;
    }

    function _validateOrder(
        CallState memory callState,
        MarketInfo memory,
        IEndpoint.SignedOrder memory signedOrder,
        bytes32 orderDigest,
        bool isTaker,
        address linkedSigner
    ) internal view returns (bool) {
        if ((signedOrder.order.appendix & 255) != orderVersion()) {
            return false;
        }
        if (signedOrder.order.sender == X_ACCOUNT) {
            return true;
        }
        IEndpoint.Order memory order = signedOrder.order;
        if (isTaker) {
            if (_isMakerOnly(order.appendix)) {
                return false;
            }
        } else {
            if (_isTakerOnly(order.appendix)) {
                return false;
            }
        }
        int128 filledAmount = filledAmounts[orderDigest];
        order.amount -= filledAmount;

        if (_isReduceOnly(order.appendix)) {
            int128 amount = callState.isPerp
                ? callState
                    .perp
                    .getBalance(callState.productId, order.sender)
                    .amount
                : callState
                    .spot
                    .getBalance(callState.productId, order.sender)
                    .amount;
            if ((order.amount > 0) == (amount > 0)) {
                order.amount = 0;
            } else if (order.amount > 0) {
                order.amount = MathHelper.min(order.amount, -amount);
            } else if (order.amount < 0) {
                order.amount = MathHelper.max(order.amount, -amount);
            }
        }

        return
            ((order.priceX18 > 0) || _isTWAP(order.appendix)) &&
            (signedOrder.order.sender == N_ACCOUNT ||
                _checkSignature(
                    order.sender,
                    orderDigest,
                    linkedSigner,
                    signedOrder.signature
                )) &&
            // valid amount
            (order.amount != 0) &&
            !_expired(order.expiration);
    }

    function _feeAmount(
        uint32 productId,
        bytes32 subaccount,
        MarketInfo memory market,
        int128 matchQuote,
        int128 alreadyMatched, // in USDC
        bool taker
    ) internal view returns (int128, int128) {
        // X account is passthrough for trading and incurs
        // no fees
        if (subaccount == X_ACCOUNT) {
            return (0, matchQuote);
        }
        int128 meteredQuote = 0;
        if (taker) {
            // flat minimum fee
            if (alreadyMatched == 0) {
                meteredQuote += market.minSize;
                if (matchQuote < 0) {
                    meteredQuote = -meteredQuote;
                }
            }

            // exclude the portion on [0, self.min_size) for match_quote and
            // add to metered_quote
            // fee is only applied on [minSize, quote_amount)
            int128 feeApplied = MathHelper.abs(alreadyMatched + matchQuote) -
                market.minSize;
            feeApplied = MathHelper.min(feeApplied, matchQuote.abs());
            if (feeApplied > 0) {
                if (matchQuote < 0) {
                    feeApplied = -feeApplied;
                }
                meteredQuote += feeApplied;
            }
        } else {
            // for maker rebates things stay the same
            meteredQuote += matchQuote;
        }

        int128 keepRateX18 = ONE -
            getFeeFractionX18(subaccount, productId, taker);
        int128 newMeteredQuote = (meteredQuote > 0)
            ? meteredQuote.mul(keepRateX18)
            : meteredQuote.div(keepRateX18);
        int128 fee = meteredQuote - newMeteredQuote;
        market.collectedFees += fee;
        return (fee, matchQuote - fee);
    }

    function feeAmount(
        uint32 productId,
        bytes32 subaccount,
        MarketInfo memory market,
        int128 matchQuote,
        int128 alreadyMatched,
        bool taker
    ) internal virtual returns (int128, int128) {
        return
            _feeAmount(
                productId,
                subaccount,
                market,
                matchQuote,
                alreadyMatched,
                taker
            );
    }

    struct OrdersInfo {
        bytes32 takerDigest;
        bytes32 makerDigest;
        bytes32 takerSender;
        bytes32 makerSender;
        int128 makerAmount;
        int128 takerAmount;
        int128 takerFee;
        int128 takerAmountDelta;
        int128 takerQuoteDelta;
    }

    function _matchOrderOrder(
        CallState memory callState,
        MarketInfo memory market,
        IEndpoint.Order memory taker,
        IEndpoint.Order memory maker,
        OrdersInfo memory ordersInfo
    ) internal {
        int128 takerAmountDelta;
        int128 takerQuoteDelta;
        // execution happens at the maker's price
        if (taker.amount < 0) {
            takerAmountDelta = MathHelper.max(taker.amount, -maker.amount);
        } else if (taker.amount > 0) {
            takerAmountDelta = MathHelper.min(taker.amount, -maker.amount);
        } else {
            return;
        }

        takerAmountDelta -= takerAmountDelta % market.sizeIncrement;

        int128 makerQuoteDelta = takerAmountDelta.mul(maker.priceX18);

        takerQuoteDelta = -makerQuoteDelta;

        // apply the maker fee
        int128 makerFee;

        (makerFee, makerQuoteDelta) = feeAmount(
            callState.productId,
            maker.sender,
            market,
            makerQuoteDelta,
            0, // alreadyMatched doesn't matter for a maker order
            false
        );

        taker.amount -= takerAmountDelta;
        maker.amount += takerAmountDelta;

        _updateBalances(
            callState,
            market.quoteId,
            maker.sender,
            -takerAmountDelta,
            makerQuoteDelta
        );

        ordersInfo.takerAmountDelta = takerAmountDelta;
        ordersInfo.takerQuoteDelta = takerQuoteDelta;

        emit FillOrder(
            callState.productId,
            ordersInfo.makerDigest,
            maker.sender,
            maker.priceX18,
            ordersInfo.makerAmount,
            maker.expiration,
            maker.nonce,
            maker.appendix,
            _isIsolated(maker.appendix),
            false,
            makerFee,
            -takerAmountDelta,
            makerQuoteDelta
        );
    }

    function isHealthy(
        bytes32 /* subaccount */
    ) internal view virtual returns (bool) {
        return true;
    }

    function matchOrders(IEndpoint.MatchOrdersWithSigner calldata txn)
        external
        onlyEndpoint
    {
        CallState memory callState = _getCallState(txn.matchOrders.productId);

        OrdersInfo memory ordersInfo;

        MarketInfo memory market = getMarketInfo(callState.productId);
        IEndpoint.SignedOrder memory taker = txn.matchOrders.taker;
        IEndpoint.SignedOrder memory maker = txn.matchOrders.maker;

        // isolated subaccounts cannot be used as sender
        require(
            !RiskHelper.isIsolatedSubaccount(taker.order.sender),
            ERR_INVALID_TAKER
        );
        require(
            !RiskHelper.isIsolatedSubaccount(maker.order.sender),
            ERR_INVALID_MAKER
        );

        ordersInfo = OrdersInfo({
            takerDigest: getDigest(callState.productId, taker.order),
            makerDigest: getDigest(callState.productId, maker.order),
            takerSender: taker.order.sender,
            makerSender: maker.order.sender,
            makerAmount: maker.order.amount,
            takerAmount: 0,
            takerFee: 0,
            takerAmountDelta: 0,
            takerQuoteDelta: 0
        });
        if (digestToSubaccount[ordersInfo.takerDigest] != bytes32(0)) {
            taker.order.sender = digestToSubaccount[ordersInfo.takerDigest];
        }
        if (digestToSubaccount[ordersInfo.makerDigest] != bytes32(0)) {
            maker.order.sender = digestToSubaccount[ordersInfo.makerDigest];
        }

        ordersInfo.takerAmount = taker.order.amount;

        require(
            _validateOrder(
                callState,
                market,
                taker,
                ordersInfo.takerDigest,
                true,
                txn.takerLinkedSigner
            ),
            ERR_INVALID_TAKER
        );
        require(
            _validateOrder(
                callState,
                market,
                maker,
                ordersInfo.makerDigest,
                false,
                txn.makerLinkedSigner
            ),
            ERR_INVALID_MAKER
        );

        if (txn.takerAmountDelta != 0) {
            require(_isTWAP(taker.order.appendix), ERR_INVALID_TAKER);
            require(
                (txn.takerAmountDelta > 0) == (taker.order.amount > 0),
                ERR_INVALID_TAKER
            );
            if (taker.order.amount > 0) {
                require(
                    taker.order.amount >= txn.takerAmountDelta &&
                        maker.order.amount <= -txn.takerAmountDelta,
                    ERR_INVALID_TAKER
                );
            } else {
                require(
                    taker.order.amount <= txn.takerAmountDelta &&
                        maker.order.amount >= -txn.takerAmountDelta,
                    ERR_INVALID_TAKER
                );
            }

            taker.order.amount = txn.takerAmountDelta;
            maker.order.amount = -txn.takerAmountDelta;
        }

        // ensure orders are crossing
        require(
            (maker.order.amount > 0) != (taker.order.amount > 0),
            ERR_ORDERS_CANNOT_BE_MATCHED
        );
        if (maker.order.amount > 0) {
            require(
                maker.order.priceX18 >= taker.order.priceX18,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );
        } else {
            require(
                maker.order.priceX18 <= taker.order.priceX18,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );
        }

        _matchOrderOrder(
            callState,
            market,
            taker.order,
            maker.order,
            ordersInfo
        );

        // apply the taker fee
        (ordersInfo.takerFee, ordersInfo.takerQuoteDelta) = feeAmount(
            callState.productId,
            taker.order.sender,
            market,
            ordersInfo.takerQuoteDelta,
            -maker.order.priceX18.mul(filledAmounts[ordersInfo.takerDigest]),
            true
        );

        _updateBalances(
            callState,
            market.quoteId,
            taker.order.sender,
            ordersInfo.takerAmountDelta,
            ordersInfo.takerQuoteDelta
        );

        require(isHealthy(taker.order.sender), ERR_INVALID_TAKER);
        require(isHealthy(maker.order.sender), ERR_INVALID_MAKER);

        marketInfo[callState.productId].collectedFees = market.collectedFees;

        if (taker.order.sender != X_ACCOUNT) {
            filledAmounts[ordersInfo.takerDigest] += ordersInfo
                .takerAmountDelta;
        }

        if (maker.order.sender != X_ACCOUNT) {
            filledAmounts[ordersInfo.makerDigest] -= ordersInfo
                .takerAmountDelta;
        }

        emitTakerEvent(callState.productId, taker, ordersInfo);
    }

    function emitTakerEvent(
        uint32 productId,
        IEndpoint.SignedOrder memory taker,
        OrdersInfo memory ordersInfo
    ) internal {
        emit FillOrder(
            productId,
            ordersInfo.takerDigest,
            ordersInfo.takerSender,
            taker.order.priceX18,
            ordersInfo.takerAmount,
            taker.order.expiration,
            taker.order.nonce,
            taker.order.appendix,
            _isIsolated(taker.order.appendix),
            true,
            ordersInfo.takerFee,
            ordersInfo.takerAmountDelta,
            ordersInfo.takerQuoteDelta
        );
    }

    function dumpFees() external onlyEndpoint {
        // loop over all spot and perp product ids
        uint32[] memory productIds = spotEngine.getProductIds();

        for (uint32 i = 1; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            MarketInfoStore memory market = marketInfo[productId];
            if (market.collectedFees == 0) {
                continue;
            }

            spotEngine.updateBalance(
                quoteIds[productId],
                X_ACCOUNT,
                market.collectedFees
            );

            market.collectedFees = 0;
            marketInfo[productId] = market;
        }

        productIds = perpEngine.getProductIds();

        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            MarketInfoStore memory market = marketInfo[productId];
            if (market.collectedFees == 0) {
                continue;
            }

            perpEngine.updateBalance(
                productId,
                X_ACCOUNT,
                0,
                market.collectedFees
            );

            market.collectedFees = 0;
            marketInfo[productId] = market;
        }
    }

    function getFeeFractionX18(
        bytes32 subaccount,
        uint32 productId,
        bool taker
    ) public view returns (int128) {
        FeeRates memory userFeeRates = _getUserFeeRates(subaccount, productId);
        return taker ? userFeeRates.takerRateX18 : userFeeRates.makerRateX18;
    }

    function getFeeRatesX18(bytes32 subaccount, uint32 productId)
        public
        view
        returns (int128, int128)
    {
        FeeRates memory userFeeRates = _getUserFeeRates(subaccount, productId);
        return (userFeeRates.takerRateX18, userFeeRates.makerRateX18);
    }

    function getTierFeeRateX18(uint32 tier, uint32 productId)
        public
        view
        returns (FeeRates memory)
    {
        if (nonDefaultFeeTierMask & (1 << tier) != 0) {
            return feeRates[tier][productId];
        }
        return
            FeeRates({
                makerRateX18: 0,
                takerRateX18: 200_000_000_000_000 // 2 bps
            });
    }

    function _getUserFeeRates(bytes32 subaccount, uint32 productId)
        private
        view
        returns (FeeRates memory)
    {
        if (RiskHelper.isIsolatedSubaccount(subaccount)) {
            subaccount = parentSubaccounts[subaccount];
        }
        uint32 feeTier = feeTiers[address(uint160(bytes20(subaccount)))];
        return getTierFeeRateX18(feeTier, productId);
    }

    function updateFeeTier(address user, uint32 newTier) external {
        require(msg.sender == address(clearinghouse), ERR_UNAUTHORIZED);
        if (newTier != 0 && !addressTouched[user]) {
            addressTouched[user] = true;
            customFeeAddresses.push(user);
        }
        feeTiers[user] = newTier;
        emit FeeTierUpdate(user, newTier);
    }

    function updateTierFeeRates(IEndpoint.UpdateTierFeeRates memory txn)
        external
        onlyEndpoint
    {
        if (txn.productId == QUOTE_PRODUCT_ID) {
            uint32[] memory spotProductIds = spotEngine.getProductIds();
            uint32[] memory perpProductIds = perpEngine.getProductIds();
            for (uint32 i = 0; i < spotProductIds.length; i++) {
                if (spotProductIds[i] == QUOTE_PRODUCT_ID) {
                    continue;
                }
                feeRates[txn.tier][spotProductIds[i]] = FeeRates(
                    txn.makerRateX18,
                    txn.takerRateX18
                );
            }
            for (uint32 i = 0; i < perpProductIds.length; i++) {
                feeRates[txn.tier][perpProductIds[i]] = FeeRates(
                    txn.makerRateX18,
                    txn.takerRateX18
                );
            }
        } else {
            feeRates[txn.tier][txn.productId] = FeeRates(
                txn.makerRateX18,
                txn.takerRateX18
            );
        }
        nonDefaultFeeTierMask |= uint128(1) << txn.tier;
    }

    function createIsolatedSubaccount(
        IEndpoint.CreateIsolatedSubaccount memory txn,
        address linkedSigner
    ) external onlyEndpoint returns (bytes32) {
        require(
            !RiskHelper.isIsolatedSubaccount(txn.order.sender),
            ERR_UNAUTHORIZED
        );
        require(_isIsolated(txn.order.appendix), ERR_UNAUTHORIZED);
        bytes32 digest = getDigest(txn.productId, txn.order);
        if (digestToSubaccount[digest] != bytes32(0)) {
            return digestToSubaccount[digest];
        }
        require(
            _checkSignature(
                txn.order.sender,
                digest,
                linkedSigner,
                txn.signature
            ),
            ERR_INVALID_SIGNATURE
        );

        address senderAddress = address(uint160(bytes20(txn.order.sender)));
        uint256 mask = isolatedSubaccountsMask[senderAddress];
        bytes32 newIsolatedSubaccount = bytes32(0);
        for (uint256 id = 0; (1 << id) <= mask; id += 1) {
            if (mask & (1 << id) != 0) {
                bytes32 subaccount = isolatedSubaccounts[txn.order.sender][id];
                if (subaccount != bytes32(0)) {
                    uint32 productId = RiskHelper.getIsolatedProductId(
                        subaccount
                    );
                    if (productId == txn.productId) {
                        newIsolatedSubaccount = subaccount;
                        break;
                    }
                }
            }
        }

        if (newIsolatedSubaccount == bytes32(0)) {
            require(
                !_isReduceOnly(txn.order.appendix),
                "Reduce-only order cannot create isolated subaccount"
            );
            require(
                mask != (1 << MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS) - 1,
                "Too many isolated subaccounts"
            );
            uint8 id = 0;
            while (mask & 1 != 0) {
                mask >>= 1;
                id += 1;
            }

            // |  address | reserved | productId |   id   |  'iso'  |
            // | 20 bytes |  6 bytes |  2 bytes  | 1 byte | 3 bytes |
            newIsolatedSubaccount = bytes32(
                (uint256(uint160(senderAddress)) << 96) |
                    (uint256(txn.productId) << 32) |
                    (uint256(id) << 24) |
                    6910831
            );
            isolatedSubaccountsMask[senderAddress] |= 1 << id;
            parentSubaccounts[newIsolatedSubaccount] = txn.order.sender;
            isolatedSubaccounts[txn.order.sender][id] = newIsolatedSubaccount;
        }

        digestToSubaccount[digest] = newIsolatedSubaccount;

        int128 margin = int128(_isolatedMargin(txn.order.appendix));
        if (margin > 0) {
            digestToMargin[digest] = margin;
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.order.sender,
                -margin
            );
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                newIsolatedSubaccount,
                margin
            );
        }

        return newIsolatedSubaccount;
    }

    function getIsolatedSubaccounts(bytes32 subaccount)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 nIsolatedSubaccounts = 0;
        for (uint256 id = 0; id < MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS; id++) {
            bytes32 isolatedSubaccount = isolatedSubaccounts[subaccount][id];
            if (isolatedSubaccount != bytes32(0)) {
                nIsolatedSubaccounts += 1;
            }
        }
        bytes32[] memory isolatedsubaccountsResponse = new bytes32[](
            nIsolatedSubaccounts
        );
        for (uint256 id = 0; id < MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS; id++) {
            bytes32 isolatedSubaccount = isolatedSubaccounts[subaccount][id];
            if (isolatedSubaccount != bytes32(0)) {
                isolatedsubaccountsResponse[
                    --nIsolatedSubaccounts
                ] = isolatedSubaccount;
            }
        }
        return isolatedsubaccountsResponse;
    }

    function isIsolatedSubaccountActive(bytes32 parent, bytes32 subaccount)
        external
        view
        returns (bool)
    {
        for (uint256 id = 0; id < MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS; id++) {
            if (subaccount == isolatedSubaccounts[parent][id]) {
                return true;
            }
        }
        return false;
    }

    function getParentSubaccount(bytes32 subaccount)
        external
        view
        returns (bytes32)
    {
        return parentSubaccounts[subaccount];
    }

    function assertProduct(bytes calldata transaction) external virtual {
        IEndpoint.AssertProduct memory expected = abi.decode(
            transaction[1:],
            (IEndpoint.AssertProduct)
        );

        IClearinghouse clearinghouseContract = IClearinghouse(clearinghouse);

        require(
            clearinghouseContract.getEngineByProduct(expected.productId) !=
                address(0),
            ERR_PRODUCT_NOT_MATCH
        );

        IProductEngine engine = IProductEngine(
            clearinghouseContract.getEngineByProduct(expected.productId)
        );
        bool isSpot = engine.getEngineType() == IProductEngine.EngineType.SPOT;

        MarketInfo memory marketInfoData = getMarketInfo(expected.productId);
        int128 actualSizeIncrement = marketInfoData.sizeIncrement;
        int128 actualMinSize = marketInfoData.minSize;
        uint32 actualQuoteId = marketInfoData.quoteId;

        bytes32 actualOthersHash;
        if (isSpot) {
            ISpotEngine spotEngineContract = ISpotEngine(
                clearinghouseContract.getEngineByType(
                    IProductEngine.EngineType.SPOT
                )
            );
            ISpotEngine.Config memory config = spotEngineContract.getConfig(
                expected.productId
            );
            RiskHelper.Risk memory risk = engine.getRisk(expected.productId);
            actualOthersHash = keccak256(
                abi.encode(
                    config.token,
                    config.interestInflectionUtilX18,
                    config.interestFloorX18,
                    config.interestSmallCapX18,
                    config.interestLargeCapX18,
                    config.withdrawFeeX18,
                    config.minDepositRateX18,
                    risk.longWeightInitialX18,
                    risk.longWeightMaintenanceX18,
                    risk.shortWeightInitialX18,
                    risk.shortWeightMaintenanceX18
                )
            );
        } else {
            RiskHelper.Risk memory risk = engine.getRisk(expected.productId);
            actualOthersHash = keccak256(
                abi.encode(
                    risk.longWeightInitialX18,
                    risk.longWeightMaintenanceX18,
                    risk.shortWeightInitialX18,
                    risk.shortWeightMaintenanceX18
                )
            );
        }

        require(
            actualSizeIncrement == expected.sizeIncrement &&
                actualMinSize == expected.minSize &&
                actualQuoteId == expected.quoteId &&
                actualOthersHash == expected.othersHash &&
                expected.isSpot == isSpot,
            ERR_PRODUCT_NOT_MATCH
        );
    }
}
