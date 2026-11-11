// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ITaxSchedule} from "settlement-deductions/interfaces/ITaxSchedule.sol";
import {IPublicTaxSchedule} from "./interfaces/IPublicTaxSchedule.sol";

/// @title  TaxSchedule — public tax rates, one per asset.
/// @notice A deduction policy reads the rate once per task, at creation. Nobody sets a
///         rate directly: the governor proposes, the proposal is public for `rateNotice`
///         and then takes effect by itself. No rate can exceed `maxRateBps`. An asset
///         with no rate is untaxed.
contract TaxSchedule is IPublicTaxSchedule {
    uint16 public constant BPS = 10_000;

    address public immutable governor;
    address public immutable treasury;
    uint16 public immutable maxRateBps;
    uint64 public immutable rateNotice;

    struct Proposal {
        uint16 bps;
        uint64 effectiveAt; // 0 = no proposal
    }

    mapping(address => uint16) private _rate;
    mapping(address => Proposal) private _proposal;

    modifier onlyGovernor() {
        require(msg.sender == governor, "Tax: not governor");
        _;
    }

    constructor(address governor_, address treasury_, uint16 maxRateBps_, uint64 rateNotice_) {
        require(governor_ != address(0) && treasury_ != address(0), "Tax: zero address");
        require(maxRateBps_ <= BPS, "Tax: bad ceiling");
        require(rateNotice_ <= type(uint32).max, "Tax: bad notice"); // now + notice never overflows
        governor = governor_;
        treasury = treasury_;
        maxRateBps = maxRateBps_;
        rateNotice = rateNotice_;
    }

    // ------------------------------------------------------------------ reads
    /// @inheritdoc ITaxSchedule
    function taxOf(address asset) external view returns (address, uint16) {
        return (treasury, rateOf(asset));
    }

    /// @inheritdoc IPublicTaxSchedule
    function rateOf(address asset) public view returns (uint16) {
        Proposal memory p = _proposal[asset];
        if (p.effectiveAt != 0 && block.timestamp >= p.effectiveAt) return p.bps;
        return _rate[asset];
    }

    /// @inheritdoc IPublicTaxSchedule
    function pendingRateOf(address asset) external view returns (uint16, uint64) {
        Proposal memory p = _proposal[asset];
        if (p.effectiveAt == 0 || block.timestamp >= p.effectiveAt) return (0, 0);
        return (p.bps, p.effectiveAt);
    }

    // ---------------------------------------------------------------- changes
    /// @inheritdoc IPublicTaxSchedule
    function proposeRate(address asset, uint16 bps) external onlyGovernor {
        require(bps <= maxRateBps, "Tax: above ceiling");
        _fold(asset);
        Proposal memory p = _proposal[asset];
        if (p.effectiveAt != 0) emit RateProposalWithdrawn(asset, p.bps);
        uint64 at = uint64(block.timestamp) + rateNotice;
        _proposal[asset] = Proposal(bps, at);
        emit RateProposed(asset, bps, at);
    }

    /// @inheritdoc IPublicTaxSchedule
    function withdrawProposal(address asset) external onlyGovernor {
        _fold(asset);
        Proposal memory p = _proposal[asset];
        require(p.effectiveAt != 0, "Tax: no proposal");
        delete _proposal[asset];
        emit RateProposalWithdrawn(asset, p.bps);
    }

    /// Moves a proposal whose notice has ended into the stored rate. Emits nothing: the
    /// change is already on the record as the proposal's `RateProposed`.
    function _fold(address asset) private {
        Proposal memory p = _proposal[asset];
        if (p.effectiveAt == 0 || block.timestamp < p.effectiveAt) return;
        _rate[asset] = p.bps;
        delete _proposal[asset];
    }
}
