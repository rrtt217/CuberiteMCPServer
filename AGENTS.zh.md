# AGENTS.md — 仓库开发指南

> 本文件面向在仓库 rrtt217/CuberiteMCPServer 上工作的 AI 代理/协作者。
> （Cuberite 插件 'MCPServer'，安装于 /home/david/Cuberite/Plugins/MCPServer）。
> 所有文档保持中英双语。

## 1. 项目简介

**MCPServer** 是一个 Cuberite（Lua 插件）插件，把服务器本身和一个受管的测试 bot 以 **MCP** 工具暴露给 LLM 主机。

两条 MCP 通道：
- 服务器端 Server MCP : 端口 8765（jsonrpc.lua / http.lua / main.lua，工具注册在 tools.lua）。
- Bot MCP : Node 端，端口 33333（bot/mcp.js，无状态 HTTP JSON-RPC；工具注册在 bot/tools.js）。bridge（~/.dsh/.agent-presets/cuberite/mcp-mcc.mjs）把 bot 工具注册成 mcp__mcc__*。

技术栈：Cuberite（1.12.2 协议上限）, mineflayer 4.38.0, minecraft-data 3.115.0, Node 22, patch-package.

## 2. 目录结构

```
Plugins/MCPServer/
├── config.ini        # 本机配置（自动生成，gitignored）
├── main.lua          # MCP server 生命周期 / mcp console 命令
├── tools.lua         # 服务器端 MCP 工具注册表（server 的全部 mcp__cuberite__* 工具）
├── jsonrpc.lua       # JSON-RPC 分发
├── http.lua          # HTTP 监听层
├── bot.lua           # mineflayer bot 进程管理（bot start/stop/restart/status）
├── mcc.lua           # DEPRECATED：MCC 旧引擎回退
├── config.lua        # 配置读取统一封装
├── void_guard.lua    # 虚空守卫（mineflayer 下默认关）
├── Info.lua          # 插件元数据 + 命令注册
├── docs/             # 文档（中英双语）
├── AGENTS.md         # 本文件
├── .scratch/         # 草稿/报告/一次性脚本（gitignored）
└── bot/              # Node mineflayer bot（独立 node_modules）
    ├── index.js      # 入口：config → 生命周期 → MCP endpoint
    ├── bot.js        # BotHandle（连接/重连/状态）
    ├── tools.js      # MCP 工具注册表（镜像 mcc_* 命名）
    ├── mcp.js        # 无状态 MCP 端点（:33333）
    ├── actions/      # chat / move / interact / inventory / world / windows / craft / collect
    ├── patches/      # patch-package 补丁（postinstall 自动应用）
    ├── bot.ini · package.json（postinstall=patch-package）
```

## 3. 关键操作

| 操作 | 方式 |
|---|---|
| 启动/停止/日志 | 只用 harness 的 cuberite_start / cuberite_stop / cuberite_log；**绝不**用 bash 启停服务器 |
| 关服命令 | cuberite_stop 已修好：走 execute_lua → cRoot:Get():QueueExecuteConsoleCommand('stop') |
| 启停 bot | 控制台 bot <start|stop|restart|status>，或 MCP bot_* / mcp__mcc__* 工具 |
| 插件改动 | mcp__cuberite__reload_plugin('MCPServer')（重载会短暂断开 MCP 客户端） |
| bot 改动 | bot_restart；随机名重启 = 新玩家、背包清空——先存箱子 |
| 校验 Lua | cuberite_check <plugin> + cuberite_api <query>（离线 API 参考，勿凭记忆） |
| 校验 JS | node --check bot/actions/*.js |
| 测试新 bot 工具 | 直接 HTTP POST http://127.0.0.1:33333/mcp（tools/list, tools/call）；会话内 mcp__mcc__* 目录启动时冻结 |

## 4. 工具注册与返回约定

- 服务器端 tools.lua：元素 {name, description, inputSchema, handler}；返回 textOK/textErr(toJsonString(...))。
- bot/tools.js：元素 {name, description, inputSchema, handler}，用 ok(data)/fail(errorCode,data) 包装。命名镜像 MCC 基线（docs/baseline-mcc-tools.md），因为 bridge 把每个名字注册成 mcp__mcc__<name>。
- 统一返回 {success:true,data:{...}} 或 {success:false,errorCode:'...'}。

## 5. 踩坑记录（改动前必读）

1. **关服**：cPluginManager:ExecuteConsoleCommand('stop') 在 MCP HTTP 回调（主线程）内执行会静默无效；只有 cRoot:Get():QueueExecuteConsoleCommand('stop') 有效（= Core /stop 的路径）。
2. **bwrap 沙箱**：命令跑在 --unshare-pid 命名空间里，ps/pgrep 看不到 harness 启动的外部进程——验证进程用端口探测（nc -z / ss），别用 ps。
3. **npm/patch-package**：沙箱里 ~/.npm 只读，所有 npm 操作带 npm_config_cache=<repo>/.npmcache；postinstall=patch-package 自动应用 bot/patches/*，新补丁用 npx patch-package <pkg> 生成并提交。
4. **node_modules 补丁**（全在 bot/patches/）：mineflayer=clickWindow 自确认+80ms（Cuberite 不回 0x33 事务）；minecraft-data=重新生成 1.12.2 配方（6 木变体等）；prismarine-chunk=1.9+ 区块；mineflayer-collectblock=Targets.getClosest 空安全（合并掉落会销毁实体）。
5. **openContainer 白名单**：mineflayer 4.38 只认 1.13+ 名字（chest/dispenser/...）；crafting_table/furnace 等必须 activateBlock+windowOpen（windows.js 已路由）；绕行用 mcc_activate_block，点击已自确认不挂。
6. **digBlock** 挖前自动装备最佳镐/斧/锹：捡掉落会把手持悄悄换成掉落方块→徒手速度（石头 7.5s/块）。
7. **合成**：图案必须精确（历史 bug：木棍放左列而非中列）；bot.craft 补丁后可用；工作台是工作台不是容器（deposit/withdraw 对 46 槽窗口返回 not_a_container）。
8. **右键使用是有状态动作**（1.12）：按下=activateItem，松开=deactivateItem。mcc_hold_use(action=start|stop|toggle) 是 press/release 开关而非重复点击；实体/方块目标才重复（vanilla 语义）。
9. **采集**：mcc_collect_drops = collectblock 引擎 + legacy 回退；掉落 5 分钟消失；半径以 bot 为中心；坑底/树冠内不可达掉落收不了。
10. **生成点保护**：Default 组无 core.spawnprotect.bypass，半径 10 内 dig/place 被拒（'Go further from spawn to build'）——预期行为。
11. **Pathfinder**：共享 Movements；scout canDig 默认 true；封闭/密叶区会空转——用短目标；tp 授权用于脱困。
12. **配置**：全部并入 config.ini（[Engine] engine=mineflayer|mcc；[Bot]…），机器相关→gitignored。
13. **文档**：本仓库文档采用中英拆分双文件制——每个文档拆成英文文件（`<name>.md`，纯英文）与中文文件（`<name>.zh.md`）。本文件的配对是 AGENTS.zh.md。
14. **死亡/健康同步（death_sync）**：Cuberite 的 cPlayer::Respawn() 同世界死亡重生后**从不发 update_health**（SendHealth 只在 Heal/SetFoodLevel/DoTakeDamage/OnAddToWorld 里发）。后果：客户端（mineflayer 的 bot.health/isAlive，原版血条同理）卡死在 health=0 / isAlive=false，服务器却已满血重生——mineflayer 与 Cuberite 死亡状态失步。修复：MCPServer 的 death_sync.lua 在 HOOK_PLAYER_SPAWNED 里调 Player:Heal(0) 强制重发一次健康（已端到端验证）。若再遇 health 卡 0，先确认该钩子已注册（日志含 death-sync registered）。 **该修复对遗留 MCC 引擎的坠虚空循环无效**（2026-09-09 实测）：MCC 客户端死后持续上报坠落坐标、Cuberite 照单全收，玩家照样陷进虚空（实测 y 73→-833，血 20→5 振荡）——MCC 仍需 [VoidGuard] Enabled=true。
15. **cuberite_stop 的盲区**：当服务器进程还在但 MCP 已断（如插件加载失败后），cuberite_stop 检测 mcpUp=false 会直接返回 stopped 而不发停止信号——此时只能外部 pkill 后重启。

## 6. 测试闭环

- Lua：cuberite_check + cuberite_api；JS：node --check；端到端：启服→启 bot→操作 MCP→execute_lua 复核世界（GetBlock 等）。
- 交互类（右键/长按/合成）直接 HTTP 调 bot MCP tools/call 验证。

## 7. 提交规范

- conventional-commit 风格（feat(bot): / fix(): / docs():），然后 git push origin main。
- 注意 git add -A 会把用户未提交改动卷进来——提交前 git status --short + 看 diff。
- 不改 node_modules 本身（用 patch-package 固化）。
