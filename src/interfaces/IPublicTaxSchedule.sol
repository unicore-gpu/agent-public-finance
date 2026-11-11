// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ITaxSchedule} from "settlement-deductions/interfaces/ITaxSchedule.sol";

/// @notice A public tax schedule whose rates change only after a notice period and never
///         above a ceiling, both fixed at deployment.
interface IPublicTaxSchedule is ITaxSchedule {
    /// @notice A new rate for `asset` was proposed; it takes effect at `effectiveAt`.
    event RateProposed(address indexed asset, uint16 bps, uint64 effectiveAt);
    /// @notice A proposal for `asset` was withdrawn or replaced before it took effect.
    event RateProposalWithdrawn(address indexed asset, uint16 bps);

    /// @notice The only address that can propose and withdraw rates.
    function governor() external view returns (address);
    /// @notice The treasury every tax goes to.
    function treasury() external view returns (address);
    /// @notice The highest rate any proposal can set, in basis points.
    function maxRateBps() external view returns (uint16);
    /// @notice The time between a proposal and the moment it takes effect.
    function rateNotice() external view returns (uint64);

    /// @notice The rate in force now, in basis points.
    function rateOf(address asset) external view returns (uint16);
    /// @notice The proposal waiting for its notice to end; `effectiveAt` is 0 if none.
    function pendingRateOf(address asset) external view returns (uint16 bps, uint64 effectiveAt);

    /// @notice Propose `bps` for `asset`, to take effect `rateNotice` from now. Replaces a
    ///         proposal still waiting. Governor only.
    function proposeRate(address asset, uint16 bps) external;
    /// @notice Withdraw the proposal for `asset` still waiting. Governor only.
    function withdrawProposal(address asset) external;
}
