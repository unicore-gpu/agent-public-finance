// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ICollectiveDecisionReads} from "./interfaces/ICollectiveDecisionReads.sol";
import {IPublicTreasury} from "./interfaces/IPublicTreasury.sol";

/// @title  BallotMeter
/// @notice Reports one unit of work to a public treasury program for each ballot cast on a
///         final collective decision (ERC-8436). Only decisions under one policy, raised by
///         one consumer, count: for example the judges' council of a dispute registry,
///         reached through its bridge, so that judges are paid per ballot.
///
///         Anyone can report a ballot. The meter checks the report against the decision
///         registry and counts each ballot once, under any of the programs that name it as
///         their meter. A ballot counts whatever its side, so that a judge is not paid more
///         for siding with the majority.
///
///         Ballots of a body that decides by an authorized submitter are not individual
///         ballots in the registry, and are never counted.
contract BallotMeter {
    /// ERC-8436 `ProcedureState.Final`.
    uint8 private constant FINAL = 4;

    ICollectiveDecisionReads public immutable registry;
    bytes32 public immutable policyId;
    address public immutable consumer;
    IPublicTreasury public immutable treasury;

    /// ballot key => counted
    mapping(bytes32 => bool) public counted;

    event BallotCounted(uint256 indexed programId, bytes32 indexed issueId, address indexed voter,
                        uint32 round, uint32 body);

    constructor(ICollectiveDecisionReads registry_, bytes32 policyId_, address consumer_,
                IPublicTreasury treasury_)
    {
        require(address(registry_).code.length != 0 && address(treasury_).code.length != 0,
            "Meter: no code");
        require(policyId_ != bytes32(0) && consumer_ != address(0), "Meter: bad scope");
        registry = registry_;
        policyId = policyId_;
        consumer = consumer_;
        treasury = treasury_;
    }

    function ballotKey(bytes32 issueId, uint32 round, uint32 body, address voter)
        public pure returns (bytes32)
    {
        return keccak256(abi.encode(issueId, round, body, voter));
    }

    /// @notice Counts the ballot `voter` cast in `round` and `body` of `issueId`, and reports
    ///         one unit for the voter to program `programId`.
    /// @dev    Reverts unless the issue is final, under this meter's policy and consumer; the
    ///         ballot exists; the round started no earlier than the program; and the ballot
    ///         was not counted before. The treasury then checks that this meter is the
    ///         program's meter and that the program is running and funded.
    function report(uint256 programId, bytes32 issueId, uint32 round, uint32 body, address voter)
        external
    {
        ICollectiveDecisionReads.Result memory r = registry.getResult(issueId);
        require(r.policyId == policyId && r.consumer == consumer, "Meter: not in scope");
        require(r.state == FINAL, "Meter: not final");
        require(registry.hasVoted(issueId, round, body, voter), "Meter: no ballot");
        // Work done before the program was announced and its notice ran is not paid by it.
        require(registry.getRound(issueId, round).startedAt >= treasury.programOf(programId).start,
            "Meter: before the program");

        bytes32 key = ballotKey(issueId, round, body, voter);
        require(!counted[key], "Meter: counted");
        counted[key] = true;

        emit BallotCounted(programId, issueId, voter, round, body);
        treasury.reportUnits(programId, voter, 1);
    }
}
