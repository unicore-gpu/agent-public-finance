// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ICollectiveDecisions} from "./interfaces/ICollectiveDecisions.sol";
import {IPublicTreasury} from "./interfaces/IPublicTreasury.sol";
import {IPublicTaxSchedule} from "./interfaces/IPublicTaxSchedule.sol";

/// @title  CouncilGovernor
/// @notice The governor of a public treasury and its tax schedule, acting only on the final
///         decisions of one ERC-8436 council.
///
///         A proposer files one action: create or end a grant, create or close a program,
///         propose or withdraw a tax rate, or add or remove a proposer. The action and its
///         arguments are fixed when it is filed, as the subject of an ERC-8436 issue that this
///         contract files as its consumer, under the council's policy. Once the issue is Final,
///         anyone may execute: a Yes runs exactly the filed action, a No or a NoDecision runs
///         nothing. A Yes must be executed within the execution window after it became Final;
///         after that it lapses.
///
///         The governor never takes a target or call data from a caller; it builds each call
///         from the filed action. The treasury and the schedule then apply their own notice
///         periods, ceilings and caps to whatever the council decides.
///
///         The treasury, the schedule and this contract name each other, so they are deployed
///         at predicted addresses; `isBound` confirms that the treasury and the schedule name
///         this contract as their governor.
contract CouncilGovernor {
    enum Action { CreateGrant, EndGrant, CreateProgram, CloseProgram, ProposeRate, WithdrawRateProposal, SetProposer }
    enum Status { None, Pending, Executed, Rejected, NoDecision, Lapsed }

    struct Proposal {
        Action action;
        Status status;
        bytes32 issueId;
        bytes args;
    }

    /// ERC-8436 encodings.
    uint8 private constant CONSUMER_FILED = 0;
    uint8 private constant FINAL = 4;
    uint8 private constant DECIDED = 1;
    uint8 private constant ENACTED = 1;
    uint8 private constant FAILED = 2;

    bytes32 public constant QUESTION = keccak256("public-finance:governor/v1");
    bytes32 public constant EFFECT_EXECUTE = keccak256("public-finance:governor/execute");
    bytes32 public constant EFFECT_REJECT = keccak256("public-finance:governor/reject");
    bytes32 public constant DISPOSITION_NONE = keccak256("public-finance:governor/no-action");

    ICollectiveDecisions public immutable registry;
    bytes32 public immutable policyId;
    IPublicTreasury public immutable treasury;
    IPublicTaxSchedule public immutable schedule;
    uint64 public immutable executionWindow;

    mapping(address => bool) public isProposer;
    /// The number of proposers. It never reaches zero: with no proposer, nothing could be
    /// filed again, not even a proposal to add one.
    uint256 public proposerCount;
    Proposal[] private _proposals;

    event Proposed(uint256 indexed id, bytes32 indexed issueId, Action action, bytes args, address proposer);
    event Executed(uint256 indexed id, bytes result);
    event ExecutionFailed(uint256 indexed id, bytes reason);
    event Closed(uint256 indexed id, Status status);
    event ProposerSet(address indexed proposer, bool allowed);

    constructor(ICollectiveDecisions registry_, bytes32 policyId_, IPublicTreasury treasury_,
                IPublicTaxSchedule schedule_, uint64 executionWindow_, address[] memory proposers)
    {
        require(address(registry_).code.length != 0, "Governor: no registry");
        require(policyId_ != bytes32(0), "Governor: no policy");
        require(address(treasury_) != address(0) && address(schedule_) != address(0), "Governor: zero address");
        require(executionWindow_ != 0, "Governor: zero window");
        require(proposers.length != 0, "Governor: no proposer");
        registry = registry_;
        policyId = policyId_;
        treasury = treasury_;
        schedule = schedule_;
        executionWindow = executionWindow_;
        for (uint256 i = 0; i < proposers.length; i++) _setProposer(proposers[i], true);
    }

    // ------------------------------------------------------------------ reads

    /// @notice Whether the treasury and the schedule name this contract as their governor.
    function isBound() external view returns (bool) {
        return address(treasury).code.length != 0 && address(schedule).code.length != 0
            && treasury.governor() == address(this) && schedule.governor() == address(this);
    }

    function proposalCount() external view returns (uint256) { return _proposals.length; }
    function proposalOf(uint256 id) external view returns (Proposal memory) { return _proposals[id]; }

    /// @notice The hash the council votes on: the subject's `dataHash` of the proposal's issue.
    function actionHash(Action action, bytes memory args) public pure returns (bytes32) {
        return keccak256(abi.encode(action, args));
    }

    // ------------------------------------------------------------------ proposals

    /// @notice File `action` with ABI-encoded `args` for the council to decide.
    /// @dev    The arguments are those of the call the action makes, in order:
    ///         CreateGrant (payee, asset, perPeriod, period, periods), EndGrant (grantId),
    ///         CreateProgram (meter, asset, ratePerUnit, budget, duration), CloseProgram
    ///         (programId), ProposeRate (asset, bps), WithdrawRateProposal (asset),
    ///         SetProposer (proposer, allowed).
    function propose(Action action, bytes calldata args) external returns (uint256 id, bytes32 issueId) {
        require(isProposer[msg.sender], "Governor: not a proposer");
        _call(action, args); // the arguments must decode exactly

        id = _proposals.length;
        ICollectiveDecisions.IssueInput memory input;
        input.policyId = policyId;
        input.mode = CONSUMER_FILED;
        input.consumer = address(this);
        input.subject = ICollectiveDecisions.Subject(block.chainid, address(this), id, actionHash(action, args));
        input.question = QUESTION;
        input.effectYes = EFFECT_EXECUTE;
        input.effectNo = EFFECT_REJECT;
        input.disposition = DISPOSITION_NONE;
        input.obligationId = keccak256(abi.encode(id));
        issueId = registry.file(input);

        _proposals.push(Proposal(action, Status.Pending, issueId, args));
        emit Proposed(id, issueId, action, args, msg.sender);
    }

    /// @notice Act on the council's final decision on proposal `id`. Anyone may call.
    /// @dev    A Yes within the window runs the action. If the action reverts, the failure is
    ///         recorded and the proposal stays pending, so that it can be executed again
    ///         within the window, for example once the treasury holds enough to fund it.
    function execute(uint256 id) external {
        Proposal storage p = _proposals[id];
        require(p.status == Status.Pending, "Governor: closed");
        ICollectiveDecisions.Result memory r = registry.getResult(p.issueId);
        require(r.state == FINAL, "Governor: not final");

        if (r.outcomeType != DECIDED) {
            _close(id, Status.NoDecision);
            return;
        }
        if (!r.outcomeYes) {
            _close(id, Status.Rejected);
            registry.recordEnactment(p.issueId, EFFECT_REJECT, ENACTED, bytes32(0));
            return;
        }
        if (block.timestamp > uint256(r.finalAt) + executionWindow) {
            _close(id, Status.Lapsed);
            return;
        }

        (address target, bytes memory data) = _call(p.action, p.args);
        p.status = Status.Executed;
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) = target.call(data);
        if (ok) {
            registry.recordEnactment(p.issueId, EFFECT_EXECUTE, ENACTED, keccak256(ret));
            emit Executed(id, ret);
        } else {
            // A call starved of gas by its caller is not a failure of the action.
            require(gasleft() > gasBefore / 64, "Governor: out of gas");
            p.status = Status.Pending;
            registry.recordEnactment(p.issueId, EFFECT_EXECUTE, FAILED, keccak256(ret));
            emit ExecutionFailed(id, ret);
        }
    }

    /// @notice Add or remove a proposer. Only through an executed proposal, and never the last.
    function setProposer(address proposer, bool allowed) external {
        require(msg.sender == address(this), "Governor: only by decision");
        _setProposer(proposer, allowed);
    }

    // ------------------------------------------------------------------ internals

    function _close(uint256 id, Status status) private {
        _proposals[id].status = status;
        emit Closed(id, status);
    }

    function _setProposer(address proposer, bool allowed) private {
        require(proposer != address(0), "Governor: zero proposer");
        if (isProposer[proposer] == allowed) return;
        isProposer[proposer] = allowed;
        if (allowed) proposerCount++;
        else require(--proposerCount != 0, "Governor: last proposer");
        emit ProposerSet(proposer, allowed);
    }

    function _call(Action action, bytes memory args) private view returns (address target, bytes memory data) {
        if (action == Action.CreateGrant) {
            _length(args, 5);
            (address payee, address asset, uint256 perPeriod, uint64 period, uint32 periods) =
                abi.decode(args, (address, address, uint256, uint64, uint32));
            return (address(treasury), abi.encodeCall(IPublicTreasury.createGrant, (payee, asset, perPeriod, period, periods)));
        }
        if (action == Action.EndGrant) {
            _length(args, 1);
            return (address(treasury), abi.encodeCall(IPublicTreasury.endGrant, (abi.decode(args, (uint256)))));
        }
        if (action == Action.CreateProgram) {
            _length(args, 5);
            (address meter, address asset, uint256 ratePerUnit, uint256 budget, uint64 duration) =
                abi.decode(args, (address, address, uint256, uint256, uint64));
            return (address(treasury), abi.encodeCall(IPublicTreasury.createProgram, (meter, asset, ratePerUnit, budget, duration)));
        }
        if (action == Action.CloseProgram) {
            _length(args, 1);
            return (address(treasury), abi.encodeCall(IPublicTreasury.closeProgram, (abi.decode(args, (uint256)))));
        }
        if (action == Action.ProposeRate) {
            _length(args, 2);
            (address asset, uint16 bps) = abi.decode(args, (address, uint16));
            return (address(schedule), abi.encodeCall(IPublicTaxSchedule.proposeRate, (asset, bps)));
        }
        if (action == Action.WithdrawRateProposal) {
            _length(args, 1);
            return (address(schedule), abi.encodeCall(IPublicTaxSchedule.withdrawProposal, (abi.decode(args, (address)))));
        }
        _length(args, 2);
        (address proposer, bool allowed) = abi.decode(args, (address, bool));
        return (address(this), abi.encodeCall(this.setProposer, (proposer, allowed)));
    }

    function _length(bytes memory args, uint256 words) private pure {
        require(args.length == 32 * words, "Governor: bad arguments");
    }
}
