# Agent Public Finance（智能体公共财政）

[English](README.md) | **简体中文**

为智能体（agent）在链上接单干活的网络提供公共财政。每个结算的任务交一小笔税，用来支付维持网络运转的工作，比如裁决纠纷。这笔钱怎么花，由合约来限制，而不是靠承诺。

```
任务付款 ──税──▶ 公共金库 ──┬─ 拨款：每期固定金额，期限固定
                            └─ 项目：按工作量计价，由计量器上报
```

这是一个应用，不是标准。它建立在四个标准草案之上：

- [ERC-8492](https://github.com/ethereum/ERCs/pull/2157)，Settlement Deductions for Task Escrows（任务托管的结算扣款）：从每笔付款中扣下税款，交给金库；
- ERC-8414，Token-Bound Task Tenders（代币绑定的任务招标）：任务托管合约；
- ERC-8436，Agent Collective Decision Framework（智能体集体决策框架）：负责裁决的委员会和负责治理的委员会都用它投票；
- ERC-8471，AI Dispute Resolution Framework（AI 纠纷解决框架）：纠纷的法官由财付酬。

它包含四个合约：

- **税率表**：每种资产一个税率，在任务创建时读取。税率只有在公示期过后才会变更，而且不会超过部署时固定的上限；
- **公共金库**：除了两种承诺之外，没有任何办法把钱转出去。一种是**拨款**，用于长期工作；一种是**项目**，用于按件计酬的工作。每项承诺都要先公示，钱才能开始流出；做出承诺时就要足额拨备，每个收款人有上限；承诺可以终止，但已经挣到的钱不会被收回；
- **计票器**：告诉项目，每位法官在某个委员会的最终裁决中投了多少票；
- **委员会治理合约**：让一个 ERC-8436 委员会来管理金库和税率表。委员会对一个写得清清楚楚的操作投票，通过了就执行这个操作，别的什么也不做。

这些合约遵循的规则写在 [SPEC.md](SPEC.md) 里（英文）。整个流程已经在 Sepolia 测试网上跑通，见 [Sepolia 运行结果](#sepolia-运行结果)。

## 应用场景

**按票给法官付酬。** 网络用法官委员会来解决纠纷，委员会按 ERC-8436 投票裁决。纠纷可以是 ERC-8471 的纠纷（其中需要评判的问题由 8471-8436 桥接合约提交给委员会），也可以是通过 8436-8414 适配器评判的 ERC-8414 任务。项目为每位法官在最终裁决中投下的每一票支付固定金额，无论投的是哪一边，所以法官跟着多数投票得不到任何好处。`BallotMeter` 会到委员会的注册合约核对每一张票，每张票只计一次，而且只统计某一个委员会、由某一个合约（桥接合约或适配器）提交的议题。上诉轮次的选票也计入。Sepolia 试点跑的是任务场景，集成测试两种都跑了。

**长期工作。** 没法按件计数的工作，比如维护共享合约、运行索引服务或监控服务，用拨款支付：每期固定金额，期限固定。终止拨款会停止后续各期，已经挣到的各期照样可以领取。

**其他按件计酬的工作。** 凡是合约能计数的工作，都可以通过项目按件支付，每个项目配一个自己的计量器。比如核验者每核验一个任务结果，就领一份报酬。每种工作需要单独写一个计量器，目前只有 `BallotMeter`。金库信任计量器报上来的数字，所以计量器只能统计它在链上能核实的东西。

**智能体能提前算进成本的税。** 任务创建时生效的税率，就是这个任务适用的税率。新税率要过了公示期才生效，而且不会超过上限，所以智能体接活之前就知道要交多少税。

**由委员会决定怎么花钱。** `CouncilGovernor` 是金库和税率表的治理者。名单上的提案人提交一个操作，比如开设一个项目或提议一个税率，连同具体参数；委员会以 ERC-8436 议题的形式，就这个操作本身投票；通过之后，任何人都可以在固定的期限内执行。治理合约根据提交的操作自己构造调用，从不接受调用者给的目标地址或调用数据。委员会也可以用同样的方式增加或移除提案人。

**无论谁掌权，花钱规则都不变。** 无论治理者是谁（通过 `CouncilGovernor` 的委员会，或者像试点里那样的单个账户），钱只能通过事先公示、足额拨备、有上限的承诺流出金库，税率不会超过上限，公示期也给了其他人提出反对的时间。这些规则管不到哪些情况，写在 SPEC.md 的 Security Considerations 一节。

## 目录

| 路径 | 内容 |
|---|---|
| `SPEC.md` | 税率表和金库遵循的规则 |
| `src/interfaces/IPublicTaxSchedule.sol` | 税率表接口（扩展 `ITaxSchedule`） |
| `src/interfaces/IPublicTreasury.sol` | 金库接口 |
| `src/TaxSchedule.sol` | 税率表参考实现：按资产设税率，有公示期和上限 |
| `src/PublicTreasury.sol` | 金库参考实现：拨款、项目、公示期、足额拨备、收款人上限 |
| `src/BallotMeter.sol` | 项目计量器：某个策略和调用方下的 ERC-8436 集体决策（比如一个法官委员会）一旦成为最终裁决，其中每张票计一个单位；任何人都可以上报，每张票只计一次 |
| `src/interfaces/ICollectiveDecisionReads.sol` | 计量器从 ERC-8436 注册合约读取的三个函数 |
| `src/CouncilGovernor.sol` | 金库和税率表的治理者，只按某个 ERC-8436 委员会的最终决定行事 |
| `src/interfaces/ICollectiveDecisions.sol` | 治理合约对 ERC-8436 注册合约的调用：提交议题、读取结果、记录执行情况 |
| `test/` | Foundry 单元测试、模糊测试和不变量测试：覆盖规范的每条要求、示例、非常规代币、拒收款项的收款人、重入、两种资产，以及端到端测试（由结算扣款策略收税，再由项目按案件给法官付酬） |
| `integration/` | 和真实合约一起跑的测试：带扣款钩子的 ERC-8414、ERC-8436、8436-8414 适配器、ERC-8471 及其 8436 桥接合约 |
| `script/` | 测试网试点脚本（`Pilot.s.sol`）和它用的测试币（`TestUSD.sol`） |
| `deployments/` | Sepolia 试点的合约地址 |

## 编译和测试

需要安装 [Foundry](https://book.getfoundry.sh/)。

```sh
git clone --recursive https://github.com/unicore-gpu/agent-public-finance
cd agent-public-finance
forge test
```

### 和真实合约集成

`integration/` 把本仓库的合约和真实合约放在一起跑，真实合约都作为固定版本的子模块放在 `lib/` 下：

- `JudgedTenders.t.sol`：ERC-8414 任务运行在带结算扣款钩子的内核上（`unicore-gpu/task-token-standard` 的 `settlement-deductions` 分支），结算时把税交进金库；ERC-8436 法官委员会（`garyyang-finchip/acd-framework`）通过 8436-8414 参考适配器裁决需要评判的任务；计票器按票给每位法官付酬。
- `JudgedDisputes.t.sol`：用 ERC-8471 的参考测试场景（`garyyang-finchip/ai-dispute-resolution`）把一起关于服务调用的纠纷一直跑到裁决和退款；其中需要评判的问题由陪审员委员会通过 8471-8436 桥接合约裁决，计票器按票给陪审员付酬，上诉轮次也算。
- `CouncilGovernance.t.sol`：一个 ERC-8436 委员会通过 `CouncilGovernor` 管理金库和税率表，包括项目、拨款、税率和提案人；也覆盖否决、无结论、批准过期、执行失败后重试，以及调用被故意限制 gas 的情况。

```sh
FOUNDRY_PROFILE=integration forge test
```

这个配置按 8414 和 8436 仓库的方式编译（via-IR，optimizer runs 为 1），并且只在测试用的 EVM 里放宽了合约大小上限。这些测试在现行 gas 规则和 EIP-8037 下（`--hardfork amsterdam`）都能通过。

### 测试网试点

`script/Pilot.s.sol` 在公共测试网上分三步跑同样的流程，两个公示期（默认各 10 分钟）把三步隔开：

1. `deploy`：部署全部合约，提出税率；
2. `fund`：两个任务交税，开设法官计酬项目；
3. `judge`：一个需要评判的任务，三位法官签名投票，计量器给他们付酬。

发交易的账户同时担任治理者、委托方和干活的人；法官只负责签名，不持有 ETH。报酬用的代币是 `TestUSD`，任何人都可以铸造，没有任何价值。

```sh
export FOUNDRY_PROFILE=integration
forge script script/Pilot.s.sol --sig "deploy()" --rpc-url $RPC --account <keystore> --broadcast --slow --skip-simulation
# 税率公示期过后：  --sig "fund()"
# 项目公示期过后：  --sig "judge()"
```

关于 gas 上限：部署之后的每一笔调用都带固定的 gas 上限，原因有两个。一是付款时必须给扣款策略留出它的全部预算，按实际用量估算出来的上限不够；二是公共 RPC 会把请求分到多个节点，某个节点可能还没看到上一笔交易所在的区块，按旧状态估算就会出错。部署交易的上限用 `--skip-simulation` 交给节点估算，因为在 EIP-8037 下，本地模拟可能少算新建存储的费用。三步合计，按现行 gas 规则约 2,400 万 gas，按 EIP-8037 约 1.49 亿 gas，大部分花在部署上。

#### Sepolia 运行结果

2026-11-11 在 Sepolia 上运行。Sepolia 已经按 EIP-8037 对存储计费。部署的是 commit `27d5a6e` 的合约，地址记录在 `deployments/pilot-11155111.json`。所有交易都成功，合计约 1.49 亿 gas。

| 合约 | 地址 |
|---|---|
| `DeductingTaskToken`（带结算扣款钩子的 ERC-8414） | [`0x9729…101B`](https://sepolia.etherscan.io/address/0x972912a584b39Add7A028375Ea81d58DD639101B) |
| `SettlementDeductionPolicy` | [`0x493B…36Cd`](https://sepolia.etherscan.io/address/0x493B8C0C986BC4Fd6A06cC3a97F48a6F577736Cd) |
| `TaxSchedule` | [`0x9441…a5D4`](https://sepolia.etherscan.io/address/0x9441bd4A5329AA92365B793F707626fCC7C7a5D4) |
| `PublicTreasury` | [`0xE7C9…1029`](https://sepolia.etherscan.io/address/0xE7C9842159a2cb17E92F7cA8a18D9c691A101029) |
| `ACDFRegistry`（ERC-8436） | [`0xf607…d659`](https://sepolia.etherscan.io/address/0xf60780Ae5C733476d918313eaF4E453125C4d659) |
| `ACDFTaskTenderAdapter` | [`0x1e23…6289`](https://sepolia.etherscan.io/address/0x1e2345B84ee61B88D07861b8eb9113e16E0B6289) |
| `BallotMeter` | [`0xdeF5…50cb`](https://sepolia.etherscan.io/address/0xdeF542059d26D2FFB9818F3fe027aFA881e850cb) |
| `TestUSD` | [`0xBFf6…1c11`](https://sepolia.etherscan.io/address/0xBFf6cBB7d0a0327A5b184E49944C87413c8d1c11) |

结果（单位 tUSD）：两个 5,000 的任务和一个 1,000 的评判任务各交 1% 的税，合计 110。委员会的三张票通过适配器执行生效（[`execute` 交易](https://sepolia.etherscan.io/tx/0xa77794af84e090d08cb33aec6ef634c2a8c34340be2afe24f109c9e705c86f12)），计量器对每张票只计一次，三位投票的法官各领到 2。金库余额 104，项目预算 30 还剩 24，两位没投票的法官什么也没拿到。

`fund` 的最后两笔调用（第二次领税和 `createProgram`）是用 `cast` 手动发的：脚本为领税估算 gas 时，请求落到了一个落后于链的节点上，结果回滚。现在每笔调用都带固定上限，避免了这个问题。

法官的私钥由一个公开的种子（`JUDGE_SEED`）生成，只用于这次试点。

## 状态和警告

这是草案阶段的代码。它的接口可能会变，它所依赖的标准草案也可能会变。代码没有经过审计，不要用它保管真实资金。Sepolia 试点用的是没有价值的测试币。

## 许可证

[Apache-2.0](LICENSE)。[SPEC.md](SPEC.md) 例外，采用 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)，以便任何人都能照着它实现。`lib/` 下的仓库保留各自的许可证，见 [NOTICE](NOTICE)。
