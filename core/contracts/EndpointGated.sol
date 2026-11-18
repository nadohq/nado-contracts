// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IEndpointGated.sol";
import "./libraries/MathSD21x18.sol";
import "./common/Constants.sol";

abstract contract EndpointGated is OwnableUpgradeable, IEndpointGated {
    address private endpoint;

    function setEndpoint(address _endpoint) internal onlyOwner {
        endpoint = _endpoint;
    }

    function getEndpoint() public view returns (address) {
        return endpoint;
    }

    function getOracleTime() internal view returns (uint128) {
        return IEndpoint(endpoint).getTime();
    }

    // A modifier body is inlined at every use site; routing it through one
    // function keeps the revert string in the bytecode once.
    modifier onlyEndpoint() {
        _checkEndpoint();
        _;
    }

    function _checkEndpoint() internal view {
        require(
            msg.sender == endpoint,
            "SequencerGated: caller is not the endpoint"
        );
    }
}
