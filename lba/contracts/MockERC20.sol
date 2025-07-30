// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000;
    uint8 private decimals_;

    constructor(
        string memory name,
        string memory symbol,
        uint8 _decimals
    ) ERC20(name, symbol) {
        decimals_ = _decimals;
        _mint(msg.sender, TOTAL_SUPPLY * 10 ** decimals_);
    }

    function decimals() public view virtual override returns (uint8) {
        return decimals_;
    }

    function mint(address account, uint256 amount) external {}
}
