// SPDX-License-Identifier: AGPL-3.0-only
// Derived from https://github.com/UMAprotocol/protocol/blob/%40uma/core%402.62.0/packages/core/contracts/common/implementation/FixedPoint.sol
// to expose the Unsigned struct for use in other contracts. The rest of the FixedPoint library logic is not required
// here and any porting would require significant changes to the codebase related to the removed support of SafeMath in
// OpenZeppelin 5.x.

pragma solidity ^0.8.0;

/**
 * @title Interface for fixed point arithmetic on uints
 */
interface FixedPointInterface {
    struct Unsigned {
        uint256 rawValue;
    }
}
