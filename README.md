# CuberiteMCPServer

Exposes a Cuberite Minecraft server as an MCP (Model Context Protocol) server over Streamable HTTP, so LLM hosts can call server tools.
> All documentation in this repo is bilingual (Chinese + English).

## Configuration

Everything lives in one file, config.ini (auto-generated with defaults on first run; machine-specific, so it is gitignored):

- [Network] Port / [Security] AllowedIPPrefixes — MCP HTTP endpoint
- [Engine] Engine — mineflayer (default) | mcc (deprecated fallback)
- [Bot] — mineflayer bot. NodePath may be empty (= node on PATH) or a path; BotDir defaults to bot (relative to the plugin folder). Relative paths are resolved against the plugin folder at load time.
- [MCC] — deprecated fallback engine, Enabled defaults to false
- [VoidGuard] — void-fall guard, Enabled defaults to false (the mineflayer engine respawns cleanly and does not fall into the void; only needed for the legacy MCC engine or unusual terrain).

## Bot engine

The plugin manages a test bot with a switchable engine (config.ini):

- [Engine] Engine = mineflayer — **default**. The mineflayer bot in bot/ (Node 22, stateless MCP endpoint :33333; see bot/README.md). Configured via [Bot] NodePath / BotDir / Username / RandomUsername / MinecraftVersion (default 1.12.2 — Cuberite's protocol cap; requires npm install to apply the prismarine-chunk patch; see docs/version-compat-matrix.md).
- [Engine] Engine = mcc — **DEPRECATED** legacy Minecraft Console Client (85MB binary), kept only as a manual fallback (mcc.lua).

Lifecycle commands (console): bot <start|stop|restart|status> and mcc <start|stop|restart|status> (deprecated); same actions exposed as MCP tools.

## Docs

Chinese versions of every doc live in the matching `*.zh.md` file (e.g. this README → `README.zh.md`).

- AGENTS.md — dev guide for AI agents (read this first)
- bot/README.md — bot architecture + full mcc_* tool index
- docs/version-compat-matrix.md — protocol versions vs Cuberite + the patch
- docs/handoff-mineflayer-migration.md — implementation handoff
- docs/feasibility-mineflayer.md — feasibility research
- docs/baseline-mcc-tools.md — captured MCC tool baseline
- docs/smoke-results.md — gate results
