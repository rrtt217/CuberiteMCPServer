# Feasibility Study: Using mineflayer to Replace the MCC Integration

- Branch: `research/mineflayer-feasibility`
- Date: 2026-08-30
- Subject of research: [PrismarineJS/mineflayer](https://github.com/PrismarineJS/mineflayer)
- Current solution: [Minecraft Console Client (MCC)](https://github.com/MCCTeam/Minecraft-Console-Client)
- **Conclusion: feasible, and migration is recommended**. mineflayer can directly eliminate MCC's three structural pain points (signal handling, corrupted death state, bloated configuration); the protocol layer presents no obstacle for this scenario (1.8–1.12.2 + offline mode); a Cuberite smoke test must be done first (Cuberite has never been officially validated), none of the ready-made MCP wrappers fit, so a thin layer needs to be written ourselves (about 1–2 days of work).

---

## 1. Background and Current State

### 1.1 The Current Three-Layer Pipeline of the MCC Integration (Fact List)

An on-site inspection of this repository and the DSH preset confirms that the "MCC integration" is not one piece of code, but a pipeline spread across three layers:

| Layer | Owner | Current State |
|---|---|---|
| Process lifecycle | **MCPServer plugin** (this repo's Lua) | `mcc.lua`: `StartMCC/StopMCC/RestartMCC/GetMCCStatus` — io.popen spawns the child process, fd-closing wrapper, pid tracking (`/proc/<pid>/cmdline` to prevent killing the wrong process), signal ladder (SIGTERM→SIGHUP→SIGUSR1→SIGKILL), temp ini generation. `main.lua`: autostart (delayed 60 ticks) and `OnDisable` cleanup. `tools.lua`: `mcc_start/stop/restart/status` as the plugin's own MCP tools (:8765). `Info.lua`: the `mcc` console command. |
| bot capabilities + MCP endpoint | **MCC itself** (85MB monolithic binary) | Implements the game client and embeds an MCP server (`http://127.0.0.1:33333/mcp`), enabled by the temp ini written by `mcc.lua` (`[ChatBot.McpServer]`). The plugin's Lua contains **no bot capability implementation and no MCP forwarding** — the plugin is only a process babysitter + config generator. |
| Session bridge (consumer) | **DSH cuberite preset** (`~/.dsh/.agent-presets/cuberite/`) | `mcp-mcc.mjs` (self-healing MCP client): connects to `:33333/mcp`, calls `tools/list` to auto-discover tools and register them as the session's `mcp__mcc__*`. It is a **generic contract** — it only recognizes standard MCP Streamable HTTP endpoints and does not know whether the other side is MCC or something else. The `mcp-cuberite` bridge connects to the plugin's :8765. |

There is also the repository's supporting equipment: `void_guard.lua` (void-fall guard, HOOK_PLAYER_MOVING freeze rescue), and the `[MCC]` section of `config.lua` (Enabled/AutoStart/Path/Username/RandomUsername/ServerPort/MinecraftVersion/McpPort).

### 1.2 MCC Pain Points (Migration Motivation)

1. **Signal handling**: MCC ignores SIGTERM/SIGINT/SIGQUIT, requiring a four-level signal ladder escalating to SIGKILL to stop it reliably (`mcc.lua` `g_StopLadder`).
2. **Corrupted death state**: after the bot dies, the client state is corrupted, triggering a void-fall deadlock where respawn is impossible (it ignores landing); the only cure is restarting the **entire process** with a random username to obtain a new identity (`RandomUsername` + `void_guard.lua` are both symptomatic treatments).
3. **MCP session invalidation**: restarting MCC invalidates the old MCP session, which reports -32001 until reconnection — the preset bridge was forced to be written as self-healing (`mcp-mcc.mjs` detects that error and automatically re-initializes and retries).
4. **Bloated configuration**: dual-track of temp ini + the user's main ini (`mcc_temp.ini` 47KB), with the version specification, BotOwners, TerrainAndMovements and other switches scattered around.
5. **Black-box form**: an 85MB monolithic binary whose behavior cannot be customized and whose problems cannot be fixed inside the process; every workaround lives outside the process.

## 2. Local Environment Verification (measured 2026-08-30)

| Item | Current State | Significance for the Migration |
|---|---|---|
| Node.js | v22.22.3 (nvm) | Satisfies mineflayer 4.38.0's `engines: node>=22` ✅ |
| npm | 10.9.8 available; the sandbox (workspace-write) refuses to write the `~/.npm` cache | Using `--cache <workspace>/` during development/installation bypasses it; unrelated to runtime ✅ |
| mineflayer npm | latest 4.38.0 (released 2026-08-27, time.modified 2026-08-27) | The package exists and is active ✅ |
| Cuberite server | port 25568 (`settings.ini`); version parsed by the server (current config writes 1.12.2) | mineflayer natively supports 1.8–1.12.2 ✅; the actual measurement is what matters |
| MCC itself | `/home/david/Cuberite/MinecraftConsoleClient`, 85MB | kept as fallback (see §6) |
| Plugin config | `config.ini`: MCC Enabled=true, AutoStart=false, RandomUsername=true | The migration switch will follow this file's pattern |

## 3. Research Findings (Summary)

> The full research with all source links was done via online research; here it is compressed by conclusion, with key sources inlined.

### 3.1 Maintenance Status and Version Support ✅

mineflayer is actively maintained: 4.38.0 (released 2026-08-27), 7387 stars, about 225k monthly npm downloads, with a steady release cadence in 2026. The README explicitly supports **Minecraft 1.8 through 1.21.11+** — the old 1.8–1.12.2 versions are its longest-supported path. The `version` option can be omitted (the server version is auto-detected) or explicitly specified. Offline-mode login: `auth: 'offline'` + `username`, no password needed. Sources: [repo](https://github.com/PrismarineJS/mineflayer), [npm registry](https://registry.npmjs.org/mineflayer/latest).

### 3.2 Core Capabilities Cover All Requirements of This Scenario ✅

Per the official [docs/api.md](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md):

| Scenario requirement | mineflayer API |
|---|---|
| Chat and commands | `bot.chat()` (chat and `/` commands share one entry point), `bot.tabComplete()`, chat event |
| Movement | `bot.setControlState()` (forward/back/left/right/jump/sprint/sneak) + official plugin [mineflayer-pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder) |
| View | `bot.lookAt(point)` / `bot.look` / `bot.blockAtCursor` |
| Right-click interaction | `bot.activateBlock()` (doors/containers), `bot.useOn(entity)`, `bot.placeBlock`, `bot.attack` |
| Inventory read/write | `bot.inventory` (Window), `bot.heldItem`, `bot.equip/transfer/moveSlotItem`, `bot.openChest` |
| Entity/block queries | `bot.entity`, `bot.entities` (id→entity map), `bot.blockAt`, `bot.findBlocks`, `bot.canSeeBlock` |
| Damage/death/respawn | `'health'`/`'death'` events; **auto-respawn by default** (createBot option `respawn` defaults to true), manual `bot.respawn()`; `bot.quit(reason)` graceful disconnect |

The only risk point: [issue #3882](https://github.com/PrismarineJS/mineflayer/issues/3882) "Bot freezes after taking any damage" (open; only reported on 1.21.x + 4.37.0) — the same category as MCC's "state corruption after damage", but **there is no such report for the old 1.8–1.12.2 versions**.

### 3.3 Ready-Made MCP Wrappers Do Not Fit; We Must Write Our Own ✅

- The most popular [yuniko-software/minecraft-mcp-server](https://github.com/yuniko-software/minecraft-mcp-server) (712 stars): locked to 1.21.11 and uses stdio → not usable for the old versions + HTTP scenario
- [gerred/mcpmc](https://github.com/gerred/mcpmc): unmaintained for about 2 years since 2024-12, stdio, 55 monthly downloads
- The rest (minecraft-bot-mcp, mcpflow, etc.): monthly downloads <60 or self-described as early prototype

Self-written effort: the mineflayer API maps one-to-one with the requirements; wrap a JSON-RPC layer with `node:http` and expose about 15–20 tools, roughly **300–600 lines, 1–2 working days**; switching to `@modelcontextprotocol/sdk`'s Streamable HTTP adds about 0.5–1 day. "Reconnect with a new identity" can be made into a lightweight API (close the old bot → createBot a new instance), much cleaner than MCC's whole-process restart.

### 3.4 Process Management Hits the Pain Points Squarely ✅

mineflayer is a library, so signal behavior is decided by the Node runtime: the official Node docs state that non-Windows platforms have **default handlers for SIGTERM/SIGINT that exit upon receipt** — directly eliminating MCC's ignoring of SIGTERM, which required the signal ladder escalating to SIGKILL; for a graceful exit, install a listener in the script that calls `bot.quit()` first and then `process.exit()`. A single resident bot is lightweight (CPU is only noticeably consumed with 30+ bots; lowering the view distance helps). Startup readiness is signaled by the `'spawn'` event; the local Cuberite is expected to be in the 1–5 second range (needs measurement, mainly affected by the connection throttle). Source: [Node process docs](https://nodejs.org/api/process.html#signal-events).

### 3.5 Cuberite Compatibility: No Known Bugs, But Never Officially Tested ⚠️

Searching the mineflayer repo for "Cuberite" yields only 1 hit — [PR #463](https://github.com/PrismarineJS/mineflayer/pull/463) (2016, an old report from the mineflayer 1.x era); [node-minecraft-protocol#348](https://github.com/PrismarineJS/node-minecraft-protocol/issues/348) lists Cuberite on a "automated testing against third-party servers" checklist that **is still unchecked to this day**. In other words: no known bugs, but also no guarantees. Cuberite's protocol implementation for 1.8.x–1.12.2 is fairly complete, so the risk is controllable, but **a smoke test must come first** (see §5 Phase 0).

### 3.6 Positioning Comparison ✅

mineflayer describes itself as "Create Minecraft bots with a powerful, stable, and high level JavaScript API" — an event-driven **library** (with a pathfinder/statemachine/prismarine-viewer ecosystem; the fact that all MCP wrappers are based on it is the evidence); MCC describes itself as "Lightweight console for Minecraft chat and automated scripts" — a ready-made **console application** (automation goes through C# ChatBot plugins / its own scripting syntax). For this scenario (headless bot + AI agent + process-level controllability + the need to expose an MCP interface), the library form is clearly a better fit; MCC's pain points stem precisely from the black-box nature of a ready-made application.

## 4. Architecture Layering Decision: Which Layer the Integration Goes Into

It was confirmed earlier that the current state is a three-segment pipeline. **The recommendation is to keep the same layering after the replacement**; the replacement only happens at the "bot itself" layer:

| Layer | Owner | Change After Replacement |
|---|---|---|
| bot itself + MCP endpoint | **This repo** (new `bot/` Node program) | Replaces the MCC binary: the mineflayer bot carries its own MCP HTTP endpoint |
| Process lifecycle | **MCPServer plugin** (kept) | The start command changes from `'"MinecraftConsoleClient" tmpIni'` to `node bot/index.js …`; temp ini generation changes to a bot config file; the signal ladder can be simplified |
| Session bridge | **preset** (untouched) | `mcp-mcc.mjs` only recognizes standard MCP endpoints — if the bot keeps port 33333 there are **zero changes**, otherwise change one URL line |

**Rationale**:

- **The bot code must live in this repo**: (a) the bot process is a global resource that follows the server, so its lifecycle must be managed on the server side — when switching sessions/preset mounts, the bot must not be left unattended; that is exactly why the current `mcc_start` goes through the plugin's MCP tools; (b) `~/.dsh/` is not under the repository's version control, and bot logic is a project feature that must be versioned; (c) changing the preset affects all sessions that mount that preset.
- **Lifecycle management stays in the plugin layer**: the bot sharing Cuberite's lifecycle (the plugin's `OnDisable` stops the bot; autostart follows the server startup) is a natural responsibility of the plugin layer; `mcc.lua` already has mature pid tracking and an fd-closing wrapper (preventing orphan processes from holding the port) — reuse them directly; only the signal ladder can be greatly simplified thanks to Node's default behavior.
- **The preset bridge stays untouched**: `mcp-mcc.mjs`'s self-healing logic (automatic re-initialize on -32001) can be kept as insurance; if the mineflayer session is clean (no identity-change respawn), this path basically never triggers.

## 5. Draft Migration Plan

- **Phase 0 — smoke validation (first; ~100 lines)**: a standalone script connects to `127.0.0.1:25568` and validates, for 1.8.9 / 1.12.2: offline login (`auth:'offline'`), `spawn` readiness, chat round-trip (chat + listening), `setControlState` movement + position reporting, `activateBlock` right-click, taking damage → `'death'` → auto-respawn (key validation: **does not trigger void fall**), and the default SIGTERM behavior. Stop the loss at any failing step; MCC keeps serving.
- **Phase 1 — bot program + MCP endpoint (1–2 days)**: `bot/index.js` (mineflayer connection and lifecycle) + `bot/mcp.js` (HTTP JSON-RPC, about 15–20 tools: chat/command/move/look/interact/inventory/entities/health/respawn/rebuild…). Tool naming and semantics align with the MCC endpoint, so the downstream `mcp__mcc__*` tool surface switches over seamlessly. Port stays 33333. Also includes a `rebuild` API (close the old bot → new instance, replacing "restarting the whole process with a new identity").
- **Phase 2 — plugin-side changes**: `mcc.lua` → `bot.lua` (start command, temporary config rewrite, signal ladder simplified to SIGTERM + fallback SIGKILL); `config.lua`'s `[MCC]` section → `[Bot]` section (add the `Engine = mcc | mineflayer` switch, keeping mcc as the default until the smoke test passes); `tools.lua`/`Info.lua` description updates; `void_guard.lua` kept for observation (default off if mineflayer does not trigger void fall).
- **Phase 3 — wrap-up**: confirm zero changes to the preset bridge (or change one port line); documentation updates; switch `config.ini` to `Engine=mineflayer` and observe; MCC kept as a fallback switch.

## 6. Risks and Mitigations

| Risk | Level | Mitigation |
|---|---|---|
| Cuberite has never been tested by mineflayer officially (nmp#348 unchecked) | Medium | Phase 0 smoke test first; stop the loss at any failing step, lossless MCC fallback (`Engine` switch) |
| Issue #3882 freeze after taking damage | Low | Only reported on 1.21.x; this scenario is 1.8–1.12.2; Phase 0 specifically validates the death/respawn path; `void_guard.lua` as safety net |
| mineflayer 4.38.0 requires Node ≥ 22 | Low | The local v22.22.3 already satisfies it; document the prerequisite |
| Deployment depends on node_modules | Low | `bot/` carries its own `package.json` + commit or install instructions; the plugin start command does a dependency-existence check |
| MCP session invalidation (when restarting the bot) | Low | Port unchanged + the preset self-healing bridge as safety net; keep the endpoint available while the bot restarts |
| Incidental benefit: `mcp-mcc.mjs`'s self-healing logic goes idle | — | Kept as insurance, no maintenance cost |

## 7. Conclusion

1. **No obstacles at the protocol layer**: mineflayer natively covers 1.8–1.12.2 and offline login, the capability list fully covers all requirements of this scenario, and all of them are first-class APIs.
2. **Every pain point is addressed**: Node's default signal behavior, a clean death/respawn state machine, and in-process controllability in library form directly eliminate MCC's four workarounds: the signal ladder, the void-fall identity-change restart, session self-healing, and bloated configuration.
3. **Cost is controllable**: writing the MCP layer takes about 1–2 days; the plugin/preset change surface is small (the three-layer layering is kept; zero preset changes).
4. **Risk is bounded**: the only substantive unknown is Cuberite compatibility (not officially tested); the smoke script first + the `Engine` switch fallback make the failure cost nearly zero.

**Recommendation**: proceed per §5, with Phase 0 smoke validation as the first step; keep MCC as the fallback.
