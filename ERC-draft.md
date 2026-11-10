---
eip: TBD
title: Public Treasury and Tax Schedule
description: A tax schedule with notice and a ceiling, and a treasury that pays out only through announced, funded and capped commitments
author: Ben (@unicore-gpu)
discussions-to: TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-11-09
requires: 20
---

## Abstract

This ERC specifies two contracts that let a network fund public work from a tax, under rules that the contracts enforce rather than promise:

1. a **tax schedule**: one rate per asset, readable by any settlement contract or deduction policy, that can only change after a public notice period and never above a ceiling fixed at deployment;
2. a **public treasury** that holds the tax and has no way to move money other than two kinds of commitment: **grants**, a fixed amount per period for a fixed term, and **programs**, a rate per unit of work reported by a named meter contract, within a budget and an end date.

Every commitment is announced a notice period before money flows, is funded in full when it is made, is capped per recipient when it is made, and can be ended without taking away what was already earned. Decisions are made by a governor, any address, typically the executor of a collective decision. The treasury does not judge the governor's decisions; it fixes their form, their timing and their size.

## Motivation

A tax on settled work can fund what a network of agents needs and no single agent will pay for: dispute resolution, monitoring, public data, maintenance of shared contracts. The tax is only acceptable if those who pay it can check how it is spent.

Treasuries today are mostly a multisig or a governor contract that can execute arbitrary calls, with streaming or vesting contracts added for regular payments. The rules that make public spending trustworthy exist only as norms around them:

- spending is announced before it happens;
- nothing is promised that the treasury does not hold;
- no single recipient takes a large share;
- standing work is paid for a term and then decided again;
- work done is paid, even if the decision to pay for it is later reversed;
- piecework is paid per piece, at a rate known in advance.

This ERC moves those rules into the contracts, where they hold whatever the governor decides. It standardizes the three places where independent parties meet:

1. **Settlement reads the rate.** Escrows and deduction policies of any market read one rate per asset at task creation, through one function, and know it cannot change without notice.
2. **Services report work.** A dispute-resolution contract, a monitoring service or a data feed reports units of work through one function, and is paid by any conforming treasury without an integration per treasury.
3. **Anyone checks the commitments.** Payers, recipients, wallets and indexers read every commitment, what is committed and what is available, in the same form in every network.

The tax schedule is separate from the treasury because its readers are different. Settlement contracts and deduction policies read one rate at task creation; they need neither the treasury's interface nor its state.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174).

### 1. Terms

- **Asset**: `address(0)` for the chain's native currency, otherwise an [ERC-20](./eip-20.md) token.
- **Governor**: the one address allowed to propose rates and to make and end commitments. It is fixed at deployment.
- **Commitment**: a grant or a program. Grants and programs are numbered separately, from 0, in the order they are made.
- **Grant**: a promise to pay `perPeriod` of an asset to one payee at the end of each of `periods` periods of length `period`.
- **Program**: a promise to pay `ratePerUnit` of an asset for each unit of work that one meter reports, up to a budget, between `start` and `end` inclusive.
- **Meter**: the address named by a program to report units of work and the worker who did them.
- **Recipient**: the payee of a grant, or the meter of a program.
- **Committed**, for an asset: the sum over its grants of `(periods - claimedPeriods) * perPeriod`, plus the sum over its programs of `remaining`, plus the sum over all workers of `earnedOf(asset, worker)`.
- **Outstanding**, for an asset and a recipient: the sum of `(periods - claimedPeriods) * perPeriod` over the grants it is the payee of, plus the sum of `remaining` over the programs it is the meter of.
- **Available**: the treasury's balance of an asset minus what is committed in it, or zero if the balance is lower.
- **Notice period**: the time between making a commitment, or proposing a rate, and the moment it takes effect.

### 2. Conformance

A tax schedule conforms if it implements section 3 and meets every requirement of section 4. A treasury conforms if it implements section 5 and meets every requirement of section 6. Support for [ERC-165](./eip-165.md) is OPTIONAL.

### 3. Tax schedule interface

`ITaxSchedule` is the interface that the reference policy of the Settlement Deductions for Task Escrows ERC reads at task creation. It is repeated here so that this document is complete.

```solidity
interface ITaxSchedule {
    /// The tax on payouts in `asset`: the treasury it goes to and its rate in basis points.
    function taxOf(address asset) external view returns (address treasury, uint16 bps);
}

interface IPublicTaxSchedule is ITaxSchedule {
    event RateProposed(address indexed asset, uint16 bps, uint64 effectiveAt);
    event RateProposalWithdrawn(address indexed asset, uint16 bps);

    function governor() external view returns (address);
    function treasury() external view returns (address);
    function maxRateBps() external view returns (uint16);
    function rateNotice() external view returns (uint64);

    /// The rate in force now.
    function rateOf(address asset) external view returns (uint16);
    /// The proposal waiting for its notice to end, if any (`effectiveAt` is 0 if none).
    function pendingRateOf(address asset) external view returns (uint16 bps, uint64 effectiveAt);

    function proposeRate(address asset, uint16 bps) external;
    function withdrawProposal(address asset) external;
}
```

### 4. Tax schedule requirements

1. **Fixed parameters.** `governor`, `treasury`, `maxRateBps` and `rateNotice` MUST NOT change after deployment. `governor` and `treasury` MUST NOT be zero. `maxRateBps` MUST NOT exceed 10000. `rateNotice` MUST NOT exceed `2**32 - 1` seconds, so that no proposal time can overflow.
2. **Reading.** `taxOf(asset)` MUST return `(treasury(), rateOf(asset))` and MUST NOT revert. An asset with no rate has a rate of zero.
3. **Proposals.** Only the governor MAY call `proposeRate` and `withdrawProposal`. `proposeRate` MUST revert if `bps > maxRateBps`. It MUST set the proposal's `effectiveAt` to the current block timestamp plus `rateNotice`, MUST replace any proposal for the asset still waiting for its notice to end (emitting `RateProposalWithdrawn` for it), and MUST emit `RateProposed`.
4. **Taking effect.** From `effectiveAt` until a later proposal takes effect, `rateOf` MUST return the proposed rate, without any further transaction. Before `effectiveAt`, `rateOf` MUST return the rate in force before the proposal.
5. **Withdrawal.** `withdrawProposal` MUST revert unless a proposal for the asset is waiting for its notice to end. It MUST remove that proposal and emit `RateProposalWithdrawn`. A proposal that has taken effect cannot be withdrawn; changing the rate again takes a new proposal and a new notice.

### 5. Treasury interface

```solidity
interface IPublicTreasury {
    struct Grant {
        address payee;
        address asset;
        uint128 perPeriod;
        uint64 period;
        uint64 start;
        uint32 periods;        // after the grant is ended: the periods it earned
        uint32 claimedPeriods;
    }

    struct Program {
        address meter;
        address asset;
        uint128 ratePerUnit;
        uint64 start;
        uint64 end;            // last second at which units are accepted
        uint256 remaining;     // budget not yet earned
    }

    event GrantCreated(uint256 indexed id, address indexed payee, address indexed asset,
                       uint256 perPeriod, uint64 period, uint32 periods, uint64 start);
    event GrantClaimed(uint256 indexed id, address indexed payee, uint256 amount);
    event GrantEnded(uint256 indexed id, uint32 periodsEarned, uint256 released);
    event ProgramCreated(uint256 indexed id, address indexed meter, address indexed asset,
                         uint256 ratePerUnit, uint256 budget, uint64 start, uint64 end);
    event UnitsReported(uint256 indexed id, address indexed worker, uint256 units, uint256 amount);
    event ProgramClosed(uint256 indexed id, uint256 released);
    event EarningsWithdrawn(address indexed asset, address indexed worker, uint256 amount);

    function governor() external view returns (address);
    function noticePeriod() external view returns (uint64);
    function maxTerm() external view returns (uint64);
    function recipientCapBps() external view returns (uint16);

    function committedOf(address asset) external view returns (uint256);
    function availableOf(address asset) external view returns (uint256);
    function outstandingOf(address asset, address recipient) external view returns (uint256);
    function earnedOf(address asset, address worker) external view returns (uint256);

    function grantCount() external view returns (uint256);
    function grantOf(uint256 id) external view returns (Grant memory);
    function claimableOf(uint256 id) external view returns (uint256);
    function programCount() external view returns (uint256);
    function programOf(uint256 id) external view returns (Program memory);

    function createGrant(address payee, address asset, uint256 perPeriod, uint64 period, uint32 periods)
        external returns (uint256 id);
    function endGrant(uint256 id) external;
    function claimGrant(uint256 id) external;

    function createProgram(address meter, address asset, uint256 ratePerUnit, uint256 budget, uint64 duration)
        external returns (uint256 id);
    function reportUnits(uint256 id, address worker, uint256 units) external;
    function closeProgram(uint256 id) external;
    function withdrawEarnings(address asset, address worker) external;
}
```

### 6. Treasury requirements

1. **Fixed parameters.** `governor`, `noticePeriod`, `maxTerm` and `recipientCapBps` MUST NOT change after deployment. `governor` MUST NOT be zero. `recipientCapBps` MUST be between 1 and 10000. `maxTerm` MUST NOT be zero, and `noticePeriod + maxTerm` MUST NOT exceed `2**32 - 1` seconds, so that no start or end time can overflow.
2. **Only two ways out.** The treasury MUST NOT transfer any asset except in `claimGrant`, to the grant's payee, and in `withdrawEarnings`, to the worker. It MUST NOT expose any other function that transfers assets or executes arbitrary calls. It MUST accept the native currency.
3. **Funded.** Making a commitment MUST revert if its full amount (`perPeriod * periods` for a grant, `budget` for a program) exceeds `availableOf(asset)`. Every function MUST keep `committedOf(asset)` and `outstandingOf(asset, recipient)` equal to the sums defined in section 1.
4. **Announced.** A commitment's `start` MUST be the block timestamp at which it is made plus `noticePeriod`. A program's `end` MUST be `start + duration`. `createGrant` MUST emit `GrantCreated` and `createProgram` MUST emit `ProgramCreated`, with these values. Ids MUST be assigned in sequence from 0, separately for grants and programs.
5. **Bounded.** A grant's `period * periods`, and a program's `duration`, MUST NOT exceed `maxTerm`. Zero amounts, periods, budgets and durations MUST revert, and so MUST a `perPeriod` or `ratePerUnit` that does not fit in 128 bits.
6. **Capped per recipient.** Making a commitment MUST revert if it would raise `outstandingOf(asset, recipient)` above `balance * recipientCapBps / 10000`, rounded down, where `balance` is the treasury's balance of the asset at that moment. The computation MUST NOT overflow for any balance. The recipient MUST NOT be zero, the governor, or the treasury itself.
7. **Only the governor commits.** Only the governor MAY call `createGrant`, `createProgram` and `endGrant`, and `closeProgram` while the program is running (`block.timestamp <= end`).
8. **Earned stays earned.** `endGrant` MUST revert if the grant has no periods left to earn. It MUST reduce the grant's `periods` to those already earned, MUST release the rest, and MUST emit `GrantEnded`; a period not finished when the grant is ended earns nothing. Ending a grant before its start cancels it. While a program is running, `closeProgram` MUST set its `end` to the current block timestamp minus one, so that it accepts no more units, MUST release its unspent budget (which MAY be zero), and MUST emit `ProgramClosed`. After a program's end, anyone MAY call `closeProgram`; it MUST then release the unspent budget, MUST revert if there is none, and MUST emit `ProgramClosed`. Earned periods and reported earnings MUST stay payable.
9. **Claims.** A grant earns one period at each `start + k * period` for `k` from 1 to `periods`. `claimableOf(id)` MUST return the earned periods not yet claimed times `perPeriod`. `claimGrant` MUST be callable by anyone, MUST pay the claimable amount to the payee only, MUST revert if it is zero, and MUST emit `GrantClaimed`.
10. **Units.** `reportUnits` MUST revert unless called by the program's meter, between `start` and `end` inclusive, for a nonzero number of units and a worker that is not zero, the governor or the treasury, and unless `units * ratePerUnit` is at most the program's `remaining`. It MUST move that amount from `remaining` to `earnedOf(asset, worker)` and MUST emit `UnitsReported`.
11. **Withdrawal of earnings.** `withdrawEarnings(asset, worker)` MUST be callable by anyone, MUST pay `earnedOf(asset, worker)` to `worker` only, MUST set it to zero, MUST revert if it was zero, and MUST emit `EarningsWithdrawn`.
12. **Order.** Every function that transfers an asset MUST update its state and emit its event before the transfer.
13. **Unknown ids.** `grantOf`, `claimableOf`, `programOf` and every function taking an id MUST revert for an id that has not been assigned.

## Rationale

**Why a standard.** A network usually runs one treasury, so the treasury alone would be a product. The interfaces around it are not: the rate is read by every escrow and deduction policy in a market, work is reported by services that serve many networks, and commitments are read by every payer and tool. Fixing these interfaces lets each side be built once.

**Two forms of spending.** Public work comes in two shapes. Standing work, such as maintaining contracts or running monitoring, is paid per period for a term, then decided again; that is a grant. Piecework, such as ruling on a dispute, is paid per piece at a rate fixed in advance; that is a program. Paying judges per case ruled, and not for agreeing with a majority, keeps the payment independent of the verdict. An arbitrary `execute` was left out on purpose: any spending rule a treasury states is void if one call can bypass it.

**Funded in full when made.** A commitment counts against the treasury's balance from the moment it is made, so a recipient does not depend on future tax income: every period it earns can be paid. The governor can still end a grant, so what a payee can count on is the periods it has earned and the notice before any new commitment. A program's budget, not its expected spending, is committed for the same reason.

**Notice.** Commitments and rate changes take effect a notice period after they are made. Tax payers can react to a rate before it applies to their tasks, and anyone can object to a commitment before money flows, through whatever process the governor answers to. The governor can end a grant, close a program or withdraw a rate proposal during the notice, so a mistake costs nothing.

**A cap per recipient.** No commitment may raise a recipient's outstanding amount above a fixed share of the balance at the time it is made. This spreads the treasury over several providers and keeps any one of them from holding most of its money. The cap is per address, so it does not stop a governor that splits a commitment over several addresses it controls; see Security Considerations.

**Meters, not judges of work.** The treasury does not know what a case or a report is. A program names one meter, which the governor trusts to count units, for example a dispute-resolution contract reporting each ruling and the judge who made it. Meters from different systems work with any conforming treasury.

**Lazy rates.** A rate takes effect at a known time without a keeper transaction. Contracts that read the schedule at task creation always see the rate in force, and the rate history is fully determined by the `RateProposed` and `RateProposalWithdrawn` events.

**Permissionless claims.** Anyone may claim a grant or withdraw a worker's earnings, and the money goes only to the payee or worker. Recipients that are contracts without a way to call the treasury can still be paid, and a relayer can pay the gas.

**One governor, any process.** The governor is a single address so that any decision process can sit behind it: a collective decision registry's executor, a timelock, a multisig. The treasury does not trust that process; it fixes what the process can do and when.

**Relation to existing work.** A governor contract with a timelock delays and records decisions, but a passed proposal can still make any call, so the rules above stay outside the contract. Streaming and vesting contracts pay one recipient over time once funded; they do not limit what a treasury commits overall or per recipient. [ERC-1620](./eip-1620.md) streams money between two parties, who can change or stop a stream by agreement. [ERC-7794](./eip-7794.md) registers grants and their disbursements as records managed by a grant manager, without holding the money. Here the treasury holds the money and its interface is the only way out.

## Backwards Compatibility

This ERC introduces new contracts. `ITaxSchedule` is the interface that the reference policy of the Settlement Deductions for Task Escrows ERC reads at task creation, so such a policy works with a conforming schedule unchanged. That policy refuses a task whose rate exceeds its own cap on deductions. Deployers SHOULD set `maxRateBps` no higher than the cap of every policy that reads the schedule, and well below it if payees also assign part of their payouts, since the tax is taken first.

## Test Cases

**Interface identifiers** (as computed by Solidity's `type(I).interfaceId`, which excludes inherited functions, for implementations that also support ERC-165): `ITaxSchedule` = `0xbbb356a6`; `IPublicTaxSchedule` = `0x562cde7d`; `IPublicTreasury` = `0x0ea4abf4`.

**Rate change.** `maxRateBps = 500`, `rateNotice = 7 days`. At day 0 the governor proposes 1% for an asset. Until day 7, `taxOf` returns 0; from day 7 on, 1%. A proposal of 6% reverts. A proposal of 2% made at day 10 and withdrawn at day 12 leaves the rate at 1%.

**Grant.** `noticePeriod = 3 days`, `maxTerm = 365 days`, `recipientCapBps = 3000`. The treasury holds 1,000. A grant of 20 per 30 days for 12 periods commits 240 and starts at day 3. At day 33 its payee can claim 20; at day 93, 60 in total. Ending it at day 100 keeps the three earned periods payable and releases 180.

**Cap.** With the same parameters, a second grant of 100 to the same payee is refused while it holds 240 outstanding, since 340 exceeds 30% of 1,000. A grant of 100 to another payee is accepted.

**Program.** A program pays 5 per case reported by a dispute-resolution meter, with a budget of 100 for 90 days. After 20 cases the budget is spent and a 21st report reverts. The governor can still close it, which stops it without releasing anything. Closing an unfinished program releases its unspent budget; reported earnings stay withdrawable.

**Invariants.** Under any sequence of the actions above, in an ERC-20 and in the native currency: `committedOf(asset)` and `outstandingOf(asset, recipient)` equal the sums of section 1; `committedOf(asset)` never exceeds the treasury's balance; and, for an asset that delivers the amount transferred and a recipient that accepts it, every claim of a nonzero `claimableOf` and every withdrawal of a nonzero `earnedOf` succeeds.

## Reference Implementation

- `ITaxSchedule.sol`, `IPublicTaxSchedule.sol`, `IPublicTreasury.sol`: the interfaces of sections 3 and 5.
- `TaxSchedule.sol`: a tax schedule meeting section 4.
- `PublicTreasury.sol`: a treasury meeting section 6.
- Foundry tests: at least one per requirement of sections 4 and 6, the cases above, fuzz tests of the rate rules and of grant schedules, invariant tests over random sequences of every action in two assets, and end-to-end tests in which a settlement deduction policy collects the tax on task payouts into the treasury, and a program pays a judge per case reported by a meter.

## Security Considerations

**What the rules do not stop.** The treasury bounds the form, timing and size of each commitment; it does not judge it. A governor can commit the whole available balance in one decision, split over several addresses it controls, each under the cap, and have it paid out after the notice. The notice is then the only defence, and it protects only if the process behind the governor can stop it in that window: a vote to end the grants, a veto, an appeal. Deployers should choose a notice long enough for that process to act. The ban on the governor and the treasury as recipients or workers only stops the most direct case. A notice period of zero conforms but removes the guarantee that commitments are announced.

**Meters are trusted.** A meter can report units it invented, up to the program's budget. Governors should only name meters whose counting they can verify, should keep budgets and durations small, and should close a program as soon as its meter is in doubt. `reportUnits` reverts once a program has ended, been closed or spent its budget; a meter that reports as part of its own work, such as a ruling, should call it so that a revert does not stop that work.

**Recipients that cannot receive.** A payee or worker that reverts on receipt, or that a token blocks, cannot be paid. Its earned amounts stay committed and cannot be redirected, since redirecting would be a third way out of the treasury. The governor can end its grant to stop further commitments.

**Assets.** The treasury reads its balance to decide what is available. Fee-on-transfer and rebasing assets, whose balance can fall without a transfer by the treasury, can leave `committedOf` above the balance, so that late claims fail. So can an asset reachable through two addresses that share one ledger, such as a token with two entry points or a native currency that is also an ERC-20: the same balance can then be committed once under each address. A token that blocks the treasury, or whose issuer can seize its balance, can stop every payment in that asset. Treasuries should commit only assets that deliver the amount transferred, do not rebase, and have one address.

**The governor is fixed.** There is no way to replace the governor. If its key or executor is lost, money that is not committed stays in the treasury; the only way to move it is through commitments made before the loss. A network that wants to migrate makes grants to a new treasury, within the cap and after the notice.

**Re-entrancy.** Claims and withdrawals update state before transferring (section 6, requirement 12). A recipient that re-enters can only claim what it has newly earned.

**Rates and schedules.** The ceiling and the notice are fixed at deployment; a network that wants to change them deploys a new schedule, and settlement contracts that name the old one keep using it. A rate above the cap of a policy that reads the schedule stops task creation in that policy's escrow (see Backwards Compatibility). Payers should read both before relying on a schedule.

**Time.** All times are block timestamps. Validators can shift a timestamp by seconds, which is negligible against notice periods and terms of days.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
