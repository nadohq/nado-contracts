// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
import "../interfaces/IEndpoint.sol";

/// @title MatchOrdersV2Helper
/// @dev Wire codec for IEndpoint.MatchOrdersV2. The tx is the type byte
/// followed by eleven raw 32-byte words. Fields go in declaration order, high
/// bits first, and start a new word only when they don't fit:
///   words 0-4  taker: sender, priceX18 << 128 | amount,
///              expiration << 192 | nonce << 128 | appendix, r, vs
///   words 5-9  maker, same layout
///   word 10    takerAmountDelta << 128 | productId << 96 | controlFlags << 32
/// The length and the low 32 bits of word 10 are checked, so every match has
/// exactly one encoding.
library MatchOrdersV2Helper {
    uint256 internal constant TX_LENGTH = 1 + 11 * 32;
    uint256 internal constant S_MASK = type(uint256).max >> 1;

    function decode(bytes calldata transaction)
        internal
        pure
        returns (IEndpoint.MatchOrdersV2 memory)
    {
        require(transaction.length == TX_LENGTH);
        uint256 tail = _word(transaction, 10);
        require(uint32(tail) == 0);
        return
            IEndpoint.MatchOrdersV2({
                taker: _unpackSignedOrder(transaction, 0),
                maker: _unpackSignedOrder(transaction, 5),
                takerAmountDelta: int128(uint128(tail >> 128)),
                productId: uint32(tail >> 96),
                controlFlags: uint64(tail >> 32)
            });
    }

    function encode(IEndpoint.MatchOrdersV2 memory m)
        internal
        pure
        returns (bytes memory)
    {
        bytes32[11] memory w;
        _packSignedOrder(w, 0, m.taker);
        _packSignedOrder(w, 5, m.maker);
        w[10] = bytes32(
            (uint256(uint128(m.takerAmountDelta)) << 128) |
                (uint256(m.productId) << 96) |
                (uint256(m.controlFlags) << 32)
        );
        return
            abi.encodePacked(uint8(IEndpoint.TransactionType.MatchOrdersV2), w);
    }

    // OffchainExchange verifies the legacy 65-byte form, so its signature path
    // stays untouched. The engine normalizes to low-s before packing, since a
    // high-s value has no free top bit for v.
    function toSignedOrder(IEndpoint.SignedOrderV2 memory o)
        internal
        pure
        returns (IEndpoint.SignedOrder memory)
    {
        uint256 vs = uint256(o.signature.vs);
        return
            IEndpoint.SignedOrder({
                order: o.order,
                signature: abi.encodePacked(
                    o.signature.r,
                    vs & S_MASK,
                    uint8(vs >> 255) + 27
                )
            });
    }

    // reads in place; abi.decode-ing a bytes32[11] memory copy costs ~150
    // bytes of EndpointTx code, which sits just under the EIP-170 limit
    function _word(bytes calldata transaction, uint256 i)
        private
        pure
        returns (uint256)
    {
        unchecked {
            return uint256(bytes32(transaction[1 + 32 * i:]));
        }
    }

    function _unpackSignedOrder(bytes calldata transaction, uint256 i)
        private
        pure
        returns (IEndpoint.SignedOrderV2 memory o)
    {
        unchecked {
            uint256 priceX18AndAmount = _word(transaction, i + 1);
            uint256 expirationNonceAppendix = _word(transaction, i + 2);
            o.order = IEndpoint.Order({
                sender: bytes32(_word(transaction, i)),
                priceX18: int128(uint128(priceX18AndAmount >> 128)),
                amount: int128(uint128(priceX18AndAmount)),
                expiration: uint64(expirationNonceAppendix >> 192),
                nonce: uint64(expirationNonceAppendix >> 128),
                appendix: uint128(expirationNonceAppendix)
            });
            o.signature = IEndpoint.CompactSignature({
                r: bytes32(_word(transaction, i + 3)),
                vs: bytes32(_word(transaction, i + 4))
            });
        }
    }

    function _packSignedOrder(
        bytes32[11] memory w,
        uint256 i,
        IEndpoint.SignedOrderV2 memory o
    ) private pure {
        w[i] = o.order.sender;
        w[i + 1] = bytes32(
            (uint256(uint128(o.order.priceX18)) << 128) |
                uint128(o.order.amount)
        );
        w[i + 2] = bytes32(
            (uint256(o.order.expiration) << 192) |
                (uint256(o.order.nonce) << 128) |
                o.order.appendix
        );
        w[i + 3] = o.signature.r;
        w[i + 4] = o.signature.vs;
    }
}
