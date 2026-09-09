# Handoff: Implementing the mineflayer Replacement of MCC

> Handed to the next session that actually mounts the cuberite preset. This document is the **implementation handoff**: read it and you can start — every decision is made, every fact is verified.
> Companion reading: `docs/feasibility-mineflayer.md` (feasibility study, with research sources and risk matrix).
>
> - Date: 2026-08-30
> - Branch: `research/mineflayer-feasibility` (feasibility report committed, commit `0c13a39`)
> - Status: **research complete, implementation not started**
> - Conclusion: feasible and migration recommended; MCC is kept as a fallback and the `Engine` switch can flip back at any time

---

## 0. Quick-start checklist

Execute in order; each step has an acceptance marker:

1. [ ] Read this document + `docs/feasibility-mineflayer.md`
2. [ ] Confirm you are on branch `research/mineflayer-feasibility` with `git log --oneline -3`
3. [ ] Capture the MCC tool baseline (§5 — do this first, while MCC still runs)
4. [ ] Phase 0 smoke script (§6) — **the gate that decides whether the whole migration succeeds**
5. [ ] Phase 1 bot program (§7)
6. [ ] Phase 2 plugin changes (§8)
7. [ ] Phase 3 preset verification and wrap-up (§9)

---

## 1. One-page background

The MCPServer plugin (this repo) exposes Cuberite as an MCP server (:8765). The test robot currently uses **Minecraft Console Client (MCC)**: an 85MB C# monolithic binary that joins the game as a bot and embeds an MCP server (:33333/mcp) exposing bot capabilities. The DSH cuberite preset bridges that endpoint into session tools `mcp__mcc__*` via `mcp-mcc.mjs`.

MCC's structural pain points (migration motivation):

1. Ignores SIGTERM/SIGINT/SIGQUIT → needs the four-stage signal ladder in `mcc.lua` (SIGTERM→SIGHUP→SIGUSR1→SIGKILL)
2. After bot death the client state is corrupted → it falls into the void and cannot respawn (ignores landing) → only restarting the **entire process** with a random username works
3. An MCC restart invalidates the MCP session (-32001) → the preset bridge was forced to become self-healing
4. Bloated configuration: temporary ini (47KB) + user main ini, two tracks
5. Black box: an 85MB binary; problems cannot be fixed in-process

**mineflayer** (Node.js library, 4.38.0, supports MC 1.8–1.26.1) can replace the MCC body: all three pain points disappear (Node exits immediately on SIGTERM by default; death auto-respawns by default with clean state; a library means everything is customizable). The cost: no off-the-shelf MCP wrapper supports 'old versions + HTTP', so a layer must be written (~1–2 days).

## 2. Current three-layer integration map (who is where; what moves and what does not)

```
┌─────────────────────────────────────────────────────────────────────┐
│ DSH cuberite preset (~/.dsh/.agent-presets/cuberite/)               │
│   mcp-cuberite bridge → plugin :8765        (unchanged)             │
│   mcp-mcc bridge (mcp-mcc.mjs) → bot :33333/mcp  (unchanged, zero edits) │
├─────────────────────────────────────────────────────────────────────┤
│ MCPServer plugin (this repo, Lua)                                   │
│   jsonrpc.lua / http.lua / tools.lua : the MCP server itself (unchanged) │
│   mcc.lua / config.lua [MCC] / Info.lua mcc command                  │
│     → process lifecycle management  (changed → bot.lua / [Bot], §8)  │
│   void_guard.lua: void-fall guard   (kept for observation, §8.4)     │
├─────────────────────────────────────────────────────────────────────┤
│ bot body                                                            │
│   now: MCC binary (/home/david/Cuberite/MinecraftConsoleClient)      │
│   target: bot/ Node program (mineflayer + own MCP endpoint) ← new, §7 │
└─────────────────────────────────────────────────────────────────────┘
```

**Layering decision (settled, do not reopen)**: bot code goes in **this repo** (versioned, and a resource whose lifetime tracks the server must be managed server-side); process lifecycle stays in the **plugin layer** (reuse mcc.lua's pid tracking and fd wrapper); the **preset bridge is untouched** (the bot keeps port 33333 → zero edits).

## 3. Machine environment facts (verified 2026-08-30)

| Item | Value | Note |
|---|---|---|
| Node.js | v22.22.3 (nvm: `~/.nvm/versions/node/v22.22.3/bin/node`) | satisfies mineflayer 4.38.0's `engines: node>=22` |
| npm | 10.9.8 | **the sandbox refuses to write `~/.npm`**: add `--cache <workspace>/.npmcache` when installing (delete afterwards, do not commit) |
| Cuberite | `/home/david/Cuberite/Cuberite`, game port **25568** | the server is managed only by the preset's `cuberite_start`/`cuberite_stop` tools |
| Plugin game-port config | `config.ini [MCC] ServerPort=25568` | the bot connection parameter follows this value |
| MCC binary | `/home/david/Cuberite/MinecraftConsoleClient` (85MB) | kept as a fallback, do not delete |
| Plugin current config | `config.ini [MCC] Enabled=true, AutoStart=false, RandomUsername=true, Username=TestBot2, MinecraftVersion=1.12.2, McpPort=33333` | `AutoStart=false` was turned off manually (debugging); note this during migration |
| mineflayer | npm latest 4.38.0 (released 2026-08-27) | depends on `mineflayer-pathfinder` (optional, for movement) |
| luacheck | run `luacheck Plugins/MCPServer/` under `/home/david/Cuberite` | the site-level .luacheckrc already lists all Cuberite globals |

## 4. The key contract: what the bot's MCP endpoint must satisfy

The only consumer is the preset's `mcp-mcc.mjs` (source fully read). Hard contract:

1. **URL**: `http://127.0.0.1:33333/mcp` (POST; the path must match exactly, otherwise edit one line in the preset)
2. **Transport**: HTTP POST + JSON-RPC 2.0. The bridge is POST-only (no GET/SSE push needed)
3. **Handshake**: the bridge sends `initialize` → `notifications/initialized` → `tools/list` in order. `initialize` must return `protocolVersion` (the bridge sends `'2025-06-18'`) and a valid result
4. **`tools/list` must return at least 1 tool** — `mcp-mcc.mjs` source: `if (tools.length === 0) throw new Error('MCC MCP tools/list returned nothing')`; an empty list kills the bridge
5. **Automatic tool registration**: the bridge registers every `t.name` from `tools/list` as the session tool `mcp__mcc__<name>`, passing `inputSchema` through. So **tool names and schemas are the compatibility layer**: keep MCC's naming (§5 baseline) and downstream switches seamlessly
6. **Session header (optional)**: the bridge reads `mcp-session-id` from the `initialize` response and echoes it if present. **Recommended design: a stateless endpoint — never send a session id and ignore any received `Mcp-Session-Id` header** — this kills 'restart invalidates the session' at the root (MCC pain point 3 exists because it tracks sessions and invalidates them on restart); the self-healing path then never triggers
7. **tools/call result shape**: `{ content: [{type:'text', text:'...'}], isError?: bool }` (MCP standard). Errors go through JSON-RPC error (`-32001`/`-32603` etc.) or `isError:true`
8. **Crash tolerance**: if the endpoint crashes/restarts, the bridge re-initializes and retries once on a session-class error; with a stateless design you do not even need that

**Protocol version note**: the plugin's own `jsonrpc.lua` is also an MCP endpoint (:8765, same version 2025-06-18); the bot endpoint's semantics can **copy its implementation** — it is the best reference (the only other in-house MCP implementation besides Lua, and already production-verified).

## 5. First step: capture the MCC tool baseline (do this while MCC still runs)

MCC is currently usable. Before migration starts, record its external surface verbatim as the Phase 1 compatibility spec:

1. `cuberite_start` (wait for `[MCPServer] [MCP] Listening on port 8765` in the log)
2. `mcp__cuberite__mcc_start` (random_name='force') → wait a dozen seconds for `mcp__mcc__*` to appear
3. Record the **complete tool-name list** of `mcp__mcc__*` and each tool's parameter schema (read them from the session tool catalog)
4. Take one sample call per tool class and record the return JSON shape: SessionStatus / ChatAndCommands / Movement / Inventory / EntityWorld
5. Death baseline: poison/drop the bot to death and observe respawn behaviour and whether it falls into the void (control-group data)
6. Write everything into `docs/baseline-mcc-tools.md` and commit

Phase 1's bot tool names, parameter names and return text formats **follow that baseline** (align where possible; new capabilities such as `rebuild` are added on top without breaking alignment).

## 6. Phase 0: smoke verification (~100-line script, the gate)

**Purpose**: mineflayer × Cuberite has never been tested officially (nmp#348 is still unchecked); prove the protocol layer works before investing 1–2 days in the full bot.

**How**:

1. `mkdir -p bot && cd bot && npm init -y && npm install mineflayer --cache ../.npmcache && rm -rf ../.npmcache`
2. Write `bot/smoke.js` (standalone, no MCP):
   - `createBot({ host:'127.0.0.1', port:25568, username:'SmokeBot', auth:'offline', version:'1.12.2' })`
   - readiness is signalled by the `'spawn'` event; print the elapsed time
3. Verify in order and print PASS/FAIL:
   - [ ] offline login + `spawn`
   - [ ] chat round-trip: `bot.chat('ping')` + listen for the echo on `'message'`
   - [ ] command execution: a side-effect-free command such as `bot.chat('/time set day')`
   - [ ] movement: `bot.setControlState('forward', true)` for 2 seconds then check position change; jump/sneak
   - [ ] right-click: `bot.lookAt` + `bot.activateBlock(bot.blockAt(bot.entity.position.offset(0,-1,0)))`
   - [ ] inventory: enumerate `bot.inventory` slots
   - [ ] **death & respawn (critical)**: `/kill` or poison → `'death'` event → default auto-respawn (`respawn` defaults to true) → `'spawn'` fires again → **position normal, no void fall** (compare against the MCC baseline)
   - [ ] SIGTERM: `process.on('SIGTERM', () => { bot.quit('sigterm'); })`; after an external kill the process exits within 1 second
4. **Version matrix**: run once with `version:'1.8.9'` and once with `version:'1.12.2'` (also try omitting version for auto-detect)
5. Record results in `docs/smoke-results.md`; **only proceed to Phase 1 if everything PASSes**

**Fail fast**: if any step fails on both versions → the migration stops, MCC keeps serving; record the failure mode in `docs/smoke-results.md` and commit.

**Pitfalls**:
- Frequent reconnects from the same IP can hit Cuberite's connection throttle — if login hangs, wait 5–10 seconds and retry
- The `kill` command needs bot permission (offline-mode OP or not depends on the server's `settings.ini` Groups); without permission use falling/lava instead
- The smoke script is a **normal Node program**; running it in the bash background is fine (the rule only restricts the server process); remember `job_kill` afterwards

## 7. Phase 1: bot program + MCP endpoint (1–2 days)

**File layout** (all under `bot/`, Node 22, as few third-party deps as possible):

```
bot/
  package.json          # name: mcpserver-bot, private, engines.node>=22
  index.js              # entry: read config → createBot → start MCP endpoint → signal handling
  config.js             # read bot.ini / env vars (host/port/username/version/mcpPort)
  bot.js                # mineflayer connection wrapper: spawn/death/health/kicked events, rebuild()
  actions/
    chat.js             # sendChat / sendCommand / read chat buffer
    move.js             # setControlState / lookAt / (optional pathfinder goto)
    interact.js         # activateBlock / useOn / attack / placeBlock
    inventory.js        # list / equip / transfer / heldItem
    world.js            # entities / blockAt / health / position / time
  mcp.js                # node:http JSON-RPC endpoint (contract in §4)
  tools.js              # tool registry: name + inputSchema + handler (aligned with §5 baseline)
  README.md             # how to run, dependencies, differences vs MCC tools
```

**Key implementation points**:

- **MCP endpoint** (mcp.js): start a service with `node:http`, POST `/mcp`, hand-write JSON-RPC dispatch (five methods are enough: initialize/notifications/initialized/tools/list/tools/call/ping). **Stateless** (§4 item 6). Response headers carry `Content-Length`, `Connection: close`, `MCP-Protocol-Version: 2025-06-18` (matching the plugin's http.lua behaviour). Use `jsonrpc.lua`'s method dispatch structure as reference
- **Tool surface**: names, parameters and return text formats copied from the §5 baseline; add `rebuild` (destroy the old bot instance → `createBot` a new one, replacing MCC's 'restart the process with a new identity'; with a stateless endpoint the session never breaks)
- **rebuild semantics**: keep the username (in offline mode reconnecting with the same name is the same player entity); if the entity is corrupted after death (compare §5 step 5), accept an optional `newUsername` parameter on rebuild
- **Signals**: `SIGTERM`/`SIGINT` → `bot.quit(reason)` → `process.exit(0)`. Node already exits by default; this is only for a graceful disconnect (so the server sees a normal logout instead of a timeout)
- **Logging**: stdout redirection is the plugin's job (reuse mcc.lua's `mcc_output.log` pattern); the bot itself writes key events (spawn/death/error) to stderr
- **Robustness**: limited auto-reconnect on mineflayer `'error'`/`'kicked'` (exponential backoff, max 5); decouple the endpoint from the bot lifecycle — the endpoint stays alive when the bot is offline and tools return `isError:true` with a reason
- **Dependencies**: install only `mineflayer` (+ optional `mineflayer-pathfinder`). Do not install `@modelcontextprotocol/sdk` — the only consumer is the POST-only hand-written bridge; stdlib is enough and avoids a supply-chain risk
- Add `bot/.npmcache` and `node_modules` to `.gitignore` (whether to commit `node_modules` is decided by the next session per repo state; default is not to commit, and the README documents installation)

## 8. Phase 2: plugin-side changes (Lua)

Per-file tasks (run `luacheck Plugins/MCPServer/` under `/home/david/Cuberite` when done):

1. **`mcc.lua` → copy to `bot.lua`** (keep mcc.lua, the fallback switch needs it):
   - `BuildMCCCommand` → `BuildBotCommand`: the command changes from `'"<MCC.Path>" "<tmpIni>"'` to `'"<node path>" "<plugin dir>/bot/index.js" --config <bot.ini>'`; drop temporary-ini generation (the bot reads its own config)
   - Simplify the signal ladder `g_StopLadder` to two stages: `{ 'SIGTERM', 'kill %d', 1.5 }, { 'SIGKILL', 'kill -9 %d', 1.0 }` (Node responds to SIGTERM by default; a 1.5s budget is generous)
   - `IsMCCProcess`'s cmdline match becomes matching `bot/index.js` (prevents killing the wrong PID on reuse; logic unchanged)
   - Keep the fd-closing wrapper **as is** (the orphan-process/port mechanism is client-independent)
   - Keep the public global function names isomorphic: `StartBot/StopBot/RestartBot/GetBotStatus/HandleConsoleBot`
2. **`config.lua`**: add a `[Bot]` section next to `[MCC]` (Enabled/AutoStart/NodePath/BotDir/Username/RandomUsername/ServerHost/ServerPort/MinecraftVersion/McpPort); **add a top-level switch `Engine = 'mcc' | 'mineflayer'` (default `'mcc'`, flip only after smoke + integration pass)**. `LoadMCPConfig` writes `GetValueSet*` defaults like `[MCC]` does
3. **`tools.lua`**: the four `mcc_status/start/stop/restart` tools dispatch by `Engine` to the right implementation (should the tool names stay `mcc_*`? — **No**: add four new tools `bot_start/stop/restart/status`; keep `mcc_*` but report the current engine; downstream semantics per the Info.lua item)
4. **`main.lua`**: the autostart branch selects `StartMCC()` or `StartBot()` by `Engine`; `OnDisable` stops both (idempotent; both already short-circuit when not running)
5. **`Info.lua`**: add `bot <start|stop|restart|status>` to ConsoleCommands (mirroring `mcc`, Handler → `HandleConsoleBot`)
6. **`void_guard.lua`**: **keep, do not touch**. It protects all players (including the bot) and is client-independent; if mineflayer never triggers the void fall the guard simply never fires (zero-cost safety net). Decide whether to disable it by default after one iteration of observation

## 9. Phase 3: preset verification and wrap-up

1. **Zero-edit preset verification**: after the bot starts, confirm `mcp__mcc__*` appears automatically (the bridge auto-discovers via `tools/list`; an unchanged port should just work). If the port/path changed: edit the `mccUrl` on the `mcp-mcc` line in `~/.dsh/.agent-presets/cuberite/agent.cordis.yml` — **note that file is not part of this repo**, so document the change separately
2. End-to-end drill: `mcp__cuberite__bot_start` → smoke each `mcp__mcc__*` tool → death/respawn drill (against the §5 baseline) → `bot_stop`
3. Switch `config.ini` to `Engine=mineflayer` and observe; keep the MCC path and `mcc.lua` untouched
4. Update `README.md` and the preset persona prompts (the two MCC-related sentences in `agent.cordis.yml` — only after the switch is confirmed)
5. Final commit; decide then whether to merge or keep the branch

## 10. Testing loop (this preset's toolchain; do not use the wrong channel)

- **Server**: managed only by `cuberite_start`/`cuberite_stop`; **never** start/kill the server in bash
- **After Lua changes**: `luacheck Plugins/MCPServer/` (under `/home/david/Cuberite`) → `mcp__cuberite__reload_plugin` (name = plugin folder name) → `cuberite_log` for results
- **After changing MCPServer itself**: `reload_plugin` disconnects MCP — use `mcp__cuberite__run_console_command` (command=`reload`) for a full reload; the MCP bridge reconnects automatically (the preset bridge's reconnect budget is ~3600 attempts); a few seconds of disconnection is expected
- **The bot is a normal Node process**: during development run it in the bash background (`run_in_background: true` + `job_output`); once wired into the plugin use `bot_start`
- **Logs**: `cuberite_log` (server side) + `job_output`/reading `mcc_output.log` directly (bot stdout)
- **MCC baseline control group**: any 'could MCC do this before?' question is answered by the §5 baseline document, not memory

## 11. Pitfalls and notes (including ones previous sessions hit)

1. **npm cache**: the sandbox refuses to write `~/.npm` — `npm install --cache <workspace>/.npmcache`, delete the cache afterwards
2. **Connection throttle**: reconnecting too often gets rejected by Cuberite — start reconnect backoff at 5 seconds
3. **`tools/list` returning an empty array kills the bridge** (§4 item 4): register at least one tool (e.g. `ping`)
4. **A stateless endpoint is a design decision, not laziness**: it eliminates the root of MCC pain point 3; do not add session tracking to the bot endpoint
5. **`reload_plugin` pointed at MCPServer itself disconnects MCP** (§10)
6. **Cuberite globals**: Lua constants such as `dimOverworld/gmSurvival/wSunny` are pure C++ with no local docs; the luacheck whitelist covers them; use the `cuberite_api` tool to check signatures before acting
7. **The `Engine` switch defaults to `'mcc'`**: do not flip it until integration is fully green; the fallback path must always remain available
8. **Death control**: mineflayer auto-respawns by default (`respawn:true`), but whether Cuberite's void-fall bug reproduces for a mineflayer client is **unknown** — the death item in Phase 0 is a hard gate, not optional
9. **Tool naming follows the baseline** (§5): the downstream `mcp__mcc__*` surface relies on it for a seamless switch; renaming requires updating every flow that depends on that surface

## 12. Acceptance criteria

- [ ] `docs/baseline-mcc-tools.md` committed, containing the full MCC tool surface + sample returns + death baseline
- [ ] `docs/smoke-results.md` committed, all PASS on both 1.8.9 and 1.12.2 (or a documented fail-fast reason)
- [ ] `bot/` complete: `node bot/index.js` runs standalone; `luacheck` clean; README complete
- [ ] Plugin side: autostart/stop/status/reload behave correctly under both `Engine` values; `luacheck Plugins/MCPServer/` has zero warnings
- [ ] End-to-end: the `mcp__mcc__*` tool surface works under the bot engine and aligns with the baseline; death respawn does not fall into the void (or is at the same level as the MCC baseline)
- [ ] Fallback verified: switching back to `Engine=mcc` leaves the MCC path fully usable
- [ ] Commit history is clear (§13) and documentation matches the implementation

## 13. Branch and commit conventions

- Current branch `research/mineflayer-feasibility` (where the research docs live). Start implementation from a new branch `feat/mineflayer-bot`, or continue on the same branch (if there is no parallel work afterwards) — **the implementation session decides; keep a single linear branch**
- Commit message style follows this repo: an imperative English summary line + blank line + body points (see existing `git log`)
- Semantically grouped commits: smoke script and results, bot program, plugin changes, documentation each get their own commit
- `docs/` is confirmed not ignored by `.gitignore`; confirm the ignore rules for `.npmcache` and `node_modules` before committing

---

**Final note**: all architectural decisions are settled and justified (§2); do not reopen them during implementation. The only real uncertainty left is mineflayer × Cuberite's actual compatibility (Phase 0 answers it), so Phase 0 is always the first step.
