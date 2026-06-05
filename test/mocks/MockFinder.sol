// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {FinderInterface} from "@uma/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

contract MockFinder is FinderInterface {
    mapping(bytes32 => address) public interfacesImplemented;

    function changeImplementationAddress(bytes32 interfaceName, address implementationAddress) external override {
        interfacesImplemented[interfaceName] = implementationAddress;
    }

    function getImplementationAddress(bytes32 interfaceName) external view override returns (address) {
        address implementationAddress = interfacesImplemented[interfaceName];
        require(implementationAddress != address(0), "Implementation not found");
        return implementationAddress;
    }
}
