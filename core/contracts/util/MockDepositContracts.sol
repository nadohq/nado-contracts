// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../interfaces/engine/ISpotEngine.sol";
import "../interfaces/engine/IProductEngine.sol";
import "../BaseWithdrawPool.sol";

contract MockNonStandardERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        require(
            amount == 0 || allowance[msg.sender][spender] == 0,
            "NonZeroAllowance"
        );
        allowance[msg.sender][spender] = amount;
        // Intentionally no return value (void), mimicking USDT on mainnet
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "BalanceTooLow");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockEndpointForDeposit {
    bytes32 public lastSubaccount;
    uint32 public lastProductId;
    uint128 public lastAmount;

    function depositCollateralWithReferral(
        bytes32 subaccount,
        uint32 productId,
        uint128 amount,
        string memory /* referral */
    ) external {
        lastSubaccount = subaccount;
        lastProductId = productId;
        lastAmount = amount;
    }
}

contract MockSpotEngineForDeposit {
    uint32[] public productIds;
    mapping(uint32 => address) public tokens;
    mapping(uint32 => ISpotEngine.Config) public configs;

    function setProduct(
        uint32 productId,
        address token,
        int128 feeX18
    ) external {
        productIds.push(productId);
        tokens[productId] = token;
        configs[productId].token = token;
        configs[productId].withdrawFeeX18 = feeX18;
    }

    function getProductIds() external view returns (uint32[] memory) {
        return productIds;
    }

    function getToken(uint32 productId) external view returns (address) {
        return tokens[productId];
    }

    function getConfig(
        uint32 productId
    ) external view returns (ISpotEngine.Config memory) {
        return configs[productId];
    }
}

contract MockClearinghouseForWithdraw {
    address public spotEngine;

    function setSpotEngine(address _spotEngine) external {
        spotEngine = _spotEngine;
    }

    function getEngineByType(
        IProductEngine.EngineType
    ) external view returns (address) {
        return spotEngine;
    }
}

contract TestWithdrawPool is BaseWithdrawPool {
    function initialize(address _clearinghouse, address _verifier) external {
        clearinghouse = _clearinghouse;
        verifier = _verifier;
    }
}
