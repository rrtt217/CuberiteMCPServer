# mcpserver-bot

Mineflayer bot with a stateless HTTP JSON-RPC (MCP) endpoint, replacing the
Minecraft Console Client (MCC) for the MCPServer plugin. See
`docs/handoff-mineflayer-migration.md` for the migration context.

## Run

```
npm install          # installs mineflayer (Node >= 22)
node index.js        # defaults: connect 127.0.0.1:25568 as offline 1.8.9, MCP on :33333
node index.js --config bot.ini
```

Config precedence: CLI `--config <file>` > environment `MCPS_BOT_*` > defaults.

| key (bot.ini `[Bot]` section) | default | meaning |
|---|---|---|
| host | 127.0.0.1 | server host |
| port | 25568 | server port |
| username | TestBot | base username |
| randomUsername | true | append random suffix |
| version | 1.8.9 | protocol version; pinned by Phase 0 (Cuberite chunk data broken at 1.9+) |
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
Inventory: `mcc_inventory_snapshot`, `mcc_inventory_search`, `mcc_select_item`
EntityWorld: `mcc_entities_query`, `mcc_world_block_at`, `mcc_raycast_block`,
`mcc_player_nearby`, `mcc_activate_block`, `mcc_entity_attack`, `mcc_dig_block`,
`mcc_place_block`
Lifecycle: `mcc_rebuild` (new bot instance, optional new username), `mcc_quit_client`

## Differences vs MCC (documented)

- Death → auto respawn with a clean state machine; no "corrupt client / void"
  restart dance. `mcc_rebuild` is the explicit fresh-instance escape hatch.
- Version pinned to 1.8.9 because Cuberite's 1.9+ chunk data is unparseable by
  prismarine-chunk (see docs/smoke-results.md §4). Cuberite serves multiple
  protocol versions per client, so MCC can keep using 1.12.2.
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
lists its slots (container section then player section), `mcc_container_deposit_item` /
`mcc_container_withdraw_item` move items, `mcc_inventory_window_action` is the low-level
click, `mcc_container_close` closes.

Note: Cuberite processes window clicks and broadcasts slot updates but never sends the
Confirm Transaction (0x33) response on 1.8; the bot self-confirms locally
(`window.requiresConfirmation = false`), so window operations are fast and non-blocking.
Give items to the bot BEFORE opening a window (server-side gives mid-window don't refresh
the open window's player section).
