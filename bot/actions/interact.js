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
      const vec3 = require('vec3')
      const block = b.blockAt(vec3(Math.floor(x), Math.floor(y), Math.floor(z)))
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
      const vec3 = require('vec3')
      const block = b.blockAt(vec3(Math.floor(x), Math.floor(y), Math.floor(z)))
      if (!block || block.type === 0) return { success: false, errorCode: 'invalid_state', data: { reason: 'air or missing' } }
      try {
        await b.lookAt(block.position.offset(0.5, 0.5, 0.5))
        await sleep(80)
        await b.dig(block)
      } catch (e) { return { success: false, errorCode: 'dig_failed', data: { error: e.message } } }
      return { success: true, data: { x, y, z, block: block.name } }
    },
    // Place the currently held block/item at a target block location.
    // face: 'auto' (default, prefers placing on top of the block below) or one
    // of down/up/north/south/west/east (attach to that neighbour).
    async placeBlock(x, y, z, face) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const vec3 = require('vec3')
      const tx = Math.floor(x), ty = Math.floor(y), tz = Math.floor(z)
      const target = b.blockAt(vec3(tx, ty, tz))
      if (target && target.type !== 0) {
        return { success: false, errorCode: 'invalid_state', data: { reason: 'target not air', block: target.name } }
      }
      const pos = botCtl.pos()
      // Self-collision pre-check: the server refuses to place a block where the
      // player's own body stands. Player AABB ~ (0.6 wide, 1.8 tall) at feet.
      if (pos) {
        const pBox = { x0: pos.x - 0.3, x1: pos.x + 0.3, y0: pos.y, y1: pos.y + 1.8, z0: pos.z - 0.3, z1: pos.z + 0.3 }
        if (tx < pBox.x1 && tx + 1 > pBox.x0 && ty < pBox.y1 && ty + 1 > pBox.y0 && tz < pBox.z1 && tz + 1 > pBox.z0) {
          return { success: false, errorCode: 'invalid_state', data: { reason: 'target intersects the bot body — stand away from the target cell' } }
        }
      }
      // Early reach check (server enforces it too; fail fast with a clear code).
      if (pos && Math.hypot(pos.x - (tx + 0.5), pos.y - (ty + 0.5), pos.z - (tz + 0.5)) > 5.0) {
        return { success: false, errorCode: 'too_far', data: { distance: Math.hypot(pos.x - (tx + 0.5), pos.y - (ty + 0.5), pos.z - (tz + 0.5)), max: 5.0 } }
      }
      // (dx,dy,dz) = vector FROM reference block TO the target.
      const faceVectors = {
        down:  [0, 1, 0],   // target sits on top of the block below
        up:    [0, -1, 0],  // target hangs below the block above
        north: [0, 0, 1],   // reference at z-1
        south: [0, 0, -1],  // reference at z+1
        west:  [1, 0, 0],   // reference at x-1
        east:  [-1, 0, 0],  // reference at x+1
      }
      const refOffsets = {
        down:  [0, -1, 0],
        up:    [0, 1, 0],
        north: [0, 0, -1],
        south: [0, 0, 1],
        west:  [-1, 0, 0],
        east:  [1, 0, 0],
      }
      let fvec = null
      if (face && face !== 'auto') {
        fvec = faceVectors[String(face).toLowerCase()]
        if (!fvec) return { success: false, errorCode: 'invalid_args', data: { face, valid: Object.keys(faceVectors) } }
      } else {
        // auto: scan neighbours, prefer below, then the other five.
        const order = ['down', 'north', 'south', 'west', 'east', 'up']
        for (const f of order) {
          const [dx, dy, dz] = refOffsets[f]
          const nb = b.blockAt(vec3(tx + dx, ty + dy, tz + dz))
          if (nb && nb.type !== 0) { fvec = faceVectors[f]; break }
        }
        if (!fvec) return { success: false, errorCode: 'invalid_state', data: { reason: 'no solid reference block adjacent to target' } }
      }
      const refPos = { x: tx + (fvec[0] === 1 ? -1 : fvec[0] === -1 ? 1 : 0), y: ty + (fvec[1] === 1 ? -1 : fvec[1] === -1 ? 1 : 0), z: tz + (fvec[2] === 1 ? -1 : fvec[2] === -1 ? 1 : 0) }
      const reference = b.blockAt(vec3(refPos.x, refPos.y, refPos.z))
      if (!reference || reference.type === 0) {
        return { success: false, errorCode: 'invalid_state', data: { reason: 'reference block missing', ref: refPos } }
      }
      if (!b.heldItem) {
        return { success: false, errorCode: 'no_item_held', data: { hint: 'select a placeable item with mcc_select_item or mcc_change_hotbar_slot first' } }
      }
      try {
        await b.placeBlock(reference, vec3(fvec[0], fvec[1], fvec[2]))
      } catch (e) {
        return { success: false, errorCode: 'place_failed', data: { error: e.message, ref: refPos } }
      }
      const placed = b.blockAt(vec3(tx, ty, tz))
      return { success: true, data: { x: tx, y: ty, z: tz, block: placed ? placed.name : 'placed', reference: refPos, face: fvec.join(',') } }
    },
  }
}
