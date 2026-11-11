// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {IPublicTreasury} from "../src/interfaces/IPublicTreasury.sol";

contract USD {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blocked;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function block_(address a) external { blocked[a] = true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[to], "USD: blocked");
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

/// Returns nothing from transfer, like some widely used tokens.
contract QuietUSD {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external { balanceOf[msg.sender] -= a; balanceOf[to] += a; }
}

/// Returns false instead of reverting.
contract FalseUSD {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address, uint256) external pure returns (bool) { return false; }
}

/// A token with a very large supply held by the treasury.
contract HugeToken {
    function balanceOf(address) external pure returns (uint256) { return type(uint256).max / 1000; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

/// A worker that tries to withdraw again while being paid.
contract GreedyWorker {
    PublicTreasury public tr;
    bool public reentered;
    function set(PublicTreasury t) external { tr = t; }
    receive() external payable {
        if (!reentered) {
            reentered = true;
            (bool ok, ) = address(tr).call(abi.encodeCall(tr.withdrawEarnings, (address(0), address(this))));
            require(!ok, "re-entry paid twice");
        }
    }
}

contract Refuser {
    receive() external payable { revert("no"); }
}

/// A payee that tries to claim again while being paid.
contract Greedy {
    PublicTreasury public tr;
    uint256 public id;
    bool public reentered;
    function set(PublicTreasury t, uint256 i) external { tr = t; id = i; }
    receive() external payable {
        if (!reentered) {
            reentered = true;
            (bool ok, ) = address(tr).call(abi.encodeCall(tr.claimGrant, (id)));
            require(!ok, "re-entry paid twice");
        }
    }
}

/// One test or more per requirement of section 6.
contract PublicTreasuryTest is Test {
    PublicTreasury tr;
    USD usd;
    address gov = address(0x60F);
    address maint = address(0x3A1);   // a team maintaining public contracts
    address maint2 = address(0x3A2);
    address meter = address(0x3E7);   // reports cases ruled
    address judge = address(0x1CDE);
    address judge2 = address(0x1CDF);
    address rando = address(0xBAD);
    uint256 constant U = 1e6;

    uint64 constant NOTICE = 3 days;
    uint64 constant TERM = 365 days;
    uint16 constant CAP = 3000;

    function setUp() public {
        tr = new PublicTreasury(gov, NOTICE, TERM, CAP);
        usd = new USD();
        usd.mint(address(tr), 1_000 * U);
    }

    function _grant(address payee, uint256 per, uint64 period, uint32 n) internal returns (uint256) {
        vm.prank(gov);
        return tr.createGrant(payee, address(usd), per, period, n);
    }

    function _program(uint256 rate, uint256 budget, uint64 duration) internal returns (uint256) {
        vm.prank(gov);
        return tr.createProgram(meter, address(usd), rate, budget, duration);
    }

    // ------------------------------------------------ 6.1 fixed parameters
    function test_parameters_and_constructor_checks() public {
        assertEq(tr.governor(), gov);
        assertEq(tr.noticePeriod(), NOTICE);
        assertEq(tr.maxTerm(), TERM);
        assertEq(tr.recipientCapBps(), CAP);
        _refused(address(0), NOTICE, TERM, CAP, "Treasury: zero governor");
        _refused(gov, NOTICE, TERM, 0, "Treasury: bad cap");
        _refused(gov, NOTICE, TERM, 10_001, "Treasury: bad cap");
        _refused(gov, NOTICE, 0, CAP, "Treasury: bad times");
        _refused(gov, type(uint64).max, TERM, CAP, "Treasury: bad times");
        _refused(gov, type(uint32).max - TERM + 1, TERM, CAP, "Treasury: bad times");
        new PublicTreasury(gov, type(uint32).max - TERM, TERM, CAP); // the largest allowed
        new PublicTreasury(gov, 0, 1, 10_000);
    }

    /// try/catch rather than expectRevert: with dynamic test linking, an expected revert
    /// in a `new` ends the test early and skips the checks after it.
    function _refused(address g, uint64 notice, uint64 term, uint16 cap, string memory why) internal {
        try new PublicTreasury(g, notice, term, cap) returns (PublicTreasury) {
            assertTrue(false, string.concat("deployed, expected: ", why));
        } catch Error(string memory got) {
            assertEq(got, why);
        }
    }

    // ------------------------------------------------ 6.2 accepts the native currency
    function test_receives_native_currency() public {
        vm.deal(rando, 1 ether);
        vm.expectEmit(address(tr));
        emit PublicTreasury.Received(rando, 1 ether);
        vm.prank(rando);
        (bool ok, ) = address(tr).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(tr.availableOf(address(0)), 1 ether);
    }

    // ------------------------------------------------ 6.3 funded in full when made
    function test_no_promises_beyond_the_money() public {
        PublicTreasury loose = new PublicTreasury(gov, NOTICE, TERM, 10_000);
        usd.mint(address(loose), 100 * U);
        vm.startPrank(gov);
        loose.createGrant(maint, address(usd), 60 * U, 30 days, 1);
        assertEq(loose.committedOf(address(usd)), 60 * U);
        assertEq(loose.availableOf(address(usd)), 40 * U);
        vm.expectRevert("Treasury: not enough unpromised money");
        loose.createGrant(maint2, address(usd), 41 * U, 30 days, 1);
        vm.expectRevert("Treasury: not enough unpromised money");
        loose.createProgram(meter, address(usd), 1, 41 * U, 30 days);
        loose.createProgram(meter, address(usd), 1, 40 * U, 30 days); // exactly what is left
        vm.stopPrank();
        assertEq(loose.availableOf(address(usd)), 0);
    }

    // ------------------------------------------------ 6.4 announced
    function test_nothing_flows_during_the_notice() public {
        uint256 g = _grant(maint, 10 * U, 1 days, 10);
        uint256 p = _program(1 * U, 10 * U, 10 days);
        assertEq(tr.grantOf(g).start, block.timestamp + NOTICE);
        assertEq(tr.programOf(p).start, block.timestamp + NOTICE);

        vm.warp(block.timestamp + NOTICE + 1 days - 1);
        assertEq(tr.claimableOf(g), 0, "first period ends one day after the notice");
        vm.warp(block.timestamp - 1 days); // one second before the program starts
        vm.prank(meter);
        vm.expectRevert("Treasury: program not running");
        tr.reportUnits(p, judge, 1);
        vm.warp(block.timestamp + 1);
        vm.prank(meter);
        tr.reportUnits(p, judge, 1);
    }

    // ------------------------------------------------ 6.5 bounded
    function test_terms_and_zero_amounts() public {
        vm.startPrank(gov);
        tr.createGrant(maint, address(usd), 1 * U, 73 days, 5); // exactly one year
        vm.expectRevert("Treasury: term too long");
        tr.createGrant(maint, address(usd), 1 * U, 73 days + 1, 5);
        vm.expectRevert("Treasury: term too long");
        tr.createProgram(meter, address(usd), 1, 1 * U, TERM + 1);
        tr.createProgram(meter, address(usd), 1, 1 * U, TERM);

        vm.expectRevert("Treasury: empty grant");
        tr.createGrant(maint, address(usd), 0, 30 days, 1);
        vm.expectRevert("Treasury: empty grant");
        tr.createGrant(maint, address(usd), 1, 0, 1);
        vm.expectRevert("Treasury: empty grant");
        tr.createGrant(maint, address(usd), 1, 30 days, 0);
        vm.expectRevert("Treasury: empty program");
        tr.createProgram(meter, address(usd), 0, 1, 1);
        vm.expectRevert("Treasury: empty program");
        tr.createProgram(meter, address(usd), 1, 0, 1);
        vm.expectRevert("Treasury: empty program");
        tr.createProgram(meter, address(usd), 1, 1, 0);
        vm.expectRevert("Treasury: amount too large");
        tr.createGrant(maint, address(usd), uint256(type(uint128).max) + 1, 1, 1);
        vm.expectRevert("Treasury: amount too large");
        tr.createProgram(meter, address(usd), uint256(type(uint128).max) + 1, 1, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------ 6.6 capped per recipient
    function test_recipient_cap_for_grants() public {
        _grant(maint, 100 * U, 30 days, 3); // 300 = 30% of 1,000
        assertEq(tr.outstandingOf(address(usd), maint), 300 * U);
        vm.prank(gov);
        vm.expectRevert("Treasury: recipient cap");
        tr.createGrant(maint, address(usd), 1, 30 days, 1);
        _grant(maint2, 100 * U, 30 days, 3); // another team is fine
    }

    function test_recipient_cap_counts_program_budgets() public {
        _program(1 * U, 300 * U, 30 days);
        assertEq(tr.outstandingOf(address(usd), meter), 300 * U);
        vm.prank(gov);
        vm.expectRevert("Treasury: recipient cap");
        tr.createProgram(meter, address(usd), 1 * U, 1, 30 days);
    }

    function test_cap_frees_up_as_money_is_paid() public {
        uint256 g = _grant(maint, 100 * U, 30 days, 3);
        vm.warp(block.timestamp + NOTICE + 30 days);
        tr.claimGrant(g); // 100 paid: balance 900, outstanding 200, cap 270
        assertEq(tr.outstandingOf(address(usd), maint), 200 * U);
        _grant(maint, 70 * U, 30 days, 1);
        vm.prank(gov);
        vm.expectRevert("Treasury: recipient cap");
        tr.createGrant(maint, address(usd), 1, 30 days, 1);
    }

    function test_the_governor_and_zero_are_never_recipients() public {
        vm.startPrank(gov);
        vm.expectRevert("Treasury: bad recipient");
        tr.createGrant(gov, address(usd), 1 * U, 30 days, 1);
        vm.expectRevert("Treasury: bad recipient");
        tr.createGrant(address(0), address(usd), 1 * U, 30 days, 1);
        vm.expectRevert("Treasury: bad recipient");
        tr.createProgram(gov, address(usd), 1, 1 * U, 30 days);
        vm.expectRevert("Treasury: bad recipient");
        tr.createProgram(address(0), address(usd), 1, 1 * U, 30 days);
        vm.expectRevert("Treasury: bad recipient");
        tr.createGrant(address(tr), address(usd), 1 * U, 30 days, 1);
        vm.expectRevert("Treasury: bad recipient");
        tr.createProgram(address(tr), address(usd), 1, 1 * U, 30 days);
        vm.stopPrank();
    }

    function test_the_governor_and_the_treasury_are_never_workers() public {
        uint256 p = _program(1 * U, 10 * U, 30 days);
        vm.warp(block.timestamp + NOTICE);
        vm.startPrank(meter);
        vm.expectRevert("Treasury: bad report");
        tr.reportUnits(p, gov, 1);
        vm.expectRevert("Treasury: bad report");
        tr.reportUnits(p, address(tr), 1);
        vm.stopPrank();
    }

    function test_payee_and_meter_share_one_cap() public {
        _grant(maint, 200 * U, 1 days, 1);
        vm.startPrank(gov);
        vm.expectRevert("Treasury: recipient cap");
        tr.createProgram(maint, address(usd), 1, 100 * U + 1, 1 days);
        tr.createProgram(maint, address(usd), 1, 100 * U, 1 days);
        vm.stopPrank();
    }

    function test_cap_has_no_overflow_for_huge_balances() public {
        HugeToken h = new HugeToken();
        uint256 bal = h.balanceOf(address(tr));
        uint256 cap = bal / 10_000 * CAP + bal % 10_000 * CAP / 10_000;
        vm.startPrank(gov);
        tr.createProgram(meter, address(h), 1, cap, 1 days); // budgets are not limited to uint128
        vm.expectRevert("Treasury: recipient cap");
        tr.createProgram(meter, address(h), 1, 1, 1 days);
        vm.stopPrank();
    }

    function test_assets_are_independent() public {
        USD y = new USD();
        y.mint(address(tr), 10);
        vm.deal(address(tr), 1 ether);
        vm.startPrank(gov);
        tr.createGrant(maint, address(usd), 300 * U, 1 days, 1);
        tr.createGrant(maint, address(y), 3, 1 days, 1);
        tr.createGrant(maint, address(0), 0.3 ether, 1 days, 1);
        vm.stopPrank();
        assertEq(tr.availableOf(address(usd)), 700 * U);
        assertEq(tr.availableOf(address(y)), 7);
        assertEq(tr.availableOf(address(0)), 0.7 ether);
        assertEq(tr.outstandingOf(address(y), maint), 3);
        assertEq(tr.committedOf(address(0)), 0.3 ether);
    }

    // ------------------------------------------------ 6.7 only the governor commits
    function test_only_the_governor_commits_and_ends() public {
        uint256 g = _grant(maint, 10 * U, 30 days, 3);
        uint256 p = _program(1 * U, 10 * U, 30 days);
        vm.startPrank(rando);
        vm.expectRevert("Treasury: not governor");
        tr.createGrant(rando, address(usd), 1 * U, 30 days, 1);
        vm.expectRevert("Treasury: not governor");
        tr.createProgram(rando, address(usd), 1, 1 * U, 30 days);
        vm.expectRevert("Treasury: not governor");
        tr.endGrant(g);
        vm.expectRevert("Treasury: program running");
        tr.closeProgram(p);
        vm.stopPrank();
    }

    // ------------------------------------------------ 6.8 earned stays earned
    function test_ending_a_grant_keeps_what_was_earned() public {
        uint256 g = _grant(maint, 50 * U, 30 days, 6);
        vm.warp(block.timestamp + NOTICE + 65 days); // two periods earned
        vm.expectEmit(address(tr));
        emit IPublicTreasury.GrantEnded(g, 2, 200 * U);
        vm.prank(gov);
        tr.endGrant(g);
        assertEq(tr.grantOf(g).periods, 2);
        assertEq(tr.claimableOf(g), 100 * U);
        assertEq(tr.availableOf(address(usd)), 900 * U, "the rest is released");
        assertEq(tr.outstandingOf(address(usd), maint), 100 * U);
        vm.warp(block.timestamp + 365 days);
        tr.claimGrant(g);
        assertEq(usd.balanceOf(maint), 100 * U, "not a period more");
        vm.prank(gov);
        vm.expectRevert("Treasury: grant over");
        tr.endGrant(g);
    }

    function test_ending_during_the_notice_cancels() public {
        uint256 g = _grant(maint, 50 * U, 30 days, 6);
        vm.prank(gov);
        tr.endGrant(g);
        assertEq(tr.committedOf(address(usd)), 0);
        assertEq(tr.outstandingOf(address(usd), maint), 0);
        vm.warp(block.timestamp + 365 days);
        assertEq(tr.claimableOf(g), 0);
        vm.expectRevert("Treasury: nothing earned");
        tr.claimGrant(g);
    }

    function test_cannot_end_a_finished_grant() public {
        uint256 g = _grant(maint, 50 * U, 30 days, 2);
        vm.warp(block.timestamp + NOTICE + 60 days);
        vm.prank(gov);
        vm.expectRevert("Treasury: grant over");
        tr.endGrant(g);
        tr.claimGrant(g);
        assertEq(usd.balanceOf(maint), 100 * U);
    }

    function test_closing_a_program_keeps_reported_earnings() public {
        uint256 p = _program(10 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(meter);
        tr.reportUnits(p, judge, 2);

        vm.warp(block.timestamp + 91 days);
        vm.expectEmit(address(tr));
        emit IPublicTreasury.ProgramClosed(p, 80 * U);
        vm.prank(rando); // anyone, after the end
        tr.closeProgram(p);
        assertEq(tr.committedOf(address(usd)), 20 * U, "the judge's 20 is still owed");
        assertEq(tr.outstandingOf(address(usd), meter), 0);
        assertEq(tr.availableOf(address(usd)), 980 * U);
        tr.withdrawEarnings(address(usd), judge);
        assertEq(usd.balanceOf(judge), 20 * U);
        assertEq(tr.committedOf(address(usd)), 0);
        vm.expectRevert("Treasury: nothing to release");
        tr.closeProgram(p);
    }

    function test_the_governor_can_stop_a_program_early() public {
        uint256 p = _program(10 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + NOTICE + 10 days);
        vm.prank(gov);
        tr.closeProgram(p);
        assertEq(tr.programOf(p).end, block.timestamp - 1);
        vm.prank(meter);
        vm.expectRevert("Treasury: program not running");
        tr.reportUnits(p, judge, 1);
    }

    function test_the_governor_can_stop_a_program_whose_budget_is_spent() public {
        uint256 p = _program(10 * U, 100 * U, 30 days);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(meter);
        tr.reportUnits(p, judge, 10);
        vm.expectEmit(address(tr));
        emit IPublicTreasury.ProgramClosed(p, 0);
        vm.prank(gov);
        tr.closeProgram(p);
        assertEq(tr.programOf(p).end, block.timestamp - 1, "no longer shown as running");
        vm.prank(gov);
        vm.expectRevert("Treasury: nothing to release");
        tr.closeProgram(p);
        tr.withdrawEarnings(address(usd), judge);
        assertEq(usd.balanceOf(judge), 100 * U);
    }

    function test_only_the_governor_closes_at_the_last_second() public {
        uint256 p = _program(10 * U, 100 * U, 30 days);
        uint64 end = tr.programOf(p).end;
        vm.warp(end);
        vm.prank(rando);
        vm.expectRevert("Treasury: program running");
        tr.closeProgram(p);
        vm.warp(end + 1);
        vm.prank(rando);
        tr.closeProgram(p);
    }

    function test_the_governor_can_cancel_a_program_in_its_notice() public {
        uint256 p = _program(10 * U, 100 * U, 90 days);
        vm.prank(gov);
        tr.closeProgram(p);
        vm.warp(block.timestamp + NOTICE + 1 days);
        vm.prank(meter);
        vm.expectRevert("Treasury: program not running");
        tr.reportUnits(p, judge, 1);
        assertEq(tr.committedOf(address(usd)), 0);
    }

    // ------------------------------------------------ 6.9 claims
    function test_grant_pays_per_period() public {
        vm.expectEmit(address(tr));
        emit IPublicTreasury.GrantCreated(0, maint, address(usd), 50 * U, 30 days, 6, uint64(block.timestamp) + NOTICE);
        uint256 g = _grant(maint, 50 * U, 30 days, 6); // 300 over six months
        assertEq(tr.availableOf(address(usd)), 700 * U, "promised money is set aside");

        vm.warp(block.timestamp + NOTICE + 30 days - 1);
        assertEq(tr.claimableOf(g), 0);
        vm.expectRevert("Treasury: nothing earned");
        tr.claimGrant(g);
        vm.warp(block.timestamp + 1);
        assertEq(tr.claimableOf(g), 50 * U);

        vm.expectEmit(address(tr));
        emit IPublicTreasury.GrantClaimed(g, maint, 50 * U);
        vm.prank(rando); // anyone may claim; the money goes to the payee
        tr.claimGrant(g);
        assertEq(usd.balanceOf(maint), 50 * U);
        assertEq(usd.balanceOf(rando), 0);

        vm.warp(block.timestamp + 365 days);
        tr.claimGrant(g);
        assertEq(usd.balanceOf(maint), 300 * U, "never more than the grant");
        assertEq(tr.committedOf(address(usd)), 0);
        assertEq(tr.outstandingOf(address(usd), maint), 0);
    }

    function testFuzz_claimable_follows_the_schedule(uint64 period, uint32 periods, uint256 per, uint64 wait) public {
        period = uint64(bound(period, 1, 30 days));
        periods = uint32(bound(periods, 1, TERM / period));
        per = bound(per, 1, 300 * U / periods);
        wait = uint64(bound(wait, 0, 2 * TERM));
        uint256 g = _grant(maint, per, period, periods);
        uint256 t0 = block.timestamp + NOTICE;
        vm.warp(block.timestamp + wait);
        uint256 n = block.timestamp < t0 ? 0 : (block.timestamp - t0) / period;
        if (n > periods) n = periods;
        assertEq(tr.claimableOf(g), n * per);
        if (n > 0) {
            tr.claimGrant(g);
            assertEq(usd.balanceOf(maint), n * per);
            assertEq(tr.claimableOf(g), 0);
        }
    }

    // ------------------------------------------------ 6.10 units
    function test_program_pays_per_unit() public {
        uint64 start = uint64(block.timestamp) + NOTICE;
        vm.expectEmit(address(tr));
        emit IPublicTreasury.ProgramCreated(0, meter, address(usd), 10 * U, 100 * U, start, start + 90 days);
        uint256 p = _program(10 * U, 100 * U, 90 days); // 10 per case
        vm.warp(block.timestamp + NOTICE);

        vm.expectEmit(address(tr));
        emit IPublicTreasury.UnitsReported(p, judge, 3, 30 * U);
        vm.prank(meter);
        tr.reportUnits(p, judge, 3);
        assertEq(tr.earnedOf(address(usd), judge), 30 * U);
        assertEq(tr.programOf(p).remaining, 70 * U);
        assertEq(tr.outstandingOf(address(usd), meter), 70 * U);
        assertEq(tr.committedOf(address(usd)), 100 * U, "earnings stay committed until withdrawn");

        vm.prank(rando);
        vm.expectRevert("Treasury: not meter");
        tr.reportUnits(p, rando, 1);
        vm.startPrank(meter);
        vm.expectRevert("Treasury: bad report");
        tr.reportUnits(p, address(0), 1);
        vm.expectRevert("Treasury: bad report");
        tr.reportUnits(p, judge, 0);
        vm.expectRevert("Treasury: budget spent");
        tr.reportUnits(p, judge, 8);
        tr.reportUnits(p, judge2, 7); // exactly the rest
        vm.expectRevert("Treasury: budget spent");
        tr.reportUnits(p, judge, 1);
        vm.stopPrank();
    }

    function test_units_are_accepted_up_to_the_last_second() public {
        uint256 p = _program(1 * U, 10 * U, 30 days);
        uint64 end = tr.programOf(p).end;
        assertEq(end, block.timestamp + NOTICE + 30 days);
        vm.warp(end);
        vm.prank(meter);
        tr.reportUnits(p, judge, 1);
        vm.warp(end + 1);
        vm.prank(meter);
        vm.expectRevert("Treasury: program not running");
        tr.reportUnits(p, judge, 1);
    }

    function test_unit_overflow_reverts() public {
        uint256 p = _program(10 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(meter);
        vm.expectRevert();
        tr.reportUnits(p, judge, type(uint256).max);
    }

    // ------------------------------------------------ 6.11 withdrawal of earnings
    function test_anyone_withdraws_a_workers_earnings_to_the_worker() public {
        uint256 p = _program(10 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(meter);
        tr.reportUnits(p, judge, 2);
        vm.expectEmit(address(tr));
        emit IPublicTreasury.EarningsWithdrawn(address(usd), judge, 20 * U);
        vm.prank(rando);
        tr.withdrawEarnings(address(usd), judge);
        assertEq(usd.balanceOf(judge), 20 * U);
        assertEq(usd.balanceOf(rando), 0);
        assertEq(tr.earnedOf(address(usd), judge), 0);
        vm.expectRevert("Treasury: nothing earned");
        tr.withdrawEarnings(address(usd), judge);
    }

    // ------------------------------------------------ 6.12 state before transfer
    function test_reentry_cannot_claim_twice() public {
        vm.deal(address(tr), 10 ether);
        Greedy greedy = new Greedy();
        vm.prank(gov);
        uint256 g = tr.createGrant(address(greedy), address(0), 1 ether, 1 days, 2);
        greedy.set(tr, g);
        vm.warp(block.timestamp + NOTICE + 2 days);
        tr.claimGrant(g);
        assertTrue(greedy.reentered());
        assertEq(address(greedy).balance, 2 ether, "paid once, in full");
    }

    function test_reentry_cannot_withdraw_twice() public {
        vm.deal(address(tr), 10 ether);
        GreedyWorker w = new GreedyWorker();
        w.set(tr);
        vm.prank(gov);
        uint256 p = tr.createProgram(meter, address(0), 1 ether, 3 ether, 30 days);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(meter);
        tr.reportUnits(p, address(w), 2);
        tr.withdrawEarnings(address(0), address(w));
        assertTrue(w.reentered());
        assertEq(address(w).balance, 2 ether, "paid once, in full");
    }

    function test_a_worker_that_cannot_receive_keeps_its_earnings() public {
        vm.deal(address(tr), 10 ether);
        Refuser r = new Refuser();
        vm.prank(gov);
        uint256 p = tr.createProgram(meter, address(0), 1 ether, 3 ether, 30 days);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(meter);
        tr.reportUnits(p, address(r), 1);
        vm.expectRevert("Treasury: transfer failed");
        tr.withdrawEarnings(address(0), address(r));
        assertEq(tr.earnedOf(address(0), address(r)), 1 ether);
    }

    // ------------------------------------------------ 6.13 unknown ids
    function test_unknown_ids_revert() public {
        vm.expectRevert();
        tr.grantOf(0);
        vm.expectRevert();
        tr.claimableOf(0);
        vm.expectRevert();
        tr.claimGrant(0);
        vm.expectRevert();
        tr.programOf(0);
        vm.prank(gov);
        vm.expectRevert();
        tr.endGrant(0);
        vm.prank(gov);
        vm.expectRevert();
        tr.closeProgram(0);
        vm.prank(meter);
        vm.expectRevert();
        tr.reportUnits(0, judge, 1);
    }

    // ------------------------------------------------ assets
    function test_native_currency_grants_and_programs() public {
        vm.deal(address(tr), 10 ether);
        vm.startPrank(gov);
        uint256 g = tr.createGrant(maint, address(0), 1 ether, 30 days, 3);
        uint256 p = tr.createProgram(meter, address(0), 0.1 ether, 1 ether, 30 days);
        vm.stopPrank();
        vm.warp(block.timestamp + NOTICE);
        vm.prank(meter);
        tr.reportUnits(p, judge, 4);
        tr.withdrawEarnings(address(0), judge);
        assertEq(judge.balance, 0.4 ether);
        vm.warp(block.timestamp + 90 days);
        tr.claimGrant(g);
        assertEq(maint.balance, 3 ether);
    }

    function test_token_without_return_value() public {
        QuietUSD q = new QuietUSD();
        q.mint(address(tr), 1_000 * U);
        vm.prank(gov);
        uint256 g = tr.createGrant(maint, address(q), 10 * U, 1 days, 1);
        vm.warp(block.timestamp + NOTICE + 1 days);
        tr.claimGrant(g);
        assertEq(q.balanceOf(maint), 10 * U);
    }

    function test_token_returning_false_fails_and_keeps_the_claim() public {
        FalseUSD f = new FalseUSD();
        f.mint(address(tr), 1_000 * U);
        vm.prank(gov);
        uint256 g = tr.createGrant(maint, address(f), 10 * U, 1 days, 1);
        vm.warp(block.timestamp + NOTICE + 1 days);
        vm.expectRevert("Treasury: transfer failed");
        tr.claimGrant(g);
        assertEq(tr.claimableOf(g), 10 * U, "nothing lost");
    }

    function test_an_asset_without_code_cannot_be_committed() public {
        vm.prank(gov);
        vm.expectRevert();
        tr.createGrant(maint, address(0xDEAD), 1, 1 days, 1);
    }

    /// A token whose code is gone by the time of the claim (selfdestruct on chains without
    /// EIP-6780): a call to it returns nothing and succeeds, which must not count as paid.
    function test_a_token_without_code_at_claim_time_is_not_paid() public {
        QuietUSD q = new QuietUSD();
        q.mint(address(tr), 1_000 * U);
        vm.prank(gov);
        uint256 g = tr.createGrant(maint, address(q), 10 * U, 1 days, 1);
        vm.etch(address(q), "");
        vm.warp(block.timestamp + NOTICE + 1 days);
        vm.expectRevert("Treasury: transfer failed");
        tr.claimGrant(g);
    }

    function test_a_payee_that_cannot_receive_keeps_its_claim() public {
        vm.deal(address(tr), 10 ether);
        Refuser r = new Refuser();
        vm.prank(gov);
        uint256 g = tr.createGrant(address(r), address(0), 1 ether, 1 days, 1);
        vm.warp(block.timestamp + NOTICE + 1 days);
        vm.expectRevert("Treasury: transfer failed");
        tr.claimGrant(g);
        assertEq(tr.claimableOf(g), 1 ether);
        assertEq(tr.committedOf(address(0)), 1 ether);
    }

    function test_a_blocked_payee_keeps_its_claim() public {
        uint256 g = _grant(maint, 10 * U, 1 days, 1);
        usd.block_(maint);
        vm.warp(block.timestamp + NOTICE + 1 days);
        vm.expectRevert("Treasury: transfer failed");
        tr.claimGrant(g);
        assertEq(tr.claimableOf(g), 10 * U);
    }

    // ------------------------------------------------ worked examples of the ERC
    function test_worked_example_grant_and_cap() public {
        uint256 day0 = block.timestamp;
        uint256 g = _grant(maint, 20 * U, 30 days, 12); // commits 240, starts at day 3
        assertEq(tr.committedOf(address(usd)), 240 * U);
        vm.prank(gov);
        vm.expectRevert("Treasury: recipient cap"); // 340 > 30% of 1,000
        tr.createGrant(maint, address(usd), 100 * U, 30 days, 1);
        _grant(maint2, 100 * U, 30 days, 1); // another payee is accepted

        vm.warp(day0 + 33 days);
        assertEq(tr.claimableOf(g), 20 * U);
        vm.warp(day0 + 93 days);
        assertEq(tr.claimableOf(g), 60 * U);
        vm.warp(day0 + 100 days);
        vm.expectEmit(address(tr));
        emit IPublicTreasury.GrantEnded(g, 3, 180 * U);
        vm.prank(gov);
        tr.endGrant(g);
        tr.claimGrant(g);
        assertEq(usd.balanceOf(maint), 60 * U);
    }

    function test_worked_example_program() public {
        uint256 p = _program(5 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + NOTICE);
        vm.startPrank(meter);
        for (uint256 i = 0; i < 20; i++) tr.reportUnits(p, judge, 1);
        vm.expectRevert("Treasury: budget spent");
        tr.reportUnits(p, judge, 1);
        vm.stopPrank();
        assertEq(tr.earnedOf(address(usd), judge), 100 * U);
    }
}
