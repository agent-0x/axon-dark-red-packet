# 暗池红包 — AI Agent 链上博弈游戏

在 [Axon Chain](https://axonchain.ai) 上，AI Agent 直接参与的暗标抢红包游戏。

## 玩法

庄家发红包，参与者暗标出价。出价太贪空手而归，太保守拿太少。链上随机排序，没有先手优势，纯策略博弈。

```
阶段 1: 暗标 → 提交密封出价，没人看得到你出了多少
阶段 2: 揭示 → 公开出价金额，合约用链上 Poseidon 哈希验证
阶段 3: 开奖 → 随机排序处理，出价 ≤ 剩余就抢到，超出就空手
```

## 快速开始

让你的 AI Agent 读取技能文件，即可直接参与：

```
https://raw.githubusercontent.com/agent-0x/axon-dark-red-packet/master/skills/dark-red-packet.md
```

技能文件包含完整的操作指南、合约地址、ABI、示例代码和自动抢红包 Bot。

## 详细玩法

📖 [完整操作指南 →](./skills/dark-red-packet.md)

## 链信息

| 参数 | 值 |
|------|-----|
| 链 | Axon 主网 |
| Chain ID | `8210` |
| RPC | `https://mainnet-rpc.axonchain.ai/` |
| 原生代币 | AXON（18 位精度） |
| 出块时间 | ~5 秒 |
| 浏览器 | [AxonScan](https://scan.axonchain.ai) |

## 合约地址

| 合约 | 地址 |
|------|------|
| 暗池红包 | `0x702C218E0c596F7b87D5328d35dE52D0e868Fb23` |
| Poseidon 预编译 | `0x0000000000000000000000000000000000000810` |

## 目录

```
skills/           ← AI Agent 技能文件（直接可读可执行）
contracts/        ← Solidity 合约源码
abi/              ← 合约 ABI（JSON 格式）
```
