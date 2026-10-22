// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IEndpoint.sol";
import {SpotEngine} from "./SpotEngine.sol";
import "./PerpEngine.sol";
import "./Endpoint.sol";
import "./Verifier.sol";
import "./common/DeployerGuard.sol";

// ContractOwner's state, shared with ContractOwnerExt, which runs under
// ContractOwner's fallback by delegatecall. Slots are the live proxy's: only
// ever append.
// solhint-disable-next-line max-states-count
abstract contract ContractOwnerStorage is
    DeployerGuard,
    EIP712Upgradeable,
    OwnableUpgradeable
{
    error InvalidInput();

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

    address public feeCollector;

    // Core keys a venue's transfers to its operator's nonce stream, so an
    // address serves one venue at most, and a replaced one never returns:
    // registering it again would revive every transfer it signed that never
    // executed.
    mapping(uint32 => address) internal venueOperators;
    // the venue an operator serves, or RETIRED_VENUE_OPERATOR once replaced;
    // the first registration retires address(0), so a venue is never
    // deregistered here: rotating its operator is the kill switch
    mapping(address => uint256) internal venueOperatorStates;

    address internal contractOwnerExt;

    modifier onlyDeployer() {
        _checkDeployer();
        _;
    }

    modifier onlyOwnerOrFeeCollector() {
        _checkOwnerOrFeeCollector();
        _;
    }

    function _checkOwnerOrFeeCollector() internal view {
        require(
            msg.sender == owner() || msg.sender == feeCollector,
            "not owner or fee collector"
        );
    }

    function _checkDeployer() internal view {
        require(msg.sender == deployer, "sender must be deployer");
    }

    function _submitSlowModeTransaction(
        IEndpoint.TransactionType txType,
        bytes memory payload
    ) internal {
        endpoint.submitSlowModeTransaction(
            abi.encodePacked(uint8(txType), payload)
        );
    }
}
