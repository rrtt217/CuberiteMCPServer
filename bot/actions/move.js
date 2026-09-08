'use strict'
// bot/actions/move.js — movement & view
// mcc_move_to now uses mineflayer-pathfinder (A* navigation) instead of the
// naive control-state walk. Tool name/schema/result shape stay compatible with
// the MCC baseline: { success, data:{ target, from, to, traveled, budgetMs } }.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const { Movements, goals } = require('mineflayer-pathfinder')

module.exports = function moveActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }
  return {
    setControlState(control, state) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const valid = ['forward', 'back', 'left', 'right', 'jump', 'sprint', 'sneak']
      if (!valid.includes(control)) return { success: false, errorCode: 'invalid_args', data: { control } }
      try { b.setControlState(control, !!state) } catch (e) { return { success: false, errorCode: 'move_failed', data: { error: e.message } } }
      return { success: true, data: { control, state: !!state, position: botCtl.pos() } }
    },
    // Pathfind to a 3D target with mineflayer-pathfinder. GoalNear(..., 1)
    // = arrive within 1 block. Times out (default 30s) if unreachable.
    async moveTo(x, y, z, opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const target = { x: Number(x), y: Number(y), z: Number(z) }
      if (![target.x, target.y, target.z].every((n) => Number.isFinite(n))) {
        return { success: false, errorCode: 'invalid_args', data: { x, y, z } }
      }
      if (!b.pathfinder) return { success: false, errorCode: 'pathfinder_unavailable', data: { hint: 'mineflayer-pathfinder not loaded' } }
      try { await b.lookAt(require('vec3')(target.x, target.y + 1, target.z)) } catch (e) { /* non-fatal */ }

      // Fresh Movements per call: keeps defaults (canDig=false, no parkour).
      try { b.pathfinder.setMovements(new Movements(b)) } catch (e) {
        return { success: false, errorCode: 'movements_failed', data: { error: e.message } }
      }

      const from = botCtl.pos()
      const startMs = Date.now()
      const goal = new goals.GoalNear(target.x, target.y, target.z, 1)
      const timeoutMs = Math.min(120000, Math.max(5000, Number((opts && opts.timeoutMs) || 30000)))

      return new Promise((resolve) => {
        let settled = false
        const finish = (ok, extra) => {
          if (settled) return
          settled = true
          b.removeListener('goal_reached', onReached)
          clearTimeout(timer)
          if (!ok) { try { b.pathfinder.setGoal(null) } catch (e) { /* ignore */ } }
          const to = botCtl.pos()
          resolve({
            success: ok,
            data: {
              mode: 'pathfinder',
              target,
              from,
              to,
              traveled: from ? Math.hypot(to.x - from.x, to.y - from.y, to.z - from.z) : 0,
              budgetMs: Date.now() - startMs,
              ...(extra || {}),
            },
          })
        }
        const onReached = () => finish(true, { reached: true })
        b.on('goal_reached', onReached)
        try { b.pathfinder.setGoal(goal, false) } catch (e) {
          finish(false, { reason: 'set_goal_failed', error: e.message })
          return
        }
        const timer = setTimeout(() => finish(false, { reason: 'timeout' }), timeoutMs)
      })
    },
    // Cancel any active pathfinder goal / control-state movement.
    stopMovement() {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      if (b.pathfinder) {
        try { b.pathfinder.setGoal(null) } catch (e) { return { success: false, errorCode: 'stop_failed', data: { error: e.message } } }
      }
      for (const c of ['forward', 'back', 'left', 'right', 'jump', 'sprint']) {
        try { b.setControlState(c, false) } catch (e) { /* ignore */ }
      }
      return { success: true, data: { stopped: true, position: botCtl.pos() } }
    },
    lookAt(x, y, z, opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const t = { x: Number(x), y: Number(y), z: Number(z) }
      if (![t.x, t.y, t.z].every((n) => Number.isFinite(n))) return { success: false, errorCode: 'invalid_args' }
      return b.lookAt(require('vec3')(t.x, t.y, t.z), opts && opts.force !== undefined ? !!opts.force : true).then(() => ({
        success: true, data: { yaw: b.entity.yaw, pitch: b.entity.pitch, target: t, position: botCtl.pos() },
      })).catch((e) => ({ success: false, errorCode: 'look_failed', data: { error: e.message } }))
    },
    async lookDirection(yaw, pitch) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const y = Number(yaw), p = Number(pitch)
      if (!Number.isFinite(y) || !Number.isFinite(p)) return { success: false, errorCode: 'invalid_args' }
      b.look(y, p, true)
      await sleep(50)
      return { success: true, data: { yaw: b.entity.yaw, pitch: b.entity.pitch } }
    },
    toggleSprint(enabled) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      b.setControlState('sprint', !!enabled)
      return { success: true, data: { enabled: !!enabled } }
    },
    toggleSneak(enabled) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      b.setControlState('sneak', !!enabled)
      return { success: true, data: { enabled: !!enabled } }
    },
  }
}
