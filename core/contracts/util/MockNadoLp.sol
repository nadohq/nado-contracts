// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./MockERC20.sol";

contract MockNadoLp is MockERC20 {
    bool private _initialized;

    constructor() MockERC20("Nado LP", "NLP", 18) {
        // Burn all initial supply to ensure total supply is always 0
        _burn(msg.sender, balanceOf(msg.sender));
        _initialized = true;
    }

    /// @dev disable minting after construction
    function mint(address account, uint256 amount) external override {
        require(!_initialized, "MockNadoLp: minting is disabled");
        _mint(account, amount);
    }
}
