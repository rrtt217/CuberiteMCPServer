# CuberiteMCPServer

Exposes a Cuberite Minecraft server as an MCP (Model Context Protocol) server
over Streamable HTTP, so LLM hosts can call server tools.

## Configuration

Everything lives in one file, `config.ini` (auto-generated with defaults on first
run; machine-specific, so it is gitignored — `settings.ini` was consolidated
into it):

- `[Network] Port` / `[Security] AllowedIPPrefixes` — MCP HTTP endpoint
- `[Engine] Engine` — `mineflayer` (default) | `mcc` (deprecated fallback)
- `[Bot]` — mineflayer bot. `NodePath` may be empty (= `node` on PATH),
  or a path; `BotDir` defaults to `bot` (relative to the plugin folder).
  Relative paths are resolved against the plugin folder at load time
  (the server launches the bot via `os.execute` from the server CWD, which cannot
  resolve plugin-relative paths itself).
- `[MCC]` — deprecated fallback engine, `Enabled` defaults to `false`
- `[VoidGuard]` — void-fall guard, `Enabled` defaults to `false`
  (the mineflayer engine respawns cleanly and never falls into the void; only
  enable it for the legacy MCC engine or buggy terrain).

## Bot engine

The plugin manages a test bot with a switchable engine (config.ini):

- `[Engine] Engine = mineflayer` — **default**. Mineflayer bot in `bot/`
  (Node 22, stateless MCP endpoint on :33333; see `bot/README.md`).
  Config via `[Bot] NodePath / BotDir / Username / RandomUsername / MinecraftVersion`
  (default 1.12.2 — Cuberite's protocol ceiling; requires the prismarine-chunk
  patch applied by `npm install`; see docs/version-compat-matrix.md).
- `[Engine] Engine = mcc` — **DEPRECATED** legacy **Minecraft Console Client**
  (85MB binary), kept only as a manual fallback (`mcc.lua`).

Lifecycle commands (console): `bot <start|stop|restart|status>` and
`mcc <start|stop|restart|status>` (deprecated); same actions exposed as
MCP tools `bot_*` / `mcc_*`.

## Docs

- `docs/version-compat-matrix.md` — protocol versions vs Cuberite + the prismarine-chunk patch
- `docs/handoff-mineflayer-migration.md` — implementation handoff
- `docs/feasibility-mineflayer.md` — feasibility research
- `docs/baseline-mcc-tools.md` — captured MCC tool baseline
- `docs/smoke-results.md` — mineflayer x Cuberite phase-0 gate results
