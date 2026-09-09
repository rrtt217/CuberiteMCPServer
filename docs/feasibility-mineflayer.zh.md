# 用 mineflayer 替代 MCC 集成的可行性研究

- 分支：`research/mineflayer-feasibility`
- 日期：2026-08-30
- 调研对象：[PrismarineJS/mineflayer](https://github.com/PrismarineJS/mineflayer)
- 现任方案：[Minecraft Console Client (MCC)](https://github.com/MCCTeam/Minecraft-Console-Client)
- **结论：可行且推荐迁移**。mineflayer 能直接消除 MCC 的三大结构性痛点（信号处理、死亡状态损坏、配置臃肿），协议层对本场景（1.8–1.12.2 + 离线模式）无障碍；需先做 Cuberite 冒烟实测（官方从未验证过 Cuberite），现成 MCP 包装均不适配，需自写一层（约 1–2 天工作量）。

---

## 1. 背景与现状

### 1.1 当前 MCC 集成的三层管线（事实清单）

对本仓库与 DSH preset 的实地检查确认，"MCC 集成"并不是一处代码，而是分布在三层的管线：

| 层 | 归属 | 现状 |
|---|---|---|
| 进程生命周期 | **MCPServer 插件**（本仓库 Lua） | `mcc.lua`：`StartMCC/StopMCC/RestartMCC/GetMCCStatus`——io.popen 拉起子进程、fd 关闭 wrapper、pid 跟踪（`/proc/<pid>/cmdline` 防误杀）、信号梯（SIGTERM→SIGHUP→SIGUSR1→SIGKILL）、临时 ini 生成。`main.lua`：autostart（延迟 60 tick）与 `OnDisable` 清理。`tools.lua`：`mcc_start/stop/restart/status` 作为插件自己的 MCP 工具（:8765）。`Info.lua`：`mcc` 控制台命令。 |
| bot 能力 + MCP 端点 | **MCC 本体**（85MB 单体二进制） | 实现游戏客户端并内嵌 MCP 服务器（`http://127.0.0.1:33333/mcp`），由 `mcc.lua` 写入的临时 ini 启用（`[ChatBot.McpServer]`）。插件 Lua 中**没有任何 bot 能力实现，也没有 MCP 转发**——插件只是进程保姆 + 配置生成器。 |
| 会话桥（消费者） | **DSH cuberite preset**（`~/.dsh/.agent-presets/cuberite/`） | `mcp-mcc.mjs`（自愈型 MCP 客户端）：连 `:33333/mcp`，调 `tools/list` 自动发现工具并注册为会话的 `mcp__mcc__*`。它是**通用契约**——只认标准 MCP Streamable HTTP 端点，不知道对面是 MCC 还是别的。`mcp-cuberite` 桥连插件的 :8765。 |

另有本仓库的周边配套：`void_guard.lua`（坠虚空守卫，HOOK_PLAYER_MOVING 冻结救援）、`config.lua` 的 `[MCC]` 段（Enabled/AutoStart/Path/Username/RandomUsername/ServerPort/MinecraftVersion/McpPort）。

### 1.2 MCC 痛点（迁移动机）

1. **信号处理**：MCC 忽略 SIGTERM/SIGINT/SIGQUIT，需要四级信号梯升级到 SIGKILL 才能可靠停止（`mcc.lua` `g_StopLadder`）。
2. **死亡状态损坏**：bot 死亡后客户端状态损坏，触发坠虚空无法重生的卡死（无视落地），只能换随机用户名重启**整个进程**换新身份（`RandomUsername` + `void_guard.lua` 都是对症药）。
3. **MCP 会话失效**：MCC 重启使旧 MCP 会话失效，报 -32001 直到重连——preset 桥被迫写成自愈型（`mcp-mcc.mjs` 检测该错误自动 re-initialize 重试）。
4. **配置臃肿**：临时 ini + 用户主 ini 双轨（`mcc_temp.ini` 47KB），版本指定、BotOwners、TerrainAndMovements 等开关散落。
5. **黑盒形态**：85MB 单体二进制，行为不可定制、问题不可在进程内修复，一切 workaround 都在进程外。

## 2. 本机环境核对（2026-08-30 实测）

| 项 | 现状 | 对迁移的意义 |
|---|---|---|
| Node.js | v22.22.3（nvm） | 满足 mineflayer 4.38.0 的 `engines: node>=22` ✅ |
| npm | 10.9.8 可用；沙箱（workspace-write）拒绝写 `~/.npm` 缓存 | 开发/安装时用 `--cache <workspace>/` 绕过即可，与运行时无关 ✅ |
| mineflayer npm | latest 4.38.0（2026-08-27 发布，time.modified 2026-08-27） | 包存在且活跃 ✅ |
| Cuberite 服务端 | 端口 25568（`settings.ini`）；版本由服务端解析（当前配置写 1.12.2） | mineflayer 原生支持 1.8–1.12.2 ✅，最终以实测为准 |
| MCC 本体 | `/home/david/Cuberite/MinecraftConsoleClient`，85MB | 保留作回退（见 §6） |
| 插件配置 | `config.ini`：MCC Enabled=true, AutoStart=false, RandomUsername=true | 迁移开关将沿用此文件模式 |

## 3. 调研发现（摘要）

> 完整调研含全部来源链接，由联网调研完成；此处按结论压缩，关键来源内联。

### 3.1 维护状态与版本支持 ✅

mineflayer 活跃维护：4.38.0（2026-08-27 发布），7387 stars，npm 月下载约 22.5 万，2026 年发版节奏稳定。README 明确支持 **Minecraft 1.8 到 1.21.11+**——1.8–1.12.2 老版本是其支持最久的路径。`version` 选项可不填（自动探测服务器版本）或显式指定。离线模式登录：`auth: 'offline'` + `username`，无需密码。来源：[repo](https://github.com/PrismarineJS/mineflayer)、[npm registry](https://registry.npmjs.org/mineflayer/latest)。

### 3.2 核心能力覆盖本场景全部需求 ✅

依据官方 [docs/api.md](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md)：

| 本场景需求 | mineflayer API |
|---|---|
| 聊天与命令 | `bot.chat()`（聊天与 `/` 命令同一入口）、`bot.tabComplete()`、chat 事件 |
| 移动 | `bot.setControlState()`（forward/back/left/right/jump/sprint/sneak）+ 官方插件 [mineflayer-pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder) |
| 视角 | `bot.lookAt(point)` / `bot.look` / `bot.blockAtCursor` |
| 右键交互 | `bot.activateBlock()`（开门/容器）、`bot.useOn(entity)`、`bot.placeBlock`、`bot.attack` |
| 物品栏读写 | `bot.inventory`（Window）、`bot.heldItem`、`bot.equip/transfer/moveSlotItem`、`bot.openChest` |
| 实体/方块查询 | `bot.entity`、`bot.entities`（id→entity map）、`bot.blockAt`、`bot.findBlocks`、`bot.canSeeBlock` |
| 受伤/死亡/重生 | `'health'`/`'death'` 事件；**默认自动重生**（createBot 选项 `respawn` 默认 true），可手动 `bot.respawn()`；`bot.quit(reason)` 优雅断开 |

唯一风险点：[issue #3882](https://github.com/PrismarineJS/mineflayer/issues/3882) "Bot freezes after taking any damage"（open，仅 1.21.x + 4.37.0 报告）——与 MCC 的"受伤后状态损坏"同类，但 **1.8–1.12.2 老版本无此报告**。

### 3.3 现成 MCP 包装均不适配，需自写 ✅

- 最热门 [yuniko-software/minecraft-mcp-server](https://github.com/yuniko-software/minecraft-mcp-server)（712 stars）：锁定 1.21.11 且走 stdio → 老版本 + HTTP 场景不可用
- [gerred/mcpmc](https://github.com/gerred/mcpmc)：2024-12 停更约 2 年，stdio，月下载 55
- 其余（minecraft-bot-mcp、mcpflow 等）：月下载 <60 或自称 early prototype

自写工作量：mineflayer API 与需求逐项一一对应，`node:http` 包一层 JSON-RPC、暴露约 15–20 个工具，约 **300–600 行、1–2 个工作日**；改用 `@modelcontextprotocol/sdk` 的 Streamable HTTP 再加约 0.5–1 天。"换身份重连"可做成轻量 API（关旧 bot → createBot 新实例），比 MCC 整进程重启干净得多。

### 3.4 进程管理正中痛点 ✅

mineflayer 是库，信号行为由 Node 运行时决定：Node 官方文档明确非 Windows 平台 **SIGTERM/SIGINT 有默认 handler，收到即退出**——直接消除 MCC 忽略 SIGTERM 需要信号梯升级到 SIGKILL 的问题；如需优雅退出，脚本内装 listener 先 `bot.quit()` 再 `process.exit()`。单 bot 常驻轻量（30+ bot 才明显吃 CPU，调低 view distance 可缓解）。启动就绪以 `'spawn'` 事件为标志，本地 Cuberite 预计 1–5 秒量级（需实测，主要受 connection throttle 影响）。来源：[Node process docs](https://nodejs.org/api/process.html#signal-events)。

### 3.5 Cuberite 兼容性：无已知 bug，但官方从未测过 ⚠️

mineflayer 仓库搜 "Cuberite" 仅 1 条命中——[PR #463](https://github.com/PrismarineJS/mineflayer/pull/463)（2016 年，mineflayer 1.x 时代旧报告）；[node-minecraft-protocol#348](https://github.com/PrismarineJS/node-minecraft-protocol/issues/348) 把 Cuberite 列入"对第三方服务端做自动化测试"清单且**至今未打勾**。即：无已知 bug，也无保证。Cuberite 对 1.8.x–1.12.2 的协议实现较完整，风险可控，但**必须先冒烟实测**（见 §5 Phase 0）。

### 3.6 定位对比 ✅

mineflayer 自述 "Create Minecraft bots with a powerful, stable, and high level JavaScript API"——事件驱动的**库**（配套 pathfinder/statemachine/prismarine-viewer 生态，MCP 包装全部基于它即是佐证）；MCC 自述 "Lightweight console for Minecraft chat and automated scripts"——现成**控制台应用**（自动化走 C# ChatBot 插件/自带脚本语法）。对本场景（无头 bot + AI 代理 + 进程级可控 + 需暴露 MCP 接口），库形态明显更贴合；MCC 的痛点恰恰源于现成应用的黑盒性。

## 4. 架构分层决策：集成放在哪一层

前文已确认现状是三段式管线。**推荐替代后保持同一分层**，替换只发生在"bot 本体"层：

| 层 | 归属 | 替代后变化 |
|---|---|---|
| bot 本体 + MCP 端点 | **本仓库**（新增 `bot/` Node 程序） | 取代 MCC 本体：mineflayer bot 自带 MCP HTTP 端点 |
| 进程生命周期 | **MCPServer 插件**（保留） | 启动命令从 `'"MinecraftConsoleClient" tmpIni'` 改为 `node bot/index.js …`；临时 ini 生成改为 bot 配置文件；信号梯可简化 |
| 会话桥 | **preset**（不动） | `mcp-mcc.mjs` 只认标准 MCP 端点——bot 保持 33333 端口则**零改动**，否则改一行 URL |

**决策依据**：

- **bot 代码必须在本仓库**：(a) bot 进程是跟着服务器走的全局资源，生命周期必须由服务器侧管理——换会话/换 preset 挂载时 bot 不能无人管，现状 `mcc_start` 走插件 MCP 工具正是这个道理；(b) `~/.dsh/` 不在仓库版本控制内，bot 逻辑是项目功能必须版本化；(c) 改 preset 影响所有挂载该 preset 的会话。
- **生命周期管理留在插件层**：bot 与 Cuberite 同生命周期（插件 `OnDisable` 停 bot、autostart 跟服务器启动）是插件层的自然职责；`mcc.lua` 已有成熟的 pid 跟踪、fd 关闭 wrapper（防孤儿进程占端口）——直接复用，仅信号梯因 Node 默认行为可大幅简化。
- **preset 桥不动**：`mcp-mcc.mjs` 的自愈逻辑（-32001 自动 re-initialize）可保留作保险；若 mineflayer 会话干净（无换身份重生），该路径基本不触发。

## 5. 迁移方案草案

- **Phase 0 — 冒烟验证（先行，~100 行）**：独立脚本连 `127.0.0.1:25568`，验证 1.8.9 / 1.12.2 的：离线登录（`auth:'offline'`）、`spawn` 就绪、聊天往返（chat + 监听）、`setControlState` 移动 + 位置回报、`activateBlock` 右键、受伤 → `'death'` → 自动重生（重点验证**不触发坠虚空**）、SIGTERM 默认行为。任一步失败即止损，MCC 继续服役。
- **Phase 1 — bot 程序 + MCP 端点（1–2 天）**：`bot/index.js`（mineflayer 连接与生命周期）+ `bot/mcp.js`（HTTP JSON-RPC，约 15–20 个工具：chat/command/move/look/interact/inventory/entities/health/respawn/rebuild…）。工具命名与语义对齐 MCC 端点，`mcp__mcc__*` 下游工具面无感切换。端口沿用 33333。附带 `rebuild` API（关旧 bot → 新实例，替代"换身份重启整进程"）。
- **Phase 2 — 插件侧改造**：`mcc.lua` → `bot.lua`（启动命令、临时配置改写、信号梯简化为 SIGTERM + 兜底 SIGKILL）；`config.lua` `[MCC]` 段 → `[Bot]` 段（新增 `Engine = mcc | mineflayer` 开关，默认保留 mcc 直到冒烟通过）；`tools.lua`/`Info.lua` 描述更新；`void_guard.lua` 保留观察（若 mineflayer 不触发坠虚空则默认关闭）。
- **Phase 3 — 收尾**：preset 桥确认零改动（或改一行端口）；文档更新；`config.ini` 切 `Engine=mineflayer` 观察；MCC 保留作回退开关。

## 6. 风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| Cuberite 从未被 mineflayer 官方测试（nmp#348 未打勾） | 中 | Phase 0 冒烟先行；任一步失败即止损，MCC 无损回退（`Engine` 开关） |
| issue #3882 受伤后冻结 | 低 | 仅 1.21.x 报告，本场景 1.8–1.12.2；Phase 0 专项验证死亡重生路径；`void_guard.lua` 兜底 |
| mineflayer 4.38.0 要求 Node ≥ 22 | 低 | 本机 v22.22.3 已满足；文档记录前置条件 |
| 部署依赖 node_modules | 低 | `bot/` 自带 `package.json` + 提交或安装说明；插件启动命令做依赖存在性检查 |
| MCP 会话失效（重启 bot 时） | 低 | 端口不变 + preset 自愈桥兜底；bot 重启时保持端点可用 |
| 临时收益：`mcp-mcc.mjs` 自愈逻辑闲置 | — | 保留作保险，无维护成本 |

## 7. 结论

1. **协议层无障碍**：mineflayer 原生覆盖 1.8–1.12.2 与离线登录，能力清单完整覆盖本场景全部需求，且均为一等 API。
2. **痛点全数命中**：Node 默认信号行为、干净的死亡/重生状态机、库形态的进程内可控性，直接消除 MCC 的信号梯、坠虚空换身份重启、会话自愈、配置臃肿四大 workaround。
3. **成本可控**：自写 MCP 层约 1–2 天；插件/preset 改动面小（保持三层分层，preset 零改动）。
4. **风险有界**：唯一实质未知是 Cuberite 兼容性（官方未测），冒烟脚本先行 + `Engine` 开关回退，失败成本趋近于零。

**建议**：按 §5 推进，Phase 0 冒烟验证作为第一步；保留 MCC 作回退。
