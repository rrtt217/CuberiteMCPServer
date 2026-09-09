# mcpserver-bot

Mineflayer bot with a stateless HTTP JSON-RPC (MCP) endpoint, replacing the
Minecraft Console Client (MCC) for the MCPServer plugin. See
`docs/handoff-mineflayer-migration.md` for the migration context.

## Run

```
npm install          # installs mineflayer + applies the prismarine-chunk patch (postinstall)
node index.js        # defaults: connect 127.0.0.1:25568 as offline 1.12.2, MCP on :33333
node index.js --config bot.ini
```

Config precedence: CLI `--config <file>` > environment `MCPS_BOT_*` > defaults.

| key (bot.ini `[Bot]` section) | default | meaning |
|---|---|---|
| host | 127.0.0.1 | server host |
| port | 25568 | server port |
| username | TestBot | base username |
| randomUsername | true | append random suffix |
| version | 1.12.2 | protocol version; 1.9-1.12.2 all work *after* the prismarine-chunk patch (see below) |
| mcpBind | 127.0.0.1 | MCP bind address |
| mcpPort | 33333 | MCP port (kept to match the harness bridge) |

## MCP endpoint

- `POST http://127.0.0.1:33333/mcp`, plain-JSON responses (the bridge does
  `JSON.parse` directly — never SSE framing, unlike MCC).
- **Stateless**: no session ids, ever. Restarting the bot never invalidates
  anything on the client side.
- Methods: `initialize`, `notifications/initialized`, `tools/list`,
  `tools/call`, `ping`.
- Tool names keep the `mcc_*` prefix so the harness bridge still exposes them
  as `mcp__mcc__*` (downstream surface unchanged vs. MCC).

## Tools

See `docs/baseline-mcc-tools.md` for the MCC surface this mirrors.

SessionStatus: `ping`, `mcc_session_status`, `mcc_server_info`,
`mcc_player_state`, `mcc_player_stats`, `mcc_world_state`
ChatAndCommands: `mcc_send_chat`, `mcc_chat_history`
Windows/GUI: `mcc_container_open_at`, `mcc_window_slots`, `mcc_container_deposit_item`,
`mcc_container_withdraw_item`, `mcc_inventory_window_action`, `mcc_container_close`
Movement: `mcc_look_at`, `mcc_look_direction`, `mcc_toggle_sprint`,
`mcc_toggle_sneak`, `mcc_change_hotbar_slot`, `mcc_move_to`, `mcc_respawn`
(note: `mcc_toggle_sneak` / `mcc_toggle_sprint` are NOT toggles — always pass
`enabled: true|false` explicitly; an empty object is rejected as `invalid_args`)
Inventory: `mcc_inventory_snapshot`, `mcc_inventory_search`, `mcc_select_item`
EntityWorld: `mcc_entities_query`, `mcc_world_block_at`, `mcc_raycast_block`,
`mcc_player_nearby`, `mcc_activate_block`, `mcc_entity_attack`, `mcc_entity_interact`
(right-click / use a tracked entity — e.g. opens a villager's trade window),
`mcc_dig_block`, `mcc_place_block`
Lifecycle: `mcc_rebuild` (new bot instance, optional new username), `mcc_quit_client`

## prismarine-chunk patch (required for 1.9+)

Cuberite always sends 1.9-1.12 chunks with the 13-bit *global* palette; a
prismarine-chunk loader bug sized the block-data BitArray from
`maxBitsPerBlock` (12, derived from minecraft-data's maxStateId=4095) instead
of the wire depth (13), so `BitArray.readBuffer(size=1664, data.length=1536)`
returned without consuming the block data and every later read desynced
(`varint is too big`, blockAt all-air, bot falls through the ground).

- Fix: `patches/prismarine-chunk+1.41.0.patch` (one line +
  comment) — `bitsPerValue: bitsPerBlock` in `src/pc/1.9/ChunkColumn.js`.
- Applied automatically by `npm install` via the `postinstall: patch-package`
  script. Running the bot from a fresh checkout requires running `npm install`
  once (or `npx patch-package`).
- Regenerate after a prismarine-chunk upgrade:
  `cd bot && npm_config_cache=<workspace>/.npmcache npx patch-package prismarine-chunk`.
- Full byte-level analysis: docs/version-compat-matrix.md.

## Differences vs MCC (documented)

- Death → auto respawn with a clean state machine; no "corrupt client / void"
  restart dance. `mcc_rebuild` is the explicit fresh-instance escape hatch.
- Version is 1.12.2 (Cuberite's protocol ceiling). 1.9-1.12.2 chunk parsing
  required patching prismarine-chunk (see below); before the patch, 1.9+ chunk
  data desynced ("varint is too big") and blockAt returned air everywhere.
- Signal handling: SIGTERM/SIGINT quit gracefully (Node default), no signal
  ladder needed.

## Smoke

`node smoke.js 1.8.9` runs the Phase 0 gate (see docs/smoke-results.md).
## Placing & digging

`mcc_place_block` (`x/y/z` + optional `face`: auto|down|up|north|south|west|east) places the
held item at the target; `mcc_dig_block` digs one. Two server-side constraints to know:

- **Spawn protection**: the Core plugin denies block modifications within its
  spawn-protect radius for non-OP players (`core.spawnprotect.bypass`). The bot
  is in the default group, so place/dig only work outside that radius.
- **Self-collision**: the server refuses to place a block where the bot's own
  body stands; the tool pre-checks this and returns a clear error.
## GUI / container windows

`mcc_container_open_at` opens any container block (chest, furnace, crafting table, hopper,
dispenser, ...) and subsequent tools operate on the opened window: `mcc_window_slots`
lists its slots (container section then player section) plus the real window type
(`windowType`, e.g. `minecraft:chest` / `minecraft:villager` / `minecraft:crafting_table`),
`mcc_container_deposit_item` /
`mcc_container_withdraw_item` move items, `mcc_inventory_window_action` is the low-level
click, `mcc_container_close` closes.

Note: Cuberite processes window clicks and broadcasts slot updates but never sends the
Confirm Transaction (0x33) response on 1.8; the bot self-confirms locally
(`window.requiresConfirmation = false`), so window operations are fast and non-blocking.
Give items to the bot BEFORE opening a window (server-side gives mid-window don't refresh
the open window's player section).
