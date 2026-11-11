// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ADRFBase, T, A} from "adrf-test/ADRFBase.t.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {BallotMeter} from "../src/BallotMeter.sol";
import {ICollectiveDecisionReads} from "../src/interfaces/ICollectiveDecisionReads.sol";
import {IPublicTreasury} from "../src/interfaces/IPublicTreasury.sol";
import {TestUSD} from "../script/TestUSD.sol";

/// Judges of an ERC-8471 dispute are paid per ballot from a public treasury program.
///
/// The fixture is the ERC-8471 reference test fixture: its dispute registry and the 8471-8436
/// bridge, a service escrow with one call charged twice, and a 2-of-3 jurors' council. Its
/// ERC-8436 registry here is the real one (acd-framework), not the copy that 8471 vendors for its
/// own tests. A judged sub-question becomes an 8436 issue whose consumer is the bridge, so the
/// meter is scoped to the council's policy and the bridge.
contract JudgedDisputesTest is ADRFBase {
    uint256 constant U = 1e6;
    uint256 constant PAY = 2 * U;

    TestUSD usd;
    PublicTreasury treasury;
    BallotMeter meter;
    uint256 pid;

    function setUp() public override {
        super.setUp();
        usd = new TestUSD();
        treasury = new PublicTreasury(address(this), 1 hours, 365 days, 3000);
        meter = new BallotMeter(ICollectiveDecisionReads(address(acdf)), acdfPolicyId, address(bridge),
                                IPublicTreasury(address(treasury)));
        usd.mint(address(treasury), 100 * U);
        pid = treasury.createProgram(address(meter), address(usd), PAY, 30 * U, 90 days);
        vm.warp(block.timestamp + 1 hours);
    }

    function openQuality() internal returns (bytes32 caseId, bytes32 issueId) {
        caseId = fileAs(client, qualityClaim());
        reg.openJudgment(caseId, 0);
        issueId = issueOf(caseId, 0);
    }

    function settleAndFinalize(bytes32 issueId) internal {
        acdf.settleRound(issueId);
        vm.warp(block.timestamp + DAY + 1);
        acdf.finalize(issueId);
    }

    function payJuror(bytes32 issueId, uint32 round, uint256 i) internal {
        vm.prank(rando);
        meter.report(pid, issueId, round, 0, jurors[i]);
        treasury.withdrawEarnings(address(usd), jurors[i]);
    }

    function test_dispute_judges_are_paid_and_the_ruling_is_enacted() public {
        (bytes32 caseId, bytes32 issueId) = openQuality();
        assertEq(acdf.getIssue(issueId).consumer, address(bridge));

        // two of three jurors find that the delivery does not conform
        voteBlock(issueId, 1, 2);
        settleAndFinalize(issueId);

        // the dispute runs to its end: the finding is imported, the claim sustained, the refund paid
        bridge.importResult(caseId, 0);
        reg.decide(caseId);
        vm.warp(block.timestamp + 2 * DAY + 1);
        reg.finalize(caseId);
        assertEq(uint8(reg.getRuling(caseId).result), uint8(T.SubstantiveResult.Sustained));
        uint256 before = escrow.balanceOf(client);
        escrow.enact(caseId, REFUND);
        assertEq(escrow.balanceOf(client), before + 1 ether);

        // the two jurors who voted are paid one ballot each; the third has no ballot
        payJuror(issueId, 1, 0);
        payJuror(issueId, 1, 1);
        assertEq(usd.balanceOf(jurors[0]), PAY);
        assertEq(usd.balanceOf(jurors[1]), PAY);
        vm.expectRevert("Meter: no ballot");
        meter.report(pid, issueId, 1, 0, jurors[2]);
        vm.expectRevert("Meter: counted");
        meter.report(pid, issueId, 1, 0, jurors[0]);
        assertEq(usd.balanceOf(address(treasury)), 96 * U);
    }

    function test_jurors_are_paid_whichever_side() public {
        (, bytes32 issueId) = openQuality();
        voteApprove(issueId, 1, 2);
        settleAndFinalize(issueId);
        assertTrue(acdf.getResult(issueId).outcomeYes);
        payJuror(issueId, 1, 0);
        payJuror(issueId, 1, 1);
        assertEq(usd.balanceOf(jurors[0]), PAY);
        assertEq(usd.balanceOf(jurors[1]), PAY);
    }

    function test_ballots_of_an_appeal_round_count_too() public {
        (bytes32 caseId, bytes32 issueId) = openQuality();
        // round 1 blocks; the provider appeals; round 2 approves, overturning round 1
        voteBlock(issueId, 1, 2);
        acdf.settleRound(issueId);
        vm.prank(provider);
        acdf.appeal(issueId);
        for (uint256 i = 1; i < 3; i++) {
            vm.prank(jurors[i]);
            acdf.castBallot(issueId, 2, 0, true);
        }
        acdf.settleRound(issueId); // appeals exhausted: Final
        A.Result memory r = acdf.getResult(issueId);
        assertEq(uint8(r.state), uint8(A.ProcedureState.Final));
        assertEq(r.roundCount, 2);
        bridge.importResult(caseId, 0);

        // four ballots in all: jurors 0 and 1 in round 1, jurors 1 and 2 in round 2
        payJuror(issueId, 1, 0);
        payJuror(issueId, 1, 1);
        payJuror(issueId, 2, 1);
        payJuror(issueId, 2, 2);
        assertEq(usd.balanceOf(jurors[0]), PAY);
        assertEq(usd.balanceOf(jurors[1]), 2 * PAY);
        assertEq(usd.balanceOf(jurors[2]), PAY);
        vm.expectRevert("Meter: no ballot");
        meter.report(pid, issueId, 2, 0, jurors[0]);
    }

    function test_a_provisional_result_is_not_paid() public {
        (, bytes32 issueId) = openQuality();
        voteBlock(issueId, 1, 2);
        acdf.settleRound(issueId);
        assertEq(uint8(acdf.getResult(issueId).state), uint8(A.ProcedureState.Provisional));
        vm.expectRevert("Meter: not final");
        meter.report(pid, issueId, 1, 0, jurors[0]);
    }

    function test_an_issue_of_the_same_council_for_another_consumer_is_not_paid() public {
        // the same jurors' council decides a question filed by another relying contract
        A.IssueInput memory input;
        input.policyId = acdfPolicyId;
        input.mode = A.AcceptanceMode.CONSUMER_FILED;
        input.consumer = address(this);
        input.subject = A.Subject({chainId: block.chainid, target: address(this), id: 1, dataHash: bytes32(0)});
        input.question = keccak256("another question");
        input.effectYes = keccak256("yes");
        input.effectNo = keccak256("no");
        input.disposition = keccak256("none");
        input.obligationId = keccak256("another obligation");
        bytes32 issueId = acdf.file(input);
        voteApprove(issueId, 1, 2);
        settleAndFinalize(issueId);
        vm.expectRevert("Meter: not in scope");
        meter.report(pid, issueId, 1, 0, jurors[0]);
    }
}
