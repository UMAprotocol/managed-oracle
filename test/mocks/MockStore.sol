// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StoreInterface} from "../../src/data-verification-mechanism/interfaces/StoreInterface.sol";
import {FixedPoint} from "../../src/common/implementation/FixedPoint.sol";

/**
 * @title Mock Store contract for testing.
 * @notice Implements StoreInterface for testing the ManagedOptimisticOracleV2 contract.
 */
contract MockStore is StoreInterface {
    /**
     * @notice Pays Oracle fees in ETH to the store.
     * @dev Mock implementation that accepts ETH payments.
     */
    function payOracleFees() external payable override {
        // Mock implementation - just accept the payment
    }

    /**
     * @notice Pays oracle fees in the margin currency, erc20Address, to the store.
     * @dev Mock implementation that accepts ERC20 payments.
     * @param erc20Address address of the ERC20 token used to pay the fee.
     * @param amount number of tokens to transfer. An approval for at least this amount must exist.
     */
    function payOracleFeesErc20(address erc20Address, FixedPoint.Unsigned calldata amount) external override {
        // Mock implementation - just accept the payment
    }

    /**
     * @notice Computes the regular oracle fees that a contract should pay for a period.
     * @dev Mock implementation that returns fixed fees.
     * @param startTime defines the beginning time from which the fee is paid.
     * @param endTime end time until which the fee is paid.
     * @param pfc "profit from corruption", or the maximum amount of margin currency that a
     * token sponsor could extract from the contract through corrupting the price feed in their favor.
     * @return regularFee amount owed for the duration from start to end time for the given pfc.
     * @return latePenalty for paying the fee after the deadline.
     */
    function computeRegularFee(uint256 startTime, uint256 endTime, FixedPoint.Unsigned calldata pfc)
        external
        pure
        override
        returns (FixedPoint.Unsigned memory regularFee, FixedPoint.Unsigned memory latePenalty)
    {
        // Mock implementation - return fixed fees
        regularFee = FixedPoint.fromUnscaledUint(100e18); // 100 tokens
        latePenalty = FixedPoint.fromUnscaledUint(0);
    }

    /**
     * @notice Computes the final oracle fees that a contract should pay at settlement.
     * @param currency token used to pay the final fee.
     * @return finalFee amount due.
     */
    function computeFinalFee(address currency) external pure override returns (FixedPoint.Unsigned memory) {
        // Mock implementation - return fixed final fee of 100 tokens
        return FixedPoint.Unsigned(100e18);
    }
}
