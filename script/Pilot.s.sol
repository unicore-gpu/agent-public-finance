// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ACDFTypes as T} from "acdf/ACDFTypes.sol";
import {ACDFPolicyRegistry} from "acdf/ACDFPolicyRegistry.sol";
import {ACDFRegistry} from "acdf/ACDFRegistry.sol";
import {ACDFTaskTenderAdapter} from "acdf/adapters/ACDFTaskTenderAdapter.sol";
import {ITaskTenderKernel} from "acdf/interfaces/ITaskTenderKernel.sol";
import {DeductingTaskToken} from "task-token/companions/DeductingTaskToken.sol";
import {ITaskTender} from "task-token/contracts/interfaces/ITaskTender.sol";
import {SettlementDeductionPolicy} from "settlement-deductions/SettlementDeductionPolicy.sol";
import {TaxSchedule} from "../src/TaxSchedule.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {BallotMeter} from "../src/BallotMeter.sol";
import {ICollectiveDecisionReads} from "../src/interfaces/ICollectiveDecisionReads.sol";
import {TestUSD} from "./TestUSD.sol";

/// @notice The public-finance pilot in three steps, each a separate run, because two notice
///         periods must pass in real time between them:
///
///           deploy  every contract; the tax rate is proposed
///           fund    (after the rate notice) two tasks settle and pay tax; the judging
///                   program is opened
///           judge   (after the program notice) a judged task: three judges sign ballots,
///                   the council's decision is enacted, the tax is collected, the meter
///                   reports the ballots and the judges' earnings are withdrawn to them
///
///         The broadcasting account plays the governor, the client and the worker. The five
///         judges only sign: their keys come from JUDGE_SEED and they need no ether.
///         Addresses are kept in deployments/pilot-<chainid>.json.
///
///         FOUNDRY_PROFILE=integration forge script script/Pilot.s.sol --sig "deploy()" \
///             --rpc-url $RPC --account <keystore> --broadcast --slow --skip-simulation
///
///         --slow sends each transaction after the previous one is mined, so a failure stops
///         the run. --skip-simulation takes each gas limit from the node's own estimate: under
///         EIP-8037 the local simulation can undercount what the node charges for new storage.
contract Pilot is Script {
    uint256 constant U = 1e6;

    // ---- parameters (pilot values; each can be set in the environment)
    function _taxBps() internal view returns (uint16) { return uint16(vm.envOr("TAX_BPS", uint256(100))); }
    function _taxCeilingBps() internal view returns (uint16) { return uint16(vm.envOr("TAX_CEILING_BPS", uint256(500))); }
    function _policyCapBps() internal view returns (uint16) { return uint16(vm.envOr("POLICY_CAP_BPS", uint256(3000))); }
    function _rateNotice() internal view returns (uint64) { return uint64(vm.envOr("RATE_NOTICE", uint256(10 minutes))); }
    function _treasuryNotice() internal view returns (uint64) { return uint64(vm.envOr("TREASURY_NOTICE", uint256(10 minutes))); }
    function _maxTerm() internal view returns (uint64) { return uint64(vm.envOr("MAX_TERM", uint256(365 days))); }
    function _recipientCapBps() internal view returns (uint16) { return uint16(vm.envOr("RECIPIENT_CAP_BPS", uint256(3000))); }
    function _payPerBallot() internal view returns (uint256) { return vm.envOr("PAY_PER_BALLOT", 2 * U); }
    function _programBudget() internal view returns (uint256) { return vm.envOr("PROGRAM_BUDGET", 30 * U); }
    function _programDuration() internal view returns (uint64) { return uint64(vm.envOr("PROGRAM_DURATION", uint256(90 days))); }
    function _judgeSeed() internal view returns (uint256) { return vm.envOr("JUDGE_SEED", uint256(1)); }

    uint32 constant JUDGES = 5;
    uint32 constant QUORUM = 3;
    uint64 constant VOTE_WINDOW = 1 days;
    uint64 constant MAX_DECISION = 2 days;
    uint64 constant JUDGMENT_WINDOW = 7 days;
    uint64 constant MARGIN = 1 hours;
    uint256 constant ORDINARY_REWARD = 5_000 * U;
    uint256 constant JUDGED_REWARD = 1_000 * U;
    /// A payout must leave the deduction policy its whole budget (300,000) at the call, which
    /// it rarely uses: a limit estimated from the gas used falls short, and the kernel
    /// refuses. Under EIP-8037 a payout also creates storage. Only the gas used is paid.
    uint256 constant PAYOUT_GAS = 2_000_000;
    /// Every other call also carries a fixed limit, so that no step depends on a gas estimate.
    /// A public RPC endpoint balances requests across nodes, and one that has not yet seen the
    /// previous transaction's block estimates against stale state and reverts. The limit is
    /// well above what each call uses under EIP-8037 and below 2^24.
    uint256 constant CALL_GAS = 6_000_000;

    bytes32 constant TASK_DOC = sha256("pilot TASK.md");
    bytes32 constant TASK_ROOT = sha256("pilot task root");
    bytes32 constant RESULT = sha256("pilot deliverable");

    // ---- the deployment record
    struct Book {
        address token;
        address schedule;
        address treasury;
        address task;
        address deductions;
        address policies;
        address decisions;
        bytes32 council;
        address adapter;
        address meter;
    }

    function _path() internal view returns (string memory) {
        return string.concat("deployments/pilot-", vm.toString(block.chainid), ".json");
    }

    function _judgeKey(uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode("pilot judge", _judgeSeed(), i)));
    }

    function judges() public view returns (address[] memory j) {
        j = new address[](JUDGES);
        for (uint256 i = 0; i < JUDGES; i++) j[i] = vm.addr(_judgeKey(i));
    }

    // ================================================================== step 1
    function deploy() external {
        Book memory b;
        vm.startBroadcast();
        (, address me,) = vm.readCallers();

        b.token = address(new TestUSD());
        PublicTreasury treasury = new PublicTreasury(me, _treasuryNotice(), _maxTerm(), _recipientCapBps());
        b.treasury = address(treasury);
        TaxSchedule schedule = new TaxSchedule(me, b.treasury, _taxCeilingBps(), _rateNotice());
        b.schedule = address(schedule);
        DeductingTaskToken task = new DeductingTaskToken("Pilot Task", "PTASK", schedule, _policyCapBps());
        b.task = address(task);
        b.deductions = task.deductionPolicy();

        ACDFPolicyRegistry policies = new ACDFPolicyRegistry();
        b.policies = address(policies);
        b.decisions = address(new ACDFRegistry(policies));
        b.council = policies.registerPolicy(_councilSpec(me));
        b.adapter = address(new ACDFTaskTenderAdapter(
            ACDFRegistry(b.decisions), ITaskTenderKernel(b.task), b.council, MARGIN));
        b.meter = address(new BallotMeter(
            ICollectiveDecisionReads(b.decisions), b.council, b.adapter, treasury));

        schedule.proposeRate(b.token, _taxBps());
        vm.stopBroadcast();

        _write(b);
        console.log("deployed; the rate takes effect after the rate notice (seconds):", _rateNotice());
    }

    function _councilSpec(address authority) internal view returns (T.PolicySpec memory s) {
        T.BodySpec[] memory bodies = new T.BodySpec[](1);
        bodies[0].kind = T.BodyKind.ROSTER_KOFN;
        bodies[0].acceptance = T.Acceptance.SIGNED_BALLOTS;
        bodies[0].members = judges();
        bodies[0].k = QUORUM;
        bodies[0].window = VOTE_WINDOW;
        T.Node[] memory nodes = new T.Node[](1);
        nodes[0].op = T.Combinator.BODY;
        nodes[0].body = 0;
        nodes[0].children = new uint32[](0);

        s.family = keccak256("pilot.judges.task-acceptance");
        s.version = 1;
        s.updateAuthority = authority;
        s.bodies = bodies;
        s.nodes = nodes;
        s.appealStanding = T.AppealStanding.ANYONE;
        s.appealMode = T.AppealMode.PRESERVE_UNLESS_OVERTURNED;
        s.maxTotalDuration = MAX_DECISION;
        s.descriptorHash = keccak256("pilot judges' council: 3 of 5 signed ballots, one day, no appeal");
    }

    // ================================================================== step 2
    function fund() external {
        Book memory b = _read();
        TaxSchedule schedule = TaxSchedule(b.schedule);
        require(schedule.rateOf(b.token) == _taxBps(), "Pilot: the rate notice is still running");
        PublicTreasury treasury = PublicTreasury(payable(b.treasury));

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        TestUSD(b.token).mint{gas: CALL_GAS}(me, 2 * ORDINARY_REWARD + JUDGED_REWARD);
        for (uint256 i = 0; i < 2; i++) {
            uint256 id = _mintTask(b, me, ORDINARY_REWARD);
            uint256 sid = DeductingTaskToken(b.task).submitFulfillment{gas: CALL_GAS}(id, RESULT, "ipfs://pilot-result");
            DeductingTaskToken(b.task).acceptFulfillment{gas: PAYOUT_GAS}(id, sid);
            SettlementDeductionPolicy(payable(b.deductions)).claim{gas: CALL_GAS}(id, b.treasury);
        }
        uint256 pid = treasury.createProgram{gas: CALL_GAS}(b.meter, b.token, _payPerBallot(), _programBudget(), _programDuration());
        vm.stopBroadcast();

        vm.writeJson(vm.toString(pid), _path(), ".programId");
        console.log("treasury holds:", TestUSD(b.token).balanceOf(b.treasury));
        console.log("program", pid, "starts at:", treasury.programOf(pid).start);
    }

    // ================================================================== step 3
    function judge() external {
        Book memory b = _read();
        uint256 pid = vm.parseJsonUint(vm.readFile(_path()), ".programId");
        PublicTreasury treasury = PublicTreasury(payable(b.treasury));
        require(block.timestamp >= treasury.programOf(pid).start, "Pilot: the program notice is still running");
        ACDFRegistry decisions = ACDFRegistry(b.decisions);
        address[] memory j = judges();

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        uint256 id = _mintTask(b, b.adapter, JUDGED_REWARD);
        uint256 sid = DeductingTaskToken(b.task).submitFulfillment{gas: CALL_GAS}(id, RESULT, "ipfs://pilot-result");
        bytes32 issueId = ACDFTaskTenderAdapter(b.adapter).open{gas: CALL_GAS}(id, sid);

        // Three of the five judges approve, by signed ballots submitted in one batch.
        address[] memory voters = new address[](QUORUM);
        bool[] memory approves = new bool[](QUORUM);
        bytes[] memory sigs = new bytes[](QUORUM);
        for (uint256 i = 0; i < QUORUM; i++) {
            voters[i] = j[i];
            approves[i] = true;
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(_judgeKey(i), decisions.ballotDigest(issueId, 1, 0, j[i], true));
            sigs[i] = abi.encodePacked(r, s, v);
        }
        decisions.submitSignedBallots{gas: CALL_GAS}(issueId, 0, voters, approves, sigs);
        decisions.settleRound{gas: CALL_GAS}(issueId);
        ACDFTaskTenderAdapter(b.adapter).execute{gas: PAYOUT_GAS}(issueId);
        SettlementDeductionPolicy(payable(b.deductions)).claim{gas: CALL_GAS}(id, b.treasury);

        for (uint256 i = 0; i < QUORUM; i++) {
            BallotMeter(b.meter).report{gas: CALL_GAS}(pid, issueId, 1, 0, j[i]);
            treasury.withdrawEarnings{gas: CALL_GAS}(b.token, j[i]);
        }
        vm.stopBroadcast();

        console.log("judged task:", id);
        console.logBytes32(issueId);
        console.log("worker (this account) holds:", TestUSD(b.token).balanceOf(me));
        console.log("treasury holds:", TestUSD(b.token).balanceOf(b.treasury));
        for (uint256 i = 0; i < JUDGES; i++) {
            console.log("judge", j[i], TestUSD(b.token).balanceOf(j[i]));
        }
    }

    // ================================================================== helpers
    function _mintTask(Book memory b, address authority, uint256 reward) internal returns (uint256 id) {
        (, address me,) = vm.readCallers();
        ITaskTender.TenderTerms memory t =
            ITaskTender.TenderTerms(b.token, reward, 1, 0, 0, 0, 0, JUDGMENT_WINDOW);
        id = DeductingTaskToken(b.task).mintTask{gas: CALL_GAS}(me, me, authority, TASK_DOC, TASK_ROOT, "ipfs://pilot-task", t);
        TestUSD(b.token).approve{gas: CALL_GAS}(b.task, reward);
        DeductingTaskToken(b.task).fundTask{gas: CALL_GAS}(id, reward);
    }

    function _write(Book memory b) internal {
        string memory k = "pilot";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "token", b.token);
        vm.serializeAddress(k, "schedule", b.schedule);
        vm.serializeAddress(k, "treasury", b.treasury);
        vm.serializeAddress(k, "task", b.task);
        vm.serializeAddress(k, "deductions", b.deductions);
        vm.serializeAddress(k, "policies", b.policies);
        vm.serializeAddress(k, "decisions", b.decisions);
        vm.serializeBytes32(k, "council", b.council);
        vm.serializeAddress(k, "adapter", b.adapter);
        vm.serializeAddress(k, "judges", judges());
        vm.serializeUint(k, "programId", type(uint256).max); // set by fund()
        string memory out = vm.serializeAddress(k, "meter", b.meter);
        vm.writeJson(out, _path());
    }

    function _read() internal view returns (Book memory b) {
        string memory j = vm.readFile(_path());
        b.token = vm.parseJsonAddress(j, ".token");
        b.schedule = vm.parseJsonAddress(j, ".schedule");
        b.treasury = vm.parseJsonAddress(j, ".treasury");
        b.task = vm.parseJsonAddress(j, ".task");
        b.deductions = vm.parseJsonAddress(j, ".deductions");
        b.policies = vm.parseJsonAddress(j, ".policies");
        b.decisions = vm.parseJsonAddress(j, ".decisions");
        b.council = vm.parseJsonBytes32(j, ".council");
        b.adapter = vm.parseJsonAddress(j, ".adapter");
        b.meter = vm.parseJsonAddress(j, ".meter");
    }
}
