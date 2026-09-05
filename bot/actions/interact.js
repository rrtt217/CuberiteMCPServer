'use strict'
// bot/actions/interact.js — block/entity interaction
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

module.exports = function interactActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }
  return {
    async activateBlock(x, y, z) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const block = b.blockAt({ x: Math.floor(x), y: Math.floor(y), z: Math.floor(z) })
      if (!block) return { success: false, errorCode: 'block_not_found', data: { x, y, z } }
      if (block.type === 0) return { success: false, errorCode: 'invalid_state', data: { reason: 'air block' } }
      try {
        await b.lookAt(block.position.offset(0.5, 0.8, 0.5))
        await sleep(80)
        await b.activateBlock(block)
      } catch (e) { return { success: false, errorCode: 'activate_failed', data: { error: e.message } } }
      return { success: true, data: { x, y, z, block: block.name, type: block.type } }
    },
    async attackEntity(entityId) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const e = b.entities[entityId]
      if (!e) return { success: false, errorCode: 'entity_not_found', data: { entityId } }
      try { b.attack(e) } catch (err) { return { success: false, errorCode: 'attack_failed', data: { error: err.message } } }
      return { success: true, data: { entityId, type: e.name, position: botCtl.pos() } }
    },
    async useOnEntity(entityId) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const e = b.entities[entityId]
      if (!e) return { success: false, errorCode: 'entity_not_found', data: { entityId } }
      try { await b.useOn(e) } catch (err) { return { success: false, errorCode: 'use_failed', data: { error: err.message } } }
      return { success: true, data: { entityId, type: e.name } }
    },
    async digBlock(x, y, z) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const block = b.blockAt({ x: Math.floor(x), y: Math.floor(y), z: Math.floor(z) })
      if (!block || block.type === 0) return { success: false, errorCode: 'invalid_state', data: { reason: 'air or missing' } }
      try {
        await b.lookAt(block.position.offset(0.5, 0.5, 0.5))
        await sleep(80)
        await b.dig(block)
      } catch (e) { return { success: false, errorCode: 'dig_failed', data: { error: e.message } } }
      return { success: true, data: { x, y, z, block: block.name } }
    },
  }
}
