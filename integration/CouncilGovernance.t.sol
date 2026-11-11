// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ACDFBase} from "acdf-test/ACDFBase.t.sol";
import {ACDFTypes as T} from "acdf/ACDFTypes.sol";
import {TaxSchedule} from "../src/TaxSchedule.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {CouncilGovernor} from "../src/CouncilGovernor.sol";
import {ICollectiveDecisions} from "../src/interfaces/ICollectiveDecisions.sol";
import {IPublicTreasury} from "../src/interfaces/IPublicTreasury.sol";
import {IPublicTaxSchedule} from "../src/interfaces/IPublicTaxSchedule.sol";
import {TestUSD} from "../script/TestUSD.sol";

/// A treasury whose `createProgram` needs about 10 million gas, to starve on purpose.
contract HungryTreasury {
    address public governor;
    uint256 public programs;
    uint256[] private _scratch;
    constructor(address governor_) { governor = governor_; }
    function createProgram(address, address, uint256, uint256, uint64) external returns (uint256) {
        uint256 x;
        for (uint256 i = 0; i < 20_000; i++) x = uint256(keccak256(abi.encode(x, i, gasleft())));
        return programs++;
    }
}

/// The treasury and the tax schedule governed by an ERC-8436 council, on the real ERC-8436
/// registry. ACDFBase is the ERC-8436 reference's own test base: its registries, its five
/// roster members and its ballot helper. The council is 3 of the 5, one day to vote, no appeal.
contract CouncilGovernanceTest is ACDFBase {
    uint256 constant U = 1e6;
    uint64 constant NOTICE = 3 days;
    uint64 constant RATE_NOTICE = 7 days;
    uint64 constant WINDOW = 7 days;

    TestUSD usd;
    CouncilGovernor gov;
    PublicTreasury treasury;
    TaxSchedule schedule;
    bytes32 council;

    address proposer = address(0x9909);
    address meter = address(0x3E7E);
    address newcomer = address(0x2E3);

    function setUp() public override {
        super.setUp();
        T.PolicySpec memory s = minimalSpec(5, 3, 1 days);
        s.family = keccak256("treasury.council");
        s.maxTotalDuration = 2 days;
        council = register(s);
        usd = new TestUSD();

        // The governor, the treasury and the schedule name each other: deploy at predicted addresses.
        uint64 n = vm.getNonce(address(this));
        address treasuryAt = vm.computeCreateAddress(address(this), n + 1);
        address scheduleAt = vm.computeCreateAddress(address(this), n + 2);
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        gov = new CouncilGovernor(ICollectiveDecisions(address(reg)), council, IPublicTreasury(treasuryAt),
                                  IPublicTaxSchedule(scheduleAt), WINDOW, proposers);
        treasury = new PublicTreasury(address(gov), NOTICE, 365 days, 3000);
        schedule = new TaxSchedule(address(gov), address(treasury), 500, RATE_NOTICE);
        assertEq(address(treasury), treasuryAt);
        assertEq(address(schedule), scheduleAt);
        assertTrue(gov.isBound());

        usd.mint(address(treasury), 100 * U);
    }

    // ------------------------------------------------------------------ helpers

    function _propose(CouncilGovernor.Action a, bytes memory args) internal returns (uint256 id, bytes32 issueId) {
        vm.prank(proposer);
        (id, issueId) = gov.propose(a, args);
    }

    function _decide(bytes32 issueId, bool yes) internal {
        vote(issueId, 0, 0, yes);
        vote(issueId, 0, 1, yes);
        vote(issueId, 0, 2, yes);
        reg.settleRound(issueId);
        assertFinalDecided(issueId, yes);
    }

    function _program(uint256 budget) internal view returns (bytes memory) {
        return abi.encode(meter, address(usd), 2 * U, budget, uint64(90 days));
    }

    function _status(uint256 id) internal view returns (CouncilGovernor.Status) {
        return gov.proposalOf(id).status;
    }

    function _enactment(bytes32 issueId, bytes32 effect) internal view returns (T.EnactmentStatus) {
        return reg.getEnactment(issueId, address(gov), effect).status;
    }

    // ------------------------------------------------------------------ decisions that act

    function test_the_council_opens_a_program() public {
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));

        // the council votes on exactly this action, filed by the governor as its consumer
        T.Issue memory issue = reg.getIssue(issueId);
        assertEq(issue.consumer, address(gov));
        assertEq(uint8(issue.effectClass), uint8(T.EffectClass.Binding));
        assertEq(issue.policyId, council);
        assertEq(issue.subject.target, address(gov));
        assertEq(issue.subject.id, id);
        assertEq(issue.subject.dataHash, gov.actionHash(CouncilGovernor.Action.CreateProgram, _program(30 * U)));

        _decide(issueId, true);
        vm.prank(rando);
        gov.execute(id);

        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Executed));
        assertEq(treasury.programCount(), 1);
        IPublicTreasury.Program memory p = treasury.programOf(0);
        assertEq(p.meter, meter);
        assertEq(p.asset, address(usd));
        assertEq(p.ratePerUnit, 2 * U);
        assertEq(p.remaining, 30 * U);
        assertEq(p.start, block.timestamp + NOTICE, "the treasury's own notice still applies");
        assertEq(uint8(_enactment(issueId, gov.EFFECT_EXECUTE())), uint8(T.EnactmentStatus.Enacted));

        vm.expectRevert("Governor: closed");
        gov.execute(id);
    }

    function test_the_council_sets_the_tax_rate_and_the_notice_still_runs() public {
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.ProposeRate, abi.encode(address(usd), uint16(100)));
        _decide(issueId, true);
        gov.execute(id);
        (uint16 bps, uint64 at) = schedule.pendingRateOf(address(usd));
        assertEq(bps, 100);
        assertEq(at, block.timestamp + RATE_NOTICE);
        assertEq(schedule.rateOf(address(usd)), 0);
        vm.warp(at);
        assertEq(schedule.rateOf(address(usd)), 100);
    }

    function test_the_ceiling_still_binds_the_council() public {
        // 6% is above the schedule's 5% ceiling: the council approves, the schedule refuses
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.ProposeRate, abi.encode(address(usd), uint16(600)));
        _decide(issueId, true);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Pending));
        assertEq(uint8(_enactment(issueId, gov.EFFECT_EXECUTE())), uint8(T.EnactmentStatus.Failed));
        (uint16 bps,) = schedule.pendingRateOf(address(usd));
        assertEq(bps, 0);
    }

    function test_grants_and_their_end() public {
        (uint256 g, bytes32 i1) = _propose(CouncilGovernor.Action.CreateGrant,
            abi.encode(meter, address(usd), 5 * U, uint64(30 days), uint32(6)));
        _decide(i1, true);
        gov.execute(g);
        assertEq(treasury.grantCount(), 1);
        assertEq(treasury.committedOf(address(usd)), 30 * U);

        (uint256 e, bytes32 i2) = _propose(CouncilGovernor.Action.EndGrant, abi.encode(uint256(0)));
        _decide(i2, true);
        gov.execute(e);
        assertEq(treasury.committedOf(address(usd)), 0, "a grant ended before its first period releases all");
    }

    function test_the_council_adds_a_proposer() public {
        vm.prank(newcomer);
        vm.expectRevert("Governor: not a proposer");
        gov.propose(CouncilGovernor.Action.CloseProgram, abi.encode(uint256(0)));
        vm.expectRevert("Governor: only by decision");
        gov.setProposer(newcomer, true);

        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.SetProposer, abi.encode(newcomer, true));
        _decide(issueId, true);
        gov.execute(id);
        assertTrue(gov.isProposer(newcomer));
        vm.prank(newcomer);
        gov.propose(CouncilGovernor.Action.ProposeRate, abi.encode(address(usd), uint16(50)));
    }

    function test_the_last_proposer_cannot_be_removed() public {
        // removing the only proposer would leave no one able to file anything again
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.SetProposer, abi.encode(proposer, false));
        _decide(issueId, true);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Pending), "the action fails and stays pending");
        assertTrue(gov.isProposer(proposer));
        assertEq(gov.proposerCount(), 1);

        // with a second proposer added first, the first can be removed
        (uint256 a, bytes32 ia) = _propose(CouncilGovernor.Action.SetProposer, abi.encode(newcomer, true));
        _decide(ia, true);
        gov.execute(a);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Executed));
        assertFalse(gov.isProposer(proposer));
        assertEq(gov.proposerCount(), 1);
    }

    // ------------------------------------------------------------------ decisions that do not act

    function test_a_rejection_runs_nothing() public {
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));
        _decide(issueId, false);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Rejected));
        assertEq(treasury.programCount(), 0);
        assertEq(uint8(_enactment(issueId, gov.EFFECT_REJECT())), uint8(T.EnactmentStatus.Enacted));
        vm.expectRevert("Governor: closed");
        gov.execute(id);
    }

    function test_no_decision_runs_nothing() public {
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));
        vote(issueId, 0, 0, true);
        vm.warp(block.timestamp + 1 days + 1);
        reg.settleRound(issueId);
        assertFinalNoDecision(issueId, T.Reason.QUORUM_NOT_MET);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.NoDecision));
        assertEq(treasury.programCount(), 0);
    }

    function test_nothing_runs_before_the_decision_is_final() public {
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));
        vote(issueId, 0, 0, true);
        vote(issueId, 0, 1, true);
        vm.expectRevert("Governor: not final");
        gov.execute(id);
    }

    function test_an_approval_lapses_after_the_window() public {
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));
        _decide(issueId, true);
        vm.warp(block.timestamp + WINDOW + 1);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Lapsed));
        assertEq(treasury.programCount(), 0);
    }

    // ------------------------------------------------------------------ failures and limits

    function test_a_failed_action_can_be_retried_within_the_window() public {
        // 50 is above the 30% cap of a balance of 100: the treasury refuses
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.CreateProgram, _program(50 * U));
        _decide(issueId, true);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Pending));
        assertEq(uint8(_enactment(issueId, gov.EFFECT_EXECUTE())), uint8(T.EnactmentStatus.Failed));
        assertEq(treasury.programCount(), 0);

        // more tax arrives; the same approved action now fits under the cap
        usd.mint(address(treasury), 100 * U);
        gov.execute(id);
        assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Executed));
        assertEq(treasury.programOf(0).remaining, 50 * U);
        assertEq(uint8(_enactment(issueId, gov.EFFECT_EXECUTE())), uint8(T.EnactmentStatus.Enacted));
    }

    function test_starving_the_call_of_gas_never_records_a_failure() public {
        (uint256 id, bytes32 issueId) = _propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));
        _decide(issueId, true);
        for (uint256 g = 60_000; g < 1_000_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            try gov.execute{gas: g}(id) {
                assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Executed), "succeeded only by acting");
            } catch {
                assertEq(uint8(_status(id)), uint8(CouncilGovernor.Status.Pending));
                assertEq(uint8(_enactment(issueId, gov.EFFECT_EXECUTE())), uint8(T.EnactmentStatus.NotEnacted));
            }
            vm.revertToState(snap);
        }
    }

    function test_a_call_starved_of_gas_reverts_instead_of_failing() public {
        // When the action needs far more than the logging after it, a caller could forward just
        // enough gas for the action to run out while the governor keeps 1/64 to record a
        // failure. The governor refuses to record it.
        uint64 n = vm.getNonce(address(this));
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        CouncilGovernor g = new CouncilGovernor(ICollectiveDecisions(address(reg)), council,
            IPublicTreasury(vm.computeCreateAddress(address(this), n + 1)), IPublicTaxSchedule(address(schedule)),
            WINDOW, proposers);
        HungryTreasury hungry = new HungryTreasury(address(g));
        assertEq(address(g.treasury()), address(hungry));

        vm.prank(proposer);
        (uint256 id, bytes32 issueId) = g.propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));
        _decide(issueId, true);

        vm.expectRevert("Governor: out of gas");
        g.execute{gas: 8_000_000}(id);
        assertEq(uint8(g.proposalOf(id).status), uint8(CouncilGovernor.Status.Pending));
        assertEq(uint8(reg.getEnactment(issueId, address(g), g.EFFECT_EXECUTE()).status),
                 uint8(T.EnactmentStatus.NotEnacted));

        g.execute{gas: 30_000_000}(id);
        assertEq(uint8(g.proposalOf(id).status), uint8(CouncilGovernor.Status.Executed));
        assertEq(hungry.programs(), 1);
    }

    function test_only_proposers_file_and_arguments_must_decode_exactly() public {
        vm.prank(rando);
        vm.expectRevert("Governor: not a proposer");
        gov.propose(CouncilGovernor.Action.CreateProgram, _program(30 * U));

        vm.startPrank(proposer);
        vm.expectRevert("Governor: bad arguments");
        gov.propose(CouncilGovernor.Action.CreateProgram, abi.encode(meter, address(usd)));
        vm.expectRevert("Governor: bad arguments");
        gov.propose(CouncilGovernor.Action.EndGrant, abi.encode(uint256(0), uint256(1)));
        vm.expectRevert();
        gov.propose(CouncilGovernor.Action.ProposeRate, abi.encode(address(usd), uint256(70_000))); // not a uint16
        vm.stopPrank();
    }

    function test_only_the_governor_moves_the_treasury_or_the_rate() public {
        vm.startPrank(proposer);
        vm.expectRevert("Treasury: not governor");
        treasury.createProgram(meter, address(usd), 2 * U, 30 * U, 90 days);
        vm.expectRevert("Tax: not governor");
        schedule.proposeRate(address(usd), 100);
        vm.stopPrank();
    }
}
