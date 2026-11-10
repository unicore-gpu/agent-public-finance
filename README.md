# Public Treasury and Tax Schedule

A draft ERC and reference implementation for funding public work from a tax on settled
work, under spending rules that the contracts enforce rather than promise.

```
task payout ──tax──▶ public treasury ──┬─ grant:   fixed amount per period, fixed term
                                       └─ program: rate per unit of work, reported by a meter
```

Two contracts:

- a **tax schedule**: one rate per asset, read by escrows and deduction policies at task
  creation. A rate changes only after a public notice period, and never above a ceiling
  fixed at deployment;
- a **public treasury** with no way to move money except two kinds of commitment:
  **grants** (standing work, such as maintaining contracts) and **programs** (piecework,
  such as a judge paid per case ruled). Every commitment is announced before money flows,
  funded in full when made, capped per recipient, and can be ended without taking away
  what was already earned.

The tax reaches the treasury through a deduction policy of the
[Settlement Deductions ERC](https://github.com/unicore-gpu/settlement-deductions), whose
`ITaxSchedule` interface the tax schedule implements.

The specification is in [ERC-draft.md](ERC-draft.md). Status: **Draft**, not yet submitted.

## Contents

| Path | What it is |
|---|---|
| `src/interfaces/IPublicTaxSchedule.sol` | The tax schedule interface (extends `ITaxSchedule`) |
| `src/interfaces/IPublicTreasury.sol` | The treasury interface |
| `src/TaxSchedule.sol` | Reference tax schedule: rates per asset, notice, ceiling |
| `src/PublicTreasury.sol` | Reference treasury: grants, programs, notice, full funding, recipient cap |
| `src/BallotMeter.sol` | A program meter that pays one unit per ballot cast on a final ERC-8436 collective decision of one policy and consumer, such as a judges' council; anyone can report, each ballot counts once |
| `src/interfaces/ICollectiveDecisionReads.sol` | The three ERC-8436 registry reads the meter makes |
| `test/` | Foundry unit, fuzz and invariant tests: every requirement of the specification, the worked examples, odd tokens, recipients that refuse payment, re-entry, two assets, and end-to-end runs in which a settlement deduction policy collects the tax and a program pays a judge per case |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```sh
git clone --recursive https://github.com/unicore-gpu/agent-public-finance
cd agent-public-finance
forge test
```

## Status and warnings

This is a draft standard. The interfaces may change during discussion. The code has not
been audited; do not use it to hold real funds.

## License

[CC0 1.0](LICENSE).
