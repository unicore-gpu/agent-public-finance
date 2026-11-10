// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @notice The reads of an ERC-8436 (Agent Collective Decision Framework) registry that a
///         ballot meter needs, and nothing else.
/// @dev    The structs mirror `ACDFTypes.Result` and `ACDFTypes.RoundState` of the ERC-8436
///         reference (acd-framework, commit f8204fb) field by field, with each enum as the
///         `uint8` it is encoded as, so the return data decodes the same.
interface ICollectiveDecisionReads {
    struct Result {
        uint8   state;          // ProcedureState: None, Filed, Deciding, Provisional, Final, Withdrawn
        uint8   outcomeType;    // OutcomeType: None, Decided, NoDecision
        bool    outcomeYes;
        uint8   reason;
        uint64  decidedAt;
        uint64  finalAt;
        bytes32 policyId;
        uint32  roundCount;
        uint32  sourceRound;
        uint8   effectClass;
        address consumer;
        bytes32 effectYes;
        bytes32 effectNo;
        bytes32 disposition;
        bytes32 obligationId;
        bool    adoptedFromEarlierRound;
    }

    struct RoundState {
        uint64 startedAt;
        uint64 deadline;
        bool   settled;
        uint8  status;          // NodeStatus
        uint8  reason;
        uint64 at;
        uint64 appealOpenUntil;
    }

    function getResult(bytes32 issueId) external view returns (Result memory);
    /// Reverts unless 1 <= round <= the issue's round count.
    function getRound(bytes32 issueId, uint32 round) external view returns (RoundState memory);
    function hasVoted(bytes32 issueId, uint32 round, uint32 body, address voter) external view returns (bool);
}
