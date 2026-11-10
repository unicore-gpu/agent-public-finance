// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TaxSchedule} from "../src/TaxSchedule.sol";
import {IPublicTaxSchedule} from "../src/interfaces/IPublicTaxSchedule.sol";

/// One test or more per requirement of section 4.
contract TaxScheduleTest is Test {
    TaxSchedule s;
    address gov = address(0x60F);
    address treasury = address(0x7EA5);
    address usdc = address(0x05DC);
    address eurc = address(0xE0C);
    address rando = address(0xBAD);

    uint16 constant MAX = 500;
    uint64 constant NOTICE = 7 days;

    function setUp() public {
        s = new TaxSchedule(gov, treasury, MAX, NOTICE);
    }

    // ------------------------------------------------ 4.1 fixed parameters
    function test_parameters() public view {
        assertEq(s.governor(), gov);
        assertEq(s.treasury(), treasury);
        assertEq(s.maxRateBps(), MAX);
        assertEq(s.rateNotice(), NOTICE);
    }

    function test_constructor_checks() public {
        _refused(address(0), treasury, MAX, NOTICE, "Tax: zero address");
        _refused(gov, address(0), MAX, NOTICE, "Tax: zero address");
        _refused(gov, treasury, 10_001, NOTICE, "Tax: bad ceiling");
        _refused(gov, treasury, MAX, uint64(type(uint32).max) + 1, "Tax: bad notice");
        new TaxSchedule(gov, treasury, 10_000, 0); // the extremes are allowed
        new TaxSchedule(gov, treasury, 0, type(uint32).max);
    }

    /// try/catch rather than expectRevert: with dynamic test linking, an expected revert
    /// in a `new` ends the test early and skips the checks after it.
    function _refused(address g, address t, uint16 max, uint64 notice, string memory why) internal {
        try new TaxSchedule(g, t, max, notice) returns (TaxSchedule) {
            assertTrue(false, string.concat("deployed, expected: ", why));
        } catch Error(string memory got) {
            assertEq(got, why);
        }
    }

    // ------------------------------------------------ 4.2 reading
    function testFuzz_taxOf_never_reverts_and_names_the_treasury(address asset, uint64 t) public {
        vm.warp(t);
        (address to, uint16 bps) = s.taxOf(asset);
        assertEq(to, treasury);
        assertEq(bps, 0, "no rate means untaxed");
    }

    // ------------------------------------------------ 4.3 and 4.4 proposals take effect by themselves
    function test_rate_takes_effect_exactly_after_the_notice() public {
        vm.expectEmit(address(s));
        emit IPublicTaxSchedule.RateProposed(usdc, 100, uint64(block.timestamp) + NOTICE);
        vm.prank(gov);
        s.proposeRate(usdc, 100);

        (uint16 pb, uint64 at) = s.pendingRateOf(usdc);
        assertEq(pb, 100);
        assertEq(at, block.timestamp + NOTICE);

        vm.warp(at - 1);
        assertEq(s.rateOf(usdc), 0, "one second early");
        (, uint16 bps) = s.taxOf(usdc);
        assertEq(bps, 0);

        vm.warp(at);
        assertEq(s.rateOf(usdc), 100, "in force, with no transaction");
        (, bps) = s.taxOf(usdc);
        assertEq(bps, 100);
        (pb, at) = s.pendingRateOf(usdc);
        assertEq(at, 0, "nothing pending any more");
        assertEq(pb, 0);
    }

    function test_ceiling_holds() public {
        vm.startPrank(gov);
        s.proposeRate(usdc, MAX);
        vm.expectRevert("Tax: above ceiling");
        s.proposeRate(usdc, MAX + 1);
        vm.stopPrank();
    }

    function test_only_the_governor_changes_rates() public {
        vm.prank(rando);
        vm.expectRevert("Tax: not governor");
        s.proposeRate(usdc, 100);
        vm.prank(gov);
        s.proposeRate(usdc, 100);
        vm.prank(rando);
        vm.expectRevert("Tax: not governor");
        s.withdrawProposal(usdc);
    }

    function test_replacing_a_waiting_proposal_restarts_the_notice() public {
        vm.prank(gov);
        s.proposeRate(usdc, 100);
        vm.warp(block.timestamp + 5 days);

        vm.expectEmit(address(s));
        emit IPublicTaxSchedule.RateProposalWithdrawn(usdc, 100);
        vm.expectEmit(address(s));
        emit IPublicTaxSchedule.RateProposed(usdc, 200, uint64(block.timestamp) + NOTICE);
        vm.prank(gov);
        s.proposeRate(usdc, 200);

        vm.warp(block.timestamp + 2 days); // when 1% would have taken effect
        assertEq(s.rateOf(usdc), 0, "the replaced proposal never takes effect");
        vm.warp(block.timestamp + 5 days);
        assertEq(s.rateOf(usdc), 200);
    }

    function test_a_new_proposal_keeps_the_rate_in_force_meanwhile() public {
        vm.prank(gov);
        s.proposeRate(usdc, 100);
        vm.warp(block.timestamp + NOTICE);

        vm.recordLogs();
        vm.prank(gov);
        s.proposeRate(usdc, 300);
        assertEq(vm.getRecordedLogs().length, 1, "a proposal that took effect is not 'withdrawn'");

        assertEq(s.rateOf(usdc), 100);
        vm.warp(block.timestamp + NOTICE);
        assertEq(s.rateOf(usdc), 300);
    }

    function test_rates_are_per_asset() public {
        vm.startPrank(gov);
        s.proposeRate(usdc, 100);
        s.proposeRate(eurc, 250);
        vm.stopPrank();
        vm.warp(block.timestamp + NOTICE);
        assertEq(s.rateOf(usdc), 100);
        assertEq(s.rateOf(eurc), 250);
        assertEq(s.rateOf(address(0)), 0);
    }

    function test_lowering_to_zero_untaxes() public {
        vm.prank(gov);
        s.proposeRate(usdc, 100);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(gov);
        s.proposeRate(usdc, 0);
        vm.warp(block.timestamp + NOTICE);
        assertEq(s.rateOf(usdc), 0);
    }

    function test_zero_notice_takes_effect_at_once() public {
        TaxSchedule now_ = new TaxSchedule(gov, treasury, MAX, 0);
        vm.prank(gov);
        now_.proposeRate(usdc, 100);
        assertEq(now_.rateOf(usdc), 100);
        (, uint64 at) = now_.pendingRateOf(usdc);
        assertEq(at, 0);
    }

    // ------------------------------------------------ 4.5 withdrawal
    function test_withdraw_in_the_notice() public {
        vm.prank(gov);
        s.proposeRate(usdc, 100);
        vm.expectEmit(address(s));
        emit IPublicTaxSchedule.RateProposalWithdrawn(usdc, 100);
        vm.prank(gov);
        s.withdrawProposal(usdc);
        vm.warp(block.timestamp + 30 days);
        assertEq(s.rateOf(usdc), 0);
    }

    function test_cannot_withdraw_what_took_effect() public {
        vm.prank(gov);
        s.proposeRate(usdc, 100);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(gov);
        vm.expectRevert("Tax: no proposal");
        s.withdrawProposal(usdc);
        assertEq(s.rateOf(usdc), 100);
    }

    function test_cannot_withdraw_nothing() public {
        vm.prank(gov);
        vm.expectRevert("Tax: no proposal");
        s.withdrawProposal(usdc);
    }

    /// The rate example of the ERC's Test Cases, exactly.
    function test_worked_example_rates() public {
        uint256 d0 = block.timestamp;
        vm.prank(gov);
        s.proposeRate(usdc, 100);
        vm.warp(d0 + 7 days - 1);
        (, uint16 bps) = s.taxOf(usdc);
        assertEq(bps, 0);
        vm.warp(d0 + 7 days);
        (, bps) = s.taxOf(usdc);
        assertEq(bps, 100);
        vm.prank(gov);
        vm.expectRevert("Tax: above ceiling");
        s.proposeRate(usdc, 600);
        vm.warp(d0 + 10 days);
        vm.prank(gov);
        s.proposeRate(usdc, 200);
        vm.warp(d0 + 12 days);
        vm.prank(gov);
        s.withdrawProposal(usdc);
        vm.warp(d0 + 100 days);
        assertEq(s.rateOf(usdc), 100);
    }

    // ------------------------------------------------ a model of the rules
    /// Any two proposals at any times: the rate at any later moment is what the rules say.
    function testFuzz_rate_follows_the_rules(uint16 a, uint16 b, uint32 gap, uint32 probe) public {
        a = uint16(bound(a, 0, MAX));
        b = uint16(bound(b, 0, MAX));
        uint256 t0 = block.timestamp;
        vm.prank(gov);
        s.proposeRate(usdc, a);
        vm.warp(t0 + gap);
        vm.prank(gov);
        s.proposeRate(usdc, b);
        uint256 t1 = t0 + gap;
        vm.warp(t1 + probe);

        uint16 expected;
        if (probe >= NOTICE) expected = b;
        else if (gap >= NOTICE) expected = a; // a took effect before b was proposed
        else expected = 0;                    // a was replaced while still waiting
        assertEq(s.rateOf(usdc), expected);
    }
}
