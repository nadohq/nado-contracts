// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/IEndpoint.sol";
import {SpotEngine} from "./SpotEngine.sol";
import "./PerpEngine.sol";
import "./Endpoint.sol";
import "./Verifier.sol";
import "./BaseWithdrawPool.sol";
import "./DirectDepositV1.sol";

contract ContractOwner is EIP712Upgradeable, OwnableUpgradeable {
    using MathSD21x18 for int128;

    address internal deployer;
    SpotEngine internal spotEngine;
    PerpEngine internal perpEngine;
    Endpoint internal endpoint;
    IClearinghouse internal clearinghouse;
    Verifier internal verifier;
    address payable internal wrappedNative;
    bytes[] internal updateProductTxs;

    // using `bytes[]` in case we will change the layout of the calls.
    bytes[] internal rawSpotAddProductCalls;
    bytes[] internal rawPerpAddProductCalls;

    mapping(bytes32 => address payable) public directDepositV1Address;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address multisig,
        address _deployer,
        address _spotEngine,
        address _perpEngine,
        address _endpoint,
        address _clearinghouse,
        address _verifier,
        address payable _wrappedNative
    ) external initializer {
        require(_deployer == msg.sender, "expected deployed to initialize");
        __Ownable_init();
        transferOwnership(multisig);
        deployer = _deployer;
        spotEngine = SpotEngine(_spotEngine);
        perpEngine = PerpEngine(_perpEngine);
        endpoint = Endpoint(_endpoint);
        clearinghouse = IClearinghouse(_clearinghouse);
        verifier = Verifier(_verifier);
        wrappedNative = _wrappedNative;
    }

    modifier onlyDeployer() {
        require(msg.sender == deployer, "sender must be deployer");
        _;
    }

    struct SpotAddProductCall {
        uint32 productId;
        uint32 quoteId;
        int128 sizeIncrement;
        int128 minSize;
        ISpotEngine.Config config;
        RiskHelper.RiskStore riskStore;
    }

    struct PerpAddProductCall {
        uint32 productId;
        int128 sizeIncrement;
        int128 minSize;
        RiskHelper.RiskStore riskStore;
    }

    function submitSpotAddProductCall(
        uint32 productId,
        uint32 quoteId,
        int128 sizeIncrement,
        int128 minSize,
        ISpotEngine.Config calldata config,
        RiskHelper.RiskStore calldata riskStore
    ) external onlyDeployer {
        uint32[] memory pendingIds = pendingSpotAddProductIds();
        for (uint256 i = 0; i < pendingIds.length; i++) {
            require(
                productId != pendingIds[i],
                "trying to add a spot product twice."
            );
        }
        rawSpotAddProductCalls.push(
            abi.encode(
                SpotAddProductCall(
                    productId,
                    quoteId,
                    sizeIncrement,
                    minSize,
                    config,
                    riskStore
                )
            )
        );
    }

    function submitPerpAddProductCall(
        uint32 productId,
        int128 sizeIncrement,
        int128 minSize,
        RiskHelper.RiskStore calldata riskStore
    ) external onlyDeployer {
        uint32[] memory pendingIds = pendingPerpAddProductIds();
        for (uint256 i = 0; i < pendingIds.length; i++) {
            require(
                productId != pendingIds[i],
                "trying to add a perp product twice."
            );
        }
        rawPerpAddProductCalls.push(
            abi.encode(
                PerpAddProductCall(productId, sizeIncrement, minSize, riskStore)
            )
        );
    }

    function clearSpotAddProductCalls() external onlyDeployer {
        delete rawSpotAddProductCalls;
    }

    function clearPerpAddProductCalls() external onlyDeployer {
        delete rawPerpAddProductCalls;
    }

    function addProducts(uint32[] memory spotIds, uint32[] memory perpIds)
        external
        onlyOwner
    {
        for (uint256 i = 0; i < rawSpotAddProductCalls.length; i++) {
            SpotAddProductCall memory call = abi.decode(
                rawSpotAddProductCalls[i],
                (SpotAddProductCall)
            );
            require(spotIds[i] == call.productId, "spot id doesn't match.");
            spotEngine.addProduct(
                call.productId,
                call.quoteId,
                call.sizeIncrement,
                call.minSize,
                call.config,
                call.riskStore
            );
        }
        delete rawSpotAddProductCalls;

        for (uint256 i = 0; i < rawPerpAddProductCalls.length; i++) {
            PerpAddProductCall memory call = abi.decode(
                rawPerpAddProductCalls[i],
                (PerpAddProductCall)
            );
            require(perpIds[i] == call.productId, "perp id doesn't match.");
            perpEngine.addProduct(
                call.productId,
                call.sizeIncrement,
                call.minSize,
                call.riskStore
            );
        }
        delete rawPerpAddProductCalls;
    }

    function pendingSpotAddProductIds() public view returns (uint32[] memory) {
        uint32[] memory productIds = new uint32[](
            rawSpotAddProductCalls.length
        );
        for (uint256 i = 0; i < rawSpotAddProductCalls.length; i++) {
            SpotAddProductCall memory call = abi.decode(
                rawSpotAddProductCalls[i],
                (SpotAddProductCall)
            );
            productIds[i] = call.productId;
        }
        return productIds;
    }

    function pendingPerpAddProductIds() public view returns (uint32[] memory) {
        uint32[] memory productIds = new uint32[](
            rawPerpAddProductCalls.length
        );
        for (uint256 i = 0; i < rawPerpAddProductCalls.length; i++) {
            PerpAddProductCall memory call = abi.decode(
                rawPerpAddProductCalls[i],
                (PerpAddProductCall)
            );
            productIds[i] = call.productId;
        }
        return productIds;
    }

    function hasPendingAddProductCalls() public view returns (bool) {
        return
            rawPerpAddProductCalls.length > 0 ||
            rawSpotAddProductCalls.length > 0;
    }

    function submitUpdateProductTx(bytes calldata slowModeTx)
        external
        onlyDeployer
    {
        updateProductTxs.push(slowModeTx);
    }

    function clearUpdateProductTxs() external onlyDeployer {
        delete updateProductTxs;
    }

    function batchSubmitUpdateProductTxs(bytes[] calldata slowModeTxs)
        external
        onlyDeployer
    {
        for (uint256 i = 0; i < slowModeTxs.length; i++) {
            bytes memory txn = slowModeTxs[i];
            updateProductTxs.push(txn);
        }
    }

    function updateProducts() external onlyOwner {
        for (uint256 i = 0; i < updateProductTxs.length; i++) {
            bytes memory txn = updateProductTxs[i];
            endpoint.submitSlowModeTransaction(txn);
        }
        delete updateProductTxs;
    }

    function withdrawInsurance(uint128 amount, address sendTo)
        external
        onlyOwner
    {
        IEndpoint.WithdrawInsurance memory _txn = IEndpoint.WithdrawInsurance(
            amount,
            sendTo
        );
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.WithdrawInsurance),
            abi.encode(_txn)
        );
        endpoint.submitSlowModeTransaction(txn);
    }

    function delistProduct(
        uint32[] calldata productIds,
        int128[] calldata pricesX18,
        bytes32[] calldata subaccounts
    ) external onlyDeployer {
        require(productIds.length == pricesX18.length, "invalid inputs");
        for (uint256 i = 0; i < productIds.length; i++) {
            IEndpoint.DelistProduct memory _txn = IEndpoint.DelistProduct(
                productIds[i],
                pricesX18[i],
                subaccounts
            );
            bytes memory txn = abi.encodePacked(
                uint8(IEndpoint.TransactionType.DelistProduct),
                abi.encode(_txn)
            );
            endpoint.submitSlowModeTransaction(txn);
        }
    }

    function dumpFees() external onlyOwner {
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.DumpFees)
        );
        endpoint.submitSlowModeTransaction(txn);
    }

    function rebalanceXWithdraw(
        uint32 productId,
        uint128 amount,
        address sendTo
    ) external onlyOwner {
        IEndpoint.RebalanceXWithdraw memory _txn = IEndpoint.RebalanceXWithdraw(
            productId,
            amount,
            sendTo
        );
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.RebalanceXWithdraw),
            abi.encode(_txn)
        );
        endpoint.submitSlowModeTransaction(txn);
    }

    function updateTierFeeRates(
        uint32[] memory tier,
        uint32[] memory productId,
        int128[] memory makerRateX18,
        int128[] memory takerRateX18
    ) external onlyOwner {
        require(tier.length == productId.length, "invalid inputs");
        require(tier.length == makerRateX18.length, "invalid inputs");
        require(tier.length == takerRateX18.length, "invalid inputs");
        for (uint256 i = 0; i < tier.length; i++) {
            IEndpoint.UpdateTierFeeRates memory _txn = IEndpoint
                .UpdateTierFeeRates(
                    tier[i],
                    productId[i],
                    makerRateX18[i],
                    takerRateX18[i]
                );
            bytes memory txn = abi.encodePacked(
                uint8(IEndpoint.TransactionType.UpdateTierFeeRates),
                abi.encode(_txn)
            );
            endpoint.submitSlowModeTransaction(txn);
        }
    }

    function hasPendingUpdateProductTxs() public view returns (bool) {
        return updateProductTxs.length > 0;
    }

    function addEngine(
        address engine,
        address offchainExchange,
        IProductEngine.EngineType engineType
    ) external onlyOwner {
        clearinghouse.addEngine(engine, offchainExchange, engineType);
    }

    function assignPubKey(
        uint256 i,
        uint256 x,
        uint256 y
    ) public onlyOwner {
        verifier.assignPubKey(i, x, y);
    }

    function deletePubkey(uint256 index) public onlyOwner {
        verifier.deletePubkey(index);
    }

    function spotUpdateRisk(
        uint32 productId,
        RiskHelper.RiskStore memory riskStore
    ) external onlyOwner {
        spotEngine.updateRisk(productId, riskStore);
    }

    function perpUpdateRisk(
        uint32 productId,
        RiskHelper.RiskStore memory riskStore
    ) external onlyOwner {
        perpEngine.updateRisk(productId, riskStore);
    }

    function setWithdrawPool(address _withdrawPool) external onlyOwner {
        clearinghouse.setWithdrawPool(_withdrawPool);
    }

    function removeWithdrawPoolLiquidity(
        uint32 productId,
        uint128 amount,
        address sendTo
    ) external onlyOwner {
        BaseWithdrawPool withdrawPool = BaseWithdrawPool(
            clearinghouse.getWithdrawPool()
        );
        withdrawPool.removeLiquidity(productId, amount, sendTo);
    }

    function createDirectDepositV1(bytes32 subaccount)
        public
        returns (address payable)
    {
        DirectDepositV1 directDepositV1 = new DirectDepositV1{
            salt: bytes32(uint256(1))
        }(address(endpoint), address(spotEngine), subaccount, wrappedNative);
        directDepositV1Address[subaccount] = payable(directDepositV1);
        return payable(directDepositV1);
    }

    function creditDepositV1(bytes32 subaccount) external {
        address payable directDepositV1 = directDepositV1Address[subaccount];
        if (directDepositV1 == address(0)) {
            directDepositV1 = createDirectDepositV1(subaccount);
        }
        DirectDepositV1(directDepositV1).creditDeposit();
    }

    function isDirectDepositV1Ready(address recipient) external returns (bool) {
        uint32[] memory productIds = spotEngine.getProductIds();
        for (uint256 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            address tokenAddr = spotEngine.getToken(productId);
            require(tokenAddr != address(0), "Invalid productId.");

            IERC20Base token = IERC20Base(tokenAddr);
            uint256 balance = token.balanceOf(recipient);
            if (tokenAddr == wrappedNative) {
                balance += recipient.balance;
            }
            balance *= 10**(18 - token.decimals());
            int128 oraclePriceX18 = spotEngine.getRisk(productId).priceX18;
            if (
                oraclePriceX18.mul(int128(uint128(balance))) >=
                MIN_DEPOSIT_AMOUNT
            ) {
                return true;
            }
        }
        return false;
    }
}
