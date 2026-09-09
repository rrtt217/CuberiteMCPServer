# mcpserver-bot

带无状态 HTTP JSON-RPC（MCP）端点的 Mineflayer bot，取代 MCPServer 插件里的 Minecraft Console Client (MCC)。迁移背景见 docs/handoff-mineflayer-migration.md。
> 本文件为双语（中文 + English）。

## 运行

```
npm install          # 安装 mineflayer + postinstall 自动应用补丁
node index.js        # 默认连 127.0.0.1:25568，offline 1.12.2，MCP 于 :33333
node index.js --config bot.ini
```

配置优先级：CLI --config <file> > 环境变量 MCPS_BOT_* > 默认值 defaults.

| key（bot.ini [Bot] 段） | 默认 | 说明 |
|---|---|---|
| host | 127.0.0.1 | 服务器地址 |
| port | 25568 | 服务器端口 |
| username | TestBot | 基础用户名 |
| randomUsername | true | 追加随机后缀 |
| version | 1.12.2 | 协议版本；1.9-1.12.2 在 prismarine-chunk 补丁后均可用（见下） |
| mcpBind | 127.0.0.1 | MCP 绑定地址 |
| mcpPort | 33333 | MCP 端口（与 harness bridge 保持一致） |

## MCP 端点

- POST http://127.0.0.1:33333/mcp，纯 JSON 响应（bridge 直接 JSON.parse，绝不用 SSE 框架，和 MCC 不同）。
- **无状态**：没有会话 id。重启 bot 不会使客户端任何东西失效。
- 方法：initialize, notifications/initialized, tools/list, tools/call, ping。
- 工具名保留 mcc_* 前缀，bridge 会按 mcp__mcc__* 暴露（下游表面与 MCC 完全一致）。

## 工具

基线见 docs/baseline-mcc-tools.md（MCC 表面镜像）。全部 42 个工具：

会话：`ping`, `mcc_session_status`, `mcc_server_info`, `mcc_player_state`, `mcc_player_stats`, `mcc_world_state`
聊天：`mcc_send_chat`, `mcc_chat_history`
窗口：`mcc_container_open_at`, `mcc_window_slots`, `mcc_container_deposit_item`, `mcc_container_withdraw_item`, `mcc_inventory_window_action`, `mcc_container_close`
移动：`mcc_look_at`, `mcc_look_direction`, `mcc_toggle_sprint`, `mcc_toggle_sneak`, `mcc_change_hotbar_slot`, `mcc_move_to`（goalType: near|xz|block|face|any, mode: scout|walk）, `mcc_can_reach`, `mcc_path_status`, `mcc_stop_movement`, `mcc_respawn`
（注意：mcc_toggle_sneak / mcc_toggle_sprint 不是开关——必须显式传 enabled: true|false；空对象会被 invalid_args 拒绝。）
背包：`mcc_inventory_snapshot`, `mcc_inventory_search`, `mcc_select_item`
实体与方块：`mcc_entities_query`, `mcc_world_block_at`, `mcc_raycast_block`, `mcc_player_nearby`, `mcc_activate_block`, `mcc_entity_attack`, `mcc_entity_interact`（右键/使用跟踪实体——如打开村民交易窗口）, `mcc_dig_block`, `mcc_use_item`, `mcc_hold_use`, `mcc_hold_left`, `mcc_place_block`
合成：`mcc_craft`（itemType/count/table）
采集：`mcc_collect_drops`（collectblock 引擎 + legacy 回退）
生命周期：`mcc_rebuild`（新 bot 实例，可选新用户名）, `mcc_quit_client`

### 交互语义（右键 / 长按）

- `mcc_use_item`：单次右键。无目标=使用手持物品（activateItem：吃/扔/钓鱼/拉弓/水桶…）；x,y,z=激活方块；entityId=右键实体。
- `mcc_hold_use`：长按右键。物品模式 = **press/release**：action=start（按下 activateItem）/ stop（松开 deactivateItem）/ toggle（翻转），durationMs 自动松开（拉弓放箭）；针对实体/方块时是 vanilla 式每 250ms 重复右键（喂食/连点）。1.12 的「use」是有状态动作，不是重复点击器。
- `mcc_hold_left`：长按左键。entityId=连续攻击直到死亡/消失/超时；仅 x,y,z=挖单块；带 dx,dy,dz+count=前进式连挖一条巷道（挖一格走一格，strip-mine/楼梯），受 durationMs 限制。

### 合成

- `mcc_craft(itemType, count?, table?)`：直接用 mineflayer 的 recipe（postinstall 的 minecraft-data 补丁已重生成 1.12.2 全配方：6 种木板变体、船、楼梯、栅栏等）。table={x,y,z} 用于 3x3 配方（自动开/关工作台）。
- 图案必须精确摆放（历史坑：木棍被排到左列而非中列导致永远出不了镐）。
- **工作台是工作台，不是容器**：deposit/withdraw 对 46 槽工作台窗口返回 not_a_container。

### 采集

- `mcc_collect_drops(radius?, maxItems?, timeoutMs?)`：优先 mineflayer-collectblock 引擎（按距离逐个 pathfind + 等待拾取，带墙钟超时+取消），加载失败回退 legacy 走点循环。结果里 engine=collectblock|legacy。
- 掉落 5 分钟消失；半径以 bot 为中心；坑底/树冠内不可达的掉落两引擎都收不了（地形限制）。

## prismarine-chunk 补丁（1.9+ 必需）

Cuberite 总是用 13-bit *全局*调色板发 1.9-1.12 区块；prismarine-chunk 的 loader bug 用 maxBitsPerBlock（12，来自 minecraft-data 的 maxStateId=4095）而不是线上的 13 去算块数据 BitArray，导致 BitArray.readBuffer(size=1664, data.length=1536) 不消费块数据、之后所有读取错位（varint is too big、blockAt 全空气、bot 穿地）。

- 修复：patches/prismarine-chunk+1.41.0.patch（一行 + 注释）— src/pc/1.9/ChunkColumn.js 中 bitsPerValue: bitsPerBlock。
- npm install 通过 postinstall: patch-package 自动应用。全新检出首次运行前必须 npm install（或 npx patch-package）。
- prismarine-chunk 升级后重新生成：cd bot && npm_config_cache=<workspace>/.npmcache npx patch-package prismarine-chunk。
- 完整字节级分析：docs/version-compat-matrix.md。

## 与 MCC 的差异

- 死亡 → 干净重生状态机；不再有「corrupt client / void」重启舞蹈。mcc_rebuild 是显式新实例逃生口。
- 版本 1.12.2（Cuberite 协议上限）。1.9-1.12.2 区块解析依赖上面的 prismarine-chunk 补丁。
- 信号处理：SIGTERM/SIGINT 优雅退出（Node 默认），无需信号阶梯。
- 其它 node_modules 补丁（都在 patches/，postinstall 应用）：mineflayer=clickWindow 自确认+80ms 结算（Cuberite 不回 0x33）；minecraft-data=重生成 1.12.2 配方；mineflayer-collectblock=Targets.getClosest 空安全。

## 冒烟

node smoke.js 1.8.9 跑 Phase 0 门禁（见 docs/smoke-results.md）。

## 放置与挖掘

`mcc_place_block`（x/y/z + face: auto|down|up|north|south|west|east）把手持物品放到目标格；`mcc_dig_block` 挖一个。几个约束要知道：

- **生成点保护**：Core 插件拒绝非 OP 在保护半径内改方块（core.spawnprotect.bypass）。bot 在 default 组，所以只能在半径外放置/挖掘。
- **自身碰撞**：服务器拒绝在 bot 身体所在格放置；工具会预检并返回清晰错误。
- `mcc_dig_block` 挖前会自动装备最佳镐/斧/锹（捡起掉落会把手持悄悄换成掉落物→徒手速度）。

## GUI / 容器窗口

`mcc_container_open_at` 打开任意容器方块（箱子/熔炉/工作台/漏斗/发射器…），后续工具作用于已开窗口：`mcc_window_slots` 列出槽位（容器段+玩家段）与真实窗口类型（windowType，如 minecraft:chest / minecraft:villager / minecraft:crafting_table）；`mcc_container_deposit_item` / `mcc_container_withdraw_item` 移动物品；`mcc_inventory_window_action` 是底层点击；`mcc_container_close` 关闭。

注意：mineflayer 4.38 的 openContainer 只认 1.13+ 名字，crafting_table/furnace 等由工具内部走 activateBlock+windowOpen。Cuberite 处理窗口点击并广播槽位更新，但从不在 1.8 回 Confirm Transaction(0x33)；bot 本地自确认（window.requiresConfirmation=false），窗口操作快速不阻塞。**开窗前先给 bot 物品**（窗口打开中服务器侧发放的物品不会刷新已开窗口的玩家段）。
