// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ACDFTypes as A} from "acdf/ACDFTypes.sol";
import {ACDFPolicyRegistry} from "acdf/ACDFPolicyRegistry.sol";
import {ACDFRegistry} from "acdf/ACDFRegistry.sol";
import {ADRFTypes as T} from "adrf/ADRFTypes.sol";
import {ADRFPolicyRegistry} from "adrf/ADRFPolicyRegistry.sol";
import {IADRFDisputeRegistry} from "adrf/interfaces/IADRFDisputeRegistry.sol";
import {ADRFACDFBridge} from "adrf/bridges/ADRFACDFBridge.sol";
import {ADRFServiceEscrow} from "adrf/examples/ADRFServiceEscrow.sol";
// Imported so that their artifacts are compiled for vm.deployCode; this script embeds none of
// their creation code, which would push its own initcode past the EIP-3860 limit.
import {ADRFDisputeRegistry} from "adrf/ADRFDisputeRegistry.sol";
import {ADRFBindingModule} from "adrf/modules/ADRFBindingModule.sol";
import {ADRFFilingModule} from "adrf/modules/ADRFFilingModule.sol";
import {ADRFResolutionModule} from "adrf/modules/ADRFResolutionModule.sol";
import {ADRFDecisionModule} from "adrf/modules/ADRFDecisionModule.sol";
import {ADRFRecordModule} from "adrf/modules/ADRFRecordModule.sol";
import {ADRFOutcomeModule} from "adrf/modules/ADRFOutcomeModule.sol";
import {DeductingTaskToken} from "task-token/companions/DeductingTaskToken.sol";
import {ITaskTender} from "task-token/contracts/interfaces/ITaskTender.sol";
import {SettlementDeductionPolicy} from "settlement-deductions/SettlementDeductionPolicy.sol";
import {TaxSchedule} from "../src/TaxSchedule.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {BallotMeter} from "../src/BallotMeter.sol";
import {CouncilGovernor} from "../src/CouncilGovernor.sol";
import {TestUSD} from "./TestUSD.sol";

/// @notice The second public-finance pilot: a council governs the treasury, and the jurors of an
///         ERC-8471 dispute are paid per ballot. Four steps, each a separate run, because the
///         notice periods and the dispute's review window must pass in real time between them:
///
///           deploy   a treasury and a tax schedule governed by a stewards' council through
///                    CouncilGovernor; an ERC-8414 kernel with the deduction hook; an ERC-8471
///                    dispute registry with its 8436 bridge and the reference service escrow;
///                    a ballot meter for the jurors' council. The stewards decide the first
///                    action: a 1% tax rate.
///           fund     (after the rate notice) two tasks pay tax; the stewards decide the second
///                    action: a program that pays the jurors 2 tUSD per ballot.
///           dispute  (after the program notice) a service call is delivered and charged; the
///                    client disputes the delivery; two of three jurors find that it does not
///                    conform; the finding is imported and the dispute decided; the meter pays
///                    the two jurors.
///           close    (after the dispute's review window) the ruling becomes final and the
///                    escrow refunds the charge.
///
///         It reuses the ERC-8436 registry of the first pilot (deployments/pilot-<chainid>.json)
///         and keeps its own record in deployments/pilot2-<chainid>.json. The broadcasting
///         account is the proposer, the client of the tasks and of the service call, and the
///         worker. The stewards and the jurors only sign; their keys, and the provider's, come
///         from JUDGE_SEED and are for the pilot only. The provider receives a little ether for
///         its two transactions.
///
///         FOUNDRY_PROFILE=integration forge script script/Pilot2.s.sol --sig "deploy()" \
///             --rpc-url $RPC --account <keystore> --broadcast --slow --skip-simulation \
///             --with-gas-price 10000 --priority-gas-price 100
///
///         Pin both fees (in wei): left to itself, forge has priced transactions at 1 gwei on a
///         network asking for about 70 wei.
contract Pilot2 is Script {
    uint256 constant U = 1e6;
    uint64 constant MIN = 60;

    // ---- parameters (pilot values; each can be set in the environment)
    function _rateNotice() internal view returns (uint64) { return uint64(vm.envOr("RATE_NOTICE", uint256(10 * MIN))); }
    function _treasuryNotice() internal view returns (uint64) { return uint64(vm.envOr("TREASURY_NOTICE", uint256(10 * MIN))); }
    function _judgeSeed() internal view returns (uint256) { return vm.envOr("JUDGE_SEED", uint256(1)); }

    uint16 constant TAX_BPS = 100;
    uint256 constant PAY_PER_BALLOT = 2 * U;
    uint256 constant PROGRAM_BUDGET = 30 * U;
    uint64 constant PROGRAM_DURATION = 90 days;
    uint64 constant EXECUTION_WINDOW = 7 days;

    uint256 constant STEWARDS = 5;
    uint32 constant STEWARD_QUORUM = 3;
    uint256 constant JURORS = 3;
    uint32 constant JUROR_QUORUM = 2;

    uint256 constant ORDINARY_REWARD = 5_000 * U;
    uint256 constant CALL_PRICE = 0.0001 ether;
    uint256 constant PROVIDER_GAS_MONEY = 0.001 ether;
    /// Every call carries a fixed limit, so that no step depends on a gas estimate made by a
    /// node behind the chain (see Pilot.s.sol). Below 2^24 and above what each call uses.
    uint256 constant CALL_GAS = 12_000_000;

    bytes32 constant TASK_DOC = sha256("pilot TASK.md");
    bytes32 constant TASK_ROOT = sha256("pilot task root");
    bytes32 constant RESULT = sha256("pilot deliverable");
    bytes32 constant TERMS = keccak256("pilot service terms v1");
    bytes32 constant VERSION = keccak256("pilot model v1");
    bytes32 constant CONFORMS = keccak256("the deliverable conforms to the acceptance criteria");

    struct Book {
        address token; address governor; address treasury; address schedule;
        address task; address deductions;
        address decisions; address policies; bytes32 stewards; bytes32 jurors;
        address disputes; address bridge; address escrow; bytes32 disputePolicy; bytes32 binding;
        address meter; address provider;
    }

    // ------------------------------------------------------------------ keys

    function _key(string memory role, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode("pilot2", role, _judgeSeed(), i)));
    }

    function _members(string memory role, uint256 n) internal view returns (address[] memory m) {
        m = new address[](n);
        for (uint256 i = 0; i < n; i++) m[i] = vm.addr(_key(role, i));
    }

    function stewards() public view returns (address[] memory) { return _members("steward", STEWARDS); }
    function jurors() public view returns (address[] memory) { return _members("juror", JURORS); }
    function provider() public view returns (address) { return vm.addr(_key("provider", 0)); }

    // ================================================================== step 1
    function deploy() external {
        Book memory b;
        string memory first = vm.readFile(string.concat("deployments/pilot-", vm.toString(block.chainid), ".json"));
        b.decisions = vm.parseJsonAddress(first, ".decisions");
        b.policies = vm.parseJsonAddress(first, ".policies");
        b.provider = provider();

        vm.startBroadcast();
        (, address me,) = vm.readCallers();

        b.token = vm.deployCode("TestUSD.sol:TestUSD");
        ACDFPolicyRegistry policies = ACDFPolicyRegistry(b.policies);
        b.stewards = policies.registerPolicy{gas: CALL_GAS}(_council(me, "pilot2.stewards", stewards(), STEWARD_QUORUM, 1 days, 2 days,
            "pilot2 stewards' council: 3 of 5 signed ballots, one day, no appeal"));
        b.jurors = policies.registerPolicy{gas: CALL_GAS}(_council(me, "pilot2.jurors", jurors(), JUROR_QUORUM, 15 * MIN, 40 * MIN,
            "pilot2 jurors' council: 2 of 3 signed ballots, 15 minutes, no appeal"));

        // The governor, the treasury and the schedule name each other: predicted addresses.
        uint64 n = vm.getNonce(me);
        address[] memory proposers = new address[](1);
        proposers[0] = me;
        b.governor = vm.deployCode("CouncilGovernor.sol:CouncilGovernor", abi.encode(b.decisions, b.stewards,
            vm.computeCreateAddress(me, n + 1), vm.computeCreateAddress(me, n + 2), EXECUTION_WINDOW, proposers));
        b.treasury = vm.deployCode("PublicTreasury.sol:PublicTreasury",
            abi.encode(b.governor, _treasuryNotice(), uint64(365 days), uint16(3000)));
        b.schedule = vm.deployCode("TaxSchedule.sol:TaxSchedule",
            abi.encode(b.governor, b.treasury, uint16(500), _rateNotice()));
        require(CouncilGovernor(b.governor).isBound(), "Pilot2: governor not bound");

        b.task = vm.deployCode("DeductingTaskToken.sol:DeductingTaskToken",
            abi.encode("Pilot Task 2", "PTASK2", b.schedule, uint16(3000)));
        b.deductions = DeductingTaskToken(b.task).deductionPolicy();

        _deployDisputes(b, me);
        b.meter = vm.deployCode("BallotMeter.sol:BallotMeter", abi.encode(b.decisions, b.jurors, b.bridge, b.treasury));
        payable(b.provider).transfer(PROVIDER_GAS_MONEY);

        // The stewards' first decision: a 1% tax rate.
        _decide(b, CouncilGovernor.Action.ProposeRate, abi.encode(b.token, TAX_BPS));
        vm.stopBroadcast();

        _write(b);
        (uint16 bps, uint64 at) = TaxSchedule(b.schedule).pendingRateOf(b.token);
        console.log("deployed; rate (bps) proposed by the council:", bps);
        console.log("the rate takes effect at:", at);
    }

    function _deployDisputes(Book memory b, address me) internal {
        address pol = vm.deployCode("ADRFPolicyRegistry.sol:ADRFPolicyRegistry");
        address[6] memory m = [
            vm.deployCode("ADRFBindingModule.sol:ADRFBindingModule", abi.encode(pol)),
            vm.deployCode("ADRFFilingModule.sol:ADRFFilingModule", abi.encode(pol)),
            vm.deployCode("ADRFResolutionModule.sol:ADRFResolutionModule", abi.encode(pol)),
            vm.deployCode("ADRFDecisionModule.sol:ADRFDecisionModule", abi.encode(pol)),
            vm.deployCode("ADRFRecordModule.sol:ADRFRecordModule", abi.encode(pol)),
            vm.deployCode("ADRFOutcomeModule.sol:ADRFOutcomeModule", abi.encode(pol))
        ];
        b.disputes = vm.deployCode("ADRFDisputeRegistry.sol:ADRFDisputeRegistry",
            abi.encode(pol, m[0], m[1], m[2], m[3], m[4], m[5]));
        b.bridge = vm.deployCode("ADRFACDFBridge.sol:ADRFACDFBridge", abi.encode(b.disputes, b.decisions));
        b.escrow = vm.deployCode("ADRFServiceEscrow.sol:ADRFServiceEscrow", abi.encode(b.disputes));
        ADRFServiceEscrow escrow = ADRFServiceEscrow(payable(b.escrow));

        // A fast track: the jurors' council decides within 40 minutes, inside a 60-minute decision
        // window; one review of 10 minutes.
        T.PolicySpec memory p;
        p.family = keccak256(abi.encode("pilot2.disputes", block.chainid, me));
        p.version = 1;
        p.updateAuthority = me;
        p.objectKind = keccak256("service-call");
        p.methods = new T.MethodBinding[](1);
        p.methods[0] = T.MethodBinding(escrow.KIND_RESULT(), T.QuestionType.JUDGED, b.bridge, b.jurors, T.OnUndetermined.NO_DECISION);
        p.effects = new T.Effect[](1);
        p.effects[0] = T.Effect(escrow.EFFECT_REFUND(), T.EffectCategory.SUBSTANTIVE);
        p.track.filingWindow = 1 days;
        p.track.acceptanceWindow = 30 * MIN;
        p.track.evidenceWindow = 30 * MIN;
        p.track.decisionWindow = 60 * MIN;
        p.track.reviewWindow = 10 * MIN;
        p.track.maxReviews = 1;
        p.track.reviewTypes = T.REVIEW_FACT | T.REVIEW_EVIDENCE | T.REVIEW_RULE_APPLICATION;
        p.track.reviewMode = T.ReviewMode.PRESERVE_UNLESS_OVERTURNED;
        p.track.maxTotalDuration = 60 * MIN + (10 * MIN + 60 * MIN);
        p.track.enactmentMargin = 10 * MIN;
        p.standing = T.StandingMode.BENEFICIARIES;
        p.resultProfile = T.RESULT_PROFILE_V1;
        p.economicDeclaration = keccak256("pilot2: no fees; the jurors are paid by a public treasury program");
        p.descriptorHash = keccak256("pilot2: service-call disputes, judged by the jurors' council");
        b.disputePolicy = ADRFPolicyRegistry(pol).registerPolicy{gas: CALL_GAS}(p);

        T.BindingInput memory bi;
        bi.policyId = b.disputePolicy;
        bi.mode = T.AcceptanceMode.PRE_COMMIT;
        bi.authorizedEffects = new bytes32[](1);
        bi.authorizedEffects[0] = escrow.EFFECT_REFUND();
        bi.executors = new address[](0);
        bi.beneficiaries = new address[](0);
        bi.termsHash = keccak256("pilot2: binding of the service escrow");
        b.binding = escrow.bindTo{gas: CALL_GAS}(bi);
    }

    // ================================================================== step 2
    function fund() external {
        Book memory b = _read();
        require(TaxSchedule(b.schedule).rateOf(b.token) == TAX_BPS, "Pilot2: the rate notice is still running");

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        TestUSD(b.token).mint{gas: CALL_GAS}(me, 2 * ORDINARY_REWARD);
        for (uint256 i = 0; i < 2; i++) {
            ITaskTender.TenderTerms memory t = ITaskTender.TenderTerms(b.token, ORDINARY_REWARD, 1, 0, 0, 0, 0, 7 days);
            uint256 id = DeductingTaskToken(b.task).mintTask{gas: CALL_GAS}(me, me, me, TASK_DOC, TASK_ROOT, "ipfs://pilot-task", t);
            TestUSD(b.token).approve{gas: CALL_GAS}(b.task, ORDINARY_REWARD);
            DeductingTaskToken(b.task).fundTask{gas: CALL_GAS}(id, ORDINARY_REWARD);
            uint256 sid = DeductingTaskToken(b.task).submitFulfillment{gas: CALL_GAS}(id, RESULT, "ipfs://pilot-result");
            DeductingTaskToken(b.task).acceptFulfillment{gas: CALL_GAS}(id, sid);
            SettlementDeductionPolicy(payable(b.deductions)).claim{gas: CALL_GAS}(id, b.treasury);
        }

        // The stewards' second decision: pay the jurors per ballot.
        _decide(b, CouncilGovernor.Action.CreateProgram,
            abi.encode(b.meter, b.token, PAY_PER_BALLOT, PROGRAM_BUDGET, PROGRAM_DURATION));
        vm.stopBroadcast();

        uint256 pid = PublicTreasury(payable(b.treasury)).programCount() - 1;
        vm.writeJson(vm.toString(pid), _path(), ".programId");
        console.log("treasury holds:", TestUSD(b.token).balanceOf(b.treasury));
        console.log("program", pid, "starts at:", PublicTreasury(payable(b.treasury)).programOf(pid).start);
    }

    // ================================================================== step 3
    function dispute() external {
        Book memory b = _read();
        string memory j = vm.readFile(_path());
        uint256 pid = vm.parseJsonUint(j, ".programId");
        require(block.timestamp >= PublicTreasury(payable(b.treasury)).programOf(pid).start,
            "Pilot2: the program notice is still running");
        ADRFServiceEscrow escrow = ADRFServiceEscrow(payable(b.escrow));
        IADRFDisputeRegistry reg = IADRFDisputeRegistry(b.disputes);
        ACDFRegistry decisions = ACDFRegistry(b.decisions);

        // The client pays for a service call; the provider delivers and is charged for it.
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        escrow.deposit{value: CALL_PRICE, gas: CALL_GAS}();
        uint256 callId = escrow.openCall{gas: CALL_GAS}(b.provider, CALL_PRICE, TERMS, VERSION, 4 hours);
        vm.stopBroadcast();
        vm.startBroadcast(_key("provider", 0));
        escrow.deliver{gas: CALL_GAS}(callId, VERSION);
        escrow.settle{gas: CALL_GAS}(callId);
        vm.stopBroadcast();

        // The client disputes the delivery; the jurors' council decides whether it conforms.
        vm.startBroadcast();
        bytes32 caseId = reg.file{gas: CALL_GAS}(b.binding, _claim(escrow, callId, b.provider));
        reg.openJudgment{gas: CALL_GAS}(caseId, 0);
        bytes32 issueId = ADRFACDFBridge(b.bridge).issueOf(keccak256(abi.encode(caseId, uint32(0))));

        address[] memory js = jurors();
        address[] memory voters = new address[](JUROR_QUORUM);
        bool[] memory approves = new bool[](JUROR_QUORUM);
        bytes[] memory sigs = new bytes[](JUROR_QUORUM);
        for (uint256 i = 0; i < JUROR_QUORUM; i++) {
            voters[i] = js[i];
            approves[i] = false; // the deliverable does not conform
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key("juror", i), decisions.ballotDigest(issueId, 1, 0, js[i], false));
            sigs[i] = abi.encodePacked(r, s, v);
        }
        decisions.submitSignedBallots{gas: CALL_GAS}(issueId, 0, voters, approves, sigs);
        decisions.settleRound{gas: CALL_GAS}(issueId);
        ADRFACDFBridge(b.bridge).importResult{gas: CALL_GAS}(caseId, 0);
        reg.decide{gas: CALL_GAS}(caseId);

        // The jurors are paid per ballot.
        for (uint256 i = 0; i < JUROR_QUORUM; i++) {
            BallotMeter(b.meter).report{gas: CALL_GAS}(pid, issueId, 1, 0, js[i]);
            PublicTreasury(payable(b.treasury)).withdrawEarnings{gas: CALL_GAS}(b.token, js[i]);
        }
        vm.stopBroadcast();

        vm.writeJson(vm.toString(caseId), _path(), ".caseId");
        vm.writeJson(vm.toString(issueId), _path(), ".issueId");
        vm.writeJson(vm.toString(callId), _path(), ".callId");
        console.log("dispute decided (Provisional); close it after the review window");
        console.logBytes32(caseId);
        console.log("client (this account):", me);
        for (uint256 i = 0; i < JURORS; i++) console.log("juror", js[i], TestUSD(b.token).balanceOf(js[i]));
        console.log("treasury holds:", TestUSD(b.token).balanceOf(b.treasury));
    }

    // ================================================================== step 4
    function close() external {
        Book memory b = _read();
        string memory j = vm.readFile(_path());
        bytes32 caseId = vm.parseJsonBytes32(j, ".caseId");
        ADRFServiceEscrow escrow = ADRFServiceEscrow(payable(b.escrow));
        IADRFDisputeRegistry reg = IADRFDisputeRegistry(b.disputes);

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        uint256 before = escrow.balanceOf(me);
        reg.finalize{gas: CALL_GAS}(caseId);
        escrow.enact{gas: CALL_GAS}(caseId, escrow.EFFECT_REFUND());
        vm.stopBroadcast();

        T.Ruling memory u = reg.getRuling(caseId);
        console.log("ruling result (1 = Sustained):", uint8(u.result));
        console.log("refunded to the client's escrow balance (wei):", escrow.balanceOf(me) - before);
    }

    // ================================================================== helpers

    /// A proposal decided by the stewards: filed, signed by three of five, settled, executed.
    function _decide(Book memory b, CouncilGovernor.Action action, bytes memory args) internal {
        CouncilGovernor gov = CouncilGovernor(b.governor);
        ACDFRegistry decisions = ACDFRegistry(b.decisions);
        (uint256 id, bytes32 issueId) = gov.propose{gas: CALL_GAS}(action, args);
        address[] memory ss = stewards();
        address[] memory voters = new address[](STEWARD_QUORUM);
        bool[] memory approves = new bool[](STEWARD_QUORUM);
        bytes[] memory sigs = new bytes[](STEWARD_QUORUM);
        for (uint256 i = 0; i < STEWARD_QUORUM; i++) {
            voters[i] = ss[i];
            approves[i] = true;
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key("steward", i), decisions.ballotDigest(issueId, 1, 0, ss[i], true));
            sigs[i] = abi.encodePacked(r, s, v);
        }
        decisions.submitSignedBallots{gas: CALL_GAS}(issueId, 0, voters, approves, sigs);
        decisions.settleRound{gas: CALL_GAS}(issueId);
        gov.execute{gas: CALL_GAS}(id);
        require(gov.proposalOf(id).status == CouncilGovernor.Status.Executed, "Pilot2: not executed");
    }

    function _council(address authority, string memory family, address[] memory members, uint32 k, uint64 window,
                      uint64 maxDuration, string memory descriptor) internal pure returns (A.PolicySpec memory s)
    {
        A.BodySpec[] memory bodies = new A.BodySpec[](1);
        bodies[0].kind = A.BodyKind.ROSTER_KOFN;
        bodies[0].acceptance = A.Acceptance.SIGNED_BALLOTS;
        bodies[0].members = members;
        bodies[0].k = k;
        bodies[0].window = window;
        A.Node[] memory nodes = new A.Node[](1);
        nodes[0].op = A.Combinator.BODY;
        nodes[0].body = 0;
        nodes[0].children = new uint32[](0);
        s.family = keccak256(bytes(family));
        s.version = 1;
        s.updateAuthority = authority;
        s.bodies = bodies;
        s.nodes = nodes;
        s.appealStanding = A.AppealStanding.ANYONE;
        s.appealMode = A.AppealMode.PRESERVE_UNLESS_OVERTURNED;
        s.maxTotalDuration = maxDuration;
        s.descriptorHash = keccak256(bytes(descriptor));
    }

    function _claim(ADRFServiceEscrow escrow, uint256 callId, address respondent) internal view returns (T.ClaimInput memory c) {
        c.object = escrow.objectOf(callId);
        c.eventRef = escrow.EVENT_DELIVERY();
        c.proposition = keccak256("claim: the delivery does not conform");
        c.normRef = TERMS;
        c.clause = keccak256("terms: the deliverable conforms to the acceptance criteria");
        c.obligationKind = escrow.KIND_RESULT();
        c.respondent = respondent;
        c.requestedEffects = new bytes32[](1);
        c.requestedEffects[0] = escrow.EFFECT_REFUND();
        c.effectOnSustained = escrow.EFFECT_REFUND();
        c.fallbackRef = escrow.DISPOSITION_STATUS_QUO();
        c.evidenceScopeHash = keccak256("pilot2: evidence scope");
        c.documentHash = keccak256(abi.encode("pilot2: case document", callId));
        c.decisive = 0;
        c.supportsWhen = T.Value.FALSE;
        c.subQuestions = new T.SubQuestionInput[](1);
        c.subQuestions[0].proposition = CONFORMS;
        c.subQuestions[0].qType = T.QuestionType.JUDGED;
        c.subQuestions[0].obligationKind = escrow.KIND_RESULT();
        c.subQuestions[0].dependsOn = new uint32[](0);
        c.subQuestions[0].requiredValues = new T.Value[](0);
    }

    function _path() internal view returns (string memory) {
        return string.concat("deployments/pilot2-", vm.toString(block.chainid), ".json");
    }

    function _write(Book memory b) internal {
        string memory k = "pilot2";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "token", b.token);
        vm.serializeAddress(k, "governor", b.governor);
        vm.serializeAddress(k, "treasury", b.treasury);
        vm.serializeAddress(k, "schedule", b.schedule);
        vm.serializeAddress(k, "task", b.task);
        vm.serializeAddress(k, "deductions", b.deductions);
        vm.serializeAddress(k, "decisions", b.decisions);
        vm.serializeAddress(k, "policies", b.policies);
        vm.serializeBytes32(k, "stewards", b.stewards);
        vm.serializeBytes32(k, "jurors", b.jurors);
        vm.serializeAddress(k, "disputes", b.disputes);
        vm.serializeAddress(k, "bridge", b.bridge);
        vm.serializeAddress(k, "escrow", b.escrow);
        vm.serializeBytes32(k, "disputePolicy", b.disputePolicy);
        vm.serializeBytes32(k, "binding", b.binding);
        vm.serializeAddress(k, "meter", b.meter);
        vm.serializeAddress(k, "provider", b.provider);
        vm.serializeAddress(k, "stewardKeys", stewards());
        vm.serializeAddress(k, "jurorKeys", jurors());
        vm.serializeUint(k, "programId", type(uint256).max);   // set by fund()
        vm.serializeUint(k, "callId", type(uint256).max);      // set by dispute()
        vm.serializeBytes32(k, "issueId", bytes32(0));         // set by dispute()
        string memory out = vm.serializeBytes32(k, "caseId", bytes32(0)); // set by dispute()
        vm.writeJson(out, _path());
    }

    function _read() internal view returns (Book memory b) {
        string memory j = vm.readFile(_path());
        b.token = vm.parseJsonAddress(j, ".token");
        b.governor = vm.parseJsonAddress(j, ".governor");
        b.treasury = vm.parseJsonAddress(j, ".treasury");
        b.schedule = vm.parseJsonAddress(j, ".schedule");
        b.task = vm.parseJsonAddress(j, ".task");
        b.deductions = vm.parseJsonAddress(j, ".deductions");
        b.decisions = vm.parseJsonAddress(j, ".decisions");
        b.policies = vm.parseJsonAddress(j, ".policies");
        b.stewards = vm.parseJsonBytes32(j, ".stewards");
        b.jurors = vm.parseJsonBytes32(j, ".jurors");
        b.disputes = vm.parseJsonAddress(j, ".disputes");
        b.bridge = vm.parseJsonAddress(j, ".bridge");
        b.escrow = vm.parseJsonAddress(j, ".escrow");
        b.disputePolicy = vm.parseJsonBytes32(j, ".disputePolicy");
        b.binding = vm.parseJsonBytes32(j, ".binding");
        b.meter = vm.parseJsonAddress(j, ".meter");
        b.provider = vm.parseJsonAddress(j, ".provider");
    }
}
