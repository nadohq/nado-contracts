// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IIERC20Base {
    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);
}

interface IIEndpoint {
    function depositCollateralWithReferral(
        bytes32 subaccount,
        uint32 productId,
        uint128 amount,
        string memory referral
    ) external;
}

interface IISpotEngine {
    function getProductIds() external view returns (uint32[] memory);

    function getToken(uint32 productId) external view returns (address);
}

contract DirectDepositV1 is Ownable {
    IIEndpoint internal endpoint;
    IISpotEngine internal spotEngine;
    bytes32 internal subaccount;
    address payable internal wrappedNative;

    event NativeTokenTransferFailed(uint256 amount);
    event DirectDepositV1Created(
        uint8 indexed version,
        bytes32 indexed subaccount,
        address dda
    );

    constructor(
        address _endpoint,
        address _spotEngine,
        bytes32 _subaccount,
        address payable _wrappedNative
    ) {
        endpoint = IIEndpoint(_endpoint);
        spotEngine = IISpotEngine(_spotEngine);
        subaccount = _subaccount;
        wrappedNative = _wrappedNative;
        uint256 balance = address(this).balance;
        if (balance != 0) {
            // shouldn't revert even if the transfer fails, otherwise the funds
            // will be stuck in the DDA forever.
            (bool success, ) = wrappedNative.call{value: balance}("");
            if (!success) {
                emit NativeTokenTransferFailed(balance);
            }
        }
        emit DirectDepositV1Created(version(), subaccount, address(this));
    }

    receive() external payable {
        (bool success, ) = wrappedNative.call{value: msg.value}("");
        require(success, "Failed to wrap native token.");
    }

    function safeTransfer(
        IIERC20Base self,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = address(self).call(
            abi.encodeWithSelector(IIERC20Base.transfer.selector, to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed"
        );
    }

    function creditDeposit() external {
        uint32[] memory productIds = spotEngine.getProductIds();
        for (uint256 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            address tokenAddr = spotEngine.getToken(productId);
            require(tokenAddr != address(0), "Invalid productId.");
            IIERC20Base token = IIERC20Base(tokenAddr);
            uint256 balance = token.balanceOf(address(this));
            if (balance != 0) {
                token.approve(address(endpoint), balance);
                endpoint.depositCollateralWithReferral(
                    subaccount,
                    productId,
                    uint128(balance),
                    "-1"
                );
            }
        }
    }

    function withdraw(IIERC20Base token) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        safeTransfer(token, msg.sender, balance);
    }

    function withdrawNative() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = msg.sender.call{value: balance}("");
        require(success, "Failed to transfer native token to owner");
    }

    function version() public pure returns (uint8) {
        return 1;
    }
}
