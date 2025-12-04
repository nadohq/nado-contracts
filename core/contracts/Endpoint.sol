// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IOffchainExchange.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./EndpointGated.sol";
import "./common/Errors.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/IERC20Base.sol";
import "./interfaces/IVerifier.sol";

interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

// solhint-disable-next-line max-states-count
contract Endpoint is IEndpoint, EIP712Upgradeable, OwnableUpgradeable {
    using ERC20Helper for IERC20Base;

    IClearinghouse public clearinghouse;
    ISpotEngine private spotEngine;
    IPerpEngine private perpEngine;
    ISanctionsList private sanctions;

    address internal sequencer;
    int128 private sequencerFees;

    mapping(bytes32 => uint64) internal subaccountIds;
    mapping(uint64 => bytes32) internal subaccounts;
    uint64 internal numSubaccounts;

    mapping(address => uint64) internal nonces;

    uint64 public nSubmissions;

    SlowModeConfig internal slowModeConfig;
    mapping(uint64 => SlowModeTx) internal slowModeTxs;

    struct Times {
        uint128 perpTime;
        uint128 spotTime;
    }

    Times internal times;

    mapping(uint32 => int128) internal sequencerFee;

    mapping(bytes32 => address) internal linkedSigners;

    mapping(bytes32 => address) internal nlpSigners;
    NlpPool[] public nlpPools;

    int128 private slowModeFees;

    // invitee -> referralCode
    mapping(address => string) public referralCodes; // deprecated

    mapping(uint32 => int128) internal priceX18;
    address internal offchainExchange;

    IVerifier private verifier;

    function initialize(
        address _sanctions,
        address _sequencer,
        address _offchainExchange,
        IClearinghouse _clearinghouse,
        address _verifier
    ) external initializer {
        __Ownable_init();
        __EIP712_init("Nado", "0.0.1");
        sequencer = _sequencer;
        clearinghouse = _clearinghouse;
        offchainExchange = _offchainExchange;
        verifier = IVerifier(_verifier);
        sanctions = ISanctionsList(_sanctions);
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

    function _recordSubaccount(bytes32 subaccount) internal {
        if (subaccountIds[subaccount] == 0) {
            subaccountIds[subaccount] = ++numSubaccounts;
            subaccounts[numSubaccounts] = subaccount;
        }
    }

    function requireSubaccount(bytes32 subaccount) private view {
        require(
            subaccount == X_ACCOUNT ||
                subaccount == N_ACCOUNT ||
                (subaccountIds[subaccount] != 0),
            ERR_REQUIRES_DEPOSIT
        );
    }

    function validateSubmissionIdx(uint64 idx) private view {
        require(idx == nSubmissions, ERR_INVALID_SUBMISSION_INDEX);
    }

    function validateNonce(bytes32 sender, uint64 nonce) internal virtual {
        require(
            nonce == nonces[address(uint160(bytes20(sender)))]++,
            ERR_WRONG_NONCE
        );
    }

    function chargeFee(bytes32 sender, int128 fee) internal {
        chargeFee(sender, fee, QUOTE_PRODUCT_ID);
    }

    function chargeFee(
        bytes32 sender,
        int128 fee,
        uint32 productId
    ) internal {
        spotEngine.updateBalance(productId, sender, -fee);
        sequencerFee[productId] += fee;
    }

    function chargeSlowModeFee(IERC20Base token, address from)
        internal
        virtual
    {
        require(address(token) != address(0));
        token.safeTransferFrom(
            from,
            address(this),
            clearinghouse.getSlowModeFee()
        );
    }

    function getLinkedSigner(bytes32 subaccount)
        public
        view
        virtual
        returns (address)
    {
        return
            RiskHelper.isIsolatedSubaccount(subaccount)
                ? linkedSigners[
                    IOffchainExchange(offchainExchange).getParentSubaccount(
                        subaccount
                    )
                ]
                : linkedSigners[subaccount];
    }

    function getLinkedSignerOrNlpSigner(bytes32 subaccount)
        internal
        view
        virtual
        returns (address)
    {
        address linkedSigner = getLinkedSigner(subaccount);
        if (linkedSigner != address(0)) {
            return linkedSigner;
        }
        return nlpSigners[subaccount];
    }

    function validateSignature(
        bytes32 sender,
        bytes32 digest,
        bytes memory signature
    ) internal virtual {
        verifier.validateSignature(
            sender,
            getLinkedSigner(sender),
            digest,
            signature
        );
    }

    function computeDigest(
        TransactionType txType,
        bytes calldata transactionBody
    ) internal view virtual returns (bytes32) {
        return verifier.computeDigest(txType, transactionBody);
    }

    function safeTransferFrom(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal virtual {
        token.safeTransferFrom(from, address(this), amount);
    }

    function safeTransferTo(
        IERC20Base token,
        address to,
        uint256 amount
    ) internal virtual {
        token.safeTransfer(to, amount);
    }

    function handleDepositTransfer(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal {
        require(address(token) != address(0), ERR_INVALID_PRODUCT);
        safeTransferFrom(token, from, amount);
        safeTransferTo(token, address(clearinghouse), amount);
    }

    function validateSender(bytes32 txSender, address sender) internal view {
        require(
            address(uint160(bytes20(txSender))) == sender ||
                sender == address(this),
            ERR_SLOW_MODE_WRONG_SENDER
        );
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

    function addNlpPool(address owner, uint128 balanceWeightX18) private {
        uint64 poolId = uint64(nlpPools.length);

        bytes32 subaccount = NLP_POOL_ACCOUNT_START;
        if (nlpPools.length > 1) {
            subaccount = bytes32(
                uint256(nlpPools[nlpPools.length - 1].subaccount) + 1
            );
        }
        _recordSubaccount(subaccount);

        nlpPools.push(
            NlpPool({
                poolId: poolId,
                subaccount: subaccount,
                owner: owner,
                balanceWeightX18: balanceWeightX18
            })
        );
        nlpSigners[subaccount] = owner;
    }

    function updateNlpPool(
        uint64 poolId,
        address owner,
        uint128 balanceWeightX18
    ) private {
        require(poolId < nlpPools.length, ERR_INVALID_NLP_POOL);
        if (poolId == 0) {
            require(owner == address(0), "cannot set owner for pool 0.");
            require(
                balanceWeightX18 > 0,
                "cannot set 0 balance weight for pool 0."
            );
        }
        nlpPools[poolId].owner = owner;
        nlpPools[poolId].balanceWeightX18 = balanceWeightX18;
        nlpSigners[nlpPools[poolId].subaccount] = owner;
    }

    function deleteNlpPool(uint64 poolId) private {
        require(poolId > 0 && poolId < nlpPools.length, ERR_INVALID_NLP_POOL);
        clearinghouse.clearNlpPoolPosition(nlpPools[poolId].subaccount);
        updateNlpPool(poolId, address(0), uint128(0));
    }

    function getNlpPools() external view returns (NlpPool[] memory) {
        return nlpPools;
    }

    function requireUnsanctioned(address sender) internal view virtual {
        require(!sanctions.isSanctioned(sender), ERR_WALLET_SANCTIONED);
    }

    function submitSlowModeTransaction(bytes calldata transaction) external {
        TransactionType txType = TransactionType(uint8(transaction[0]));

        // special case for DepositCollateral because upon
        // slow mode submission we must take custody of the
        // actual funds

        address sender = msg.sender;

        if (txType == TransactionType.DepositCollateral) {
            revert();
        } else if (txType == TransactionType.DepositInsurance) {
            DepositInsurance memory txn = abi.decode(
                transaction[1:],
                (DepositInsurance)
            );
            require(
                txn.amount >= uint128(SLOW_MODE_FEE),
                ERR_DEPOSIT_TOO_SMALL
            );
            handleDepositTransfer(_getQuote(), sender, uint256(txn.amount));
        } else if (
            txType == TransactionType.WithdrawInsurance ||
            txType == TransactionType.DelistProduct ||
            txType == TransactionType.DumpFees ||
            txType == TransactionType.RebalanceXWithdraw ||
            txType == TransactionType.UpdateTierFeeRates ||
            txType == TransactionType.AddNlpPool ||
            txType == TransactionType.UpdateNlpPool ||
            txType == TransactionType.DeleteNlpPool
        ) {
            require(sender == owner());
        } else {
            chargeSlowModeFee(_getQuote(), sender);
            slowModeFees += SLOW_MODE_FEE;
        }

        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        requireUnsanctioned(sender);
        slowModeTxs[_slowModeConfig.txCount++] = SlowModeTx({
            executableAt: uint64(block.timestamp) + SLOW_MODE_TX_DELAY, // hardcoded to three days
            sender: sender,
            tx: transaction
        });
        // TODO: to save on costs we could potentially just emit something
        // for now, we can just create a separate loop in the engine that queries the remote
        // sequencer for slow mode transactions, and ignore the possibility of a reorgy attack
        slowModeConfig = _slowModeConfig;
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
            uint256 gasRemaining = gasleft();
            // solhint-disable-next-line no-empty-blocks
            try this.processSlowModeTransaction(txn.sender, txn.tx) {} catch {
                // we need to differentiate between a revert and an out of gas
                // the issue is that in evm every inner call only 63/64 of the
                // remaining gas in the outer frame is forwarded. as a result
                // the amount of gas left for execution is (63/64)**len(stack)
                // and you can get an out of gas while spending an arbitrarily
                // low amount of gas in the final frame. we use a heuristic
                // here that isn't perfect but covers our cases.
                // having gasleft() <= gasRemaining / 2 buys us 44 nested calls
                // before we miss out of gas errors; 1/2 ~= (63/64)**44
                // this is good enough for our purposes

                if (gasleft() <= 250000 || gasleft() <= gasRemaining / 2) {
                    // solhint-disable-next-line no-inline-assembly
                    assembly {
                        invalid()
                    }
                }

                // try return funds now removed
            }
        }
    }

    function executeSlowModeTransaction() external {
        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        _executeSlowModeTransaction(_slowModeConfig, false);
        nSubmissions += 1;
        slowModeConfig = _slowModeConfig;
    }

    // TODO: these do not need senders or nonces
    // we can save some gas by creating new structs
    function processSlowModeTransaction(
        address sender,
        bytes calldata transaction
    ) public {
        require(msg.sender == address(this));
        TransactionType txType = TransactionType(uint8(transaction[0]));
        if (txType == TransactionType.DepositCollateral) {
            DepositCollateral memory txn = abi.decode(
                transaction[1:],
                (DepositCollateral)
            );
            validateSender(txn.sender, sender);
            _recordSubaccount(txn.sender);
            clearinghouse.depositCollateral(txn);
        } else if (txType == TransactionType.WithdrawCollateral) {
            WithdrawCollateral memory txn = abi.decode(
                transaction[1:],
                (WithdrawCollateral)
            );
            validateSender(txn.sender, sender);
            clearinghouse.withdrawCollateral(
                txn.sender,
                txn.productId,
                txn.amount,
                address(0),
                nSubmissions
            );
        } else if (txType == TransactionType.DepositInsurance) {
            clearinghouse.depositInsurance(transaction);
        } else if (txType == TransactionType.LinkSigner) {
            LinkSigner memory txn = abi.decode(transaction[1:], (LinkSigner));
            validateSender(txn.sender, sender);
            requireSubaccount(txn.sender);
            linkedSigners[txn.sender] = address(uint160(bytes20(txn.signer)));
        } else if (txType == TransactionType.WithdrawInsurance) {
            clearinghouse.withdrawInsurance(transaction, nSubmissions);
        } else if (txType == TransactionType.DelistProduct) {
            clearinghouse.delistProduct(transaction);
        } else if (txType == TransactionType.DumpFees) {
            IOffchainExchange(offchainExchange).dumpFees();
            uint32[] memory spotIds = spotEngine.getProductIds();
            int128[] memory fees = new int128[](spotIds.length);
            for (uint256 i = 0; i < spotIds.length; i++) {
                fees[i] = sequencerFee[spotIds[i]];
                sequencerFee[spotIds[i]] = 0;
            }
            requireSubaccount(X_ACCOUNT);
            clearinghouse.claimSequencerFees(fees);
        } else if (txType == TransactionType.RebalanceXWithdraw) {
            clearinghouse.rebalanceXWithdraw(transaction, nSubmissions);
        } else if (txType == TransactionType.UpdateTierFeeRates) {
            UpdateTierFeeRates memory txn = abi.decode(
                transaction[1:],
                (UpdateTierFeeRates)
            );
            IOffchainExchange(offchainExchange).updateTierFeeRates(txn);
        } else if (txType == TransactionType.AddNlpPool) {
            AddNlpPool memory txn = abi.decode(transaction[1:], (AddNlpPool));
            addNlpPool(txn.owner, txn.balanceWeightX18);
        } else if (txType == TransactionType.UpdateNlpPool) {
            UpdateNlpPool memory txn = abi.decode(
                transaction[1:],
                (UpdateNlpPool)
            );
            updateNlpPool(txn.poolId, txn.owner, txn.balanceWeightX18);
        } else if (txType == TransactionType.DeleteNlpPool) {
            DeleteNlpPool memory txn = abi.decode(
                transaction[1:],
                (DeleteNlpPool)
            );
            deleteNlpPool(txn.poolId);
        } else {
            revert();
        }
    }

    function processTransaction(bytes calldata transaction) internal {
        TransactionType txType = TransactionType(uint8(transaction[0]));
        if (txType == TransactionType.LiquidateSubaccount) {
            SignedLiquidateSubaccount memory signedTx = abi.decode(
                transaction[1:],
                (SignedLiquidateSubaccount)
            );
            if (signedTx.tx.sender != N_ACCOUNT) {
                validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
                validateSignature(
                    signedTx.tx.sender,
                    _hashTypedDataV4(computeDigest(txType, transaction[1:])),
                    signedTx.signature
                );
                requireSubaccount(signedTx.tx.sender);
                // No liquidation fee for finalization (productId == uint32.max) because:
                // 1) The liquidator receives no profit from finalization
                // 2) Finalization can only occur once per underwater subaccount, eliminating
                //    sybil attack concerns that would otherwise require a fee deterrent.
                if (signedTx.tx.productId != type(uint32).max) {
                    chargeFee(signedTx.tx.sender, LIQUIDATION_FEE);
                }
            }
            clearinghouse.liquidateSubaccount(signedTx.tx);
        } else if (txType == TransactionType.WithdrawCollateral) {
            SignedWithdrawCollateral memory signedTx = abi.decode(
                transaction[1:],
                (SignedWithdrawCollateral)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(computeDigest(txType, transaction[1:])),
                signedTx.signature
            );
            chargeFee(
                signedTx.tx.sender,
                spotEngine.getConfig(signedTx.tx.productId).withdrawFeeX18,
                signedTx.tx.productId
            );
            clearinghouse.withdrawCollateral(
                signedTx.tx.sender,
                signedTx.tx.productId,
                signedTx.tx.amount,
                address(0),
                nSubmissions
            );
        } else if (txType == TransactionType.SpotTick) {
            SpotTick memory txn = abi.decode(transaction[1:], (SpotTick));
            Times memory t = times;
            uint128 dt = t.spotTime == 0 ? 0 : txn.time - t.spotTime;
            spotEngine.updateStates(dt);
            t.spotTime = txn.time;
            times = t;
        } else if (txType == TransactionType.PerpTick) {
            PerpTick memory txn = abi.decode(transaction[1:], (PerpTick));
            Times memory t = times;
            uint128 dt = t.perpTime == 0 ? 0 : txn.time - t.perpTime;
            perpEngine.updateStates(dt, txn.avgPriceDiffs);
            t.perpTime = txn.time;
            times = t;
        } else if (txType == TransactionType.UpdatePrice) {
            (uint32 productId, int128 newPriceX18) = clearinghouse.updatePrice(
                transaction
            );
            if (productId != 0) {
                priceX18[productId] = newPriceX18;
            }
        } else if (txType == TransactionType.SettlePnl) {
            clearinghouse.settlePnl(transaction);
        } else if (txType == TransactionType.MatchOrders) {
            MatchOrders memory txn = abi.decode(transaction[1:], (MatchOrders));
            requireSubaccount(txn.taker.order.sender);
            requireSubaccount(txn.maker.order.sender);

            MatchOrdersWithSigner memory txnWithSigner = MatchOrdersWithSigner({
                matchOrders: txn,
                takerLinkedSigner: getLinkedSignerOrNlpSigner(
                    txn.taker.order.sender
                ),
                makerLinkedSigner: getLinkedSignerOrNlpSigner(
                    txn.maker.order.sender
                ),
                takerAmountDelta: 0
            });
            IOffchainExchange(offchainExchange).matchOrders(txnWithSigner);
        } else if (txType == TransactionType.MatchOrdersWithAmount) {
            MatchOrdersWithAmount memory txn = abi.decode(
                transaction[1:],
                (MatchOrdersWithAmount)
            );
            requireSubaccount(txn.matchOrders.taker.order.sender);
            requireSubaccount(txn.matchOrders.maker.order.sender);
            MatchOrdersWithSigner memory txnWithSigner = MatchOrdersWithSigner({
                matchOrders: txn.matchOrders,
                takerLinkedSigner: getLinkedSignerOrNlpSigner(
                    txn.matchOrders.taker.order.sender
                ),
                makerLinkedSigner: getLinkedSignerOrNlpSigner(
                    txn.matchOrders.maker.order.sender
                ),
                takerAmountDelta: txn.takerAmountDelta
            });
            IOffchainExchange(offchainExchange).matchOrders(txnWithSigner);
        } else if (txType == TransactionType.ExecuteSlowMode) {
            SlowModeConfig memory _slowModeConfig = slowModeConfig;
            _executeSlowModeTransaction(_slowModeConfig, true);
            slowModeConfig = _slowModeConfig;
        } else if (txType == TransactionType.MintNlp) {
            SignedMintNlp memory signedTx = abi.decode(
                transaction[1:],
                (SignedMintNlp)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(computeDigest(txType, transaction[1:])),
                signedTx.signature
            );
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            priceX18[NLP_PRODUCT_ID] = signedTx.oraclePriceX18;
            clearinghouse.mintNlp(
                signedTx.tx,
                signedTx.oraclePriceX18,
                nlpPools,
                signedTx.nlpPoolRebalanceX18
            );
        } else if (txType == TransactionType.BurnNlp) {
            SignedBurnNlp memory signedTx = abi.decode(
                transaction[1:],
                (SignedBurnNlp)
            );
            requireSubaccount(signedTx.tx.sender);
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(computeDigest(txType, transaction[1:])),
                signedTx.signature
            );
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            priceX18[NLP_PRODUCT_ID] = signedTx.oraclePriceX18;
            clearinghouse.burnNlp(
                signedTx.tx,
                signedTx.oraclePriceX18,
                nlpPools,
                signedTx.nlpPoolRebalanceX18
            );
        } else if (txType == TransactionType.ManualAssert) {
            clearinghouse.manualAssert(transaction);
        } else if (txType == TransactionType.LinkSigner) {
            SignedLinkSigner memory signedTx = abi.decode(
                transaction[1:],
                (SignedLinkSigner)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(computeDigest(txType, transaction[1:])),
                signedTx.signature
            );
            linkedSigners[signedTx.tx.sender] = address(
                uint160(bytes20(signedTx.tx.signer))
            );
        } else if (txType == TransactionType.UpdateFeeTier) {
            clearinghouse.updateFeeTier(transaction);
        } else if (txType == TransactionType.TransferQuote) {
            SignedTransferQuote memory signedTx = abi.decode(
                transaction[1:],
                (SignedTransferQuote)
            );
            _recordSubaccount(signedTx.tx.recipient);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(computeDigest(txType, transaction[1:])),
                signedTx.signature
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            clearinghouse.transferQuote(signedTx.tx);
        } else if (txType == TransactionType.AssertCode) {
            clearinghouse.assertCode(transaction);
        } else if (txType == TransactionType.AssertProduct) {
            IOffchainExchange(offchainExchange).assertProduct(transaction);
        } else if (txType == TransactionType.CreateIsolatedSubaccount) {
            CreateIsolatedSubaccount memory txn = abi.decode(
                transaction[1:],
                (CreateIsolatedSubaccount)
            );
            bytes32 newIsolatedSubaccount = IOffchainExchange(offchainExchange)
                .createIsolatedSubaccount(
                    txn,
                    getLinkedSigner(txn.order.sender)
                );
            _recordSubaccount(newIsolatedSubaccount);
        } else if (txType == TransactionType.CloseIsolatedSubaccount) {
            CloseIsolatedSubaccount memory txn = abi.decode(
                transaction[1:],
                (CloseIsolatedSubaccount)
            );
            IOffchainExchange(offchainExchange).tryCloseIsolatedSubaccount(
                txn.subaccount
            );
        } else {
            revert();
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

        bytes32 digest = keccak256(abi.encode(idx));
        for (uint256 i = 0; i < transactions.length; ++i) {
            digest = keccak256(abi.encodePacked(digest, transactions[i]));
        }
        verifier.requireValidSignature(digest, e, s, signerBitmask);

        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
            nSubmissions += 1;
        }
    }

    function submitTransactionsCheckedWithGasLimit(
        uint64 idx,
        bytes[] calldata transactions,
        uint256 gasLimit
    ) external {
        uint256 initialGas = gasleft();
        validateSubmissionIdx(idx);
        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
            uint256 gasUsed = initialGas - gasleft();
            if (gasUsed > gasLimit) {
                verifier.revertGasInfo(i, gasUsed);
            }
        }
        verifier.revertGasInfo(transactions.length, initialGas - gasleft());
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

    function _getQuote() internal view returns (IERC20Base) {
        return IERC20Base(spotEngine.getToken(QUOTE_PRODUCT_ID));
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
