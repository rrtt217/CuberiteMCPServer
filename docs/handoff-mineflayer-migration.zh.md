# 交接文档：mineflayer 替代 MCC 迁移实施

> 交给下一个实际挂载 cuberite preset 的 session。本文档是**实施交接书**：读完即可开工，所有决策已定，所有事实已核。
> 配套阅读：`docs/feasibility-mineflayer.md`（可行性研究，含调研来源与风险矩阵）。
>
> - 日期：2026-08-30
> - 分支：`research/mineflayer-feasibility`（可行性报告已提交，commit `0c13a39`）
> - 状态：**研讨完成，实施未开始**
> - 结论：可行且推荐迁移；MCC 保留作回退，全程可用 `Engine` 开关切回

---

## 0. 快速上手检查单

按序执行，每步都有验收标志：

1. [ ] 读本文档 + `docs/feasibility-mineflayer.md`
2. [ ] 用 `git log --oneline -3` 确认在 `research/mineflayer-feasibility` 分支
3. [ ] 捕获 MCC 工具基线（§5，趁 MCC 还能跑先做）
4. [ ] Phase 0 冒烟脚本（§6）——**决定整个迁移成败的闸门**
5. [ ] Phase 1 bot 程序（§7）
6. [ ] Phase 2 插件改造（§8）
7. [ ] Phase 3 preset 验证与收尾（§9）

---

## 1. 背景一页纸

MCPServer 插件（本仓库）把 Cuberite 暴露为 MCP 服务器（:8765）。测试机器人目前用 **Minecraft Console Client (MCC)**：一个 85MB 的 C# 单体二进制，作为 bot 加入游戏，并内嵌一个 MCP 服务器（:33333/mcp）暴露 bot 能力。DSH cuberite preset 用 `mcp-mcc.mjs` 桥接该端点为会话工具 `mcp__mcc__*`。

MCC 的结构性痛点（迁移动机）：

1. 忽略 SIGTERM/SIGINT/SIGQUIT → 需要 `mcc.lua` 的四级信号梯（SIGTERM→SIGHUP→SIGUSR1→SIGKILL）
2. bot 死亡后客户端状态损坏 → 坠虚空无法重生（无视落地）→ 只能换随机用户名重启**整个进程**
3. MCC 重启使 MCP 会话失效（-32001）→ preset 桥被迫写成自愈型
4. 配置臃肿：临时 ini（47KB）+ 用户主 ini 双轨
5. 黑盒：85MB 二进制，问题不可在进程内修复

**mineflayer**（Node.js 库，4.38.0，支持 MC 1.8–1.26.1）可替代 MCC 本体：三大痛点全数消除（Node 默认对 SIGTERM 立即退出；死亡默认自动重生且状态干净；库形态一切可定制）。代价：现成 MCP 包装均不支持"老版本 + HTTP"，需自写一层（约 1–2 天）。

## 2. 当前三层集成图（谁在哪一层，替代后谁动谁不动）

```
┌─────────────────────────────────────────────────────────────────────┐
│ DSH cuberite preset (~/.dsh/.agent-presets/cuberite/)               │
│   mcp-cuberite 桥 → 插件 :8765        （不动）                       │
│   mcp-mcc 桥 (mcp-mcc.mjs) → bot :33333/mcp  （不动，零改动）        │
├─────────────────────────────────────────────────────────────────────┤
│ MCPServer 插件 (本仓库, Lua)                                        │
│   jsonrpc.lua / http.lua / tools.lua ：MCP 服务器本体 （不动）        │
│   mcc.lua / config.lua [MCC] / Info.lua mcc 命令                    │
│     → 进程生命周期管理        （改造 → bot.lua / [Bot] 段，§8）       │
│   void_guard.lua：坠虚空守卫   （保留观察，§8.4）                     │
├─────────────────────────────────────────────────────────────────────┤
│ bot 本体                                                            │
│   现状：MCC 二进制（/home/david/Cuberite/MinecraftConsoleClient）    │
│   目标：bot/ Node 程序（mineflayer + 自写 MCP 端点）  ← 新写，§7     │
└─────────────────────────────────────────────────────────────────────┘
```

**分层决策（已定，勿再议）**：bot 代码放**本仓库**（版本化 + 跟服务器同生命周期的资源必须由服务器侧管理）；进程生命周期留**插件层**（复用 mcc.lua 的 pid 跟踪与 fd wrapper）；preset 桥**不动**（bot 沿用 33333 端口则零改动）。

## 3. 本机环境事实（2026-08-30 核对）

| 项 | 值 | 备注 |
|---|---|---|
| Node.js | v22.22.3（nvm: `~/.nvm/versions/node/v22.22.3/bin/node`） | 满足 mineflayer 4.38.0 的 `engines: node>=22` |
| npm | 10.9.8 | **沙箱拒绝写 `~/.npm`**：安装时加 `--cache <工作区内路径>/.npmcache`（事后删掉，别提交） |
| Cuberite | `/home/david/Cuberite/Cuberite`，游戏端口 **25568** | 服务器只由 preset 的 `cuberite_start`/`cuberite_stop` 工具管理 |
| 插件游戏端口配置 | `config.ini [MCC] ServerPort=25568` | bot 连接参数沿用此值 |
| MCC 二进制 | `/home/david/Cuberite/MinecraftConsoleClient`（85MB） | 保留作回退，不删 |
| 插件当前配置 | `config.ini [MCC] Enabled=true, AutoStart=false, RandomUsername=true, Username=TestBot2, MinecraftVersion=1.12.2, McpPort=33333` | `AutoStart=false` 是人为关的（调试期），迁移时注意 |
| mineflayer | npm latest 4.38.0（2026-08-27 发布） | 依赖 `mineflayer-pathfinder`（可选，移动导航用） |
| luacheck | 在 `/home/david/Cuberite` 下运行 `luacheck Plugins/MCPServer/` | 站点级 .luacheckrc 已列全 Cuberite 全局量 |

## 4. 关键契约：bot 的 MCP 端点必须满足什么

唯一消费者是 preset 的 `mcp-mcc.mjs`（已通读源码）。硬性契约：

1. **URL**：`http://127.0.0.1:33333/mcp`（POST；路径必须精确匹配，否则改 preset 一行）
2. **传输**：HTTP POST + JSON-RPC 2.0。桥是 POST-only（不需要实现 GET/SSE 推送）
3. **握手**：桥按序发 `initialize` → `notifications/initialized` → `tools/list`。`initialize` 必须返回 `protocolVersion`（桥发 `'2025-06-18'`）与合法 result
4. **`tools/list` 必须返回至少 1 个工具**——`mcp-mcc.mjs` 源码：`if (tools.length === 0) throw new Error('MCC MCP tools/list returned nothing')`，空列表会让桥挂掉
5. **工具自动注册**：桥把 `tools/list` 结果的每个 `t.name` 注册为会话工具 `mcp__mcc__<name>`，`inputSchema` 一并透传。所以**工具名与 schema 就是兼容层**：沿用 MCC 的命名（§5 基线），下游无感切换
6. **会话头（可选）**：桥读 `initialize` 响应的 `mcp-session-id` 头，有就回传。**推荐设计：无状态端点，完全不发 session id、忽略任何收到的 `Mcp-Session-Id` 头**——这从根上消灭"重启使会话失效"问题（MCC 痛点 3 的成因是它跟踪会话并在重启时作废），自愈路径永不触发
7. **tools/call 结果形状**：`{ content: [{type:"text", text:"..."}], isError?: bool }`（MCP 标准）。错误走 JSON-RPC error（`-32001`/`-32603` 等）或 `isError:true`
8. **崩溃容忍**：端点崩溃/重启后，桥下一次调用若收到会话类错误会自动 re-initialize 重试一次；无状态设计下连这个都不需要

**协议版本注意**：插件自己的 `jsonrpc.lua` 也是 MCP 端点（:8765，同版本 2025-06-18），bot 端点的语义可直接**抄它的实现**——这是最好的参考实现（同为 Lua 之外唯一的自家 MCP 实现，且已在生产验证）。

## 5. 第一步：捕获 MCC 工具基线（趁 MCC 还能跑，先做）

MCC 目前可用。迁移开始前把它的对外面原样记录下来，作为 Phase 1 的兼容规格：

1. `cuberite_start`（等到日志出现 `[MCPServer] [MCP] Listening on port 8765`）
2. `mcp__cuberite__mcc_start`（random_name="force"）→ 等十几秒 `mcp__mcc__*` 自动出现
3. 记录 `mcp__mcc__*` 的**完整工具名清单**与每个工具的参数 schema（从会话工具目录直接读）
4. 逐类工具各取一次样本调用，记录返回 JSON 形状：SessionStatus / ChatAndCommands / Movement / Inventory / EntityWorld
5. 死亡基线：给 bot 服毒/摔落致死，观察重生行为与是否坠虚空（对照组数据）
6. 全部写入 `docs/baseline-mcc-tools.md` 并提交

Phase 1 的 bot 工具名、参数名、返回文本格式**以这份基线为准**（能对齐就对齐；新增能力如 `rebuild` 另加，不破坏对齐）。

## 6. Phase 0：冒烟验证（~100 行脚本，决定成败的闸门）

**目的**：官方从未测过 mineflayer × Cuberite（nmp#348 至今未打勾），先证明协议层通，再投入 1–2 天写完整 bot。

**做法**：

1. `mkdir -p bot && cd bot && npm init -y && npm install mineflayer --cache ../.npmcache && rm -rf ../.npmcache`
2. 写 `bot/smoke.js`（独立脚本，不接 MCP）：
   - `createBot({ host:'127.0.0.1', port:25568, username:'SmokeBot', auth:'offline', version:'1.12.2' })`
   - 就绪以 `'spawn'` 事件为标志，打印耗时
3. 依次验证并打印 PASS/FAIL：
   - [ ] 离线登录 + `spawn`
   - [ ] 聊天往返：`bot.chat('ping')` + 监听 `'message'` 收到回显
   - [ ] 命令执行：`bot.chat('/time set day')` 之类无副作用命令
   - [ ] 移动：`bot.setControlState('forward', true)` 2 秒后位置变化；跳/潜行
   - [ ] 右键：`bot.lookAt` + `bot.activateBlock(bot.blockAt(bot.entity.position.offset(0,-1,0)))`
   - [ ] 物品栏：`bot.inventory` 枚举 slot
   - [ ] **死亡重生（重点）**：`/kill` 或服毒 → `'death'` 事件 → 默认自动重生（`respawn` 选项默认 true）→ `'spawn'` 再次触发 → **位置正常、不坠虚空**（对照 MCC 基线）
   - [ ] SIGTERM：`process.on('SIGTERM', () => { bot.quit('sigterm'); })`，外部 kill 后进程在 1 秒内退出
4. **版本矩阵**：分别用 `version:'1.8.9'` 和 `version:'1.12.2'` 各跑一遍（不填 version 自动探测也试一次）
5. 结果记入 `docs/smoke-results.md`，**全部 PASS 才进 Phase 1**

**失败即止损**：任一步在两个版本上都失败 → 迁移终止，MCC 继续服役，在 `docs/smoke-results.md` 记录失败模式并提交。

**坑**：
- 同 IP 频繁重连可能撞 Cuberite 的连接节流——登录卡住先等 5–10 秒再试
- `kill` 命令需要 bot 有权限（离线模式默认 OP 与否看服务器 `settings.ini` 的 Groups）；无权限就改用摔落/岩浆
- 冒烟脚本是**普通 Node 程序**，用 bash 后台跑没问题（规则只限制服务器进程）；跑完记得 `job_kill`

## 7. Phase 1：bot 程序 + MCP 端点（1–2 天）

**文件布局**（全部在 `bot/`，Node 22，尽量零第三方依赖）：

```
bot/
  package.json          # name: mcpserver-bot, private, engines.node>=22
  index.js              # 入口：读配置 → createBot → 启动 MCP 端点 → 信号处理
  config.js             # 读 bot.ini / 环境变量（host/port/username/version/mcpPort）
  bot.js                # mineflayer 连接封装：spawn/death/health/kicked 事件、rebuild()
  actions/
    chat.js             # sendChat / sendCommand / 读聊天缓冲
    move.js             # setControlState / lookAt / （可选 pathfinder goto）
    interact.js         # activateBlock / useOn / attack / placeBlock
    inventory.js        # list / equip / transfer / heldItem
    world.js            # entities / blockAt / health / position / time
  mcp.js                # node:http JSON-RPC 端点（契约见 §4）
  tools.js              # 工具注册表：name + inputSchema + handler（对齐 §5 基线）
  README.md             # 运行方式、依赖、与 MCC 工具的差异表
```

**关键实现点**：

- **MCP 端点**（mcp.js）：`node:http` 起服务，POST `/mcp`，手写 JSON-RPC 分发（initialize/notifications/initialized/tools/list/tools/call/ping 五个方法足够）。**无状态**（§4 第 6 条）。响应头带 `Content-Length`、`Connection: close`、`MCP-Protocol-Version: 2025-06-18`（对齐插件 http.lua 的行为）。参考 `jsonrpc.lua` 的方法分发结构
- **工具面**：名字、参数、返回文本格式照抄 §5 基线；新增 `rebuild`（销毁旧 bot 实例 → `createBot` 新实例，替代 MCC 的"换身份重启整进程"；无状态端点下会话根本不断）
- **rebuild 语义**：保留 username（离线模式重连同名即同玩家实体）；若死亡后实体损坏（对照 §5 步骤 5），rebuild 时接受可选 `newUsername` 参数
- **信号**：`SIGTERM`/`SIGINT` → `bot.quit(reason)` → `process.exit(0)`。Node 默认已会退出，这里只为优雅断开（服务器看到正常下线而非超时）
- **日志**：stdout 重定向由插件侧负责（复用 mcc.lua 的 `mcc_output.log` 模式）；bot 自己往 stderr 打关键事件（spawn/death/error）
- **健壮性**：mineflayer `'error'`/`'kicked'` 事件里做有限次自动重连（指数退避，上限 5 次）；端点与 bot 生命周期解耦——bot 掉线时端点活着，工具返回 `isError:true` + 原因
- **依赖**：只装 `mineflayer`（+ 可选 `mineflayer-pathfinder`）。不要装 `@modelcontextprotocol/sdk`——唯一消费者是 POST-only 的自写桥，stdlib 够用且少一类供应链风险
- **`bot/` 里 `.npmcache`、`node_modules` 加进 `.gitignore`**（`node_modules` 是否提交由下一步会话按仓库现状定，默认不提交、README 写安装说明）

## 8. Phase 2：插件侧改造（Lua）

逐文件任务（完成后跑 `luacheck Plugins/MCPServer/`，在 `/home/david/Cuberite` 下）：

1. **`mcc.lua` → 复制为 `bot.lua`**（保留 mcc.lua 不删，回退开关要用）：
   - `BuildMCCCommand` → `BuildBotCommand`：命令从 `'"<MCC.Path>" "<tmpIni>"'` 改为 `'"<node 路径>" "<插件目录>/bot/index.js" --config <bot.ini>'`；删掉临时 ini 生成（bot 读自己的配置）
   - 信号梯 `g_StopLadder` 简化为两级：`{ "SIGTERM", "kill %d", 1.5 }, { "SIGKILL", "kill -9 %d", 1.0 }`（Node 默认响应 SIGTERM，1.5 秒预算已宽裕）
   - `IsMCCProcess` 的 cmdline 匹配改为匹配 `bot/index.js`（防 PID 复用误杀，逻辑不变）
   - fd 关闭 wrapper **原样保留**（防孤儿进程占端口的机制与客户端无关）
   - 对外全局函数名保持同型：`StartBot/StopBot/RestartBot/GetBotStatus/HandleConsoleBot`
2. **`config.lua`**：`[MCC]` 段旁新增 `[Bot]` 段（Enabled/AutoStart/NodePath/BotDir/Username/RandomUsername/ServerHost/ServerPort/MinecraftVersion/McpPort）；**新增顶层开关 `Engine = "mcc" | "mineflayer"`（默认 `"mcc"`，冒烟+联调通过后才切）**。`LoadMCPConfig` 照 `[MCC]` 的写法补 `GetValueSet*` 默认值写入
3. **`tools.lua`**：`mcc_status/start/stop/restart` 四个工具按 `Engine` 分派到对应实现（工具名对外不变，还是 `mcc_*`？——**否**：新增 `bot_start/stop/restart/status` 四个工具，`mcc_*` 保留但按 Engine 报告当前引擎；下游语义见 Info.lua 条）
4. **`main.lua`**：autostart 分支按 `Engine` 选择 `StartMCC()` 或 `StartBot()`；`OnDisable` 两者都停（幂等，本来就有 not running 短路）
5. **`Info.lua`**：ConsoleCommands 加 `bot <start|stop|restart|status>`（照 `mcc` 的写法，Handler 指向 `HandleConsoleBot`）
6. **`void_guard.lua`**：**保留，不动**。它保护所有玩家（含 bot），与客户端无关；mineflayer 若不触发坠虚空，守卫自然永不触发（零成本兜底）。观察一个迭代周期后再决定是否默认关闭

## 9. Phase 3：preset 验证与收尾

1. **preset 零改动验证**：bot 起来后确认 `mcp__mcc__*` 自动出现（桥按 `tools/list` 自动发现，端口没变就该工作）。若改了端口/路径：编辑 `~/.dsh/.agent-presets/cuberite/agent.cordis.yml` 的 `mcp-mcc` 行 `mccUrl`——**注意该文件不属于本仓库**，改动要单独说明
2. 端到端演练：`mcp__cuberite__bot_start` → `mcp__mcc__*` 逐工具冒烟 → 死亡重生演练（对照 §5 基线）→ `bot_stop`
3. `config.ini` 切 `Engine=mineflayer` 观察；MCC 路径与 `mcc.lua` 保留不动
4. 更新 `README.md` 与 preset 的 persona 提示（`agent.cordis.yml` 里 MCC 相关的两句——只在确认切换后才改）
5. 收尾提交，合并或保留分支由当时决定

## 10. 测试闭环（本 preset 的工具链，别用错通道）

- **服务器**：只由 `cuberite_start`/`cuberite_stop` 管理；**绝不在 bash 里启动/杀服务器**
- **改 Lua 后**：`luacheck Plugins/MCPServer/`（在 `/home/david/Cuberite` 下）→ `mcp__cuberite__reload_plugin`（name=插件文件夹名）→ `cuberite_log` 看结果
- **改 MCPServer 自身后**：`reload_plugin` 会断 MCP——用 `mcp__cuberite__run_console_command`（command=`reload`）全量重载；MCP 桥会自动重连（preset 桥的重连预算约 3600 次尝试），断几秒属预期
- **bot 是普通 Node 进程**：开发期用 bash 后台跑（`run_in_background: true` + `job_output`）；接入插件后走 `bot_start`
- **日志**：`cuberite_log`（服务器侧）+ `job_output`/直接读 `mcc_output.log`（bot 侧 stdout）
- ** MCC 基线对照组**：任何"以前 MCC 能不能做到"的疑问，用 §5 的基线文档回答，别靠记忆

## 11. 坑与注意事项（含前人踩过的）

1. **npm 缓存**：沙箱拒绝写 `~/.npm`——`npm install --cache <工作区内路径>/.npmcache`，装完删缓存
2. **连接节流**：bot 重连太密会被 Cuberite 拒——重连退避起步 5 秒
3. **`tools/list` 返回空数组会挂桥**（§4 第 4 条）：bot 端点至少注册一个工具（如 `ping`）
4. **无状态端点是设计决定不是偷懒**：它消灭 MCC 痛点 3 的根源；别给 bot 端点加会话跟踪
5. **`reload_plugin` 指向 MCPServer 自己会断 MCP**（§10）
6. **Cuberite 全局量**：Lua 里 `dimOverworld/gmSurvival/wSunny` 等纯 C++ 常量本地无文档，luacheck 白名单已覆盖；`cuberite_api` 工具可查签名，动手前先查
7. **`Engine` 开关默认 `"mcc"`**：联调全绿前不要切，回退路径必须始终可用
8. **死亡对照**：mineflayer 默认 `respawn:true` 自动重生，但 Cuberite 的坠虚空 bug 是否对 mineflayer 客户端复现**未知**——Phase 0 的死亡项是硬闸门，不是可选项
9. **工具命名对齐基线**（§5）：`mcp__mcc__*` 的下游工具面靠它无感切换；改名要连带更新后续所有依赖该面的流程

## 12. 验收标准

- [ ] `docs/baseline-mcc-tools.md` 提交，含 MCC 完整工具面 + 样本返回 + 死亡基线
- [ ] `docs/smoke-results.md` 提交，1.8.9 与 1.12.2 双版本全 PASS（或记录止损理由）
- [ ] `bot/` 完整：`node bot/index.js` 可独立运行；`luacheck` 干净；README 齐备
- [ ] 插件侧：`Engine` 开关两种取值下 autostart/stop/status/reload 全部行为正确；`luacheck Plugins/MCPServer/` 零告警
- [ ] 端到端：`mcp__mcc__*` 工具面在 bot 引擎下可用且与基线对齐；死亡重生不坠虚空（或与 MCC 基线同水平）
- [ ] 回退验证：切回 `Engine=mcc` 后 MCC 路径完整可用
- [ ] 提交历史清晰（见 §13），文档与实现同步

## 13. 分支与提交约定

- 当前分支 `research/mineflayer-feasibility`（研讨文档所在）。实施从这里开新分支 `feat/mineflayer-bot`，或在同一分支继续（若后续无并行工作）——**实施会话自行判断，保持单一分支线性提交即可**
- 提交信息风格沿用本仓库：首行祈使句英文摘要 + 空行 + 正文要点（参考 `git log` 现有提交）
- 语义分组提交：冒烟脚本与结果、bot 程序、插件改造、文档各自独立成 commit
- `docs/` 已确认不被 `.gitignore` 忽略；`.npmcache`、`node_modules` 提交前确认忽略规则

---

**最后一句**：所有架构决策已定且给了依据（§2），实施时不要重开讨论；真正的不确定性只剩一个——mineflayer × Cuberite 的实际兼容性（Phase 0 回答它），所以 Phase 0 永远是第一步。
