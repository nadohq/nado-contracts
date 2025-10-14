// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

contract AirdropDelegation {
    // Mapping to store the latest receiver for each address
    mapping(address => address) public delegations;

    // Event emitted when airdrop is delegated
    event AirdropDelegated(address indexed caller, address indexed receiver);

    /**
     * @dev Delegates airdrop to a specified receiver
     * @param receiver The address to receive the airdrop
     */
    function delegateAirdrop(address receiver) external {
        require(receiver != address(0), "Invalid receiver address");
        require(receiver != msg.sender, "Cannot delegate to self");

        // Update the delegation mapping
        delegations[msg.sender] = receiver;

        // Emit the event
        emit AirdropDelegated(msg.sender, receiver);
    }

    /**
     * @dev Get the current delegation for an address
     * @param delegator The address to check delegation for
     * @return The address that the delegator has delegated to
     */
    function getDelegation(address delegator) external view returns (address) {
        return delegations[delegator];
    }
}
