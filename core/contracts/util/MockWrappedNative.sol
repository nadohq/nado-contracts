// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./MockERC20.sol";

contract MockWrappedNative is MockERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) MockERC20(name_, symbol_, decimals_) {} // solhint-disable-line no-empty-blocks

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
