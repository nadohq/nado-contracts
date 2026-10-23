// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./EndpointStorage.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IOffchainExchange.sol";
import "./interfaces/IERC20Base.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MatchOrdersV2Helper.sol";

contract EndpointTx is EIP712Upgradeable, OwnableUpgradeable, EndpointStorage {
    using ERC20Helper for IERC20Base;

    function validateSender(bytes32 txSender, address sender) internal view {
        require(
            address(uint160(bytes20(txSender))) == sender ||
                sender == address(this),
            ERR_SLOW_MODE_WRONG_SENDER
        );
    }

    function _getQuote() internal view returns (IERC20Base) {
        return IERC20Base(spotEngine.getToken(QUOTE_PRODUCT_ID));
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
            IEndpoint.NlpPool({
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
        require(poolId < nlpPools.length);
        if (poolId == 0) {
            require(owner == address(0));
            require(balanceWeightX18 > 0);
        }
        nlpPools[poolId].owner = owner;
        nlpPools[poolId].balanceWeightX18 = balanceWeightX18;
        nlpSigners[nlpPools[poolId].subaccount] = owner;
    }

    function deleteNlpPool(uint64 poolId) private {
        require(poolId > 0 && poolId < nlpPools.length);
        clearinghouse.clearNlpPoolPosition(nlpPools[poolId].subaccount);
        updateNlpPool(poolId, address(0), uint128(0));
    }

    function validateNonce(bytes32 sender, uint64 nonce) internal virtual {
        require(
            nonce == nonces[address(uint160(bytes20(sender)))]++,
            ERR_WRONG_NONCE
        );
    }

    function venueVaultSubaccount(uint32 venueId)
        internal
        pure
        returns (bytes32)
    {
        return bytes32((uint256(3) << 32) | uint256(venueId));
    }

    function isVenueVault(bytes32 subaccount) internal pure returns (bool) {
        return (uint256(subaccount) >> 32) == 3;
    }

    function updateVenue(uint32 venueId, address operator) private {
        require(venueId != 0, ERR_UNAUTHORIZED);
        if (venues.length == 0) {
            // Slot 0 is core so that venueId == array index.
            venues.push(
                IEndpoint.Venue({
                    venueId: 0,
                    subaccount: bytes32(0),
                    operator: address(0)
                })
            );
        }
        if (venueId == venues.length) {
            bytes32 vault = venueVaultSubaccount(venueId);
            _recordSubaccount(vault);
            venues.push(
                IEndpoint.Venue({
                    venueId: venueId,
                    subaccount: vault,
                    operator: operator
                })
            );
        } else {
            require(venueId < venues.length, ERR_UNAUTHORIZED);
            venues[venueId].operator = operator;
        }
    }

    function getRegisteredVenue(uint32 venueId)
        internal
        view
        returns (IEndpoint.Venue memory venue)
    {
        require(
            venueId != 0 && venueId < venues.length,
            ERR_VENUE_NOT_REGISTERED
        );
        venue = venues[venueId];
        require(venue.operator != address(0), ERR_VENUE_NOT_REGISTERED);
    }

    function venueTransferBalance(
        bytes32 from,
        bytes32 to,
        uint128 amount
    ) internal {
        require(amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        int128 toTransfer = int128(amount);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, from, -toTransfer);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, to, toTransfer);
        // Same rule as Clearinghouse._isAboveInitial: a depositing user cannot
        // strip margin below initial, and a vault (quote-only) cannot overdraw.
        require(
            clearinghouse.getHealth(from, IProductEngine.HealthType.INITIAL) >=
                0,
            ERR_SUBACCT_HEALTH
        );
    }

    function executeVenueDeposit(bytes calldata transaction) internal {
        IEndpoint.SignedVenueDeposit memory signedTx = abi.decode(
            transaction[1:],
            (IEndpoint.SignedVenueDeposit)
        );
        IEndpoint.VenueDeposit memory txn = signedTx.tx;
        require(txn.productId == QUOTE_PRODUCT_ID, ERR_INVALID_PRODUCT);
        require(!isVenueVault(txn.sender), ERR_UNAUTHORIZED);
        require(!RiskHelper.isIsolatedSubaccount(txn.sender), ERR_UNAUTHORIZED);
        IEndpoint.Venue memory venue = getRegisteredVenue(txn.venueId);

        validateFee(signedTx.feeX18, txn.productId);
        // No sanction check here: the sanctions oracle mutates outside the
        // engine's fork, so an in-contract check would desync engine and
        // chain; the gateway screens instead.
        validateSignedTx(
            txn.sender,
            txn.nonce,
            transaction,
            signedTx.signature,
            true
        );
        chargeFee(txn.sender, signedTx.feeX18, txn.productId);
        _recordSubaccount(venue.subaccount);
        venueTransferBalance(txn.sender, venue.subaccount, txn.amount);
    }

    function executeVenueTransfer(bytes calldata transaction) internal {
        IEndpoint.SignedVenueTransfer memory signedTx = abi.decode(
            transaction[1:],
            (IEndpoint.SignedVenueTransfer)
        );
        IEndpoint.VenueTransfer memory txn = signedTx.tx;
        require(txn.productId == QUOTE_PRODUCT_ID, ERR_INVALID_PRODUCT);
        require(txn.fromVenueId != txn.toVenueId, ERR_UNAUTHORIZED);
        // v1 gate: transfers may only target core; lift to enable direct
        // venue<->venue.
        require(txn.toVenueId == 0, ERR_UNAUTHORIZED);

        IEndpoint.Venue memory venue = getRegisteredVenue(txn.fromVenueId);
        // The tx carries no sender: the recovered signer must be the from
        // venue's registered operator, which also keys the nonce stream.
        // Funds move from the registry vault and the fee follows the funds.
        bytes32 operator = bytes32(bytes20(venue.operator));
        validateFee(signedTx.feeX18, txn.productId);
        validateNonce(operator, txn.nonce);
        validateCompactSignature(
            operator,
            _hashTypedDataV4(
                computeDigest(
                    IEndpoint.TransactionType(uint8(transaction[0])),
                    transaction[1:]
                )
            ),
            signedTx.signature,
            false
        );

        bytes32 to;
        if (txn.toVenueId == 0) {
            to = txn.recipient;
            require(!isVenueVault(to), ERR_UNAUTHORIZED);
            require(!RiskHelper.isIsolatedSubaccount(to), ERR_UNAUTHORIZED);
        } else {
            to = getRegisteredVenue(txn.toVenueId).subaccount;
        }
        _recordSubaccount(to);
        // The fee comes out of the transferred amount: the vault must pay
        // exactly what the venue's ledger debited, or the venue's local vault
        // mirror drifts by engine-decided fees; the recipient bears the fee.
        require(uint128(signedTx.feeX18) < txn.amount, ERR_FEE_EXCEEDS_AMOUNT);
        venueTransferBalance(venue.subaccount, to, txn.amount);
        chargeFee(to, signedTx.feeX18, txn.productId);
    }

    function validateFee(int128 feeX18, uint32 productId) internal view {
        int128 currentFeeX18 = spotEngine.getConfig(productId).withdrawFeeX18;
        require(feeX18 >= 0);
        require(feeX18 <= currentFeeX18);
    }

    function computeDigest(
        IEndpoint.TransactionType txType,
        bytes calldata transactionBody
    ) internal view virtual returns (bytes32) {
        return verifier.computeDigest(txType, transactionBody);
    }

    function validateSignedTx(
        bytes32 sender,
        uint64 nonce,
        bytes calldata transaction,
        bytes memory signature,
        bool allowLinkedSigner
    ) internal {
        validateNonce(sender, nonce);
        validateSignature(
            sender,
            _hashTypedDataV4(
                computeDigest(
                    IEndpoint.TransactionType(uint8(transaction[0])),
                    transaction[1:]
                )
            ),
            signature,
            allowLinkedSigner
        );
        requireSubaccount(sender);
    }

    function validateSignedTx(
        bytes32 sender,
        uint64 nonce,
        bytes calldata transaction,
        IEndpoint.CompactSignature memory signature,
        bool allowLinkedSigner
    ) internal {
        validateNonce(sender, nonce);
        validateCompactSignature(
            sender,
            _hashTypedDataV4(
                computeDigest(
                    IEndpoint.TransactionType(uint8(transaction[0])),
                    transaction[1:]
                )
            ),
            signature,
            allowLinkedSigner
        );
        requireSubaccount(sender);
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
        bytes memory signature,
        bool allowLinkedSigner
    ) internal virtual {
        verifier.validateSignature(
            sender,
            allowLinkedSigner ? getLinkedSigner(sender) : address(0),
            digest,
            signature
        );
    }

    function validateCompactSignature(
        bytes32 sender,
        bytes32 digest,
        IEndpoint.CompactSignature memory signature,
        bool allowLinkedSigner
    ) internal virtual {
        verifier.validateCompactSignature(
            sender,
            allowLinkedSigner ? getLinkedSigner(sender) : address(0),
            digest,
            signature
        );
    }

    // TODO: these do not need senders or nonces
    // we can save some gas by creating new structs
    function processSlowModeTransactionImpl(
        address sender,
        bytes calldata transaction
    ) public {
        IEndpoint.TransactionType txType = IEndpoint.TransactionType(
            uint8(transaction[0])
        );
        if (txType == IEndpoint.TransactionType.DepositCollateral) {
            IEndpoint.DepositCollateral memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.DepositCollateral)
            );
            validateSender(txn.sender, sender);
            _recordSubaccount(txn.sender);
            clearinghouse.depositCollateral(txn);
        } else if (txType == IEndpoint.TransactionType.WithdrawCollateral) {
            IEndpoint.WithdrawCollateral memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.WithdrawCollateral)
            );
            validateSender(txn.sender, sender);
            clearinghouse.withdrawCollateral(
                txn.sender,
                txn.productId,
                txn.amount,
                address(0),
                nSubmissions
            );
        } else if (txType == IEndpoint.TransactionType.DepositInsurance) {
            clearinghouse.depositInsurance(transaction);
        } else if (txType == IEndpoint.TransactionType.LinkSigner) {
            IEndpoint.LinkSigner memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.LinkSigner)
            );
            validateSender(txn.sender, sender);
            requireSubaccount(txn.sender);
            linkedSigners[txn.sender] = address(uint160(bytes20(txn.signer)));
        } else if (txType == IEndpoint.TransactionType.WithdrawInsurance) {
            clearinghouse.withdrawInsurance(transaction, nSubmissions);
        } else if (txType == IEndpoint.TransactionType.DelistProduct) {
            clearinghouse.delistProduct(transaction);
        } else if (txType == IEndpoint.TransactionType.DumpFees) {
            IOffchainExchange(offchainExchange).dumpFees();
            uint32[] memory spotIds = spotEngine.getProductIds();
            int128[] memory fees = new int128[](spotIds.length);
            for (uint256 i = 0; i < spotIds.length; i++) {
                fees[i] = sequencerFee[spotIds[i]];
                sequencerFee[spotIds[i]] = 0;
            }
            requireSubaccount(X_ACCOUNT);
            clearinghouse.claimSequencerFees(fees);
        } else if (txType == IEndpoint.TransactionType.RebalanceXWithdraw) {
            clearinghouse.rebalanceXWithdraw(transaction, nSubmissions);
        } else if (txType == IEndpoint.TransactionType.UpdateTierFeeRates) {
            IEndpoint.UpdateTierFeeRates memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.UpdateTierFeeRates)
            );
            IOffchainExchange(offchainExchange).updateTierFeeRates(txn);
        } else if (txType == IEndpoint.TransactionType.AddNlpPool) {
            IEndpoint.AddNlpPool memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.AddNlpPool)
            );
            addNlpPool(txn.owner, txn.balanceWeightX18);
        } else if (txType == IEndpoint.TransactionType.UpdateNlpPool) {
            IEndpoint.UpdateNlpPool memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.UpdateNlpPool)
            );
            updateNlpPool(txn.poolId, txn.owner, txn.balanceWeightX18);
        } else if (txType == IEndpoint.TransactionType.DeleteNlpPool) {
            IEndpoint.DeleteNlpPool memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.DeleteNlpPool)
            );
            deleteNlpPool(txn.poolId);
        } else if (txType == IEndpoint.TransactionType.ForceRebalanceNlpPool) {
            IEndpoint.ForceRebalanceNlpPool memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.ForceRebalanceNlpPool)
            );
            clearinghouse.forceRebalanceNlpPool(
                nlpPools,
                txn.nlpPoolRebalanceX18
            );
        } else if (txType == IEndpoint.TransactionType.NlpProfitShare) {
            IEndpoint.NlpProfitShare memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.NlpProfitShare)
            );
            require(
                txn.poolId > 0 && txn.poolId < nlpPools.length,
                ERR_INVALID_NLP_POOL
            );
            require(
                nlpPools[txn.poolId].owner != address(0),
                ERR_INVALID_NLP_POOL
            );
            require(
                address(uint160(bytes20(txn.recipient))) ==
                    nlpPools[txn.poolId].owner,
                ERR_UNAUTHORIZED
            );
            requireSubaccount(txn.recipient);
            require(!RiskHelper.isIsolatedSubaccount(txn.recipient));
            clearinghouse.nlpProfitShare(
                nlpPools[txn.poolId].subaccount,
                txn.recipient,
                txn.amount
            );
        } else if (txType == IEndpoint.TransactionType.UpdateBuilder) {
            IOffchainExchange(offchainExchange).updateBuilder(transaction);
        } else if (txType == IEndpoint.TransactionType.ClaimBuilderFee) {
            IEndpoint.ClaimBuilderFee memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.ClaimBuilderFee)
            );
            validateSender(txn.sender, sender);
            requireSubaccount(txn.sender);
            IOffchainExchange(offchainExchange).claimBuilderFee(
                txn.sender,
                txn.builderId
            );
        } else if (txType == IEndpoint.TransactionType.UpdateVenue) {
            IEndpoint.UpdateVenue memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.UpdateVenue)
            );
            updateVenue(txn.venueId, txn.operator);
        } else {
            revert();
        }
    }

    function submitSlowModeTransactionImpl(bytes calldata transaction) public {
        IEndpoint.TransactionType txType = IEndpoint.TransactionType(
            uint8(transaction[0])
        );

        // special case for DepositCollateral because upon
        // slow mode submission we must take custody of the
        // actual funds

        address sender = msg.sender;

        // An entry too large to clear off the queue head would freeze the
        // queue permanently, so bound everything a non-owner can enqueue.
        // Checked here rather than per branch so that a future
        // non-owner-reachable type is covered by construction. The owner is
        // exempt: DelistProduct carries one word per position holder and is
        // bounded by SLOW_MODE_GAS_BUDGET instead.
        if (sender != owner()) {
            require(
                transaction.length <= MAX_USER_SLOW_MODE_TX_BYTES,
                ERR_SLOW_MODE_TX_TOO_LARGE
            );
        }

        if (txType == IEndpoint.TransactionType.DepositCollateral) {
            revert();
        } else if (txType == IEndpoint.TransactionType.DepositInsurance) {
            IEndpoint.DepositInsurance memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.DepositInsurance)
            );
            require(
                txn.amount >= uint128(SLOW_MODE_FEE),
                ERR_DEPOSIT_TOO_SMALL
            );
            handleDepositTransfer(_getQuote(), sender, uint256(txn.amount));
        } else if (
            txType == IEndpoint.TransactionType.WithdrawInsurance ||
            txType == IEndpoint.TransactionType.DelistProduct ||
            txType == IEndpoint.TransactionType.DumpFees ||
            txType == IEndpoint.TransactionType.RebalanceXWithdraw ||
            txType == IEndpoint.TransactionType.UpdateTierFeeRates ||
            txType == IEndpoint.TransactionType.AddNlpPool ||
            txType == IEndpoint.TransactionType.UpdateNlpPool ||
            txType == IEndpoint.TransactionType.DeleteNlpPool ||
            txType == IEndpoint.TransactionType.ForceRebalanceNlpPool ||
            txType == IEndpoint.TransactionType.NlpProfitShare ||
            txType == IEndpoint.TransactionType.UpdateBuilder ||
            txType == IEndpoint.TransactionType.UpdateVenue
        ) {
            require(sender == owner());
        } else {
            chargeSlowModeFee(_getQuote(), sender);
            slowModeFees += SLOW_MODE_FEE;
        }

        IEndpoint.SlowModeConfig memory _slowModeConfig = slowModeConfig;
        requireUnsanctioned(sender);
        slowModeTxs[_slowModeConfig.txCount++] = IEndpoint.SlowModeTx({
            executableAt: uint64(block.timestamp) + SLOW_MODE_TX_DELAY, // hardcoded to three days
            sender: sender,
            tx: transaction
        });
        // TODO: to save on costs we could potentially just emit something
        // for now, we can just create a separate loop in the engine that queries the remote
        // sequencer for slow mode transactions, and ignore the possibility of a reorgy attack
        slowModeConfig = _slowModeConfig;
    }

    function _matchOrders(
        IEndpoint.MatchOrders memory txn,
        int128 takerAmountDelta,
        bool isOtc
    ) internal {
        requireSubaccount(txn.taker.order.sender);
        requireSubaccount(txn.maker.order.sender);
        IOffchainExchange(offchainExchange).matchOrders(
            IEndpoint.MatchOrdersWithSigner({
                matchOrders: txn,
                takerLinkedSigner: getLinkedSignerOrNlpSigner(
                    txn.taker.order.sender
                ),
                makerLinkedSigner: getLinkedSignerOrNlpSigner(
                    txn.maker.order.sender
                ),
                takerAmountDelta: takerAmountDelta,
                isOtc: isOtc
            })
        );
    }

    function processTransactionImpl(bytes calldata transaction) public {
        IEndpoint.TransactionType txType = IEndpoint.TransactionType(
            uint8(transaction[0])
        );
        if (txType == IEndpoint.TransactionType.LiquidateSubaccount) {
            IEndpoint.SignedLiquidateSubaccount memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedLiquidateSubaccount)
            );
            if (signedTx.tx.sender != N_ACCOUNT) {
                validateSignedTx(
                    signedTx.tx.sender,
                    signedTx.tx.nonce,
                    transaction,
                    signedTx.signature,
                    true
                );
                // No liquidation fee for finalization (productId == uint32.max) because:
                // 1) The liquidator receives no profit from finalization
                // 2) Finalization can only occur once per underwater subaccount, eliminating
                //    sybil attack concerns that would otherwise require a fee deterrent.
                if (signedTx.tx.productId != type(uint32).max) {
                    chargeFee(signedTx.tx.sender, LIQUIDATION_FEE);
                }
            }
            clearinghouse.liquidateSubaccount(signedTx.tx);
        } else if (txType == IEndpoint.TransactionType.Deleverage) {
            IEndpoint.Deleverage memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.Deleverage)
            );
            clearinghouse.deleverage(txn);
        } else if (txType == IEndpoint.TransactionType.WithdrawCollateral) {
            IEndpoint.SignedWithdrawCollateral memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedWithdrawCollateral)
            );
            validateSignedTx(
                signedTx.tx.sender,
                signedTx.tx.nonce,
                transaction,
                signedTx.signature,
                true
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
        } else if (txType == IEndpoint.TransactionType.WithdrawCollateralV2) {
            IEndpoint.SignedWithdrawCollateralV2 memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedWithdrawCollateralV2)
            );
            validateSignedTx(
                signedTx.tx.sender,
                signedTx.tx.nonce,
                transaction,
                signedTx.signature,
                signedTx.tx.sendTo == address(0)
            );
            int128 currentFeeX18 = spotEngine
                .getConfig(signedTx.tx.productId)
                .withdrawFeeX18;
            require(signedTx.feeX18 >= 0);
            require(signedTx.feeX18 <= currentFeeX18);
            chargeFee(
                signedTx.tx.sender,
                signedTx.feeX18,
                signedTx.tx.productId
            );
            clearinghouse.withdrawCollateral(
                signedTx.tx.sender,
                signedTx.tx.productId,
                signedTx.tx.amount,
                signedTx.tx.sendTo,
                nSubmissions
            );
        } else if (txType == IEndpoint.TransactionType.VenueDeposit) {
            executeVenueDeposit(transaction);
        } else if (txType == IEndpoint.TransactionType.VenueTransfer) {
            executeVenueTransfer(transaction);
        } else if (txType == IEndpoint.TransactionType.SpotTick) {
            IEndpoint.SpotTick memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.SpotTick)
            );
            Times memory t = times;
            uint128 dt = t.spotTime == 0 ? 0 : txn.time - t.spotTime;
            spotEngine.updateStates(dt);
            t.spotTime = txn.time;
            times = t;
        } else if (txType == IEndpoint.TransactionType.PerpTick) {
            IEndpoint.PerpTick memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.PerpTick)
            );
            Times memory t = times;
            uint128 dt = t.perpTime == 0 ? 0 : txn.time - t.perpTime;
            perpEngine.updateStates(dt, txn.avgPriceDiffs);
            t.perpTime = txn.time;
            times = t;
        } else if (txType == IEndpoint.TransactionType.UpdatePrice) {
            (uint32 productId, int128 newPriceX18) = clearinghouse.updatePrice(
                transaction
            );
            if (productId != 0) {
                priceX18[productId] = newPriceX18;
            }
        } else if (txType == IEndpoint.TransactionType.SettlePnl) {
            clearinghouse.settlePnl(transaction);
        } else if (txType == IEndpoint.TransactionType.MatchOrders) {
            _matchOrders(
                abi.decode(transaction[1:], (IEndpoint.MatchOrders)),
                0,
                false
            );
        } else if (txType == IEndpoint.TransactionType.MatchOrdersWithAmount) {
            IEndpoint.MatchOrdersWithAmount memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.MatchOrdersWithAmount)
            );
            _matchOrders(txn.matchOrders, txn.takerAmountDelta, false);
        } else if (txType == IEndpoint.TransactionType.MatchOrdersV2) {
            IEndpoint.MatchOrdersV2 memory txn = MatchOrdersV2Helper.decode(
                transaction
            );
            require(txn.controlFlags & ~MATCH_FLAG_OTC == 0);
            _matchOrders(
                IEndpoint.MatchOrders({
                    productId: txn.productId,
                    taker: MatchOrdersV2Helper.toSignedOrder(txn.taker),
                    maker: MatchOrdersV2Helper.toSignedOrder(txn.maker)
                }),
                txn.takerAmountDelta,
                txn.controlFlags & MATCH_FLAG_OTC != 0
            );
        } else if (txType == IEndpoint.TransactionType.MintNlp) {
            IEndpoint.SignedMintNlp memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedMintNlp)
            );
            validateSignedTx(
                signedTx.tx.sender,
                signedTx.tx.nonce,
                transaction,
                signedTx.signature,
                true
            );
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            priceX18[NLP_PRODUCT_ID] = signedTx.oraclePriceX18;
            clearinghouse.mintNlp(
                signedTx.tx,
                signedTx.oraclePriceX18,
                nlpPools,
                signedTx.nlpPoolRebalanceX18
            );
        } else if (txType == IEndpoint.TransactionType.BurnNlp) {
            IEndpoint.SignedBurnNlp memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedBurnNlp)
            );
            validateSignedTx(
                signedTx.tx.sender,
                signedTx.tx.nonce,
                transaction,
                signedTx.signature,
                true
            );
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            priceX18[NLP_PRODUCT_ID] = signedTx.oraclePriceX18;
            clearinghouse.burnNlp(
                signedTx.tx,
                signedTx.oraclePriceX18,
                nlpPools,
                signedTx.nlpPoolRebalanceX18
            );
        } else if (txType == IEndpoint.TransactionType.ManualAssert) {
            clearinghouse.manualAssert(transaction);
        } else if (txType == IEndpoint.TransactionType.LinkSigner) {
            IEndpoint.SignedLinkSigner memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedLinkSigner)
            );
            validateSignedTx(
                signedTx.tx.sender,
                signedTx.tx.nonce,
                transaction,
                signedTx.signature,
                true
            );
            linkedSigners[signedTx.tx.sender] = address(
                uint160(bytes20(signedTx.tx.signer))
            );
        } else if (txType == IEndpoint.TransactionType.UpdateFeeTier) {
            clearinghouse.updateFeeTier(transaction);
        } else if (txType == IEndpoint.TransactionType.TransferQuoteV2) {
            IEndpoint.SignedTransferQuoteV2 memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedTransferQuoteV2)
            );
            _recordSubaccount(signedTx.tx.recipient);
            validateSignedTx(
                signedTx.tx.sender,
                signedTx.tx.nonce,
                transaction,
                signedTx.signature,
                true
            );
            int128 cap = (RiskHelper.isIsolatedSubaccount(
                signedTx.tx.recipient
            ) || RiskHelper.isIsolatedSubaccount(signedTx.tx.sender))
                ? HEALTHCHECK_FEE / 10
                : HEALTHCHECK_FEE;
            require(signedTx.feeX18 >= 0 && signedTx.feeX18 <= cap);
            chargeFee(signedTx.tx.sender, signedTx.feeX18);
            clearinghouse.transferQuote(signedTx.tx);
        } else if (txType == IEndpoint.TransactionType.TransferQuote) {
            IEndpoint.SignedTransferQuote memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedTransferQuote)
            );
            _recordSubaccount(signedTx.tx.recipient);
            validateSignedTx(
                signedTx.tx.sender,
                signedTx.tx.nonce,
                transaction,
                signedTx.signature,
                true
            );
            if (
                RiskHelper.isIsolatedSubaccount(signedTx.tx.recipient) ||
                RiskHelper.isIsolatedSubaccount(signedTx.tx.sender)
            ) {
                chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE / 10);
            } else {
                chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            }
            clearinghouse.transferQuote(signedTx.tx);
        } else if (txType == IEndpoint.TransactionType.AssertCode) {
            clearinghouse.assertCode(transaction);
        } else if (txType == IEndpoint.TransactionType.AssertProduct) {
            IOffchainExchange(offchainExchange).assertProduct(transaction);
        } else if (
            txType == IEndpoint.TransactionType.CreateIsolatedSubaccount
        ) {
            IEndpoint.CreateIsolatedSubaccount memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.CreateIsolatedSubaccount)
            );
            bytes32 newIsolatedSubaccount = IOffchainExchange(offchainExchange)
                .createIsolatedSubaccount(
                    txn,
                    getLinkedSigner(txn.order.sender)
                );
            _recordSubaccount(newIsolatedSubaccount);
        } else if (
            txType == IEndpoint.TransactionType.CloseIsolatedSubaccount
        ) {
            IEndpoint.CloseIsolatedSubaccount memory txn = abi.decode(
                transaction[1:],
                (IEndpoint.CloseIsolatedSubaccount)
            );
            IOffchainExchange(offchainExchange).tryCloseIsolatedSubaccount(
                txn.subaccount
            );
        } else {
            revert();
        }
    }
}
