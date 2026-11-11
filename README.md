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

### Integration with the real contracts

`integration/` runs the whole loop on the real contracts: ERC-8414 tasks on the kernel with
the settlement-deduction hook (`unicore-gpu/task-token-standard`, branch
`settlement-deductions`) pay tax into the treasury, and an ERC-8436 judges' council
(`garyyang-finchip/acd-framework`) decides judged tasks through the reference 8436-8414
adapter; the ballot meter pays each judge per ballot from a treasury program. Both are
pinned submodules under `lib/`.

```sh
FOUNDRY_PROFILE=integration forge test
```

The profile compiles everything as those repositories do (via-IR, optimizer runs 1) and
raises the contract size limit for the test EVM only.

### Testnet pilot

`script/Pilot.s.sol` runs the same loop on a public testnet in three steps, separated by the
two notice periods (10 minutes each by default): `deploy`, `fund` (two tasks pay tax; the
judging program opens) and `judge` (a judged task; three judges sign ballots; the meter pays
them). The broadcasting account is the governor, client and worker; the judges only sign and
hold no ether. The reward token is `TestUSD`, which anyone can mint and which has no value.

```sh
export FOUNDRY_PROFILE=integration
forge script script/Pilot.s.sol --sig "deploy()" --rpc-url $RPC --account <keystore> --broadcast --slow --skip-simulation
# after the rate notice:    --sig "fund()"
# after the program notice: --sig "judge()"
```

Gas limits: every call after the deployment carries a fixed limit. A payout must leave the
deduction policy its whole budget, which an estimate from the gas used does not, and a public
RPC endpoint that balances requests across nodes can estimate against a block it has not
yet seen. `--skip-simulation` takes the deployments' limits from the node, because under
EIP-8037 the local simulation can undercount new storage. The three steps use about 24
million gas under the current schedule and about 149 million under EIP-8037, most of it to
deploy.

#### Sepolia run

Run on 2026-11-11 on Sepolia, which prices storage under EIP-8037. Addresses are in
`deployments/pilot-11155111.json`. Every transaction succeeded, using about 149 million gas
in all.

| Contract | Address |
|---|---|
| `DeductingTaskToken` (ERC-8414 with the settlement-deduction hook) | [`0x9729…101B`](https://sepolia.etherscan.io/address/0x972912a584b39Add7A028375Ea81d58DD639101B) |
| `SettlementDeductionPolicy` | [`0x493B…36Cd`](https://sepolia.etherscan.io/address/0x493B8C0C986BC4Fd6A06cC3a97F48a6F577736Cd) |
| `TaxSchedule` | [`0x9441…a5D4`](https://sepolia.etherscan.io/address/0x9441bd4A5329AA92365B793F707626fCC7C7a5D4) |
| `PublicTreasury` | [`0xE7C9…1029`](https://sepolia.etherscan.io/address/0xE7C9842159a2cb17E92F7cA8a18D9c691A101029) |
| `ACDFRegistry` (ERC-8436) | [`0xf607…d659`](https://sepolia.etherscan.io/address/0xf60780Ae5C733476d918313eaF4E453125C4d659) |
| `ACDFTaskTenderAdapter` | [`0x1e23…6289`](https://sepolia.etherscan.io/address/0x1e2345B84ee61B88D07861b8eb9113e16E0B6289) |
| `BallotMeter` | [`0xdeF5…50cb`](https://sepolia.etherscan.io/address/0xdeF542059d26D2FFB9818F3fe027aFA881e850cb) |
| `TestUSD` | [`0xBFf6…1c11`](https://sepolia.etherscan.io/address/0xBFf6cBB7d0a0327A5b184E49944C87413c8d1c11) |

Outcome, in tUSD: two tasks of 5,000 and one judged task of 1,000 paid 1% tax, 110 in all.
The council's three ballots were enacted through the adapter
([`execute`](https://sepolia.etherscan.io/tx/0xa77794af84e090d08cb33aec6ef634c2a8c34340be2afe24f109c9e705c86f12)),
the meter counted each ballot once, and each of the three judges who voted withdrew 2. The
treasury holds 104, the program has 24 of its 30 left, and the two judges who did not vote
hold nothing.

The last two calls of `fund` (the second claim and `createProgram`) were sent with `cast`:
the script's estimate for the claim reached a node behind the chain and reverted. Fixed gas
limits now avoid that.

The judges' keys are derived from a public seed (`JUDGE_SEED`). They are for this pilot only.

## Status and warnings

This is a draft standard. The interfaces may change during discussion. The code has not
been audited; do not use it to hold real funds.

## License

[CC0 1.0](LICENSE).
