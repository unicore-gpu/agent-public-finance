// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ICollectiveDecisionReads} from "./ICollectiveDecisionReads.sol";

/// @notice What a relying contract (an ERC-8436 consumer) needs from an ERC-8436 (Agent
///         Collective Decision Framework) registry: filing its own issues, reading their
///         results, and logging its enactments.
/// @dev    The structs mirror `ACDFTypes.Subject` and `ACDFTypes.IssueInput` of the ERC-8436
///         reference (acd-framework, commit f8204fb) field by field, with each enum as the
///         `uint8` it is encoded as, so the call data encodes the same.
interface ICollectiveDecisions is ICollectiveDecisionReads {
    struct Subject {
        uint256 chainId;
        address target;
        uint256 id;
        bytes32 dataHash;
    }

    struct IssueInput {
        bytes32 policyId;
        uint8   mode;             // AcceptanceMode: CONSUMER_FILED, STANDING_ACCEPTANCE, POST_ACK
        bytes32 acceptanceId;
        address consumer;
        Subject subject;
        bytes32 question;
        bytes32 effectYes;
        bytes32 effectNo;
        bytes32 disposition;
        bytes32 obligationId;
        uint64  consumerDeadline;
    }

    function file(IssueInput calldata input) external returns (bytes32 issueId);
    /// `status` is an EnactmentStatus: NotEnacted, Enacted, Failed.
    function recordEnactment(bytes32 issueId, bytes32 effectId, uint8 status, bytes32 ref) external;
}
