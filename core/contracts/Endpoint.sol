// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IOffchainExchange.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./EndpointGated.sol";
import "./EndpointTx.sol";
import "./EndpointStorage.sol";
import "./common/DeployerGuard.sol";
import "./common/Errors.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/IERC20Base.sol";
import "./interfaces/IVerifier.sol";
import "./interfaces/IProxyManager.sol";

// Gas spent by submitTransactionsChecked in verifier.requireValidSignature,
// which the gas probe (submitTransactionsCheckedWithGasLimit) cannot execute
// because no (e, s) signature exists at probe time. Steady-state worst case
// measured at ~51k (8-of-8 signers, cold storage slots; VerifierGasProbe
// test) plus the sequencer-check SLOAD, rounded up. Deliberately excludes
// the one-off aggregate-pubkey cache rebuild after a key rotation (up to
// ~950k), which is absorbed by the sequencer's gas-limit multiplier.
// Declared here rather than in common/Constants.sol so the bytecode
// (metadata hash) of unrelated contracts importing Constants.sol stays
// unchanged.
uint256 constant SIG_VERIFICATION_GAS_ESTIMATE = 60_000;

// solhint-disable-next-line max-states-count
contract Endpoint is
    DeployerGuard,
    EIP712Upgradeable,
    OwnableUpgradeable,
    EndpointStorage,
    IEndpoint
{
    using ERC20Helper for IERC20Base;

    function initialize(
        address _sanctions,
        address _sequencer,
        address _offchainExchange,
        IClearinghouse _clearinghouse,
        address _verifier,
        address _endpointTx
    ) external initializer onlyImplDeployer {
        __Ownable_init();
        __EIP712_init("Nado", "0.0.1");
        sequencer = _sequencer;
        clearinghouse = _clearinghouse;
        offchainExchange = _offchainExchange;
        verifier = IVerifier(_verifier);
        sanctions = ISanctionsList(_sanctions);
        endpointTx = _endpointTx;
        spotEngine = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        );
        perpEngine = IPerpEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        );
        slowModeConfig = SlowModeConfig({timeout: 0, txCount: 0, txUpTo: 0});
        priceX18[QUOTE_PRODUCT_ID] = ONE;

        if (nlpPools.length == 0) {
            nlpPools.push(
                NlpPool({
                    poolId: 0,
                    subaccount: N_ACCOUNT,
                    owner: address(0),
                    balanceWeightX18: uint128(ONE)
                })
            );
        }
    }

    function _delegatecallEndpointTx(bytes memory callData)
        internal
        returns (bytes memory)
    {
        require(endpointTx != address(0), "Endpoint Tx not set");
        (bool success, bytes memory result) = endpointTx.delegatecall(callData);
        if (!success) {
            if (result.length == 0) {
                revert();
            }
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    function validateSubmissionIdx(uint64 idx) private view {
        require(idx == nSubmissions, ERR_INVALID_SUBMISSION_INDEX);
    }

    function isValidDepositAmount(
        bytes32 subaccount,
        uint32 productId,
        uint128 amount
    ) internal returns (bool) {
        int256 minDepositAmount = MIN_DEPOSIT_AMOUNT;
        if (subaccount != X_ACCOUNT && (subaccountIds[subaccount] == 0)) {
            minDepositAmount = MIN_FIRST_DEPOSIT_AMOUNT;
        }
        return
            clearinghouse.checkMinDeposit(productId, amount, minDepositAmount);
    }

    function depositCollateral(
        bytes12 subaccountName,
        uint32 productId,
        uint128 amount
    ) external {
        bytes32 subaccount = bytes32(
            abi.encodePacked(msg.sender, subaccountName)
        );
        require(
            isValidDepositAmount(subaccount, productId, amount),
            ERR_DEPOSIT_TOO_SMALL
        );
        depositCollateralWithReferral(
            subaccount,
            productId,
            amount,
            DEFAULT_REFERRAL_CODE
        );
    }

    function depositCollateralWithReferral(
        bytes32 subaccount,
        uint32 productId,
        uint128 amount,
        string memory
    ) public {
        require(!RiskHelper.isIsolatedSubaccount(subaccount), ERR_UNAUTHORIZED);

        address sender = address(bytes20(subaccount));

        // depositor / depositee need to be unsanctioned
        requireUnsanctioned(msg.sender);
        requireUnsanctioned(sender);

        if (!isValidDepositAmount(subaccount, productId, amount)) {
            // we cannot revert here, otherwise direct deposit could be blocked when there are
            // multiple assets awaiting credit but one of them is below the minimum deposit amount.
            // we can just skip the deposit and continue with the next asset.
            return;
        }

        handleDepositTransfer(
            IERC20Base(spotEngine.getToken(productId)),
            msg.sender,
            uint256(amount)
        );
        // copy from submitSlowModeTransaction
        SlowModeConfig memory _slowModeConfig = slowModeConfig;

        slowModeTxs[_slowModeConfig.txCount++] = SlowModeTx({
            executableAt: uint64(block.timestamp) + SLOW_MODE_TX_DELAY, // hardcoded to three days
            sender: sender,
            tx: abi.encodePacked(
                uint8(TransactionType.DepositCollateral),
                abi.encode(
                    DepositCollateral({
                        sender: subaccount,
                        productId: productId,
                        amount: amount
                    })
                )
            )
        });
        slowModeConfig = _slowModeConfig;
    }

    function getNlpPools() external view returns (NlpPool[] memory) {
        return nlpPools;
    }

    function submitSlowModeTransaction(bytes calldata transaction)
        external
        virtual
    {
        _delegatecallEndpointTx(
            abi.encodeWithSelector(
                EndpointTx.submitSlowModeTransactionImpl.selector,
                transaction
            )
        );
    }

    function _executeSlowModeTransaction(
        SlowModeConfig memory _slowModeConfig,
        bool fromSequencer
    ) internal {
        require(
            _slowModeConfig.txUpTo < _slowModeConfig.txCount,
            ERR_NO_SLOW_MODE_TXS_REMAINING
        );
        SlowModeTx memory txn = slowModeTxs[_slowModeConfig.txUpTo];
        delete slowModeTxs[_slowModeConfig.txUpTo++];

        require(
            fromSequencer || (txn.executableAt <= block.timestamp),
            ERR_SLOW_TX_TOO_RECENT
        );

        if (block.chainid == 31337) {
            // for testing purposes, we don't fail silently when the chainId is hardhat's default.
            this.processSlowModeTransaction(txn.sender, txn.tx);
        } else {
            // EIP-150 forwards at most 63/64 of the remaining gas, so demand
            // the full budget plus overhead upfront: the inner call then
            // provably receives its entire budget, a failure can never be a
            // caller-induced out-of-gas, and the item is always safe to
            // consume. An under-gassed caller reverts here, before the queue
            // entry is touched.
            require(
                gasleft() >=
                    SLOW_MODE_GAS_BUDGET +
                        SLOW_MODE_GAS_BUDGET /
                        63 +
                        SLOW_MODE_GAS_BUFFER,
                ERR_INSUFFICIENT_GAS
            );
            try
                this.processSlowModeTransaction{gas: SLOW_MODE_GAS_BUDGET}(
                    txn.sender,
                    txn.tx
                )
            // solhint-disable-next-line no-empty-blocks
            {

            } catch {
                // failed within its guaranteed budget: the tx is defective,
                // skip it and let the queue advance
            }
        }
    }

    function executeSlowModeTransaction() external {
        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        _executeSlowModeTransaction(_slowModeConfig, false);
        nSubmissions += 1;
        slowModeConfig = _slowModeConfig;
    }

    function processSlowModeTransaction(
        address sender,
        bytes calldata transaction
    ) public virtual {
        require(msg.sender == address(this));

        _delegatecallEndpointTx(
            abi.encodeWithSelector(
                EndpointTx.processSlowModeTransactionImpl.selector,
                sender,
                transaction
            )
        );
    }

    function processTransaction(bytes calldata transaction) internal virtual {
        TransactionType txType = IEndpoint.TransactionType(
            uint8(transaction[0])
        );
        if (txType == TransactionType.ExecuteSlowMode) {
            SlowModeConfig memory _slowModeConfig = slowModeConfig;
            _executeSlowModeTransaction(_slowModeConfig, true);
            slowModeConfig = _slowModeConfig;
        } else {
            _delegatecallEndpointTx(
                abi.encodeWithSelector(
                    EndpointTx.processTransactionImpl.selector,
                    transaction
                )
            );
        }
    }

    function submitTransactionsChecked(
        uint64 idx,
        bytes[] calldata transactions,
        bytes32 e,
        bytes32 s,
        uint8 signerBitmask
    ) external {
        validateSubmissionIdx(idx);
        require(msg.sender == sequencer);
        // TODO: if one of these transactions fails this means the sequencer is in an error state
        // we should probably record this, and engage some sort of recovery mode

        bytes32 transactionsHash = keccak256(abi.encode(idx));
        for (uint256 i = 0; i < transactions.length; ++i) {
            transactionsHash = keccak256(
                abi.encodePacked(transactionsHash, transactions[i])
            );
        }
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    keccak256(
                        "SubmitTransactions(uint64 idx,bytes32 transactionsHash)"
                    ),
                    idx,
                    transactionsHash
                )
            )
        );
        verifier.requireValidSignature(digest, e, s, signerBitmask);

        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
            nSubmissions += 1;
        }
    }

    // Gas probe for submitTransactionsChecked: always reverts with the
    // measured gas via revertGasInfo. It must burn the same gas as the real
    // submission, so it mirrors the hash/digest computation and nSubmissions
    // writes; the verifier call is the one piece it cannot execute (no (e, s)
    // signature exists at probe time) and is accounted for by
    // SIG_VERIFICATION_GAS_ESTIMATE.
    function submitTransactionsCheckedWithGasLimit(
        uint64 idx,
        bytes[] calldata transactions,
        uint256 gasLimit
    ) external {
        uint256 initialGas = gasleft();
        validateSubmissionIdx(idx);

        bytes32 transactionsHash = keccak256(abi.encode(idx));
        for (uint256 i = 0; i < transactions.length; ++i) {
            transactionsHash = keccak256(
                abi.encodePacked(transactionsHash, transactions[i])
            );
        }
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    keccak256(
                        "SubmitTransactions(uint64 idx,bytes32 transactionsHash)"
                    ),
                    idx,
                    transactionsHash
                )
            )
        );
        // consumes the otherwise-unused digest; a keccak output is never zero
        require(digest != bytes32(0));

        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
            nSubmissions += 1;
            uint256 gasUsed = initialGas -
                gasleft() +
                SIG_VERIFICATION_GAS_ESTIMATE;
            if (gasUsed > gasLimit) {
                verifier.revertGasInfo(i, gasUsed);
            }
        }
        verifier.revertGasInfo(
            transactions.length,
            initialGas - gasleft() + SIG_VERIFICATION_GAS_ESTIMATE
        );
    }

    function setInitialPrice(uint32 productId, int128 initialPriceX18)
        external
    {
        require(
            msg.sender == address(spotEngine) ||
                msg.sender == address(perpEngine),
            ERR_UNAUTHORIZED
        );
        require(priceX18[productId] == 0, ERR_UNAUTHORIZED);
        priceX18[productId] = initialPriceX18;
    }

    function getSubaccountId(bytes32 subaccount)
        external
        view
        returns (uint64)
    {
        return subaccountIds[subaccount];
    }

    function getPriceX18(uint32 productId)
        public
        override
        returns (int128 _priceX18)
    {
        _priceX18 = priceX18[productId];
        require(_priceX18 != 0, ERR_INVALID_PRODUCT);
        emit PriceQuery(productId);
    }

    function getTime() external view returns (uint128) {
        Times memory t = times;
        uint128 _time = t.spotTime > t.perpTime ? t.spotTime : t.perpTime;
        require(_time != 0, ERR_INVALID_TIME);
        return _time;
    }

    function getOffchainExchange() external view returns (address) {
        return offchainExchange;
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

    function upgradeEndpointTx(address _endpointTx) external {
        require(
            msg.sender ==
                IProxyManager(_getProxyManager()).getProxyManagerHelper(),
            ERR_UNAUTHORIZED
        );
        endpointTx = _endpointTx;
    }

    function getEndpointTx() external view returns (address) {
        return endpointTx;
    }

    function getSequencer() external view returns (address) {
        return sequencer;
    }

    function getSlowModeTx(uint64 idx)
        external
        view
        returns (
            SlowModeTx memory,
            uint64,
            uint64
        )
    {
        return (
            slowModeTxs[idx],
            slowModeConfig.txUpTo,
            slowModeConfig.txCount
        );
    }

    function getNonce(address sender) external view returns (uint64) {
        return nonces[sender];
    }
}
