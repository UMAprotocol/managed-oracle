// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {StoreInterface} from "src/data-verification-mechanism/interfaces/StoreInterface.sol";
import {FixedPointInterface} from "src/common/interfaces/FixedPointInterface.sol";

contract MockStore is StoreInterface {
    mapping(address => uint256) public finalFeeByCurrency;

    function setFinalFee(address currency, uint256 amount) external {
        finalFeeByCurrency[currency] = amount;
    }

    function payOracleFees() external payable {}

    function payOracleFeesErc20(address, /*erc20Address*/ FixedPointInterface.Unsigned calldata /*amount*/ ) external {}

    function computeRegularFee(uint256, uint256, FixedPointInterface.Unsigned calldata)
        external
        pure
        returns (FixedPointInterface.Unsigned memory regularFee, FixedPointInterface.Unsigned memory latePenalty)
    {
        regularFee = FixedPointInterface.Unsigned({rawValue: 0});
        latePenalty = FixedPointInterface.Unsigned({rawValue: 0});
    }

    function computeFinalFee(address currency) external view returns (FixedPointInterface.Unsigned memory) {
        return FixedPointInterface.Unsigned({rawValue: finalFeeByCurrency[currency]});
    }
}
