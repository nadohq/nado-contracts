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
import {DirectDepositV1, IIERC20Base} from "./DirectDepositV1.sol";
import "./interfaces/IERC20Base.sol";
import "./interfaces/IERC4626Base.sol";
import "./libraries/ERC20Helper.sol";
import "./common/Constants.sol";
import "./ContractOwnerStorage.sol";

contract ContractOwner is ContractOwnerStorage {
    error VenueOperatorUnavailable();
    using MathSD21x18 for int128;
    using ERC20Helper for IERC20Base;

    uint256 private constant RETIRED_VENUE_OPERATOR = type(uint256).max;

    event FeeCollectorUpdated(address indexed feeCollector);

    // accept ETH so withdrawFromDirectDepositV1 can receive native withdrawals
    receive() external payable {}

    // every selector ContractOwner does not implement runs in ContractOwnerExt
    // solhint-disable-next-line payable-fallback, no-complex-fallback
    fallback() external {
        address impl = contractOwnerExt;
        require(impl != address(0), "ContractOwner Ext not set");
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    function initialize(
        address multisig,
        address _deployer,
        address _spotEngine,
        address _perpEngine,
        address _endpoint,
        address _clearinghouse,
        address _verifier,
        address payable _wrappedNative,
        address _contractOwnerExt
    ) external initializer onlyImplDeployer {
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
        // recorded by ProxyManager when it registers this contract
        contractOwnerExt = _contractOwnerExt;
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        feeCollector = _feeCollector;
        emit FeeCollectorUpdated(_feeCollector);
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

    // the delegate runs with this contract's authority, so it changes only
    // through ProxyManager, which records the code hash of what it installs
    function upgradeContractOwnerExt(address _contractOwnerExt) external {
        require(
            msg.sender ==
                IProxyManager(_getProxyManager()).getProxyManagerHelper(),
            ERR_UNAUTHORIZED
        );
        contractOwnerExt = _contractOwnerExt;
    }

    function getContractOwnerExt() external view returns (address) {
        return contractOwnerExt;
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
            require(productId != pendingIds[i], "dup spot");
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
            require(productId != pendingIds[i], "dup perp");
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
            require(spotIds[i] == call.productId, "spot mismatch");
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
            require(perpIds[i] == call.productId, "perp mismatch");
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

    function updateVenue(uint32 venueId, address operator) external onlyOwner {
        uint256 state = venueOperatorStates[operator];
        if (state != 0 && state != venueId) revert VenueOperatorUnavailable();
        address current = venueOperators[venueId];
        if (current != operator) {
            venueOperatorStates[current] = RETIRED_VENUE_OPERATOR;
        }
        venueOperators[venueId] = operator;
        venueOperatorStates[operator] = venueId;
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.UpdateVenue,
            abi.encode(IEndpoint.UpdateVenue(venueId, operator))
        );
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

    function assignEcdsaSigner(uint256 i, address signer) public onlyOwner {
        verifier.assignEcdsaSigner(i, signer);
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
        require(
            getDirectDepositV1BytecodeHash() ==
                0x7974df41bdca2be1539fa7d01f41277f0d728823b20230a18a31e40c707874e7,
            "dda hash"
        );
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

    function wrapVaultAsset(bytes32 subaccount, uint32 productId) external {
        address payable directDepositV1 = directDepositV1Address[subaccount];
        if (directDepositV1 == address(0)) {
            directDepositV1 = createDirectDepositV1(subaccount);
        }

        address tokenAddr = spotEngine.getToken(productId);
        require(tokenAddr != address(0));

        address assetTokenAddr = IERC4626Base(tokenAddr).asset();
        require(assetTokenAddr != address(0));

        uint256 assetBalance = IERC20Base(assetTokenAddr).balanceOf(
            directDepositV1
        );
        if (IERC4626Base(tokenAddr).previewDeposit(assetBalance) != 0) {
            DirectDepositV1(directDepositV1).withdraw(
                IIERC20Base(assetTokenAddr)
            );
            IERC20Base assetToken = IERC20Base(assetTokenAddr);
            assetToken.approve(tokenAddr, 0);
            assetToken.approve(tokenAddr, assetBalance);
            IERC4626Base(tokenAddr).deposit(assetBalance, directDepositV1);
        }
    }

    function isWrapVaultAssetReady(
        address recipient,
        uint32 productId,
        bool isFirstDeposit
    ) external returns (bool) {
        address tokenAddr = spotEngine.getToken(productId);
        require(tokenAddr != address(0));

        address assetTokenAddr = IERC4626Base(tokenAddr).asset();
        require(assetTokenAddr != address(0));

        uint256 assetBalance = IERC20Base(assetTokenAddr).balanceOf(recipient);
        uint256 wrappedBalance = IERC4626Base(tokenAddr).previewDeposit(
            assetBalance
        );
        if (wrappedBalance != 0) {
            wrappedBalance *= 10**(18 - IERC20Base(tokenAddr).decimals());

            return
                _isDepositAmountReady(
                    productId,
                    wrappedBalance,
                    isFirstDeposit
                );
        }
        return false;
    }

    function isDirectDepositV1Ready(address recipient, bool isFirstDeposit)
        external
        returns (bool)
    {
        uint32[] memory productIds = spotEngine.getProductIds();
        for (uint256 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            address tokenAddr = spotEngine.getToken(productId);
            require(tokenAddr != address(0));

            IERC20Base token = IERC20Base(tokenAddr);
            uint256 balance = token.balanceOf(recipient);
            if (tokenAddr == wrappedNative) {
                balance += recipient.balance;
            }
            balance *= 10**(18 - token.decimals());
            if (_isDepositAmountReady(productId, balance, isFirstDeposit)) {
                return true;
            }
        }
        return false;
    }

    function _isDepositAmountReady(
        uint32 productId,
        uint256 balance,
        bool isFirstDeposit
    ) internal returns (bool) {
        int128 oraclePriceX18 = spotEngine.getRisk(productId).priceX18;
        if (oraclePriceX18 <= 0) {
            return false;
        }
        if (balance > INT128_MAX) {
            return true;
        }
        return
            oraclePriceX18.mul(int128(uint128(balance))) >=
            (isFirstDeposit ? MIN_FIRST_DEPOSIT_AMOUNT : MIN_DEPOSIT_AMOUNT);
    }

    function getDirectDepositV1BytecodeHash() public pure returns (bytes32) {
        return keccak256(type(DirectDepositV1).creationCode);
    }

    function replaceUsdcEWithUsdc(bytes32 subaccount) external {
        require(block.chainid == 57073, ERR_UNAUTHORIZED);
        address payable directDepositV1 = directDepositV1Address[subaccount];
        require(directDepositV1 != address(0), "no dda");
        address usdcE = 0xF1815bd50389c46847f0Bda824eC8da914045D14;
        address usdc = 0x2D270e6886d130D724215A266106e6832161EAEd;
        uint256 balance = IERC20Base(usdcE).balanceOf(directDepositV1);
        if (balance > 0) {
            IERC20Base(usdc).transferFrom(msg.sender, directDepositV1, balance);
            DirectDepositV1(directDepositV1).withdraw(IIERC20Base(usdcE));
            IERC20Base(usdcE).safeTransfer(msg.sender, balance);
        }
    }

    function withdrawFromDirectDepositV1(bytes32 subaccount, address token)
        external
        onlyOwner
    {
        address payable directDepositV1 = directDepositV1Address[subaccount];
        require(directDepositV1 != address(0), "no dda");
        if (token == address(0)) {
            uint256 preBalance = address(this).balance;
            DirectDepositV1(directDepositV1).withdrawNative();
            uint256 postBalance = address(this).balance;
            require(postBalance > preBalance, "empty");
            (bool success, ) = msg.sender.call{value: postBalance - preBalance}(
                ""
            );
            require(success, "xfer");
        } else {
            uint256 preBalance = IERC20Base(token).balanceOf(address(this));
            DirectDepositV1(directDepositV1).withdraw(IIERC20Base(token));
            uint256 postBalance = IERC20Base(token).balanceOf(address(this));
            require(postBalance > preBalance, "empty");
            IERC20Base(token).safeTransfer(
                msg.sender,
                postBalance - preBalance
            );
        }
    }
}
