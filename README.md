# CuberiteMCPServer

Exposes a Cuberite Minecraft server as an MCP (Model Context Protocol) server
over Streamable HTTP, so LLM hosts can call server tools.

## Bot engine

The plugin manages a test bot with a switchable engine (config.ini):

- `[Engine] Engine = mcc` — legacy **Minecraft Console Client** (85MB binary,
  kept as the fallback path; see `mcc.lua`).
- `[Engine] Engine = mineflayer` — **mineflayer bot** in `bot/` (Node 22,
  stateless MCP endpoint on :33333; see `bot/README.md`).
  `[Bot] NodePath / BotDir / Username / RandomUsername / MinecraftVersion`
  (pinned to 1.8.9 per docs/smoke-results.md) configure it.

Lifecycle commands (console): `mcc <start|stop|restart|status>` and
`bot <start|stop|restart|status>`; same actions exposed as MCP tools
`mcc_*` / `bot_*`.

## Docs

- `docs/handoff-mineflayer-migration.md` — implementation handoff
- `docs/feasibility-mineflayer.md` — feasibility research
- `docs/baseline-mcc-tools.md` — captured MCC tool baseline
- `docs/smoke-results.md` — mineflayer x Cuberite phase-0 gate results
