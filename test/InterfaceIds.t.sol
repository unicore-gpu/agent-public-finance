// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITaxSchedule} from "settlement-deductions/interfaces/ITaxSchedule.sol";
import {IPublicTaxSchedule} from "../src/interfaces/IPublicTaxSchedule.sol";
import {IPublicTreasury} from "../src/interfaces/IPublicTreasury.sol";

/// The identifiers published in the ERC's Test Cases section.
contract InterfaceIdsTest is Test {
    function test_interface_ids() public pure {
        assertEq(type(ITaxSchedule).interfaceId, bytes4(0xbbb356a6));
        assertEq(type(IPublicTaxSchedule).interfaceId, bytes4(0x562cde7d));
        assertEq(type(IPublicTreasury).interfaceId, bytes4(0x0ea4abf4));
    }
}
