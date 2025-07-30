// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./BaseProxyManager.sol";

contract ProxyManager is BaseProxyManager {
    function getContractCodeHash(address impl)
        external
        view
        override
        returns (bytes32)
    {
        return _getCodeHash(impl.code);
    }

    function submitImpl(string memory name, address impl)
        external
        override
        onlySubmitter
    {
        require(pendingImpls[name] != address(0), "unsupported contract.");
        pendingImpls[name] = impl;
        pendingHashes[name] = _getCodeHash(impl.code);
    }

    function refreshCodeHash(string memory name)
        external
        override
        onlySubmitter
    {
        address proxy = proxies[name];
        address impl;
        if (_isEqual(name, CLEARINGHOUSE_LIQ)) {
            impl = _getClearinghouseLiqImpl();
        } else {
            impl = _getImpl(proxy);
        }
        pendingHashes[name] = _getCodeHash(impl.code);
        codeHashes[name] = pendingHashes[name];
    }

    function registerRegularProxy(string memory name, address proxy)
        external
        override
        onlyOwner
    {
        require(proxies[name] == address(0), "already registered.");
        address impl = _getImpl(proxy);
        contractNames.push(name);
        proxies[name] = proxy;
        pendingImpls[name] = impl;
        pendingHashes[name] = _getCodeHash(impl.code);
        codeHashes[name] = pendingHashes[name];
        if (_isEqual(name, CLEARINGHOUSE)) {
            proxyManagerHelper.registerClearinghouse(proxy);
            address clearinghouseLiq = _getClearinghouseLiqImpl();
            pendingImpls[CLEARINGHOUSE_LIQ] = clearinghouseLiq;
            pendingHashes[CLEARINGHOUSE_LIQ] = _getCodeHash(
                clearinghouseLiq.code
            );
            codeHashes[CLEARINGHOUSE_LIQ] = pendingHashes[CLEARINGHOUSE_LIQ];
        }
    }
}
