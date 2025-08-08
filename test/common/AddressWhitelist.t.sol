// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AddressWhitelist} from "src/common/implementation/AddressWhitelist.sol";
import {AddressWhitelistInterface} from "src/common/interfaces/AddressWhitelistInterface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AddressWhitelistTest is Test {
    AddressWhitelist private whitelist;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private nonOwner = makeAddr("nonOwner");

    function setUp() public {
        whitelist = new AddressWhitelist();
    }

    function test_AddAndContains() public {
        assertFalse(whitelist.isOnWhitelist(alice));
        whitelist.addToWhitelist(alice);
        assertTrue(whitelist.isOnWhitelist(alice));

        address[] memory all = whitelist.getWhitelist();
        assertEq(all.length, 1);
        assertEq(all[0], alice);
    }

    function test_AddDuplicate_NoDuplicate_NoEvent() public {
        whitelist.addToWhitelist(alice);

        vm.recordLogs();
        whitelist.addToWhitelist(alice); // duplicate add should be a no-op
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "duplicate add should not emit an event");

        address[] memory all = whitelist.getWhitelist();
        assertEq(all.length, 1);
        assertEq(all[0], alice);
    }

    function test_Remove_RemovesAndUpdatesView() public {
        whitelist.addToWhitelist(alice);
        whitelist.addToWhitelist(bob);

        assertTrue(whitelist.isOnWhitelist(alice));
        assertTrue(whitelist.isOnWhitelist(bob));

        whitelist.removeFromWhitelist(alice);

        assertFalse(whitelist.isOnWhitelist(alice));
        assertTrue(whitelist.isOnWhitelist(bob));

        address[] memory all = whitelist.getWhitelist();
        assertEq(all.length, 1);
        assertEq(all[0], bob);
    }

    function test_RemoveNonexistent_NoRevert_NoEvent() public {
        vm.recordLogs();
        whitelist.removeFromWhitelist(alice); // not present
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "removing missing element should not emit an event");
    }

    function test_OnlyOwner_AddAndRemove_RevertForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        whitelist.addToWhitelist(alice);

        whitelist.addToWhitelist(alice);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        whitelist.removeFromWhitelist(alice);
    }

    function test_GetWhitelist_MultipleAddresses_IgnoresOrder() public {
        whitelist.addToWhitelist(alice);
        whitelist.addToWhitelist(bob);
        whitelist.addToWhitelist(carol);

        address[] memory all = whitelist.getWhitelist();
        assertEq(all.length, 3);
        assertTrue(_contains(all, alice));
        assertTrue(_contains(all, bob));
        assertTrue(_contains(all, carol));
    }

    function test_IsWhitelistEnabled_AlwaysTrue() public view {
        assertTrue(whitelist.isWhitelistEnabled());
    }

    function test_SupportsInterface() public view {
        bytes4 iid = type(AddressWhitelistInterface).interfaceId;
        assertTrue(whitelist.supportsInterface(iid));
        assertFalse(whitelist.supportsInterface(0xffffffff));
    }

    // --------- helpers ---------
    function _contains(address[] memory arr, address target) private pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }
}
