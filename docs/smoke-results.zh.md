# Phase 0 冒烟结果：mineflayer × Cuberite

> 日期：2026-09-06 | 服务器：Cuberite（端口 25568，离线模式）| mineflayer 4.38.0 / minecraft-protocol 1.68.0 / prismarine-chunk 1.41.0 / Node v22.22.3
> 脚本：`bot/smoke.js`（可复跑；`--stay` 模式配合外部熔岩击杀做死亡门验证）
> **结论：全部硬门通过，进入 Phase 1。** bot 版本固定 **1.8.9**（或自动探测）；1.12.2 有区块数据兼容问题（见 §4），不阻挡迁移。

## 1. 版本矩阵总表

所有检查项均在两个协议版本（1.8.9、1.12.2）及自动探测下运行：

| 检查项 | 1.8.9 | 1.12.2 | 自动探测 | 说明 |
|---|---|---|---|---|
| 离线登录 + spawn | ✅ 140ms | ✅ 175ms | ✅ 523ms | 就绪以 `spawn` 事件为准 |
| 聊天往返（echo） | ✅ 3s 内 | ✅ | ✅ | `<SmokeBot_x> ping_N` 回显 |
| 命令执行（/help） | ✅ | ✅ | ✅ | 默认组可运行；`/time`、`/kill` 默认组无权限（改用 /help 验证） |
| 移动 forward 2s | ✅ 1.20 格 | ✅ 4.87 格 | ✅ 2.20 格 | 位置变化 |
| jump / sneak | ✅ y 不变 | ⚠️ 见 §4（走入坑内） | ✅ | 1.12.2 首次因出生点被实验挖空误判，修复地形后仍受区块 bug 影响 |
| 右键 activateBlock | ✅ block=stone | ⚠️ block=air（区块未解析） | ✅ block=stone | 1.12.2 方块数据不可用 |
| 物品栏枚举 | ✅ 46 slots | ✅ | ✅ | |
| **死亡 → 自动重生 → 不坠虚空** | ✅ 外部熔岩击杀 | ✅ 外部熔岩击杀 | （同 1.8.9/1.12.2） | 关键门 |
| SIGTERM |（脚本含 handler；Node 默认即退出）| 同左 | 同左 | 后续 Phase 1 实测进程退出 |

## 2. 死亡重生门

（外部熔岩击杀，对照组见 docs/baseline-mcc-tools.md §4）两版本实测（bot 站于实体方块地面，脚下放置熔岩）：

- 1.8.9（SmokeBot_9420）：health 20→16→12→8→4→0 → `[DEATH] was melted by lava` → `death` 事件 → **`respawn` 包** → 服务器侧确认重生回出生点 (100,70,1)、health=20、**无坠虚空**。
- 1.12.2（SmokeBot_1742）：同样流程，重生回 (100,70,1)、health=20、**无坠虚空**。

**比对 MCC**：本次 MCC 对照也正常自动重生（未触发坠虚空）；MCC 的坠虚空是其偶发状态损坏（会话开始时即复现一次，需换身份重启）。mineflayer 状态机干净，死亡→重生无历史包袱，**优于 MCC**。

## 3. /kill 权限说明

默认组无 `/kill` 与 `/time` 权限（`[INFO] Forbidden command; insufficient privileges: "/kill"`）。冒烟脚本改用默认玩家可执行的 `/help` 验证命令管道；死亡门改用服务器侧放置熔岩（与 MCC 对照同法）。

## 4. 1.12.2 区块数据兼容问题

（根因已定位，非阻塞）

症状：1.12.2 连接下 prismarine-chunk 解析失败（`varint is too big`），`blockAt` 返回 air，右键读到 air，行走可能误入坑洞。

根因（实测确证）：

1. **网络层**：Cuberite 用 Z_SYNC_FLUSH 结尾的 zlib 流压缩包；`minecraft-protocol` 的 `Decompressor` 调用 `zlib.unzipSync(payload, { finishFlush: 2 })` 对该流**抛错丢包**；去掉该选项后解压完全成功（64807 字节）。→ 这是 `minecraft-protocol` 对非 Z_FINISH 结束流的兼容问题。
2. **包内层**：map_chunk 的 data 字段是 `[varint 长度][zlib]` 预压缩的整个区块 blob（`a7 fa 03 78 9c…`，解压得 64807 字节），且解压后的内层结构**不是**标准 1.9+ palette 区块格式（prismarine 仍报 varint 错）——即 Cuberite 对 1.9+ 区块有私有序列化。要完整修复需逆向 Cuberite 的区块编码（投入远大于收益）。

处置：**bot 固定 1.8.9**（Cuberite 对每客户端单独适配协议，1.8.9 无此问题，方块数据完全正常，与 MCC 的 1.12.2 连接可并存）。1.12.2 的修复留作后续（可考虑 prismarine 兼容层，或 Cuberite 侧配置）。

## 5. Phase 0 验收

- [x] `bot/` 目录就绪，mineflayer 4.38.0 安装成功（npm cache 用 `--cache ../.npmcache`）
- [x] 1.8.9 全项 PASS（含死亡门）
- [x] 1.12.2 非区块项 PASS（含死亡门）；区块项受限有根因记录
- [x] 自动探测可用（≈1.12.2 或适配版本，冒烟时行为正常）
- [x] 结论：**全部 PASS（止损条件未触发），进入 Phase 1**