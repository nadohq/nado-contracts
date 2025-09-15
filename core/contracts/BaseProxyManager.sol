// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface ITransparentUpgradeableProxy {
    function upgradeTo(address) external;
}

// we can't use the name `IClearinghouse` here, hardhat-abi-exporter gives
// `duplicate output destination` error.
interface IIClearinghouse {
    function getClearinghouseLiq() external view returns (address);

    function upgradeClearinghouseLiq(address _clearinghouseLiq) external;
}

// ProxyAdmin cannot access to any functions of the implementation of a proxy,
// so we have to create a helper contract to help us visit impl functions.
contract ProxyManagerHelper {
    address internal proxyManager;
    address internal clearinghouse;

    modifier onlyOwner() {
        require(
            msg.sender == proxyManager,
            "only proxyManager can access to ProxyManagerHelper."
        );
        _;
    }

    constructor() {
        proxyManager = msg.sender;
    }

    function registerClearinghouse(address _clearinghouse) external onlyOwner {
        clearinghouse = _clearinghouse;
    }

    function getClearinghouseLiq() external view returns (address) {
        return IIClearinghouse(clearinghouse).getClearinghouseLiq();
    }

    function upgradeClearinghouseLiq(address clearinghouseLiq)
        external
        onlyOwner
    {
        IIClearinghouse(clearinghouse).upgradeClearinghouseLiq(
            clearinghouseLiq
        );
    }
}

abstract contract BaseProxyManager is OwnableUpgradeable {
    string internal constant CLEARINGHOUSE = "Clearinghouse";
    string internal constant CLEARINGHOUSE_LIQ = "ClearinghouseLiq";

    address public submitter;
    ProxyManagerHelper internal proxyManagerHelper;

    string[] internal contractNames;
    mapping(string => address) public proxies;
    mapping(string => address) public pendingImpls;
    mapping(string => bytes32) public pendingHashes;
    mapping(string => bytes32) public codeHashes;

    modifier onlySubmitter() {
        require(
            msg.sender == submitter,
            "only submitter can submit new impls."
        );
        _;
    }

    struct NewImpl {
        string name;
        address impl;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init();
        submitter = msg.sender;
        proxyManagerHelper = new ProxyManagerHelper();
    }

    function _getSlice(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (bytes memory) {
        bytes memory ret = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            ret[i - start] = data[i];
        }
        return ret;
    }

    function getContractCodeHash(address impl)
        external
        view
        virtual
        returns (bytes32);

    function submitImpl(string memory name, address impl) external virtual;

    function refreshCodeHash(string memory name) external virtual;

    function registerRegularProxy(string memory name, address proxy)
        external
        virtual;

    function _getCodeHash(bytes memory code) internal pure returns (bytes32) {
        uint256 len = code.length;
        require(len >= 2, "invalid code: len < 2.");
        uint16 cborLength = uint16(bytes2(_getSlice(code, len - 2, len)));
        require(len >= 2 + cborLength, "invalid code: len < 2 + cborLength.");
        return keccak256(_getSlice(code, 0, len - cborLength - 2));
    }

    function updateSubmitter(address newSubmitter) external onlyOwner {
        submitter = newSubmitter;
    }

    function forceMigrateSelf(address newImpl) external onlyOwner {
        ITransparentUpgradeableProxy(address(this)).upgradeTo(newImpl);
    }

    function migrateAll(NewImpl[] calldata newImpls) external onlyOwner {
        for (uint32 i = 0; i < newImpls.length; i++) {
            if (_isEqual(newImpls[i].name, CLEARINGHOUSE_LIQ)) {
                _migrateClearinghouseLiq(newImpls[i]);
            } else {
                _migrateRegularProxy(newImpls[i]);
            }
            codeHashes[newImpls[i].name] = pendingHashes[newImpls[i].name];
        }
        require(!hasPending(), "still having pending impls to be migrated.");
    }

    function getProxyManagerHelper() external view returns (address) {
        return address(proxyManagerHelper);
    }

    function getContractNames() external view returns (string[] memory) {
        string[] memory ret = new string[](contractNames.length);
        for (uint32 i = 0; i < contractNames.length; i++) {
            ret[i] = contractNames[i];
        }
        return ret;
    }

    function getCodeHash(string memory name) external view returns (bytes32) {
        return codeHashes[name];
    }

    function hasPending() public view returns (bool) {
        for (uint32 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            address proxy = proxies[name];
            if (_getImpl(proxy) != pendingImpls[name]) {
                return true;
            }
        }
        if (_isClearinghouseRegistered()) {
            if (_getClearinghouseLiqImpl() != pendingImpls[CLEARINGHOUSE_LIQ]) {
                return true;
            }
        }
        return false;
    }

    function _isEqual(string memory a, string memory b)
        internal
        pure
        returns (bool)
    {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function _getImpl(address proxy) internal view returns (address) {
        (bool success, bytes memory returndata) = proxy.staticcall(
            hex"5c60da1b"
        );
        require(success, "failed to query impl of the proxy.");
        return abi.decode(returndata, (address));
    }

    function _getClearinghouseLiqImpl() internal view returns (address) {
        return proxyManagerHelper.getClearinghouseLiq();
    }

    function _validateImpl(address currentImpl, NewImpl calldata newImpl)
        internal
        view
    {
        require(
            pendingImpls[newImpl.name] == newImpl.impl,
            "new impls don't match with pending impls."
        );
        require(
            currentImpl != newImpl.impl,
            "current impl is already the new impl."
        );
    }

    function _migrateRegularProxy(NewImpl calldata newImpl) internal {
        address proxy = proxies[newImpl.name];
        _validateImpl(_getImpl(proxy), newImpl);
        ITransparentUpgradeableProxy(proxy).upgradeTo(newImpl.impl);
    }

    function _migrateClearinghouseLiq(NewImpl calldata newImpl) internal {
        require(
            _isEqual(newImpl.name, CLEARINGHOUSE_LIQ),
            "invalid new impl provided."
        );
        require(
            _isClearinghouseRegistered(),
            "Clearinghouse hasn't been registered."
        );
        _validateImpl(_getClearinghouseLiqImpl(), newImpl);
        proxyManagerHelper.upgradeClearinghouseLiq(newImpl.impl);
    }

    function _isClearinghouseRegistered() internal view returns (bool) {
        return proxies[CLEARINGHOUSE] != address(0);
    }
}
