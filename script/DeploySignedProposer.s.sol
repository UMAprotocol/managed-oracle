// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {SignedProposer} from "../src/optimistic-oracle-v2/implementation/SignedProposer.sol";

/**
 * @title Deployment script for SignedProposer
 * @notice Deploys a UUPS SignedProposer implementation and atomically initialized ERC1967 proxy
 *
 * Environment variables:
 * - MNEMONIC: Required. The mnemonic phrase for the deployer wallet
 * - PERMIT2_ADDRESS: Optional. Permit2 address; defaults to the canonical deployment
 * - SIGNED_PROPOSER_ADMIN: Optional. Admin address; defaults to the deployer
 */
contract DeploySignedProposer is Script {
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (SignedProposer signedProposer) {
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address permit2Address = vm.envOr("PERMIT2_ADDRESS", CANONICAL_PERMIT2);
        address admin = vm.envOr("SIGNED_PROPOSER_ADMIN", deployer);

        console.log("Deployer:", deployer);
        console.log("Permit2:", permit2Address);
        console.log("Admin:", admin);

        vm.startBroadcast(deployerPrivateKey);

        SignedProposer implementation = new SignedProposer();
        signedProposer = SignedProposer(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(SignedProposer.initialize, (ISignatureTransfer(permit2Address), admin))
                )
            )
        );

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("SignedProposer proxy:", address(signedProposer));
        console.log("SignedProposer implementation:", address(implementation));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Permit2:", permit2Address);
        console.log("Admin:", admin);
    }
}
