// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "acdf-test/ACDFBase.t.sol";
import {ACDFTypes as T} from "acdf/ACDFTypes.sol";
import {ACDFTaskTenderAdapter} from "acdf/adapters/ACDFTaskTenderAdapter.sol";
import {ITaskTenderKernel} from "acdf/interfaces/ITaskTenderKernel.sol";
import {DeductingTaskToken} from "task-token/companions/DeductingTaskToken.sol";
import {ITaskTender} from "task-token/contracts/interfaces/ITaskTender.sol";
import {SettlementDeductionPolicy} from "settlement-deductions/SettlementDeductionPolicy.sol";
import {TaxSchedule} from "../src/TaxSchedule.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {BallotMeter} from "../src/BallotMeter.sol";
import {ICollectiveDecisionReads as D} from "../src/interfaces/ICollectiveDecisionReads.sol";

contract USDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// The whole loop on the real contracts: ERC-8414 tasks (the kernel with the settlement
/// deduction hook) pay tax at settlement into the public treasury, and the treasury pays the
/// judges of an ERC-8436 council per ballot on the tasks they judge through the 8436-8414
/// adapter. ACDFBase is the ERC-8436 reference's own test base: its registry, its five
/// roster members and its ballot helper.
contract JudgedTendersTest is ACDFBase {
    uint256 constant U = 1e6;
    uint64 constant MARGIN = 1 hours;

    USDC usdc;
    PublicTreasury treasury;
    TaxSchedule schedule;
    DeductingTaskToken task;
    SettlementDeductionPolicy deductions;
    ACDFTaskTenderAdapter adapter;
    BallotMeter meter;
    bytes32 council;
    uint256 pid;

    address gov       = address(0x60F);
    address owner     = address(0xA11CE);
    address publisher = address(0xB0B);
    address client    = address(0xC11);
    address worker    = address(0xCAFE);
    address reviewer  = address(0x5EE);   // accepts the ordinary, unjudged tasks

    function setUp() public override {
        super.setUp(); // the 8436 policy and decision registries, five members, a fixed clock

        usdc = new USDC();
        treasury = new PublicTreasury(gov, 3 days, 365 days, 3000);
        schedule = new TaxSchedule(gov, address(treasury), 500, 7 days);
        task = new DeductingTaskToken("Task", "TASK", schedule, 3000);
        deductions = SettlementDeductionPolicy(payable(vm.computeCreateAddress(address(task), 1)));
        assertEq(task.deductionPolicy(), address(deductions));

        // The judges' council: 3 of the 5 members, one day to vote, no appeal.
        T.PolicySpec memory s = minimalSpec(5, 3, 1 days);
        s.family = keccak256("judges.task-acceptance");
        s.maxTotalDuration = 2 days;
        council = register(s);
        adapter = new ACDFTaskTenderAdapter(reg, ITaskTenderKernel(address(task)), council, MARGIN);
        meter = new BallotMeter(D(address(reg)), council, address(adapter), treasury);

        vm.prank(gov);
        schedule.proposeRate(address(usdc), 100); // 1%
        vm.warp(block.timestamp + 7 days);
        usdc.mint(client, 1_000_000 * U);

        // Ten ordinary tasks of 1,000 settle and pay 1% each; anyone collects it.
        for (uint256 i = 0; i < 10; i++) {
            uint256 id = _mint(reviewer, 1_000 * U);
            uint256 sid = _submit(id);
            vm.prank(reviewer);
            task.acceptFulfillment(id, sid);
            deductions.claim(id, address(treasury));
        }
        assertEq(usdc.balanceOf(address(treasury)), 100 * U);
        assertEq(usdc.balanceOf(worker), 10 * 990 * U);

        // The governor opens a judging program: 2 per ballot, budget 30 (the 30% cap).
        vm.prank(gov);
        pid = treasury.createProgram(address(meter), address(usdc), 2 * U, 30 * U, 90 days);
        vm.warp(block.timestamp + 3 days);
    }

    function _mint(address authority, uint256 reward) internal returns (uint256 id) {
        ITaskTender.TenderTerms memory t =
            ITaskTender.TenderTerms(address(usdc), reward, 1, 0, 0, 0, 0, 7 days);
        id = task.mintTask(owner, publisher, authority, TD, TH, "ipfs://task", t);
        vm.startPrank(client);
        usdc.approve(address(task), reward);
        task.fundTask(id, reward);
        vm.stopPrank();
    }

    function _submit(uint256 id) internal returns (uint256 sid) {
        bytes32 res = RES_; // a sha256 constant is a precompile call: take it before the prank
        vm.prank(worker);
        sid = task.submitFulfillment(id, res, "ipfs://result");
    }

    bytes32 constant RES_ = sha256("deliverable");
    bytes32 constant TD = sha256("TASK.md");
    bytes32 constant TH = sha256("taskroot");

    function _judgedSubmission() internal returns (uint256 id, bytes32 issueId) {
        id = _mint(address(adapter), 1_000 * U);
        uint256 sid = _submit(id);
        issueId = adapter.open(id, sid);
    }

    function _refused(bytes memory call, string memory reason) internal {
        (bool ok, bytes memory ret) = address(meter).call(call);
        assertFalse(ok, "should revert");
        assertEq(ret, abi.encodeWithSignature("Error(string)", reason));
    }

    // ------------------------------------------------------------------ the loop

    function test_the_tax_on_a_judged_task_pays_its_judges() public {
        (uint256 id, bytes32 issueId) = _judgedSubmission();
        vote(issueId, 0, 0, true);
        vote(issueId, 0, 1, true);
        vote(issueId, 0, 2, true);
        reg.settleRound(issueId);
        assertFinalDecided(issueId, true);

        // The council's decision is enacted: the kernel accepts and pays, less the tax.
        adapter.execute(issueId);
        assertEq(usdc.balanceOf(worker), 11 * 990 * U);
        deductions.claim(id, address(treasury));
        assertEq(usdc.balanceOf(address(treasury)), 110 * U);

        // Anyone reports the three ballots; each judge earns 2 and withdraws it.
        for (uint256 i = 0; i < 3; i++) meter.report(pid, issueId, 1, 0, members[i]);
        _refused(abi.encodeCall(BallotMeter.report, (pid, issueId, 1, 0, members[3])), "Meter: no ballot");
        for (uint256 i = 0; i < 3; i++) {
            treasury.withdrawEarnings(address(usdc), members[i]);
            assertEq(usdc.balanceOf(members[i]), 2 * U);
        }
        assertEq(usdc.balanceOf(address(treasury)), 104 * U);
        assertEq(treasury.programOf(pid).remaining, 24 * U);
    }

    function test_judges_are_paid_when_they_reject() public {
        (, bytes32 issueId) = _judgedSubmission();
        vote(issueId, 0, 0, false);
        vote(issueId, 0, 1, true);
        vote(issueId, 0, 2, false);
        vote(issueId, 0, 3, false);
        reg.settleRound(issueId);
        assertFinalDecided(issueId, false);
        adapter.execute(issueId);
        assertEq(usdc.balanceOf(worker), 10 * 990 * U, "rejected: no payout, no tax");

        for (uint256 i = 0; i < 4; i++) meter.report(pid, issueId, 1, 0, members[i]);
        for (uint256 i = 0; i < 4; i++) assertEq(treasury.earnedOf(address(usdc), members[i]), 2 * U);
    }

    function test_judges_are_paid_when_the_council_reaches_no_decision() public {
        (, bytes32 issueId) = _judgedSubmission();
        vote(issueId, 0, 0, true);
        vote(issueId, 0, 1, false);
        vm.warp(block.timestamp + 1 days + 1);
        reg.settleRound(issueId);
        assertFinalNoDecision(issueId, T.Reason.QUORUM_NOT_MET);

        meter.report(pid, issueId, 1, 0, members[0]);
        meter.report(pid, issueId, 1, 0, members[1]);
        assertEq(treasury.earnedOf(address(usdc), members[0]), 2 * U);
        assertEq(treasury.earnedOf(address(usdc), members[1]), 2 * U);
    }

    function test_a_ballot_is_not_counted_before_the_decision_is_final() public {
        (, bytes32 issueId) = _judgedSubmission();
        vote(issueId, 0, 0, true);
        _refused(abi.encodeCall(BallotMeter.report, (pid, issueId, 1, 0, members[0])), "Meter: not final");
    }

    /// Someone else files decisions under the same council policy: the council may judge
    /// them, but the treasury does not pay for them.
    function test_the_same_council_judging_for_another_consumer_is_not_paid() public {
        bytes32 other = fileAsConsumer(council, 42);
        vote(other, 0, 0, true);
        vote(other, 0, 1, true);
        vote(other, 0, 2, true);
        reg.settleRound(other);
        assertFinalDecided(other, true);
        _refused(abi.encodeCall(BallotMeter.report, (pid, other, 1, 0, members[0])), "Meter: not in scope");
    }

    /// A council whose judges sign their ballots off chain, submitted in one batch by anyone:
    /// the judges need no ether, and the meter counts their ballots the same way.
    function test_signed_ballots_are_paid_the_same() public {
        T.BodySpec[] memory bodies = new T.BodySpec[](1);
        bodies[0] = rosterBody(5, 3, 1 days, T.Acceptance.SIGNED_BALLOTS);
        T.Node[] memory nodes = new T.Node[](1);
        nodes[0] = bodyNode(0);
        T.PolicySpec memory s = spec(bodies, nodes, keccak256("judges.signed"));
        s.maxTotalDuration = 2 days;
        bytes32 signedCouncil = register(s);
        ACDFTaskTenderAdapter a2 = new ACDFTaskTenderAdapter(reg, ITaskTenderKernel(address(task)), signedCouncil, MARGIN);
        BallotMeter m2 = new BallotMeter(D(address(reg)), signedCouncil, address(a2), treasury);
        vm.prank(gov);
        uint256 p2 = treasury.createProgram(address(m2), address(usdc), 2 * U, 10 * U, 90 days);
        vm.warp(block.timestamp + 3 days);

        uint256 id = _mint(address(a2), 1_000 * U);
        bytes32 issueId = a2.open(id, _submit(id));
        address[] memory voters = new address[](3);
        bool[] memory approves = new bool[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            voters[i] = members[i];
            approves[i] = true;
            sigs[i] = sign(pk[i], reg.ballotDigest(issueId, 1, 0, members[i], true));
        }
        vm.prank(address(0xBEEF)); // anyone submits the batch
        reg.submitSignedBallots(issueId, 0, voters, approves, sigs);
        reg.settleRound(issueId);
        a2.execute(issueId);
        assertEq(usdc.balanceOf(worker), 11 * 990 * U);

        for (uint256 i = 0; i < 3; i++) m2.report(p2, issueId, 1, 0, members[i]);
        for (uint256 i = 0; i < 3; i++) assertEq(treasury.earnedOf(address(usdc), members[i]), 2 * U);
        assertEq(members[0].balance + members[1].balance + members[2].balance, 0, "the judges hold no ether");
    }

    // ------------------------------------------------------------------ the reads

    /// The meter's three reads decode the real registry's return data field by field.
    function test_the_meter_reads_the_real_registry() public {
        (, bytes32 issueId) = _judgedSubmission();
        vote(issueId, 0, 0, true);
        vote(issueId, 0, 1, true);
        vote(issueId, 0, 2, true);
        reg.settleRound(issueId);

        T.Result memory a = reg.getResult(issueId);
        D.Result memory b = D(address(reg)).getResult(issueId);
        assertEq(b.state, uint8(a.state));
        assertEq(b.outcomeType, uint8(a.outcomeType));
        assertEq(b.outcomeYes, a.outcomeYes);
        assertEq(b.reason, uint8(a.reason));
        assertEq(b.decidedAt, a.decidedAt);
        assertEq(b.finalAt, a.finalAt);
        assertEq(b.policyId, a.policyId);
        assertEq(b.roundCount, a.roundCount);
        assertEq(b.sourceRound, a.sourceRound);
        assertEq(b.effectClass, uint8(a.effectClass));
        assertEq(b.consumer, a.consumer);
        assertEq(b.effectYes, a.effectYes);
        assertEq(b.effectNo, a.effectNo);
        assertEq(b.disposition, a.disposition);
        assertEq(b.obligationId, a.obligationId);
        assertEq(b.adoptedFromEarlierRound, a.adoptedFromEarlierRound);
        assertEq(b.state, 4, "Final");
        assertEq(b.consumer, address(adapter));

        T.RoundState memory ra = reg.getRound(issueId, 1);
        D.RoundState memory rb = D(address(reg)).getRound(issueId, 1);
        assertEq(rb.startedAt, ra.startedAt);
        assertEq(rb.deadline, ra.deadline);
        assertEq(rb.settled, ra.settled);
        assertEq(rb.status, uint8(ra.status));
        assertEq(rb.reason, uint8(ra.reason));
        assertEq(rb.at, ra.at);
        assertEq(rb.appealOpenUntil, ra.appealOpenUntil);

        assertTrue(D(address(reg)).hasVoted(issueId, 1, 0, members[2]));
        assertFalse(D(address(reg)).hasVoted(issueId, 1, 0, members[3]));
    }
}
