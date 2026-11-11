// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BallotMeter} from "../src/BallotMeter.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {ICollectiveDecisionReads as D} from "../src/interfaces/ICollectiveDecisionReads.sol";
import {IPublicTreasury} from "../src/interfaces/IPublicTreasury.sol";

contract Token {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

/// Behaves like the ERC-8436 reference registry for the three reads the meter makes.
contract MockDecisions is D {
    mapping(bytes32 => Result) internal _results;
    mapping(bytes32 => mapping(uint32 => RoundState)) internal _rounds;
    mapping(bytes32 => mapping(uint32 => mapping(uint32 => mapping(address => bool)))) internal _voted;

    function setIssue(bytes32 id, bytes32 policyId, address consumer, uint8 state, uint32 roundCount) external {
        Result storage r = _results[id];
        r.policyId = policyId;
        r.consumer = consumer;
        r.state = state;
        r.roundCount = roundCount;
    }

    function startRound(bytes32 id, uint32 round, uint64 at) external { _rounds[id][round].startedAt = at; }
    function vote(bytes32 id, uint32 round, uint32 body, address voter) external { _voted[id][round][body][voter] = true; }

    function getResult(bytes32 id) external view returns (Result memory) { return _results[id]; }
    function getRound(bytes32 id, uint32 round) external view returns (RoundState memory) {
        require(round >= 1 && round <= _results[id].roundCount, "ACDF: round index");
        return _rounds[id][round];
    }
    function hasVoted(bytes32 id, uint32 round, uint32 body, address voter) external view returns (bool) {
        return _voted[id][round][body][voter];
    }
}

contract BallotMeterTest is Test {
    uint8 constant DECIDING = 2;
    uint8 constant FINAL = 4;
    uint256 constant U = 1e6;

    Token usdc;
    PublicTreasury treasury;
    MockDecisions acdf;
    BallotMeter meter;

    address gov = address(0x60F);
    address bridge = address(0xB1D6E);   // the dispute registry's bridge: the consumer that files
    bytes32 council = keccak256("judges' council policy");
    address j1 = address(0x11);
    address j2 = address(0x12);
    address j3 = address(0x13);
    uint256 pid;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new Token();
        treasury = new PublicTreasury(gov, 3 days, 365 days, 3000);
        acdf = new MockDecisions();
        meter = new BallotMeter(acdf, council, bridge, treasury);
        usdc.mint(address(treasury), 1_000 * U);

        vm.prank(gov);
        pid = treasury.createProgram(address(meter), address(usdc), 2 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + 3 days); // the notice runs; the program starts
    }

    /// A case decided in one round by three judges, the round started now.
    function _case(bytes32 id) internal {
        acdf.setIssue(id, council, bridge, FINAL, 1);
        acdf.startRound(id, 1, uint64(block.timestamp));
        acdf.vote(id, 1, 0, j1);
        acdf.vote(id, 1, 0, j2);
        acdf.vote(id, 1, 0, j3);
    }

    function _refused(bytes memory call, string memory reason) internal {
        (bool ok, bytes memory ret) = address(meter).call(call);
        assertFalse(ok, "should revert");
        assertEq(ret, abi.encodeWithSignature("Error(string)", reason));
    }

    function _report(uint256 program, bytes32 id, uint32 round, uint32 body, address voter)
        internal pure returns (bytes memory)
    {
        return abi.encodeCall(BallotMeter.report, (program, id, round, body, voter));
    }

    // ------------------------------------------------------------------ counting

    function test_each_judge_is_paid_per_ballot() public {
        _case("case-1");
        _case("case-2");
        meter.report(pid, "case-1", 1, 0, j1);
        meter.report(pid, "case-1", 1, 0, j2);
        meter.report(pid, "case-2", 1, 0, j1);

        assertEq(treasury.earnedOf(address(usdc), j1), 4 * U);
        assertEq(treasury.earnedOf(address(usdc), j2), 2 * U);
        assertEq(treasury.earnedOf(address(usdc), j3), 0);
        assertEq(treasury.programOf(pid).remaining, 94 * U);

        treasury.withdrawEarnings(address(usdc), j1);
        assertEq(usdc.balanceOf(j1), 4 * U);
    }

    function test_anyone_can_report() public {
        _case("case-1");
        vm.prank(address(0xBEEF));
        meter.report(pid, "case-1", 1, 0, j3);
        assertEq(treasury.earnedOf(address(usdc), j3), 2 * U);
    }

    function test_a_ballot_counts_once() public {
        _case("case-1");
        meter.report(pid, "case-1", 1, 0, j1);
        _refused(_report(pid, "case-1", 1, 0, j1), "Meter: counted");
        assertTrue(meter.counted(meter.ballotKey("case-1", 1, 0, j1)));
    }

    function test_a_ballot_counts_once_across_programs() public {
        vm.prank(gov);
        uint256 second = treasury.createProgram(address(meter), address(usdc), 2 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + 3 days); // both programs running
        _case("case-1");
        meter.report(pid, "case-1", 1, 0, j1);
        _refused(_report(second, "case-1", 1, 0, j1), "Meter: counted");
        meter.report(second, "case-1", 1, 0, j2); // another ballot may go to either
        assertEq(treasury.earnedOf(address(usdc), j1), 2 * U);
    }

    function test_every_round_of_an_appealed_case_counts() public {
        bytes32 id = "appealed";
        acdf.setIssue(id, council, bridge, FINAL, 2);
        acdf.startRound(id, 1, uint64(block.timestamp));
        acdf.startRound(id, 2, uint64(block.timestamp + 1 days));
        acdf.vote(id, 1, 0, j1);
        acdf.vote(id, 2, 0, j1);
        meter.report(pid, id, 1, 0, j1);
        meter.report(pid, id, 2, 0, j1);
        assertEq(treasury.earnedOf(address(usdc), j1), 4 * U);
    }

    // ------------------------------------------------------------------ refusals

    function test_a_decision_that_is_not_final_does_not_count() public {
        _case("case-1");
        acdf.setIssue("case-1", council, bridge, DECIDING, 1);
        _refused(_report(pid, "case-1", 1, 0, j1), "Meter: not final");
    }

    function test_another_policy_or_consumer_does_not_count() public {
        _case("case-1");
        acdf.setIssue("case-1", keccak256("another council"), bridge, FINAL, 1);
        _refused(_report(pid, "case-1", 1, 0, j1), "Meter: not in scope");
        acdf.setIssue("case-1", council, address(0xC0), FINAL, 1);
        _refused(_report(pid, "case-1", 1, 0, j1), "Meter: not in scope");
    }

    function test_an_unknown_issue_does_not_count() public {
        _refused(_report(pid, "nothing", 1, 0, j1), "Meter: not in scope");
    }

    function test_no_ballot_no_pay() public {
        _case("case-1");
        _refused(_report(pid, "case-1", 1, 0, address(0x99)), "Meter: no ballot");
        _refused(_report(pid, "case-1", 1, 1, j1), "Meter: no ballot"); // another body
    }

    function test_a_round_outside_the_issue_does_not_count() public {
        _case("case-1");
        acdf.vote("case-1", 2, 0, j1); // a ballot record the registry would never hold
        _refused(_report(pid, "case-1", 2, 0, j1), "ACDF: round index");
    }

    function test_work_before_the_program_started_is_not_paid_by_it() public {
        bytes32 id = "old";
        acdf.setIssue(id, council, bridge, FINAL, 1);
        acdf.startRound(id, 1, treasury.programOf(pid).start - 1);
        acdf.vote(id, 1, 0, j1);
        _refused(_report(pid, id, 1, 0, j1), "Meter: before the program");
    }

    function test_a_program_with_another_meter_refuses() public {
        _case("case-1");
        vm.prank(gov);
        uint256 other = treasury.createProgram(address(0x3E7), address(usdc), 2 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + 3 days);
        _case("case-2");
        _refused(_report(other, "case-2", 1, 0, j1), "Treasury: not meter");
        assertFalse(meter.counted(meter.ballotKey("case-2", 1, 0, j1)), "a refused report counts nothing");
    }

    function test_an_ended_program_refuses_and_a_new_one_pays() public {
        vm.warp(treasury.programOf(pid).end + 1);
        _case("late");
        _refused(_report(pid, "late", 1, 0, j1), "Treasury: program not running");

        vm.prank(gov);
        uint256 next = treasury.createProgram(address(meter), address(usdc), 2 * U, 100 * U, 90 days);
        vm.warp(block.timestamp + 3 days);
        _refused(_report(next, "late", 1, 0, j1), "Meter: before the program");
        _case("new");
        meter.report(next, "new", 1, 0, j1);
        assertEq(treasury.earnedOf(address(usdc), j1), 2 * U);
    }

    function test_a_spent_budget_refuses() public {
        vm.prank(gov);
        uint256 small = treasury.createProgram(address(meter), address(usdc), 2 * U, 3 * U, 90 days);
        vm.warp(block.timestamp + 3 days);
        _case("case-1");
        meter.report(small, "case-1", 1, 0, j1);
        _refused(_report(small, "case-1", 1, 0, j2), "Treasury: budget spent");
    }

    // ------------------------------------------------------------------ setup

    function test_constructor_checks() public {
        assertTrue(_deployFails(D(address(0xD0)), council, bridge, treasury));
        assertTrue(_deployFails(acdf, council, bridge, IPublicTreasury(address(0xD0))));
        assertTrue(_deployFails(acdf, bytes32(0), bridge, treasury));
        assertTrue(_deployFails(acdf, council, address(0), treasury));
        assertFalse(_deployFails(acdf, council, bridge, treasury));
    }

    function _deployFails(D r, bytes32 p, address c, IPublicTreasury t) internal returns (bool) {
        try new BallotMeter(r, p, c, t) returns (BallotMeter) { return false; } catch { return true; }
    }
}
