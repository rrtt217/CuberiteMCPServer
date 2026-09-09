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
      // Server reach check (Cuberite: ~5.26 from eye; use a conservative 5.0
      // from the bot's feet). Out-of-reach clicks are silently ignored by the
      // server (no window opens, nothing moves), yet the old code returned
      // success — a classic "inventory ops silently no-op / look desynced".
      const pos = botCtl.pos()
      if (pos) {
        const dist = Math.hypot(pos.x - (block.position.x + 0.5), pos.y - (block.position.y + 0.5), pos.z - (block.position.z + 0.5))
        if (dist > 5.0) {
          return { success: false, errorCode: 'too_far', data: { x, y, z, block: block.name, distance: Math.round(dist * 10) / 10, max: 5.0, hint: 'move closer (mcc_move_to) then retry' } }
        }
      }
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
      try {
        // Face the entity first: the server picks the "use" target from the
        // player's view direction when processing the use_entity packet
        // (Cuberite HOOK_PLAYER_RIGHT_CLICKING_ENTITY), so a stale facing makes
        // right-clicks (e.g. opening a villager's trade window) silently no-op.
        await b.lookAt(e.position.offset(0, 1, 0))
        await sleep(80)
        await b.useOn(e)
      } catch (err) { return { success: false, errorCode: 'use_failed', data: { error: err.message } } }
      const p = botCtl.pos()
      return { success: true, data: { entityId, type: e.name,
        entityPos: { x: e.position.x, y: e.position.y, z: e.position.z },
        distance: p ? Math.round(Math.hypot(p.x - e.position.x, p.y - e.position.y, p.z - e.position.z) * 10) / 10 : null } }
    },
    async digBlock(x, y, z) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      // Auto-equip the best mining tool before digging. Picking up drops can
      // silently swap the held item to a block (e.g. dirt), which makes b.dig()
      // mine at bare-hand speed; re-equipping here keeps dig speed optimal.
      try {
        const tier = { golden: -1, wooden: 0, stone: 1, iron: 2, diamond: 3 }
        const tools = (b.inventory.items() || []).filter((it) =>
          /pickaxe|axe|shovel$/.test(it.name || ''))
        if (tools.length) {
          tools.sort((a, c) => (tier[a.name.replace(/_pickaxe$|_axe$|_shovel$/, '')] ?? -2) - (tier[c.name.replace(/_pickaxe$|_axe$|_shovel$/, '')] ?? -2))
          const best = tools[tools.length - 1]
          if (!b.heldItem || b.heldItem.slot !== best.slot) {
            await b.equip(best, 'hand')
            await sleep(60)
          }
        }
      } catch (e) { /* tool auto-equip is best-effort */ }
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
    // Right-click: use the held item in hand (air), interact with a block, or
    // use (right-click) a tracked entity.
    async useItem(entityId, x, y, z) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const vec3 = require('vec3')
      try {
        if (entityId != null) {
          const e = b.entities[Number(entityId)]
          if (!e) return { success: false, errorCode: 'entity_not_found', data: { entityId } }
          await b.useOn(e)
          return { success: true, data: { action: 'useOnEntity', entityId: Number(entityId), type: e.name || e.displayName || null } }
        }
        if (x != null && y != null && z != null) {
          const block = b.blockAt(vec3(Math.floor(x), Math.floor(y), Math.floor(z)))
          if (!block || block.type === 0) return { success: false, errorCode: 'block_not_found', data: { x, y, z } }
          await b.lookAt(block.position.offset(0.5, 0.8, 0.5))
          await sleep(80)
          await b.activateBlock(block)
          return { success: true, data: { action: 'activateBlock', x: block.position.x, y: block.position.y, z: block.position.z, block: block.name } }
        }
        await b.activateItem()
        return { success: true, data: { action: 'activateItem', held: b.heldItem ? { name: b.heldItem.name, type: b.heldItem.type, count: b.heldItem.count } : null } }
      } catch (e) {
        return { success: false, errorCode: 'use_failed', data: { error: e.message } }
      }
    },
    // Long-press right button. In 1.12 "use" is a stateful action started by
    // use_item and stopped by the release-use packet (Player Digging status 5).
    //  - No target (item mode): action start = press (activateItem), stop =
    //    release (deactivateItem), toggle = flip current holding state.
    //    durationMs auto-releases a start (e.g. charge bow then fire).
    //  - entityId / x,y,z (targeted mode): repeated right-click of that target
    //    every ~250ms for durationMs — vanilla hold-right on entities/blocks.
    async holdUse(action, entityId, x, y, z, durationMs) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const act = String(action || 'repeat').toLowerCase()
      const dur = Math.max(0, Math.min(Number(durationMs) || 3000, 30000))
      if (entityId != null || (x != null && y != null && z != null)) {
        if (act === 'start' || act === 'stop' || act === 'toggle') {
          return { success: false, errorCode: 'invalid_args', data: { hint: 'start/stop/toggle apply to the held item (no entity/block target); pass repeat (or leave action unset) for a targeted hold' } }
        }
        const start = Date.now()
        let count = 0
        let last = null
        while (Date.now() - start < dur) {
          last = await this.useItem(entityId, x, y, z)
          count++
          if (!last || !last.success) break
          await sleep(250)
        }
        return { success: true, data: { action: 'holdUseRepeat', target: entityId != null ? ('entity ' + entityId) : ('block ' + x + ',' + y + ',' + z), uses: count, last } }
      }
      const press = act === 'start' || (act === 'toggle' && !b.usingHeldItem)
      try {
        if (act === 'stop') {
          await b.deactivateItem()
        } else if (press) {
          await b.activateItem()
        } else {
          return { success: false, errorCode: 'invalid_args', data: { action: act, hint: "use 'start', 'stop', or 'toggle'" } }
        }
      } catch (e) {
        return { success: false, errorCode: 'use_failed', data: { error: e.message } }
      }
      if (press && dur > 0) {
        setTimeout(() => { try { b.deactivateItem() } catch (e) { /* ignore */ } }, dur)
      }
      return { success: true, data: { action: press ? 'press' : 'release', usingHeldItem: !!b.usingHeldItem, autoReleaseMs: press ? dur : null, held: b.heldItem ? { name: b.heldItem.name, type: b.heldItem.type, count: b.heldItem.count } : null } }
    },
    // Long-press left button: attack an entity until it is gone, dig a single
    // block, or (with dx/dy/dz + count) continuously mine a row of cells,
    // stepping into each one (strip-mine / staircase).
    async holdLeft(entityId, x, y, z, dx, dy, dz, count, durationMs) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const dur = Math.max(0, Math.min(Number(durationMs) || 5000, 30000))
      if (entityId != null) {
        const id = Number(entityId)
        if (!b.entities[id]) return { success: false, errorCode: 'entity_not_found', data: { entityId } }
        const start = Date.now()
        let hits = 0
        while (Date.now() - start < dur && b.entities[id] && b.entities[id].health > 0) {
          try { b.attack(b.entities[id]) } catch (e) { break }
          hits++
          await sleep(450)
        }
        return { success: true, data: { action: 'holdAttack', entityId: id, hits, ms: Date.now() - start } }
      }
      if (x == null || y == null || z == null) {
        return { success: false, errorCode: 'invalid_args', data: { hint: 'pass entityId OR x,y,z (optionally dx,dy,dz + count for continuous mining)' } }
      }
      const forward = (dx || dy || dz) && count > 0
      const steps = forward ? Math.max(1, Number(count)) : 1
      const cx = Math.floor(x), cy = Math.floor(y), cz = Math.floor(z)
      const digs = []
      const start = Date.now()
      for (let i = 0; i < steps && Date.now() - start < dur; i++) {
        const cell = forward ? { x: cx + i * dx, y: cy + i * dy, z: cz + i * dz } : { x: cx, y: cy, z: cz }
        const r = await this.digBlock(cell.x, cell.y, cell.z)
        digs.push({ x: cell.x, y: cell.y, z: cell.z, dug: !!(r && r.success) })
        if (forward && r && r.success) {
          const { goals } = require('mineflayer-pathfinder')
          try { b.pathfinder.goto(new goals.GoalNear(cell.x + 0.5, cell.y, cell.z + 0.5, 0.3)) } catch (e) { /* keep going */ }
          await sleep(300)
        }
      }
      return { success: true, data: { action: 'holdDig', mode: forward ? 'forward' : 'block', cells: digs, ms: Date.now() - start } }
    },
  }
}
