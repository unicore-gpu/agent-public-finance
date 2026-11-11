# Agent Public Finance

**English** | [简体中文](README.zh-CN.md)

Public finance for networks where agents do paid work on-chain. A small tax on each settled
task funds the work that keeps the network running, such as judging disputes, and the
contracts, not a promise, limit how that money is spent.

```
task payout ──tax──▶ public treasury ──┬─ grant:   fixed amount per period, fixed term
                                       └─ program: rate per unit of work, reported by a meter
```

This is an application, not a standard. It is built on three draft standards:

- [ERC-8492](https://github.com/ethereum/ERCs/pull/2157), Settlement Deductions for Task
  Escrows: withholds the tax from each payout and pays it to the treasury;
- ERC-8414, Token-Bound Task Tenders: the task escrow;
- ERC-8436, Agent Collective Decision Framework: the councils whose ballots the meter counts.

It has three contracts:

- a **tax schedule**: one rate per asset, read when a task is created. A rate changes only
  after a public notice period, and never above a ceiling fixed at deployment;
- a **public treasury** with no way to move money except two kinds of commitment:
  **grants** (standing work) and **programs** (piecework). Every commitment is announced
  before money flows, funded in full when made, capped per recipient, and can be ended
  without taking away what was already earned;
- a **ballot meter**, which tells a program how many ballots each judge cast on final
  decisions of one council.

The rules these contracts follow are specified in [SPEC.md](SPEC.md). The whole loop has
run on Sepolia (see [Sepolia run](#sepolia-run)).

## Use cases

**Paying judges per ballot.** A network settles disputes over task results with a council
of judges deciding under ERC-8436. A program pays each judge a fixed amount for each ballot
cast on a final decision, whichever side it took, so that a judge gains nothing by siding
with the majority. `BallotMeter` checks each ballot against the council's registry and
counts it once. This is the case the Sepolia pilot runs.

**Standing work.** Work with no unit to count, such as maintaining shared contracts or
running an indexer or a monitoring service, is paid by a grant: a fixed amount per period
for a fixed term. Ending a grant stops future periods and leaves earned ones payable.

**Other piecework.** Any work a contract can count can be paid per unit through a program
with its own meter, for example a verifier paid per task result it checks. Each kind of
work needs its own meter; only `BallotMeter` exists today. The treasury trusts a meter's
counts, so a meter must count only what it can check on-chain.

**A tax agents can price in.** The rate in force when a task is created applies to that
task. A new rate applies only after the notice period, and never above the ceiling, so an
agent knows the tax before it takes a job.

**Spending rules that hold whoever decides.** Decisions are made by one governor address:
a single account in the pilot, and in a network typically a contract that executes
collective decisions. Whoever it is, money leaves the treasury only through announced,
funded and capped commitments, and the notice period gives others time to object. What
these rules do not stop is set out in SPEC.md, under Security Considerations.

## Contents

| Path | What it is |
|---|---|
| `SPEC.md` | The rules the tax schedule and the treasury follow |
| `src/interfaces/IPublicTaxSchedule.sol` | The tax schedule interface (extends `ITaxSchedule`) |
| `src/interfaces/IPublicTreasury.sol` | The treasury interface |
| `src/TaxSchedule.sol` | Reference tax schedule: rates per asset, notice, ceiling |
| `src/PublicTreasury.sol` | Reference treasury: grants, programs, notice, full funding, recipient cap |
| `src/BallotMeter.sol` | A program meter that pays one unit per ballot cast on a final ERC-8436 collective decision of one policy and consumer, such as a judges' council; anyone can report, each ballot counts once |
| `src/interfaces/ICollectiveDecisionReads.sol` | The three ERC-8436 registry reads the meter makes |
| `test/` | Foundry unit, fuzz and invariant tests: every requirement of the specification, the worked examples, odd tokens, recipients that refuse payment, re-entry, two assets, and end-to-end runs in which a settlement deduction policy collects the tax and a program pays a judge per case |
| `integration/` | Tests against the real ERC-8414 kernel with the deduction hook, the ERC-8436 registries and their adapter |
| `script/` | The testnet pilot (`Pilot.s.sol`) and its test token (`TestUSD.sol`) |
| `deployments/` | Addresses of the Sepolia pilot |

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

Run on 2026-11-11 on Sepolia, which prices storage under EIP-8037, with the contracts of
commit `27d5a6e`. Addresses are in `deployments/pilot-11155111.json`. Every transaction
succeeded, using about 149 million gas in all.

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

This is draft code. Its interfaces may change, and so may the draft standards it builds
on. The code has not been audited; do not use it to hold real funds. The Sepolia pilot uses
a test token with no value.

## License

[Apache-2.0](LICENSE), except [SPEC.md](SPEC.md), which is
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) so that anyone can implement
it. The repositories under `lib/` keep their own licenses; see [NOTICE](NOTICE).
