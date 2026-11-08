# BBA TEST 挖矿合约（独立非代理版）

## 定位
- 单文件 Solidity `BBATestMining.sol`，Solidity ^0.8.20，供 Remix 部署测试。
- 无代理、无升级入口；未审计，也未在真实 QKI DEX 上实测。
- 部署合约时铸造 1,000,000 TEST 到部署者钱包（遵照图片里的初始发行量）。无硬性总量上限，挖矿领取会增发 TEST，燃烧则销毁 TEST。

## 主要机制
- `burn(amount)`：销毁 TEST，获得 3 倍算力。首次燃烧启动七天领取计时。
- `mint()`：每满 7 天领取一次，最多累计 5 周；超过 5 周未领的时间不会延续。算力不因领取而减少。
- 6 档每周收益率按图：0.45%、0.50%、0.55%、0.60%、0.65%、0.70%；对应档位起点为 0、5000、50000、100000、200000、400000 算力。
- 一级邀请奖励按档位 3%-8%、二级 0.5%-5%，计入邀请人的算力，**不是额外发放代币**；邀请关系只能在首次获取算力前绑定。
- 普通 ERC-20 转账税默认 3%，由管理员在 0%-5% 范围配置。这是单独设定的测试参数，不是图片所示 35%-10% 的“算力提到钱包手续费”。后者此版本只在 `tierInfo()` 展示，**未实现提现算力**。
- 所有转账税累积在合约自身的 TEST 余额中。合约余额达到 1,000 TEST 后，**下一次成功 mint** 尝试自动卖出 **恰好 1,000 TEST** 为 USDT；USDT 在路由中直接转给 DAO 地址；多余 TEST 留待下一次 mint。
- 自动卖出可经 TEST→USDT 或 TEST→WQKI→USDT，路由必须支持 `swapExactTokensForTokensSupportingFeeOnTransferTokens`。
- 根据路由报价计算滑点下限（默认 3%，最多 10%），并可设置 USDT 绝对最低额。若路由报价或交换失败，会发出 `FeesSwapSkipped` 事件，不回滚用户的 mint。
- 没有可用流动池/流动性时不卖出；需先建池提供流动性。

## Remix 部署参数
按顺序传入：
1. `dao_` — DAO 收 USDT 地址。
2. `router_` — 真实、可信的 Uniswap V2 风格路由地址，需核实方法和链 ID。
3. `usdt_` — USDT ERC-20 地址。
4. `intermediate_` — WQKI 地址（如使用两跳路由），直接 TEST/USDT 用零地址。

QKI 链参考（**部署前必须再次在链上核实**）：
- chainId: `20181205`
- Router: `0x3c91FD5247B050A1536F24D012a17a618EEFbfCA`
- USDT: `0xDF0e293CC3c7bA051763FF6b026DA0853D446E38`
- WQKI: `0x835F6dF988B6f51c9477D49e96aDBbc644ba97a2`

## 操作顺序
1. 部署，确认部署者获得 1,000,000 TEST。
2. 根据测试需要添加 TEST/USDT 或 TEST/WQKI 和 WQKI/USDT 流动性；测试前可调用 `setSwapConfig(slippageBps, minimumUSDTOut, false)` 禁用自动交换。
3. 将一部分 TEST 转给用户钱包；管理员默认免转账税，普通用户之间转账会按当前税率收费。
4. 参与者可用 `bindReferrer(parent)` 绑定上级，然后 `burn(amount)`，7 天后 `pendingReward(account)` 检查领取额度，调用 `mint()`。
5. 当 `accumulatedFees()` >= 1000 TEST 后，下一次成功 `mint()` 触发卖出。查看 `FeesSold` 或 `FeesSwapSkipped` 事件和 DAO 的 USDT 余额。

## 上线之前必须解决的风险
- **未编译/未部署/未审计**。需用 Remix 编译器 0.8.20 或更高版本验证编译，跑测试链、主网小金额测试和独立安全审查。
- 目前使用 DEX 即时报价 + 滑点防护，无法消除夹子交易/价格操纵和超低流动性风险。建议设置合适的 `minimumUsdtOut`，并限制交易金额。
- 自动交换由用户 `mint()` 触发，失败不妨碍领取；没有 mint 就不会自动交换。合约不会自动产生 USDT 或保证成交。
- 图中“锁仓 3 年、算力抵押、算力提到钱包手续费、手续费分配（拉新、LP、级别、社区）”均未实现，避免在具体规则不清楚时擅自设定真实资金流。
- 转账税会影响 DEX LP 交易。需验证路由、转账税、pair 路径、矿工交易费用的实际兼容性。
- 管理员可改 DAO、转账税、滑点和路由中间币；生产版建议多签和 timelock。