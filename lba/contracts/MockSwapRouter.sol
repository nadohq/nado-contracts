// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract MockSwapRouter is ISwapRouter, OwnableUpgradeable {
    address vrtxToken;
    address usdcToken;

    constructor(address _vrtxToken, address _usdcToken) initializer {
        __Ownable_init();
        vrtxToken = _vrtxToken;
        usdcToken = _usdcToken;
    }

    function getBalances()
        internal
        view
        returns (uint256 vrtxBalance, uint256 usdcBalance)
    {
        vrtxBalance = IERC20(vrtxToken).balanceOf(address(this));
        usdcBalance = IERC20(usdcToken).balanceOf(address(this));
    }

    function claimAllTokens() external onlyOwner {
        (uint256 vrtxBalance, uint256 usdcBalance) = getBalances();
        SafeERC20.safeTransfer(IERC20(vrtxToken), msg.sender, vrtxBalance);
        SafeERC20.safeTransfer(IERC20(usdcToken), msg.sender, usdcBalance);
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut) {
        require(
            params.tokenIn == usdcToken && params.tokenOut == vrtxToken,
            "Unsupported tokens"
        );
        require(block.timestamp <= params.deadline, "Transaction too old");
        (uint256 vrtxBalanceOld, uint256 usdcBalanceOld) = getBalances();
        uint256 usdcBalanceNew = usdcBalanceOld + params.amountIn;
        uint256 vrtxBalanceNew = (vrtxBalanceOld * usdcBalanceOld) /
            usdcBalanceNew;
        amountOut = vrtxBalanceOld - vrtxBalanceNew;
        SafeERC20.safeTransferFrom(
            IERC20(usdcToken),
            msg.sender,
            address(this),
            params.amountIn
        );
        SafeERC20.safeTransfer(IERC20(vrtxToken), params.recipient, amountOut);
    }
}
