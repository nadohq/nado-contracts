// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./common/Constants.sol";
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
import "./BaseWithdrawPool.sol";

interface IProxyManager {
    function getProxyManagerHelper() external view returns (address);

    function getCodeHash(string memory name) external view returns (bytes32);
}

contract Clearinghouse is EndpointGated, ClearinghouseStorage, IClearinghouse {
    using MathSD21x18 for int128;
    using ERC20Helper for IERC20Base;

    function initialize(
        address _endpoint,
        address _quote,
        address _clearinghouseLiq,
        uint256 _spreads,
        address _withdrawPool
    ) external initializer {
        __Ownable_init();
        setEndpoint(_endpoint);
        quote = _quote;
        clearinghouse = address(this);
        clearinghouseLiq = _clearinghouseLiq;
        spreads = _spreads;
        withdrawPool = _withdrawPool;
        emit ClearinghouseInitialized(_endpoint, _quote);
    }

    /**
     * View
     */

    function getQuote() external view returns (address) {
        return quote;
    }

    function getEngineByType(IProductEngine.EngineType engineType)
        external
        view
        returns (address)
    {
        return address(engineByType[engineType]);
    }

    function getEngineByProduct(uint32 productId)
        external
        view
        returns (address)
    {
        return address(productToEngine[productId]);
    }

    function getInsurance() external view returns (int128) {
        return insurance;
    }

    /// @notice grab total subaccount health
    function getHealth(bytes32 subaccount, IProductEngine.HealthType healthType)
        public
        returns (int128 health)
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        health = spotEngine.getHealthContribution(subaccount, healthType);
        // min health means that it is attempting to borrow a spot that exists outside
        // of the risk system -- return min health to error out this action
        if (health == (type(int128).min)) {
            return health;
        }
        health += perpEngine.getHealthContribution(subaccount, healthType);

        uint256 _spreads = spreads;
        while (_spreads != 0) {
            uint32 _spotId = uint32(_spreads & 0xFF);
            _spreads >>= 8;
            uint32 _perpId = uint32(_spreads & 0xFF);
            _spreads >>= 8;

            IProductEngine.CoreRisk memory perpCoreRisk = perpEngine
                .getCoreRisk(subaccount, _perpId, healthType);

            if (perpCoreRisk.amount == 0) {
                continue;
            }

            IProductEngine.CoreRisk memory spotCoreRisk = spotEngine
                .getCoreRisk(subaccount, _spotId, healthType);

            if (
                (spotCoreRisk.amount == 0) ||
                ((spotCoreRisk.amount > 0) == (perpCoreRisk.amount > 0))
            ) {
                continue;
            }

            int128 basisAmount;
            if (spotCoreRisk.amount > 0) {
                basisAmount = MathHelper.min(
                    spotCoreRisk.amount,
                    -perpCoreRisk.amount
                );
            } else {
                basisAmount = -MathHelper.max(
                    spotCoreRisk.amount,
                    -perpCoreRisk.amount
                );
            }

            int128 existingPenalty = (spotCoreRisk.longWeight +
                perpCoreRisk.longWeight) / 2;
            int128 spreadPenalty;
            if (spotCoreRisk.amount > 0) {
                spreadPenalty = ONE - (ONE - perpCoreRisk.longWeight) / 5;
            } else {
                spreadPenalty = ONE - (ONE - spotCoreRisk.longWeight) / 5;
            }

            health += basisAmount
                .mul(spotCoreRisk.price + perpCoreRisk.price)
                .mul(spreadPenalty - existingPenalty);
            emit PriceQuery(_spotId);
            emit PriceQuery(_perpId);
        }
    }

    function registerProduct(uint32 productId) external {
        IProductEngine engine = IProductEngine(msg.sender);
        IProductEngine.EngineType engineType = engine.getEngineType();
        require(
            address(engineByType[engineType]) == msg.sender,
            ERR_UNAUTHORIZED
        );

        productToEngine[productId] = engine;
    }

    /**
     * Actions
     */

    function addEngine(
        address engine,
        address offchainExchange,
        IProductEngine.EngineType engineType
    ) external onlyOwner {
        require(address(engineByType[engineType]) == address(0));
        require(engine != address(0));
        IProductEngine productEngine = IProductEngine(engine);
        // Register
        supportedEngines.push(engineType);
        engineByType[engineType] = productEngine;

        // add quote to product mapping
        if (engineType == IProductEngine.EngineType.SPOT) {
            productToEngine[QUOTE_PRODUCT_ID] = productEngine;
        }

        // Initialize engine
        productEngine.initialize(
            address(this),
            offchainExchange,
            quote,
            getEndpoint(),
            owner()
        );
    }

    function _tokenAddress(uint32 productId) internal view returns (address) {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        return spotEngine.getConfig(productId).token;
    }

    function _decimals(uint32 productId) internal virtual returns (uint8) {
        IERC20Base token = IERC20Base(_tokenAddress(productId));
        require(address(token) != address(0), ERR_INVALID_PRODUCT);
        return token.decimals();
    }

    function depositCollateral(IEndpoint.DepositCollateral calldata txn)
        external
        virtual
        onlyEndpoint
    {
        require(!RiskHelper.isIsolatedSubaccount(txn.sender), ERR_UNAUTHORIZED);
        require(txn.amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        uint8 decimals = _decimals(txn.productId);

        require(decimals <= MAX_DECIMALS);
        int256 multiplier = int256(10**(MAX_DECIMALS - decimals));
        int128 amountRealized = int128(txn.amount) * int128(multiplier);

        spotEngine.updateBalance(txn.productId, txn.sender, amountRealized);
        emit ModifyCollateral(amountRealized, txn.sender, txn.productId);
    }

    function transferQuote(IEndpoint.TransferQuote calldata txn)
        external
        virtual
        onlyEndpoint
    {
        require(txn.amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        int128 toTransfer = int128(txn.amount);
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );

        // require the sender address to be the same as the recipient address
        // otherwise linked signers can transfer out
        require(
            bytes20(txn.sender) == bytes20(txn.recipient),
            ERR_UNAUTHORIZED
        );
        address offchainExchange = IEndpoint(getEndpoint())
            .getOffchainExchange();
        if (RiskHelper.isIsolatedSubaccount(txn.sender)) {
            // isolated subaccounts can only transfer quote back to parent
            require(
                IOffchainExchange(offchainExchange).getParentSubaccount(
                    txn.sender
                ) == txn.recipient,
                ERR_UNAUTHORIZED
            );
        } else if (RiskHelper.isIsolatedSubaccount(txn.recipient)) {
            // regular subaccounts can transfer quote to active isolated subaccounts
            require(
                IOffchainExchange(offchainExchange).isIsolatedSubaccountActive(
                    txn.sender,
                    txn.recipient
                ),
                ERR_UNAUTHORIZED
            );
        }

        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.sender, -toTransfer);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.recipient, toTransfer);
        require(_isAboveInitial(txn.sender), ERR_SUBACCT_HEALTH);
    }

    function depositInsurance(bytes calldata transaction)
        external
        virtual
        onlyEndpoint
    {
        IEndpoint.DepositInsurance memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.DepositInsurance)
        );
        require(txn.amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        int256 multiplier = int256(
            10**(MAX_DECIMALS - _decimals(QUOTE_PRODUCT_ID))
        );
        int128 amount = int128(txn.amount) * int128(multiplier);
        insurance += amount;
    }

    function withdrawInsurance(bytes calldata transaction, uint64 idx)
        external
        virtual
        onlyEndpoint
    {
        IEndpoint.WithdrawInsurance memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.WithdrawInsurance)
        );
        require(txn.amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        int256 multiplier = int256(
            10**(MAX_DECIMALS - _decimals(QUOTE_PRODUCT_ID))
        );
        int128 amount = int128(txn.amount) * int128(multiplier);
        require(amount <= insurance, ERR_NO_INSURANCE);
        insurance -= amount;

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IERC20Base token = IERC20Base(
            spotEngine.getConfig(QUOTE_PRODUCT_ID).token
        );
        require(address(token) != address(0));
        handleWithdrawTransfer(token, txn.sendTo, txn.amount, idx);
    }

    function delistProduct(bytes calldata transaction) external onlyEndpoint {
        IEndpoint.DelistProduct memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.DelistProduct)
        );
        // only perp can be delisted
        require(
            productToEngine[txn.productId] ==
                engineByType[IProductEngine.EngineType.PERP],
            ERR_INVALID_PRODUCT
        );
        require(
            txn.priceX18 == IEndpoint(getEndpoint()).getPriceX18(txn.productId),
            ERR_INVALID_PRICE
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        for (uint256 i = 0; i < txn.subaccounts.length; i++) {
            IPerpEngine.Balance memory balance = perpEngine.getBalance(
                txn.productId,
                txn.subaccounts[i]
            );
            int128 baseDelta = -balance.amount;
            int128 quoteDelta = -baseDelta.mul(txn.priceX18);
            perpEngine.updateBalance(
                txn.productId,
                txn.subaccounts[i],
                baseDelta,
                quoteDelta
            );
            if (RiskHelper.isIsolatedSubaccount(txn.subaccounts[i])) {
                IOffchainExchange(
                    IEndpoint(getEndpoint()).getOffchainExchange()
                ).tryCloseIsolatedSubaccount(txn.subaccounts[i]);
            }
        }
    }

    function rebalanceXWithdraw(bytes calldata transaction, uint64 nSubmissions)
        external
        onlyEndpoint
    {
        IEndpoint.RebalanceXWithdraw memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.RebalanceXWithdraw)
        );

        withdrawCollateral(
            X_ACCOUNT,
            txn.productId,
            txn.amount,
            txn.sendTo,
            nSubmissions
        );
    }

    function updateFeeTier(bytes calldata transaction) external onlyEndpoint {
        IEndpoint.UpdateFeeTier memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.UpdateFeeTier)
        );
        address offchainExchange = IEndpoint(getEndpoint())
            .getOffchainExchange();
        IOffchainExchange(offchainExchange).updateFeeTier(
            txn.user,
            txn.newTier
        );
    }

    function updatePrice(bytes calldata transaction)
        external
        onlyEndpoint
        returns (uint32, int128)
    {
        IEndpoint.UpdatePrice memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.UpdatePrice)
        );
        require(txn.priceX18 > 0, ERR_INVALID_PRICE);
        IProductEngine engine = productToEngine[txn.productId];
        if (address(engine) != address(0)) {
            engine.updatePrice(txn.productId, txn.priceX18);
            return (txn.productId, txn.priceX18);
        } else {
            return (0, 0);
        }
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address to,
        uint128 amount,
        uint64 idx
    ) internal virtual {
        token.safeTransfer(withdrawPool, uint256(amount));
        BaseWithdrawPool(withdrawPool).submitWithdrawal(token, to, amount, idx);
    }

    function _balanceOf(address token) internal view virtual returns (uint128) {
        return uint128(IERC20Base(token).balanceOf(address(this)));
    }

    function withdrawCollateral(
        bytes32 sender,
        uint32 productId,
        uint128 amount,
        address sendTo,
        uint64 idx
    ) public virtual onlyEndpoint {
        require(!RiskHelper.isIsolatedSubaccount(sender), ERR_UNAUTHORIZED);
        require(amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IERC20Base token = IERC20Base(spotEngine.getConfig(productId).token);
        require(address(token) != address(0));

        if (sender != X_ACCOUNT) {
            sendTo = address(uint160(bytes20(sender)));
        }

        handleWithdrawTransfer(token, sendTo, amount, idx);

        int256 multiplier = int256(10**(MAX_DECIMALS - _decimals(productId)));
        int128 amountRealized = -int128(amount) * int128(multiplier);
        spotEngine.updateBalance(productId, sender, amountRealized);
        spotEngine.assertUtilization(productId);

        IProductEngine.HealthType healthType = sender == X_ACCOUNT
            ? IProductEngine.HealthType.PNL
            : IProductEngine.HealthType.INITIAL;

        require(getHealth(sender, healthType) >= 0, ERR_SUBACCT_HEALTH);
        emit ModifyCollateral(amountRealized, sender, productId);
    }

    function mintNlp(
        IEndpoint.MintNlp calldata txn,
        int128 oraclePriceX18,
        IEndpoint.NlpPool[] calldata nlpPools,
        int128[] calldata nlpPoolRebalanceX18
    ) external onlyEndpoint {
        require(!RiskHelper.isIsolatedSubaccount(txn.sender), ERR_UNAUTHORIZED);
        require(
            nlpPools.length == nlpPoolRebalanceX18.length,
            ERR_INVALID_NLP_REBALANCE
        );
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        spotEngine.updatePrice(NLP_PRODUCT_ID, oraclePriceX18);
        require(txn.quoteAmount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);

        int128 quoteAmount = int128(txn.quoteAmount);
        int128 rebalanceAmount = 0;
        for (uint128 i = 0; i < nlpPoolRebalanceX18.length; i++) {
            rebalanceAmount += nlpPoolRebalanceX18[i];
            require(nlpPoolRebalanceX18[i] >= 0, ERR_INVALID_NLP_REBALANCE);
        }
        require(quoteAmount == rebalanceAmount, ERR_INVALID_NLP_REBALANCE);

        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.sender, -quoteAmount);
        for (uint128 i = 0; i < nlpPoolRebalanceX18.length; i++) {
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                nlpPools[i].subaccount,
                nlpPoolRebalanceX18[i]
            );
        }

        int128 nlpAmount = quoteAmount.div(oraclePriceX18);
        spotEngine.updateBalance(NLP_PRODUCT_ID, txn.sender, nlpAmount);
        spotEngine.updateBalance(NLP_PRODUCT_ID, N_ACCOUNT, -nlpAmount);

        require(
            getHealth(txn.sender, IProductEngine.HealthType.INITIAL) >= 0,
            ERR_SUBACCT_HEALTH
        );
    }

    function burnNlp(
        IEndpoint.BurnNlp calldata txn,
        int128 oraclePriceX18,
        IEndpoint.NlpPool[] calldata nlpPools,
        int128[] calldata nlpPoolRebalanceX18
    ) external onlyEndpoint {
        require(!RiskHelper.isIsolatedSubaccount(txn.sender), ERR_UNAUTHORIZED);
        require(
            nlpPools.length == nlpPoolRebalanceX18.length,
            ERR_INVALID_NLP_REBALANCE
        );
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        spotEngine.updatePrice(NLP_PRODUCT_ID, oraclePriceX18);
        require(txn.nlpAmount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);

        int128 nlpAmount = int128(txn.nlpAmount);
        require(
            spotEngine.getNlpUnlockedBalance(txn.sender).amount >= nlpAmount,
            ERR_UNLOCKED_NLP_INSUFFICIENT
        );
        spotEngine.updateBalance(NLP_PRODUCT_ID, txn.sender, -nlpAmount);
        spotEngine.updateBalance(NLP_PRODUCT_ID, N_ACCOUNT, nlpAmount);

        int128 quoteAmount = nlpAmount.mul(oraclePriceX18);
        int128 burnFee = MathHelper.max(ONE, quoteAmount / 1000);
        quoteAmount = MathHelper.max(0, quoteAmount - burnFee);

        if (quoteAmount == 0) {
            return;
        }

        int128 rebalanceAmount = 0;
        for (uint128 i = 0; i < nlpPoolRebalanceX18.length; i++) {
            rebalanceAmount += nlpPoolRebalanceX18[i];
            require(nlpPoolRebalanceX18[i] <= 0, ERR_INVALID_NLP_REBALANCE);
        }
        require(quoteAmount == -rebalanceAmount, ERR_INVALID_NLP_REBALANCE);

        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.sender, quoteAmount);
        for (uint128 i = 0; i < nlpPoolRebalanceX18.length; i++) {
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                nlpPools[i].subaccount,
                nlpPoolRebalanceX18[i]
            );
        }

        require(
            spotEngine.getBalance(NLP_PRODUCT_ID, txn.sender).amount >= 0,
            ERR_SUBACCT_HEALTH
        );
    }

    function claimSequencerFees(int128[] calldata fees)
        external
        virtual
        onlyEndpoint
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        uint32[] memory spotIds = spotEngine.getProductIds();
        uint32[] memory perpIds = perpEngine.getProductIds();

        for (uint256 i = 0; i < spotIds.length; i++) {
            ISpotEngine.Balance memory feeBalance = spotEngine.getBalance(
                spotIds[i],
                FEES_ACCOUNT
            );
            spotEngine.updateBalance(
                spotIds[i],
                X_ACCOUNT,
                fees[i] + feeBalance.amount
            );
            spotEngine.updateBalance(
                spotIds[i],
                FEES_ACCOUNT,
                -feeBalance.amount
            );
        }

        for (uint256 i = 0; i < perpIds.length; i++) {
            IPerpEngine.Balance memory feeBalance = perpEngine.getBalance(
                perpIds[i],
                FEES_ACCOUNT
            );
            perpEngine.updateBalance(
                perpIds[i],
                X_ACCOUNT,
                feeBalance.amount,
                feeBalance.vQuoteBalance
            );
            perpEngine.updateBalance(
                perpIds[i],
                FEES_ACCOUNT,
                -feeBalance.amount,
                -feeBalance.vQuoteBalance
            );
        }
    }

    function _settlePnl(bytes32 subaccount, uint256 productIds) internal {
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        int128 amountSettled = perpEngine.settlePnl(subaccount, productIds);

        ISpotEngine(address(engineByType[IProductEngine.EngineType.SPOT]))
            .updateBalance(QUOTE_PRODUCT_ID, subaccount, amountSettled);
    }

    function settlePnl(bytes calldata transaction) external onlyEndpoint {
        IEndpoint.SettlePnl memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.SettlePnl)
        );
        for (uint128 i = 0; i < txn.subaccounts.length; ++i) {
            _settlePnl(txn.subaccounts[i], txn.productIds[i]);
        }
    }

    function _isAboveInitial(bytes32 subaccount) internal returns (bool) {
        // Weighted initial health with limit orders < 0
        return getHealth(subaccount, IProductEngine.HealthType.INITIAL) >= 0;
    }

    function _isUnderMaintenance(bytes32 subaccount) internal returns (bool) {
        // Weighted maintenance health < 0
        return getHealth(subaccount, IProductEngine.HealthType.MAINTENANCE) < 0;
    }

    function liquidateSubaccount(IEndpoint.LiquidateSubaccount calldata txn)
        external
        virtual
        onlyEndpoint
    {
        bytes4 liquidateSubaccountSelector = bytes4(
            keccak256(
                "liquidateSubaccountImpl((bytes32,bytes32,uint32,bool,int128,uint64))"
            )
        );
        bytes memory liquidateSubaccountCall = abi.encodeWithSelector(
            liquidateSubaccountSelector,
            txn
        );
        (bool success, bytes memory result) = clearinghouseLiq.delegatecall(
            liquidateSubaccountCall
        );
        require(success, string(result));
    }

    struct AddressSlot {
        address value;
    }

    function _getProxyManager() internal view returns (address) {
        AddressSlot storage proxyAdmin;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            proxyAdmin.slot := 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
        }
        return proxyAdmin.value;
    }

    function upgradeClearinghouseLiq(address _clearinghouseLiq) external {
        require(
            msg.sender ==
                IProxyManager(_getProxyManager()).getProxyManagerHelper(),
            ERR_UNAUTHORIZED
        );
        clearinghouseLiq = _clearinghouseLiq;
    }

    function getClearinghouseLiq() external view returns (address) {
        return clearinghouseLiq;
    }

    function getSpreads() external view returns (uint256) {
        return spreads;
    }

    function requireMinDeposit(uint32 productId, uint128 amount) external {
        require(amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        uint8 decimals = _decimals(productId);
        require(decimals <= MAX_DECIMALS);

        int256 multiplier = int256(10**(MAX_DECIMALS - decimals));
        int128 amountRealized = int128(multiplier) * int128(amount);
        int128 priceX18 = ONE;
        if (productId != QUOTE_PRODUCT_ID) {
            priceX18 = IEndpoint(getEndpoint()).getPriceX18(productId);
        }

        require(
            priceX18.mul(amountRealized) >= MIN_DEPOSIT_AMOUNT,
            ERR_DEPOSIT_TOO_SMALL
        );
    }

    function assertCode(bytes calldata transaction) external view virtual {
        IEndpoint.AssertCode memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.AssertCode)
        );
        require(
            txn.contractNames.length == txn.codeHashes.length,
            ERR_CODE_NOT_MATCH
        );
        require(spreads == txn.spreads, ERR_CODE_NOT_MATCH);
        for (uint256 i = 0; i < txn.contractNames.length; i++) {
            bytes32 expectedCodeHash = IProxyManager(_getProxyManager())
                .getCodeHash(txn.contractNames[i]);
            require(txn.codeHashes[i] == expectedCodeHash, ERR_CODE_NOT_MATCH);
        }
    }

    function manualAssert(bytes calldata transaction) external view virtual {
        IEndpoint.ManualAssert memory txn = abi.decode(
            transaction[1:],
            (IEndpoint.ManualAssert)
        );
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        perpEngine.manualAssert(txn.openInterests);
        spotEngine.manualAssert(txn.totalDeposits, txn.totalBorrows);
    }

    function getWithdrawPool() external view returns (address) {
        return withdrawPool;
    }

    function setWithdrawPool(address _withdrawPool) external onlyOwner {
        require(_withdrawPool != address(0));
        withdrawPool = _withdrawPool;
    }

    function setSpreads(uint256 _spreads) external virtual onlyOwner {
        spreads = _spreads;
    }

    function getSlowModeFee() external view returns (uint256) {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IERC20Base token = IERC20Base(
            spotEngine.getConfig(QUOTE_PRODUCT_ID).token
        );
        int256 multiplier = int256(10**(token.decimals() - 6));
        return uint256(int256(SLOW_MODE_FEE) * multiplier);
    }

    function clearNlpPoolPosition(bytes32 subaccount)
        external
        virtual
        onlyEndpoint
    {
        require(subaccount != N_ACCOUNT, ERR_UNAUTHORIZED);

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        uint32[] memory spotProducts = spotEngine.getProductIds();

        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        uint32[] memory perpProducts = perpEngine.getProductIds();

        for (uint32 i = 0; i < spotProducts.length; i++) {
            uint32 productId = spotProducts[i];

            ISpotEngine.Balance memory balance = spotEngine.getBalance(
                productId,
                subaccount
            );
            spotEngine.updateBalance(productId, subaccount, -balance.amount);
            spotEngine.updateBalance(productId, N_ACCOUNT, balance.amount);
        }

        for (uint32 i = 0; i < perpProducts.length; i++) {
            uint32 productId = perpProducts[i];

            IPerpEngine.Balance memory balance = perpEngine.getBalance(
                productId,
                subaccount
            );
            perpEngine.updateBalance(
                productId,
                subaccount,
                -balance.amount,
                -balance.vQuoteBalance
            );
            perpEngine.updateBalance(
                productId,
                N_ACCOUNT,
                balance.amount,
                balance.vQuoteBalance
            );
        }
    }
}
