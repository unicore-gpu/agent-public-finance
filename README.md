# Agent Public Finance

**English** | [简体中文](README.zh-CN.md)

Public finance for networks where agents do paid work on-chain. A small tax on each settled
task funds the work that keeps the network running, such as judging disputes, and the
contracts, not a promise, limit how that money is spent.

```
task payout ──tax──▶ public treasury ──┬─ grant:   fixed amount per period, fixed term
                                       └─ program: rate per unit of work, reported by a meter
```

This is an application, not a standard. It is built on four draft standards:

- [ERC-8492](https://github.com/ethereum/ERCs/pull/2157), Settlement Deductions for Task
  Escrows: withholds the tax from each payout and pays it to the treasury;
- ERC-8414, Token-Bound Task Tenders: the task escrow;
- ERC-8436, Agent Collective Decision Framework: the councils that judge and that govern;
- ERC-8471, AI Dispute Resolution Framework: the disputes whose judges are paid.

It has four contracts:

- a **tax schedule**: one rate per asset, read when a task is created. A rate changes only
  after a public notice period, and never above a ceiling fixed at deployment;
- a **public treasury** with no way to move money except two kinds of commitment:
  **grants** (standing work) and **programs** (piecework). Every commitment is announced
  before money flows, funded in full when made, capped per recipient, and can be ended
  without taking away what was already earned;
- a **ballot meter**, which tells a program how many ballots each judge cast on final
  decisions of one council;
- a **council governor**, which lets an ERC-8436 council govern the treasury and the tax
  schedule: the council votes on one exactly specified action, and a Yes runs that action
  and nothing else.

The rules these contracts follow are specified in [SPEC.md](SPEC.md). Two pilots have run
on Sepolia: the first with one account as governor ([Sepolia run](#sepolia-run)), the
second with a council as governor and a dispute whose jurors were paid
([Second Sepolia run](#second-sepolia-run)).

## Use cases

**Paying judges per ballot.** A network settles disputes with a council of judges deciding
under ERC-8436: an ERC-8471 dispute, whose judged questions the 8471-8436 bridge files as
council issues, or an ERC-8414 task judged through the 8436-8414 adapter. A program pays
each judge a fixed amount for each ballot cast on a final decision, whichever side it took,
so that a judge gains nothing by siding with the majority. `BallotMeter` checks each ballot
against the council's registry and counts it once, only for issues of one council filed by
one contract (the bridge or the adapter). Ballots of appeal rounds count too. The Sepolia
pilot runs the task case; the integration tests run both.

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

**Spending decided by a council.** `CouncilGovernor` is the governor of the treasury and
the tax schedule. A listed proposer files one action, such as opening a program or
proposing a rate, with its arguments; the council votes on exactly that action, as an
ERC-8436 issue; anyone then executes a Yes, within a fixed window. The governor builds each
call from the filed action and never takes a target or call data from a caller. The council
can also add or remove proposers the same way.

**Spending rules that hold whoever decides.** Whoever holds the governor role (a council
through `CouncilGovernor`, or a single account as in the pilot), money leaves the treasury
only through announced, funded and capped commitments, a rate never passes the ceiling, and
the notice periods give others time to object. What these rules do not stop is set out in
SPEC.md, under Security Considerations.

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
| `src/CouncilGovernor.sol` | The treasury's and schedule's governor, acting only on final decisions of one ERC-8436 council |
| `src/interfaces/ICollectiveDecisions.sol` | The ERC-8436 registry calls the governor makes: file, read, log enactments |
| `test/` | Foundry unit, fuzz and invariant tests: every requirement of the specification, the worked examples, odd tokens, recipients that refuse payment, re-entry, two assets, and end-to-end runs in which a settlement deduction policy collects the tax and a program pays a judge per case |
| `integration/` | Tests against the real contracts: ERC-8414 with the deduction hook, ERC-8436, the 8436-8414 adapter, ERC-8471 and its 8436 bridge |
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

`integration/` runs these contracts with the real ones, pinned as submodules under `lib/`:

- `JudgedTenders.t.sol`: ERC-8414 tasks on the kernel with the settlement-deduction hook
  (`unicore-gpu/task-token-standard`, branch `settlement-deductions`) pay tax into the
  treasury, and an ERC-8436 judges' council (`garyyang-finchip/acd-framework`) decides judged
  tasks through the reference 8436-8414 adapter; the ballot meter pays each judge per ballot.
- `JudgedDisputes.t.sol`: the ERC-8471 reference fixture (`garyyang-finchip/ai-dispute-resolution`)
  runs a dispute over a service call to a ruling and a refund; its judged question is
  decided by a jurors' council through the 8471-8436 bridge, and the meter pays the jurors
  per ballot, appeal rounds included.
- `CouncilGovernance.t.sol`: an ERC-8436 council governs the treasury and the tax schedule
  through `CouncilGovernor`: programs, grants, rates and proposers; rejections, NoDecision,
  lapsed approvals, failed actions retried, and calls starved of gas.

```sh
FOUNDRY_PROFILE=integration forge test
```

The profile compiles everything with via-IR and optimizer runs 1, as the 8414 and 8436
repositories do, and raises the contract size limit for the test EVM only. The suites pass
under the current gas schedule and under EIP-8037 (`--hardfork amsterdam`).

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

Gas price: pin both fees, for example `--with-gas-price 10000 --priority-gas-price 100` (in
wei). In the second pilot, forge priced the first six deployments at 1 gwei while the
network asked for about 70 wei; at 1 gwei the deployments under EIP-8037 cost about 0.2 ETH.

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

### Second pilot: a council governs, the jurors of a dispute are paid

`script/Pilot2.s.sol` runs four steps, separated by the two notice periods and the dispute's
review window (10 minutes each):

- `deploy`: a treasury and a tax schedule governed by a stewards' council (3 of 5 signed
  ballots) through `CouncilGovernor`; an ERC-8414 kernel with the deduction hook; an ERC-8471
  dispute registry with its 8436 bridge and the reference service escrow; a ballot meter for
  a jurors' council (2 of 3 signed ballots). Both councils are registered on the ERC-8436
  registry of the first pilot. The stewards decide the first action: a 1% tax rate.
- `fund`: two tasks pay tax; the stewards decide the second action: a program that pays the
  jurors 2 tUSD per ballot.
- `dispute`: the client pays for a service call; the provider delivers and charges; the
  client disputes the delivery; two of three jurors find that it does not conform; the
  finding is imported and the dispute decided; the meter pays the two jurors.
- `close`: the ruling becomes final and the escrow refunds the charge.

```sh
export FOUNDRY_PROFILE=integration
forge script script/Pilot2.s.sol --sig "deploy()" --rpc-url $RPC --account <keystore> --broadcast --slow --skip-simulation --with-gas-price 10000 --priority-gas-price 100
# after the rate notice:      --sig "fund()"
# after the program notice:   --sig "dispute()"
# after the review window:    --sig "close()"
```

The stewards and the jurors only sign. The provider sends two transactions of its own and
receives 0.001 ETH for them; its key, like theirs, is derived from `JUDGE_SEED` and is for
the pilot only.

#### Second Sepolia run

Run on 2026-11-11 on Sepolia with the contracts of commit `c2abe8c`. Addresses are in
`deployments/pilot2-11155111.json`. All 58 transactions succeeded, using about 216 million
gas.

| Contract | Address |
|---|---|
| `CouncilGovernor` | [`0x92a5…603c`](https://sepolia.etherscan.io/address/0x92a506f37945E4682E1d63a33e3b68d1eca9603c) |
| `PublicTreasury` | [`0xba8F…adaf`](https://sepolia.etherscan.io/address/0xba8Fb1A5b1D8c1B502DE6cb6f7bD5319D289adaf) |
| `TaxSchedule` | [`0x87eF…b773`](https://sepolia.etherscan.io/address/0x87eFDb25066c268281896cCabE5213810bDfb773) |
| `DeductingTaskToken` (ERC-8414 with the settlement-deduction hook) | [`0xb606…1640`](https://sepolia.etherscan.io/address/0xb6067A826d26c81E21bD80e2cFaFcC443E081640) |
| `ADRFDisputeRegistry` (ERC-8471) | [`0x4684…bbEd`](https://sepolia.etherscan.io/address/0x4684E7Ce59196763311ba4C4e41b816F8A7ebbEd) |
| `ADRFACDFBridge` (8471-8436) | [`0x488E…503f`](https://sepolia.etherscan.io/address/0x488E16befd3D17B969df5BE78f2a8b644245503f) |
| `ADRFServiceEscrow` | [`0xad10…60Ef`](https://sepolia.etherscan.io/address/0xad10E8760dd8bdd59013fc05b7e56738066960Ef) |
| `BallotMeter` | [`0x39Cf…4f23`](https://sepolia.etherscan.io/address/0x39Cffe344a9819b2D021E9A1Ff67118F88364f23) |
| `TestUSD` | [`0xb0b7…03EF`](https://sepolia.etherscan.io/address/0xb0b742c8543A4342f1eC334dA60251497aEe03EF) |

Outcome: the stewards' council set the tax rate
([`execute`](https://sepolia.etherscan.io/tx/0x717ffc1409b8fefcb39751090f257c162fa59be7b467dd5af85a09d483456e11))
and, once two tasks of 5,000 tUSD had paid 100 in tax, opened the jurors' program
([`execute`](https://sepolia.etherscan.io/tx/0xb1283ed792f06b3dae40754e34eb217196344b95c21195bf4b0dcef1bcfb8152)).
Two jurors signed that the delivery did not conform
([ballots](https://sepolia.etherscan.io/tx/0x1944cd541e8cdc932682d060467a1996f5b4b662fbd2df5f48bc456854b36be4)),
the meter paid each of them 2 tUSD
([first report](https://sepolia.etherscan.io/tx/0x357601263d9cf61ad2c31403d0ddcf3667984d8f1d11dcdb25ed6eed8e579625)),
and the third juror, who did not vote, holds nothing. The treasury holds 96 and the program
has 26 of its 30 left. The dispute was sustained and the escrow refunded the 0.0001 ETH
charge ([`enact`](https://sepolia.etherscan.io/tx/0xd4d664e24639123446cbd246948b3c9ca339655ff07332b7bbfa92becd687d26)).

The deployment ran in two parts: forge stopped after six transactions priced at 1 gwei, when
the wallet could no longer cover the next deployment at that price, and `--resume` sent the
other nineteen with pinned fees.

## Status and warnings

This is draft code. Its interfaces may change, and so may the draft standards it builds
on. The code has not been audited; do not use it to hold real funds. The Sepolia pilot uses
a test token with no value.

## License

[Apache-2.0](LICENSE), except [SPEC.md](SPEC.md), which is
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) so that anyone can implement
it. The repositories under `lib/` keep their own licenses; see [NOTICE](NOTICE).
