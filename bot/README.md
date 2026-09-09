# mcpserver-bot

Mineflayer bot with a stateless HTTP JSON-RPC (MCP) endpoint, replacing the Minecraft Console Client (MCC) for the MCPServer plugin. See docs/handoff-mineflayer-migration.md for the migration context.
> This file is bilingual (Chinese + English).

## Run

```
npm install          # install mineflayer + postinstall auto-applies patches
node index.js        # connects to 127.0.0.1:25568 by default, offline 1.12.2, MCP on :33333
node index.js --config bot.ini
```

Config precedence: CLI --config <file> > env vars MCPS_BOT_* > defaults.

| key (bot.ini [Bot] section) | default | meaning |
|---|---|---|
| host | 127.0.0.1 | server host |
| port | 25568 | server port |
| username | TestBot | base username |
| randomUsername | true | append random suffix |
| version | 1.12.2 | protocol version; 1.9-1.12.2 all usable after the prismarine-chunk patch (see below) |
| mcpBind | 127.0.0.1 | MCP bind address |
| mcpPort | 33333 | MCP port (kept in sync with the harness bridge) |

## MCP endpoint

- POST http://127.0.0.1:33333/mcp, pure JSON responses (the bridge JSON.parses directly, never using the SSE framework, unlike MCC).
- **Stateless**: no session id. Restarting the bot invalidates nothing on the client.
- Methods: initialize, notifications/initialized, tools/list, tools/call, ping.
- Tool names keep the mcc_* prefix; the bridge exposes them as mcp__mcc__* (identical downstream surface to MCC).

## Tools

Baseline: see docs/baseline-mcc-tools.md (MCC surface mirror). All 42 tools:

SessionStatus: `ping`, `mcc_session_status`, `mcc_server_info`, `mcc_player_state`, `mcc_player_stats`, `mcc_world_state`
ChatAndCommands: `mcc_send_chat`, `mcc_chat_history`
Windows/GUI: `mcc_container_open_at`, `mcc_window_slots`, `mcc_container_deposit_item`, `mcc_container_withdraw_item`, `mcc_inventory_window_action`, `mcc_container_close`
Movement: `mcc_look_at`, `mcc_look_direction`, `mcc_toggle_sprint`, `mcc_toggle_sneak`, `mcc_change_hotbar_slot`, `mcc_move_to` (goalType: near|xz|block|face|any, mode: scout|walk), `mcc_can_reach`, `mcc_path_status`, `mcc_stop_movement`, `mcc_respawn`
(Note: mcc_toggle_sneak / mcc_toggle_sprint are not toggles — you must pass enabled: true|false explicitly; an empty object is rejected with invalid_args.)
Inventory: `mcc_inventory_snapshot`, `mcc_inventory_search`, `mcc_select_item`
EntityWorld: `mcc_entities_query`, `mcc_world_block_at`, `mcc_raycast_block`, `mcc_player_nearby`, `mcc_activate_block`, `mcc_entity_attack`, `mcc_entity_interact` (right-click/use on a tracked entity — e.g. opening a villager trade window), `mcc_dig_block`, `mcc_use_item`, `mcc_hold_use`, `mcc_hold_left`, `mcc_place_block`
Crafting: `mcc_craft` (itemType/count/table)
Collection: `mcc_collect_drops` (collectblock engine + legacy fallback)
Lifecycle: `mcc_rebuild` (new bot instance, optional new username), `mcc_quit_client`

### Interaction semantics (right-click / long-press)

- `mcc_use_item`: a single right-click. No target = use the held item (activateItem: eat/throw/fish/draw bow/bucket...); x,y,z = activate a block; entityId = right-click an entity.
- `mcc_hold_use`: long-press right-click. Item mode = **press/release**: action=start (press activateItem) / stop (release deactivateItem) / toggle (flip), durationMs auto-releases (draw bow, release arrow); against entities/blocks it is a vanilla-style right-click every 250ms (feeding / repeated clicks). In 1.12 "use" is a stateful action, not a repeated clicker.
- `mcc_hold_left`: long-press left-click. entityId = keep attacking until death/disappear/timeout; x,y,z only = dig a single block; with dx,dy,dz+count = dig a tunnel forwards one block at a time (strip-mine/stairs), bounded by durationMs.

### Crafting

- `mcc_craft(itemType, count?, table?)`: uses mineflayer recipes directly (the postinstall minecraft-data patch regenerated all 1.12.2 recipes: 6 plank variants, boats, stairs, fences, etc.). table={x,y,z} for 3x3 recipes (automatically opens/closes the crafting table).
- The pattern must be placed exactly (historical gotcha: sticks arranged in the left column instead of the middle column meant no pickaxe could ever be crafted).
- **A crafting table is a crafting table, not a container**: deposit/withdraw against a 46-slot crafting table window returns not_a_container.

### Collection

- `mcc_collect_drops(radius?, maxItems?, timeoutMs?)`: prefers the mineflayer-collectblock engine (per-item pathfind by distance + wait for pickup, with wall-clock timeout + cancel), falling back to a legacy waypoint loop if it fails to load. The result reports engine=collectblock|legacy.
- Drops despawn after 5 minutes; the radius is centered on the bot; drops unreachable at pit bottoms / inside canopies cannot be collected by either engine (terrain limitation).

## prismarine-chunk patch (required for 1.9+)

Cuberite always sends 1.9-1.12 chunks with the 13-bit *global* palette; a prismarine-chunk loader bug sized the block-data BitArray from maxBitsPerBlock (12) instead of the wire depth (13), so every later read desynced (varint is too big, blockAt all-air, bot falls through the ground).

- Fix: patches/prismarine-chunk+1.41.0.patch (one line + comment) — bitsPerValue: bitsPerBlock in src/pc/1.9/ChunkColumn.js.
- Applied automatically by npm install via postinstall: patch-package. A fresh checkout must run npm install (or npx patch-package) before first run.
- To regenerate after a prismarine-chunk upgrade: cd bot && npm_config_cache=<workspace>/.npmcache npx patch-package prismarine-chunk.
- Full byte-level analysis: docs/version-compat-matrix.md.

## Differences vs MCC (documented)

- Death → a clean respawn state machine; no more "corrupt client / void" restart dance. mcc_rebuild is the explicit fresh-instance escape hatch.
- Version 1.12.2 (Cuberite protocol ceiling). 1.9-1.12.2 chunk parsing depends on the prismarine-chunk patch above.
- Signal handling: SIGTERM/SIGINT graceful exit (Node default), no signal ladder needed.
- Other node_modules patches (all in patches/, applied via postinstall): mineflayer=clickWindow self-confirmation + 80ms settlement (Cuberite never replies 0x33); minecraft-data=regenerated 1.12.2 recipes; mineflayer-collectblock=Targets.getClosest null-safety.

## Smoke

node smoke.js 1.8.9 runs the Phase 0 gate (see docs/smoke-results.md).

## Placing & digging

`mcc_place_block` (x/y/z + face: auto|down|up|north|south|west|east) puts the held item onto the target cell; `mcc_dig_block` digs one. A few constraints to know:

- **Spawn protection**: the Core plugin refuses non-OP block changes within the protection radius (core.spawnprotect.bypass). The bot is in the default group, so it can only place/dig outside the radius.
- **Self-collision**: the server refuses to place in the cell occupied by the bot's body; the tool pre-checks and returns a clear error.
- `mcc_dig_block` auto-equips the best pickaxe/axe/shovel before digging (picking up drops silently swaps the held item for the dropped block → hand-speed mining).

## GUI / container windows

`mcc_container_open_at` opens any container block (chest/furnace/crafting table/hopper/dispenser...); subsequent tools act on the opened window: `mcc_window_slots` lists the slots (container section + player section) and the real window type (windowType, e.g. minecraft:chest / minecraft:villager / minecraft:crafting_table); `mcc_container_deposit_item` / `mcc_container_withdraw_item` move items; `mcc_inventory_window_action` is the low-level click; `mcc_container_close` closes.

Note: mineflayer 4.38's openContainer only recognizes 1.13+ names; crafting_table/furnace etc. go through activateBlock+windowOpen inside the tools. Cuberite handles window clicks and broadcasts slot updates, but never replies to Confirm Transaction (0x33) on 1.8; the bot self-confirms locally (window.requiresConfirmation=false), so window operations are fast and non-blocking. **Give the bot items before opening a window** (items granted server-side while a window is open do not refresh the already-open window's player section).
