'use strict'
// bot/actions/world.js — entity / block / world reads

module.exports = function worldActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }
  function entityToObj(e) {
    if (!e) return null
    return {
      id: e.id,
      type: e.name || e.kind || 'unknown',
      name: e.username || e.displayName || e.name || null,
      position: e.position ? { x: e.position.x, y: e.position.y, z: e.position.z } : null,
      health: e.health,
      kind: e.kind,
    }
  }
  return {
    entitiesQuery(maxCount, typeFilter, radius) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const pos = botCtl.pos()
      let list = Object.values(b.entities || {}).map(entityToObj)
      if (radius && radius > 0 && pos) {
        list = list.filter((e) => e.position && Math.hypot(e.position.x - pos.x, e.position.y - pos.y, e.position.z - pos.z) <= radius)
      }
      if (typeFilter) {
        const q = String(typeFilter).toLowerCase()
        list = list.filter((e) => e.type && e.type.toLowerCase().includes(q))
      }
      list.sort((a, b2) => {
        if (!pos || !a.position || !b2.position) return 0
        return Math.hypot(a.position.x - pos.x, a.position.y - pos.y, a.position.z - pos.z) -
               Math.hypot(b2.position.x - pos.x, b2.position.y - pos.y, b2.position.z - pos.z)
      })
      const limit = Math.max(1, (maxCount || 50))
      return { success: true, data: { count: list.length, entities: list.slice(0, limit) } }
    },
    blockAt(x, y, z) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const blk = b.blockAt({ x: Math.floor(x), y: Math.floor(y), z: Math.floor(z) })
      return { success: true, data: { x: Math.floor(x), y: Math.floor(y), z: Math.floor(z),
        name: blk ? blk.name : null, type: blk ? blk.type : null, boundingBox: blk ? blk.boundingBox : null } }
    },
    raycast(maxDistance) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const dist = Number(maxDistance) || 8
      const block = b.blockAtCursor(dist)
      if (!block) return { success: true, data: { hit: false, distance: dist } }
      return { success: true, data: { hit: true, distance: block.distance, position: { x: block.position.x, y: block.position.y, z: block.position.z }, name: block.name, type: block.type } }
    },
    worldState() {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      return {
        success: true,
        data: {
          host: botCtl.cfg.host, port: botCtl.cfg.port,
          username: b.username,
          dimension: b.game ? b.game.dimension : null,
          time_of_day: b.time ? b.time.timeOfDay : null,
          day: b.time ? b.time.day : null,
          position: botCtl.pos(),
          loaded_chunks: b.world ? Object.keys(b.world.worldData ? b.world.worldData.columns : {}).length : null,
        },
      }
    },
    playerNearby(playerName, radius) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const r = Number(radius) || 32
      const pos = botCtl.pos()
      const players = Object.values(b.entities).filter((e) => e.kind === 'player')
      const q = playerName ? String(playerName).toLowerCase() : null
      let hits = players.filter((e) => {
        if (q && !(e.username || '').toLowerCase().includes(q)) return false
        if (!pos || !e.position) return false
        return Math.hypot(e.position.x - pos.x, e.position.z - pos.z) <= r
      })
      return { success: true, data: { nearby: hits.map((e) => ({ name: e.username, position: entityToObj(e).position })) } }
    },
  }
}
