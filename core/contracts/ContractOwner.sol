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
import {DirectDepositV1} from "./DirectDepositV1.sol";
import "./interfaces/IERC20Base.sol";
import "./libraries/ERC20Helper.sol";
import "./common/Constants.sol";

contract ContractOwner is EIP712Upgradeable, OwnableUpgradeable {
    using MathSD21x18 for int128;
    using ERC20Helper for IERC20Base;

    address internal deployer;
    SpotEngine internal spotEngine;
    PerpEngine internal perpEngine;
    Endpoint internal endpoint;
    IClearinghouse internal clearinghouse;
    Verifier internal verifier;
    address payable internal wrappedNative;

    bytes[] internal updateProductTxs; // deprecated
    bytes[] internal rawSpotAddProductCalls; // deprecated
    bytes[] internal rawPerpAddProductCalls; // deprecated

    mapping(bytes32 => address payable) public directDepositV1Address;

    bytes[] internal rawSpotAddOrUpdateProductCalls;
    bytes[] internal rawPerpAddOrUpdateProductCalls;

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

    struct SpotAddOrUpdateProductCall {
        uint32 productId;
        uint32 quoteId;
        int128 sizeIncrement;
        int128 minSize;
        ISpotEngine.Config config;
        RiskHelper.RiskStore riskStore;
    }

    struct PerpAddOrUpdateProductCall {
        uint32 productId;
        int128 sizeIncrement;
        int128 minSize;
        RiskHelper.RiskStore riskStore;
    }

    function submitSpotAddOrUpdateProductCall(
        uint32 productId,
        uint32 quoteId,
        int128 sizeIncrement,
        int128 minSize,
        ISpotEngine.Config calldata config,
        RiskHelper.RiskStore calldata riskStore
    ) external onlyDeployer {
        uint32[] memory pendingIds = pendingSpotAddOrUpdateProductIds();
        for (uint256 i = 0; i < pendingIds.length; i++) {
            require(
                productId != pendingIds[i],
                "trying to add or update a spot product twice."
            );
        }
        rawSpotAddOrUpdateProductCalls.push(
            abi.encode(
                SpotAddOrUpdateProductCall(
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

    function submitPerpAddOrUpdateProductCall(
        uint32 productId,
        int128 sizeIncrement,
        int128 minSize,
        RiskHelper.RiskStore calldata riskStore
    ) external onlyDeployer {
        uint32[] memory pendingIds = pendingPerpAddOrUpdateProductIds();
        for (uint256 i = 0; i < pendingIds.length; i++) {
            require(
                productId != pendingIds[i],
                "trying to add or update a perp product twice."
            );
        }
        rawPerpAddOrUpdateProductCalls.push(
            abi.encode(
                PerpAddOrUpdateProductCall(
                    productId,
                    sizeIncrement,
                    minSize,
                    riskStore
                )
            )
        );
    }

    function clearSpotAddOrUpdateProductCalls() external onlyDeployer {
        delete rawSpotAddOrUpdateProductCalls;
    }

    function clearPerpAddOrUpdateProductCalls() external onlyDeployer {
        delete rawPerpAddOrUpdateProductCalls;
    }

    function addOrUpdateProducts(
        uint32[] memory spotIds,
        uint32[] memory perpIds
    ) external onlyOwner {
        for (uint256 i = 0; i < rawSpotAddOrUpdateProductCalls.length; i++) {
            SpotAddOrUpdateProductCall memory call = abi.decode(
                rawSpotAddOrUpdateProductCalls[i],
                (SpotAddOrUpdateProductCall)
            );
            require(spotIds[i] == call.productId, "spot id doesn't match.");
            spotEngine.addOrUpdateProduct(
                call.productId,
                call.quoteId,
                call.sizeIncrement,
                call.minSize,
                call.config,
                call.riskStore
            );
        }
        delete rawSpotAddOrUpdateProductCalls;

        for (uint256 i = 0; i < rawPerpAddOrUpdateProductCalls.length; i++) {
            PerpAddOrUpdateProductCall memory call = abi.decode(
                rawPerpAddOrUpdateProductCalls[i],
                (PerpAddOrUpdateProductCall)
            );
            require(perpIds[i] == call.productId, "perp id doesn't match.");
            perpEngine.addOrUpdateProduct(
                call.productId,
                call.sizeIncrement,
                call.minSize,
                call.riskStore
            );
        }
        delete rawPerpAddOrUpdateProductCalls;
    }

    function pendingSpotAddOrUpdateProductIds()
        public
        view
        returns (uint32[] memory)
    {
        uint32[] memory productIds = new uint32[](
            rawSpotAddOrUpdateProductCalls.length
        );
        for (uint256 i = 0; i < rawSpotAddOrUpdateProductCalls.length; i++) {
            SpotAddOrUpdateProductCall memory call = abi.decode(
                rawSpotAddOrUpdateProductCalls[i],
                (SpotAddOrUpdateProductCall)
            );
            productIds[i] = call.productId;
        }
        return productIds;
    }

    function pendingPerpAddOrUpdateProductIds()
        public
        view
        returns (uint32[] memory)
    {
        uint32[] memory productIds = new uint32[](
            rawPerpAddOrUpdateProductCalls.length
        );
        for (uint256 i = 0; i < rawPerpAddOrUpdateProductCalls.length; i++) {
            PerpAddOrUpdateProductCall memory call = abi.decode(
                rawPerpAddOrUpdateProductCalls[i],
                (PerpAddOrUpdateProductCall)
            );
            productIds[i] = call.productId;
        }
        return productIds;
    }

    function hasPendingAddOrUpdateProductCalls() public view returns (bool) {
        return
            rawPerpAddOrUpdateProductCalls.length > 0 ||
            rawSpotAddOrUpdateProductCalls.length > 0;
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

    function depositInsurance(uint128 amount) external onlyOwner {
        IERC20Base quoteToken = IERC20Base(
            spotEngine.getToken(QUOTE_PRODUCT_ID)
        );

        quoteToken.approve(address(endpoint), uint256(amount));

        IEndpoint.DepositInsurance memory _txn = IEndpoint.DepositInsurance(
            amount
        );
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.DepositInsurance),
            abi.encode(_txn)
        );
        endpoint.submitSlowModeTransaction(txn);
    }

    function addNlpPool(address owner, uint128 balanceWeightX18)
        external
        onlyOwner
    {
        IEndpoint.AddNlpPool memory _txn = IEndpoint.AddNlpPool(
            owner,
            balanceWeightX18
        );
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.AddNlpPool),
            abi.encode(_txn)
        );
        endpoint.submitSlowModeTransaction(txn);
    }

    function updateNlpPool(
        uint64 poolId,
        address owner,
        uint128 balanceWeightX18
    ) external onlyOwner {
        IEndpoint.UpdateNlpPool memory _txn = IEndpoint.UpdateNlpPool(
            poolId,
            owner,
            balanceWeightX18
        );
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.UpdateNlpPool),
            abi.encode(_txn)
        );
        endpoint.submitSlowModeTransaction(txn);
    }

    function deleteNlpPool(uint64 poolId) external onlyOwner {
        IEndpoint.DeleteNlpPool memory _txn = IEndpoint.DeleteNlpPool(poolId);
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.DeleteNlpPool),
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

    function setSpreads(uint256 spreads) external onlyOwner {
        clearinghouse.setSpreads(spreads);
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

    function isDirectDepositV1Ready(address recipient, bool isFirstDeposit)
        external
        returns (bool)
    {
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
                (isFirstDeposit ? MIN_FIRST_DEPOSIT_AMOUNT : MIN_DEPOSIT_AMOUNT)
            ) {
                return true;
            }
        }
        return false;
    }

    function resetDirectDepositV1(bytes32 subaccount) external onlyOwner {
        directDepositV1Address[subaccount] = payable(0);
    }
}
