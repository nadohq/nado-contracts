// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IProxyManager {
    function getProxyManagerHelper() external view returns (address);

    function getCodeHash(string memory name) external view returns (bytes32);
}
