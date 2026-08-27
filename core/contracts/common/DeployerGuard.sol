// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";
import "./Errors.sol";

interface IOwnable {
    function owner() external view returns (address);
}

// Proxies are deployed uninitialized because their initializers need each
// other's addresses, which leaves a window where anyone could call initialize
// and seize ownership. Restricting initialize to the deploying EOA closes the
// window: deploy, initialize as the deployer (directly or through helpers
// like Clearinghouse.addEngine, hence tx.origin), then transfer ownership.
//
// The deployer identity is derived at call time from the proxy's ERC1967
// admin slot (the ProxyAdmin's owner) instead of being stored anywhere:
// implementation bytecode must stay deployment-invariant because the engine
// verifies contract code hashes against compiled artifacts, so an immutable
// would break that verification.
abstract contract DeployerGuard is Initializable {
    // ERC1967 admin slot: bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 private constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyImplDeployer() {
        _checkImplDeployer();
        _;
    }

    function _checkImplDeployer() internal view {
        address admin = StorageSlot.getAddressSlot(_ADMIN_SLOT).value;
        if (admin == address(0)) {
            // not running behind a transparent proxy: the engine's simulated
            // EVM (set_code, no proxy) and plain test proxies. On-chain
            // deployments always set the admin at proxy construction.
            return;
        }
        address deployer = admin.code.length == 0
            ? admin
            : IOwnable(admin).owner();
        // solhint-disable-next-line avoid-tx-origin
        require(tx.origin == deployer, ERR_UNAUTHORIZED);
    }
}
