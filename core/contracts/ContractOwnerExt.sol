// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./ContractOwnerStorage.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IERC20Base.sol";
import "./common/Constants.sol";

// Reached only through ContractOwner's fallback, by delegatecall, so it runs
// on ContractOwner's storage and as ContractOwner. Deployed alone it holds no
// owner, deployer or fee collector, so every function here refuses.
contract ContractOwnerExt is ContractOwnerStorage {
    function withdrawInsurance(uint128 amount, address sendTo)
        external
        onlyOwner
    {
        IEndpoint.WithdrawInsurance memory _txn = IEndpoint.WithdrawInsurance(
            amount,
            sendTo
        );
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.WithdrawInsurance,
            abi.encode(_txn)
        );
    }

    function depositInsurance(uint128 amount) external onlyOwner {
        IERC20Base quoteToken = IERC20Base(
            spotEngine.getToken(QUOTE_PRODUCT_ID)
        );

        quoteToken.approve(address(endpoint), uint256(amount));

        IEndpoint.DepositInsurance memory _txn = IEndpoint.DepositInsurance(
            amount
        );
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.DepositInsurance,
            abi.encode(_txn)
        );
    }

    function updateBuilders(
        uint32[] calldata builderIds,
        address[] calldata owners,
        uint32[] calldata defaultFeeTiers,
        int128[] calldata lowestFeeRates,
        int128[] calldata highestFeeRates
    ) external onlyOwner {
        if (
            builderIds.length != owners.length ||
            builderIds.length != defaultFeeTiers.length ||
            builderIds.length != lowestFeeRates.length ||
            builderIds.length != highestFeeRates.length
        ) {
            revert InvalidInput();
        }
        for (uint256 i = 0; i < builderIds.length; i++) {
            IEndpoint.UpdateBuilder memory _txn = IEndpoint.UpdateBuilder(
                builderIds[i],
                owners[i],
                defaultFeeTiers[i],
                lowestFeeRates[i],
                highestFeeRates[i]
            );
            _submitSlowModeTransaction(
                IEndpoint.TransactionType.UpdateBuilder,
                abi.encode(_txn)
            );
        }
    }

    function addNlpPool(address owner, uint128 balanceWeightX18)
        external
        onlyOwner
    {
        IEndpoint.AddNlpPool memory _txn = IEndpoint.AddNlpPool(
            owner,
            balanceWeightX18
        );
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.AddNlpPool,
            abi.encode(_txn)
        );
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
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.UpdateNlpPool,
            abi.encode(_txn)
        );
    }

    function deleteNlpPool(uint64 poolId) external onlyOwner {
        IEndpoint.DeleteNlpPool memory _txn = IEndpoint.DeleteNlpPool(poolId);
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.DeleteNlpPool,
            abi.encode(_txn)
        );
    }

    function forceRebalanceNlpPool(int128[] calldata nlpPoolRebalanceX18)
        external
        onlyOwner
    {
        IEndpoint.ForceRebalanceNlpPool memory _txn = IEndpoint
            .ForceRebalanceNlpPool(nlpPoolRebalanceX18);
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.ForceRebalanceNlpPool,
            abi.encode(_txn)
        );
    }

    function nlpProfitShare(
        uint64 poolId,
        bytes32 recipient,
        uint128 amount
    ) external onlyOwner {
        IEndpoint.NlpProfitShare memory _txn = IEndpoint.NlpProfitShare(
            poolId,
            recipient,
            amount
        );
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.NlpProfitShare,
            abi.encode(_txn)
        );
    }

    function delistProduct(
        uint32[] calldata productIds,
        int128[] calldata pricesX18,
        bytes32[] calldata subaccounts
    ) external onlyDeployer {
        if (productIds.length != pricesX18.length) {
            revert InvalidInput();
        }
        for (uint256 i = 0; i < productIds.length; i++) {
            IEndpoint.DelistProduct memory _txn = IEndpoint.DelistProduct(
                productIds[i],
                pricesX18[i],
                subaccounts
            );
            _submitSlowModeTransaction(
                IEndpoint.TransactionType.DelistProduct,
                abi.encode(_txn)
            );
        }
    }

    function dumpFees() external onlyOwnerOrFeeCollector {
        bytes memory txn = abi.encodePacked(
            uint8(IEndpoint.TransactionType.DumpFees)
        );
        endpoint.submitSlowModeTransaction(txn);
    }

    function rebalanceXWithdraw(
        uint32 productId,
        uint128 amount,
        address sendTo
    ) external onlyOwnerOrFeeCollector {
        IEndpoint.RebalanceXWithdraw memory _txn = IEndpoint.RebalanceXWithdraw(
            productId,
            amount,
            sendTo
        );
        _submitSlowModeTransaction(
            IEndpoint.TransactionType.RebalanceXWithdraw,
            abi.encode(_txn)
        );
    }

    function updateTierFeeRates(
        uint32[] memory tier,
        uint32[] memory productId,
        int128[] memory makerRateX18,
        int128[] memory takerRateX18
    ) external onlyOwner {
        if (
            tier.length != productId.length ||
            tier.length != makerRateX18.length ||
            tier.length != takerRateX18.length
        ) {
            revert InvalidInput();
        }
        for (uint256 i = 0; i < tier.length; i++) {
            IEndpoint.UpdateTierFeeRates memory _txn = IEndpoint
                .UpdateTierFeeRates(
                    tier[i],
                    productId[i],
                    makerRateX18[i],
                    takerRateX18[i]
                );
            _submitSlowModeTransaction(
                IEndpoint.TransactionType.UpdateTierFeeRates,
                abi.encode(_txn)
            );
        }
    }
}
