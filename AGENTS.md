# AGENTS.md — Repository Guide for AI Agents

> This file is for AI agents / collaborators working on repo rrtt217/CuberiteMCPServer
> (Cuberite plugin 'MCPServer', installed at /home/david/Cuberite/Plugins/MCPServer).
> All documentation stays bilingual (Chinese + English).

## 1. Project Overview

**MCPServer** is a Cuberite (Lua plugin) that exposes both the server and a managed test bot as **MCP** tools over Streamable HTTP.

Two MCP layers:
- Server MCP on :8765 (Lua); bot MCP on :33333 (Node, stateless). The bridge registers bot tools as mcp__mcc__*.

Stack: Cuberite (1.12.2 protocol cap), mineflayer 4.38.0, minecraft-data 3.115.0, Node 22, patch-package.

## 2. Directory Layout

```
Plugins/MCPServer/
├── config.ini        # local config (auto-generated, gitignored)
├── main.lua          # MCP server lifecycle / mcp console command
├── tools.lua         # server-side MCP tool registry (all mcp__cuberite__* tools)
├── jsonrpc.lua       # JSON-RPC dispatch
├── http.lua          # HTTP listener layer
├── bot.lua           # mineflayer bot process management (bot start/stop/restart/status)
├── mcc.lua           # DEPRECATED: MCC legacy engine fallback
├── config.lua        # unified config reading wrapper
├── void_guard.lua    # void guard (off by default under mineflayer)
├── Info.lua          # plugin metadata + command registration
├── docs/             # docs (bilingual)
├── AGENTS.md         # this file
├── .scratch/         # drafts/reports/one-off scripts (gitignored)
└── bot/              # Node mineflayer bot (standalone node_modules)
    ├── index.js      # entry: config → lifecycle → MCP endpoint
    ├── bot.js        # BotHandle (connect/reconnect/state)
    ├── tools.js      # MCP tool registry (mirrors mcc_* naming)
    ├── mcp.js        # stateless MCP endpoint (:33333)
    ├── actions/      # chat / move / interact / inventory / world / windows / craft / collect
    ├── patches/      # patch-package patches (applied automatically on postinstall)
    ├── bot.ini · package.json (postinstall=patch-package)
```

## 3. Key Operations

| Action | How |
|---|---|
| Start/Stop/Logs | Use only the harness's cuberite_start / cuberite_stop / cuberite_log; **never** start/stop the server via bash |
| Shutdown command | cuberite_stop is fixed: it goes through execute_lua → cRoot:Get():QueueExecuteConsoleCommand('stop') |
| Start/stop bot | console bot <start|stop|restart|status>, or the MCP bot_* / mcp__mcc__* tools |
| Plugin changes | mcp__cuberite__reload_plugin('MCPServer') (reloading briefly disconnects the MCP client) |
| Bot changes | bot_restart; a random-name restart = new player with a cleared inventory — store items in a chest first |
| Validate Lua | cuberite_check <plugin> + cuberite_api <query> (offline API reference; don't rely on memory) |
| Validate JS | node --check bot/actions/*.js |
| Test new bot tools | direct HTTP POST http://127.0.0.1:33333/mcp (tools/list, tools/call); the in-session mcp__mcc__* catalog is frozen at launch |

## 4. Tool Registration & Response Contract

- Server tools.lua: {name, description, inputSchema, handler}; bot tools.js mirrors; uniform {success,data}|{success:false,errorCode} response.

## 5. Hard-Won Gotchas (read before editing)

1. **Shutdown**: cPluginManager:ExecuteConsoleCommand('stop') executed inside the MCP HTTP callback (main thread) silently does nothing; only cRoot:Get():QueueExecuteConsoleCommand('stop') works (= the Core /stop path).
2. **bwrap sandbox**: commands run inside a --unshare-pid namespace; ps/pgrep cannot see external processes started by the harness — verify processes by port probing (nc -z / ss), not ps.
3. **npm/patch-package**: ~/.npm is read-only inside the sandbox; run all npm operations with npm_config_cache=<repo>/.npmcache; postinstall=patch-package applies bot/patches/* automatically; generate new patches with npx patch-package <pkg> and commit them.
4. **node_modules patches** (all in bot/patches/): mineflayer=clickWindow self-confirm +80ms (Cuberite does not reply to 0x33 transactions); minecraft-data=regenerated 1.12.2 recipes (6 wood variants etc.); prismarine-chunk=1.9+ chunks; mineflayer-collectblock=Targets.getClosest null-safety (merging drops destroys entities).
5. **openContainer whitelist**: mineflayer 4.38 only recognizes 1.13+ names (chest/dispenser/...); crafting_table/furnace etc. must use activateBlock+windowOpen (windows.js already routes this); work around it with mcc_activate_block; clicks are self-confirmed and do not hang.
6. **digBlock** auto-equips the best pickaxe/axe/shovel before digging: picking up a drop silently swaps the held item to the dropped block → bare-hand speed (stone 7.5s/block).
7. **Crafting**: the pattern must be exact (historical bug: sticks in the left column instead of the middle); usable after the bot.craft patch; a crafting table is a crafting table, not a container (deposit/withdraw on a 46-slot window returns not_a_container).
8. **Right-click use is a stateful action** (1.12): press=activateItem, release=deactivateItem. mcc_hold_use(action=start|stop|toggle) is a press/release switch, not repeated clicks; only entity/block targets repeat (vanilla semantics).
9. **Collection**: mcc_collect_drops = collectblock engine + legacy fallback; drops vanish after 5 minutes; the radius is centered on the bot; drops unreachable inside pits/tree canopies cannot be collected.
10. **Spawn protection**: the Default group has no core.spawnprotect.bypass; dig/place within radius 10 is denied ('Go further from spawn to build') — expected behavior.
11. **Pathfinder**: shared Movements; scout canDig defaults to true; enclosed/dense-leaf areas idle the bot — use short goals; tp permission is for getting unstuck.
12. **Config**: everything merged into config.ini ([Engine] engine=mineflayer|mcc; [Bot]...); machine-specific things → gitignored.
13. **Docs**: documentation is bilingual — every document is split into an EN file (`<name>.md`, English-only) and a Chinese file (`<name>.zh.md`). This file's pair is AGENTS.zh.md.
14. **Death/health sync (death_sync)**: after a same-world death respawn via cPlayer::Respawn(), Cuberite **never sends update_health** (SendHealth is only sent in Heal/SetFoodLevel/DoTakeDamage/OnAddToWorld). Consequence: the client (mineflayer's bot.health/isAlive, and the vanilla health bar likewise) gets stuck at health=0 / isAlive=false while the server has already respawned at full health — mineflayer and Cuberite fall out of sync on death state. Fix: MCPServer's death_sync.lua calls Player:Heal(0) in HOOK_PLAYER_SPAWNED to force one more health resend (verified end-to-end). If health is stuck at 0 again, first confirm that hook is registered (the log contains "death-sync registered"). **This fix does NOT help the legacy MCC engine's void-fall loop** (verified 2026-09-09): after death the MCC client keeps reporting falling positions that Cuberite accepts, so the player still sinks into the void (measured y 73→-833 with health cycling 20→5) — MCC still needs [VoidGuard] Enabled=true.
15. **cuberite_stop blind spot**: when the server process is still alive but MCP is already down (e.g., after a plugin load failure), cuberite_stop sees mcpUp=false and returns stopped without sending a stop signal — in that case you can only pkill externally and restart.

## 6. Testing Loop

- Lua: cuberite_check + cuberite_api; JS: node --check; end-to-end: start server → start bot → operate MCP → verify the world with execute_lua (GetBlock etc.).
- Interactive actions (right-click/hold/craft) are verified by calling the bot MCP tools/call directly over HTTP.

## 7. Commit Conventions

- conventional-commit style (feat(bot): / fix(): / docs():), then git push origin main.
- Note: git add -A sweeps in the user's uncommitted changes — run git status --short and review the diff before committing.
- Do not modify node_modules itself (pin changes with patch-package).
