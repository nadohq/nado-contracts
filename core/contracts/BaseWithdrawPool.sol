// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./libraries/MathHelper.sol";
import "./interfaces/IEndpoint.sol";
import "./Verifier.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IERC20Base.sol";
import "./libraries/ERC20Helper.sol";
import "./common/Constants.sol";

abstract contract BaseWithdrawPool is EIP712Upgradeable, OwnableUpgradeable {
    using ERC20Helper for IERC20Base;
    using MathSD21x18 for int128;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _initialize(address _clearinghouse, address _verifier)
        internal
        initializer
    {
        __Ownable_init();
        clearinghouse = _clearinghouse;
        verifier = _verifier;
    }

    address internal clearinghouse;

    address internal verifier;

    // submitted withdrawal idxs
    mapping(uint64 => bool) public markedIdxs;

    // collected withdrawal fees in native token decimals
    mapping(uint32 => int128) public fees;

    uint64 public minIdx;

    function resolveFastWithdrawal(bytes calldata transaction)
        internal
        pure
        returns (
            uint32 productId,
            address sendTo,
            address sender,
            uint128 amount
        )
    {
        IEndpoint.TransactionType txType = IEndpoint.TransactionType(
            uint8(transaction[0])
        );
        if (txType == IEndpoint.TransactionType.WithdrawCollateral) {
            IEndpoint.SignedWithdrawCollateral memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedWithdrawCollateral)
            );
            return (
                signedTx.tx.productId,
                address(uint160(bytes20(signedTx.tx.sender))),
                address(uint160(bytes20(signedTx.tx.sender))),
                signedTx.tx.amount
            );
        }
        if (txType == IEndpoint.TransactionType.WithdrawCollateralV2) {
            IEndpoint.SignedWithdrawCollateralV2 memory signedTx = abi.decode(
                transaction[1:],
                (IEndpoint.SignedWithdrawCollateralV2)
            );
            // V2 appendix is intentionally ignored until fast-withdraw features use it.
            address resolvedSendTo = signedTx.tx.sendTo == address(0)
                ? address(uint160(bytes20(signedTx.tx.sender)))
                : signedTx.tx.sendTo;
            return (
                signedTx.tx.productId,
                resolvedSendTo,
                address(uint160(bytes20(signedTx.tx.sender))),
                signedTx.tx.amount
            );
        }
        revert("Invalid withdrawal tx type");
    }

    function submitFastWithdrawal(
        uint64 idx,
        bytes calldata transaction,
        bytes[] calldata signatures
    ) public {
        require(!markedIdxs[idx], "Withdrawal already submitted");
        require(idx > minIdx, "idx too small");
        markedIdxs[idx] = true;

        Verifier v = Verifier(verifier);
        v.requireValidTxSignatures(transaction, idx, signatures);

        (
            uint32 productId,
            address sendTo,
            address sender,
            uint128 transferAmount
        ) = resolveFastWithdrawal(transaction);
        IERC20Base token = getToken(productId);

        require(transferAmount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);

        int128 fee = fastWithdrawalFeeAmount(token, productId, transferAmount);

        if (sendTo == msg.sender || sender == msg.sender) {
            require(transferAmount > uint128(fee), "Fee larger than balance");
            transferAmount -= uint128(fee);
        } else {
            safeTransferFrom(token, msg.sender, uint128(fee));
        }

        fees[productId] += fee;

        handleWithdrawTransfer(token, sendTo, transferAmount);
    }

    function submitWithdrawal(
        IERC20Base token,
        address sendTo,
        uint128 amount,
        uint64 idx
    ) public {
        require(msg.sender == clearinghouse);

        if (markedIdxs[idx]) {
            return;
        }
        markedIdxs[idx] = true;
        // set minIdx to most recent withdrawal submitted by sequencer
        minIdx = idx;

        if (sendTo == address(token)) {
            return;
        }

        handleWithdrawTransfer(token, sendTo, amount);
    }

    function fastWithdrawalFeeAmount(
        IERC20Base token,
        uint32 productId,
        uint128 amount
    ) public view returns (int128) {
        uint8 decimals = token.decimals();
        require(decimals <= MAX_DECIMALS);
        int256 multiplier = int256(10**(MAX_DECIMALS - uint8(decimals)));
        int128 amountX18 = int128(amount) * int128(multiplier);

        int128 proportionalFeeX18 = FAST_WITHDRAWAL_FEE_RATE.mul(amountX18);
        int128 minFeeX18 = 5 * spotEngine().getConfig(productId).withdrawFeeX18;

        int128 feeX18 = MathHelper.max(proportionalFeeX18, minFeeX18);
        return feeX18 / int128(multiplier);
    }

    function removeLiquidity(
        uint32 productId,
        uint128 amount,
        address sendTo
    ) external onlyOwner {
        handleWithdrawTransfer(getToken(productId), sendTo, amount);
    }

    function checkMarkedIdxs(uint64[] calldata idxs)
        public
        view
        returns (bool[] memory)
    {
        bool[] memory marked = new bool[](idxs.length);
        for (uint256 i = 0; i < idxs.length; i++) {
            marked[i] = markedIdxs[idxs[i]];
        }
        return marked;
    }

    function checkProductBalances(uint32[] calldata productIds)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory balances = new uint256[](productIds.length);
        for (uint256 i = 0; i < productIds.length; i++) {
            IERC20Base token = getToken(productIds[i]);
            balances[i] = token.balanceOf(address(this));
        }
        return balances;
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address to,
        uint128 amount
    ) internal virtual {
        token.safeTransfer(to, uint256(amount));
    }

    function safeTransferFrom(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal virtual {
        token.safeTransferFrom(from, address(this), amount);
    }

    function getToken(uint32 productId) internal view returns (IERC20Base) {
        IERC20Base token = IERC20Base(spotEngine().getConfig(productId).token);
        require(address(token) != address(0));
        return token;
    }

    function spotEngine() internal view returns (ISpotEngine) {
        return
            ISpotEngine(
                IClearinghouse(clearinghouse).getEngineByType(
                    IProductEngine.EngineType.SPOT
                )
            );
    }
}
