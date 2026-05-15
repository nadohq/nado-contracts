// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/IEndpoint.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/IVerifier.sol";
import "./interfaces/IERC20Base.sol";
import "./libraries/ERC20Helper.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";

interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

// solhint-disable-next-line max-states-count
abstract contract EndpointStorage {
    using ERC20Helper for IERC20Base;

    IClearinghouse public clearinghouse;
    ISpotEngine internal spotEngine;
    IPerpEngine internal perpEngine;
    ISanctionsList internal sanctions;

    address internal sequencer;
    int128 internal sequencerFees;

    mapping(bytes32 => uint64) internal subaccountIds;
    mapping(uint64 => bytes32) internal subaccounts;
    uint64 internal numSubaccounts;

    mapping(address => uint64) internal nonces;

    uint64 public nSubmissions;

    IEndpoint.SlowModeConfig internal slowModeConfig;
    mapping(uint64 => IEndpoint.SlowModeTx) internal slowModeTxs;

    struct Times {
        uint128 perpTime;
        uint128 spotTime;
    }

    Times internal times;

    mapping(uint32 => int128) internal sequencerFee;

    mapping(bytes32 => address) internal linkedSigners;

    mapping(bytes32 => address) internal nlpSigners;
    IEndpoint.NlpPool[] public nlpPools;

    int128 internal slowModeFees;

    // invitee -> referralCode
    mapping(address => string) public referralCodes; // deprecated

    mapping(uint32 => int128) internal priceX18;
    address internal offchainExchange;

    IVerifier internal verifier;

    address internal endpointTx;

    function _recordSubaccount(bytes32 subaccount) internal {
        if (subaccountIds[subaccount] == 0) {
            subaccountIds[subaccount] = ++numSubaccounts;
            subaccounts[numSubaccounts] = subaccount;
        }
    }

    function requireSubaccount(bytes32 subaccount) internal view {
        require(
            subaccount == X_ACCOUNT ||
                subaccount == N_ACCOUNT ||
                (subaccountIds[subaccount] != 0),
            ERR_REQUIRES_DEPOSIT
        );
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

    function requireUnsanctioned(address sender) internal view virtual {
        require(!sanctions.isSanctioned(sender), ERR_WALLET_SANCTIONED);
    }
}
