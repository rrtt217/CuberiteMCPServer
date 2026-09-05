'use strict'
// bot/tools.js — MCP tool registry.
//
// Tool NAMES mirror the MCC baseline (docs/baseline-mcc-tools.md, all mcc_*)
// because the harness bridge registers every tools/list entry as
// mcp__mcc__<name> — keeping the downstream tool surface unchanged.
// Return text: JSON string { success:true, data:{...} } | { success:false,
// errorCode:"..." }, matching the MCC result shape.
// Extra beyond baseline: mcc_rebuild (new bot instance), ping (fail-safe so
// tools/list never returns an empty array).

const chatActions = require('./actions/chat')
const moveActions = require('./actions/move')
const interactActions = require('./actions/interact')
const inventoryActions = require('./actions/inventory')
const worldActions = require('./actions/world')

function ok(data) { return { text: JSON.stringify({ success: true, data: data }) } }
function fail(errorCode, data) {
  const o = { success: false, errorCode }
  if (data !== undefined) o.data = data
  return { text: JSON.stringify(o) }
}
const int = (v, def) => (Number.isFinite(Number(v)) ? Number(v) : def)

function buildRegistry(botCtl) {
  const chat = chatActions(botCtl)
  const move = moveActions(botCtl)
  const interact = interactActions(botCtl)
  const inv = inventoryActions(botCtl)
  const world = worldActions(botCtl)

  const tools = [
    { name: 'ping', description: 'Reachability probe; always available even when the bot is offline.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => ok({ pong: true, state: botCtl.state }) },

    { name: 'mcc_session_status',
      description: 'Get current bot session and connection status.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => { const s = botCtl.status(); return ok({ ...s }) } },

    { name: 'mcc_server_info',
      description: 'Get active connection info and host/port.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => { const s = botCtl.status(); return ok({ host: s.host, port: s.port, version: s.version, state: s.state }) } },

    { name: 'mcc_player_state',
      description: 'Get current controlled player state.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => { const s = botCtl.status(); return ok({ username: s.username, health: s.health, food: s.food,
        gamemode: s.gamemode !== undefined ? s.gamemode : 0, currentSlot: s.held_item, yaw: s.yaw, pitch: s.pitch,
        location: s.position, version: s.version }) } },

    { name: 'mcc_player_stats',
      description: 'Get current controlled player stats, orientation, and location.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => { const s = botCtl.status(); return ok({ username: s.username, health: s.health, food: s.food,
        level: s.level || 0, totalExperience: s.experience || 0, gamemode: 0, currentSlot: s.held_item,
        yaw: s.yaw || 0, pitch: s.pitch || 0, location: s.position }) } },

    { name: 'mcc_world_state',
      description: 'Get current world state: time, dimension, position, loaded chunk count.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => world.worldState() },

    { name: 'mcc_send_chat',
      description: 'Send chat text or slash-command to the connected Minecraft server.',
      inputSchema: { type: 'object', properties: { text: { type: 'string', description: 'Text to send to server chat.' } }, required: ['text'] },
      handler: (a) => { const r = chat.sendChat(a.text); return r.success ? ok({}) : r } },

    { name: 'mcc_chat_history',
      description: 'Return the recent chat message buffer (chat + server messages).',
      inputSchema: { type: 'object', properties: { limit: { type: 'integer', default: 50 } }, required: [] },
      handler: (a) => chat.chatHistory(int(a.limit, 50)) },

    { name: 'mcc_look_at',
      description: 'Rotate the player view toward world coordinates.',
      inputSchema: { type: 'object', properties: { x: { type: 'number' }, y: { type: 'number' }, z: { type: 'number' } }, required: ['x', 'y', 'z'] },
      handler: (a) => move.lookAt(a.x, a.y, a.z).then((r) => (r.success ? ok(r.data) : r)) },

    { name: 'mcc_look_direction',
      description: 'Set the player view yaw/pitch directly (degrees).',
      inputSchema: { type: 'object', properties: { yaw: { type: 'number' }, pitch: { type: 'number' } }, required: ['yaw', 'pitch'] },
      handler: (a) => move.lookDirection(a.yaw, a.pitch).then((r) => (r.success ? ok(r.data) : r)) },

    { name: 'mcc_toggle_sprint',
      description: 'Start or stop sprinting.',
      inputSchema: { type: 'object', properties: { enabled: { type: 'boolean' } }, required: ['enabled'] },
      handler: (a) => move.toggleSprint(a.enabled) },

    { name: 'mcc_toggle_sneak',
      description: 'Start or stop sneaking.',
      inputSchema: { type: 'object', properties: { enabled: { type: 'boolean' } }, required: ['enabled'] },
      handler: (a) => move.toggleSneak(a.enabled) },

    { name: 'mcc_change_hotbar_slot',
      description: 'Change active hotbar slot (1-9).',
      inputSchema: { type: 'object', properties: { slot: { type: 'integer' } }, required: ['slot'] },
      handler: (a) => inv.changeHotbarSlot(a.slot).then((r) => (r.success ? ok(r.data) : r)) },

    { name: 'mcc_move_to',
      description: 'Walk toward a target world coordinate (control-based movement).',
      inputSchema: { type: 'object', properties: { x: { type: 'number' }, y: { type: 'number' }, z: { type: 'number' },
        timeoutMs: { type: 'integer', default: 0 } }, required: ['x', 'y', 'z'] },
      handler: (a) => move.moveTo(a.x, a.y, a.z).then((r) => (r.success ? r : r)) },

    { name: 'mcc_respawn',
      description: 'Send the respawn packet when the controlled player is dead.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => {
        const b = botCtl.bot
        if (botCtl.state !== 'online' || !b) return fail('bot_offline')
        if (b.health && b.health > 0) return fail('invalid_state', { health: b.health })
        try { b.respawn() } catch (e) { return fail('respawn_failed', { error: e.message }) }
        return ok({ respawned: true })
      } },

    { name: 'mcc_inventory_snapshot',
      description: 'List the player inventory contents.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => inv.snapshot() },

    { name: 'mcc_inventory_search',
      description: 'Search the player inventory by item name/type.',
      inputSchema: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'integer', default: 100 } }, required: ['query'] },
      handler: (a) => inv.search(a.query, int(a.limit, 100)) },

    { name: 'mcc_select_item',
      description: 'Select an item by type into the hand without rearranging inventory.',
      inputSchema: { type: 'object', properties: { itemType: { type: 'string' }, preferLowestSlot: { type: 'boolean', default: true } }, required: ['itemType'] },
      handler: (a) => inv.selectItem(a.itemType).then((r) => (r.success ? ok(r.data) : r)) },

    { name: 'mcc_entities_query',
      description: 'Query tracked entities near the bot.',
      inputSchema: { type: 'object', properties: { maxCount: { type: 'integer', default: 50 }, typeFilter: { type: ['string', 'null'], default: null }, radius: { type: 'number', default: 0 } }, required: [] },
      handler: (a) => world.entitiesQuery(int(a.maxCount, 50), a.typeFilter || null, int(a.radius, 0)) },

    { name: 'mcc_world_block_at',
      description: 'Get the block at world coordinates (block data available on 1.8.9).',
      inputSchema: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' }, z: { type: 'integer' } }, required: ['x', 'y', 'z'] },
      handler: (a) => world.blockAt(a.x, a.y, a.z) },

    { name: 'mcc_raycast_block',
      description: 'Raycast from the player view and return the first non-air block hit.',
      inputSchema: { type: 'object', properties: { maxDistance: { type: 'number', default: 8 } }, required: [] },
      handler: (a) => world.raycast(int(a.maxDistance, 8)) },

    { name: 'mcc_player_nearby',
      description: 'Check whether any (or a specific) player is nearby.',
      inputSchema: { type: 'object', properties: { playerName: { type: ['string', 'null'], default: null }, radius: { type: 'number', default: 32 } }, required: [] },
      handler: (a) => world.playerNearby(a.playerName || null, int(a.radius, 32)) },

    { name: 'mcc_activate_block',
      description: 'Right-click/activate a block (doors, chests, buttons...).',
      inputSchema: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' }, z: { type: 'integer' } }, required: ['x', 'y', 'z'] },
      handler: (a) => interact.activateBlock(a.x, a.y, a.z).then((r) => (r.success ? ok(r.data) : r)) },

    { name: 'mcc_entity_attack',
      description: 'Attack a tracked entity explicitly.',
      inputSchema: { type: 'object', properties: { entityId: { type: 'integer' } }, required: ['entityId'] },
      handler: (a) => interact.attackEntity(a.entityId).then((r) => (r.success ? ok(r.data) : r)) },

    { name: 'mcc_dig_block',
      description: 'Dig (mine) a block at world coordinates.',
      inputSchema: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' }, z: { type: 'integer' } }, required: ['x', 'y', 'z'] },
      handler: (a) => interact.digBlock(a.x, a.y, a.z).then((r) => (r.success ? ok(r.data) : r)) },

    { name: 'mcc_rebuild',
      description: 'Destroy the current bot instance and create a fresh one (optional new username).',
      inputSchema: { type: 'object', properties: { newUsername: { type: ['string', 'null'], default: null }, randomUsername: { type: ['boolean', 'null'], default: null } }, required: [] },
      handler: (a) => { const r = botCtl.rebuild({ username: a.newUsername || undefined, randomUsername: a.randomUsername === null ? undefined : !!a.randomUsername }); return ok(r.data) } },

    { name: 'mcc_quit_client',
      description: 'Quit the bot process cleanly.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      handler: () => { setTimeout(() => { botCtl.stop('quit'); process.exit(0) }, 100); return ok({ quitting: true }) } },
  ]

  const byName = new Map(tools.map((t) => [t.name, t]))
  return {
    list: () => tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
    get: (name) => byName.get(name),
  }
}

module.exports = { buildRegistry }
