// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IERC4626Base {
    function asset() external view returns (address);

    function deposit(uint256 assets, address receiver)
        external
        returns (uint256);

    function previewDeposit(uint256 assets) external view returns (uint256);
}
