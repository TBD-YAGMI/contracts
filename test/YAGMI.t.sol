// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "forge-std/Test.sol";
import "../src/YAGMI.sol";

contract YAGMITest is Test {
    YAGMI yagmi;

    function setUp() public {
        yagmi = new YAGMI();
    }

    function test_RevertWhen_SetURIAsNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(0));
        yagmi.setURI('test');
        emit log("Only owner address should be able to set URI");
    }
}

