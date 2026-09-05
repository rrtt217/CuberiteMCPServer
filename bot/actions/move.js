'use strict'
// bot/actions/move.js — movement & view
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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
    // Simple timed control-state move (no external pathfinder dependency)
    async moveTo(x, y, z, opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      opts = opts || {}
      const target = { x: Number(x), y: Number(y), z: Number(z) }
      if (![target.x, target.y, target.z].every((n) => Number.isFinite(n))) {
        return { success: false, errorCode: 'invalid_args', data: { x, y, z } }
      }
      try { await b.lookAt({ x: target.x, y: target.y + 1, z: target.z }) } catch (e) { /* non-fatal */ }
      const p0 = botCtl.pos()
      const d = Math.hypot(p0.x - target.x, p0.z - target.z)
      const budgetMs = Math.min(60000, Math.max(2000, (d / 3.0) * 1000))
      const started = Date.now()
      const far = Math.max(d * 0.9, 0.5)
      b.setControlState('forward', true)
      while (Date.now() - started < budgetMs) {
        const p = botCtl.pos()
        if (Math.hypot(p.x - target.x, p.z - target.z) < 0.7) break
        await sleep(100)
      }
      b.setControlState('forward', false)
      const p1 = botCtl.pos()
      const traveled = Math.hypot(p1.x - p0.x, p1.z - p0.z)
      return { success: Math.hypot(p1.x - target.x, p1.z - target.z) < far,
        data: { target, from: p0, to: p1, traveled, budgetMs } }
    },
    lookAt(x, y, z, opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const t = { x: Number(x), y: Number(y), z: Number(z) }
      if (![t.x, t.y, t.z].every((n) => Number.isFinite(n))) return { success: false, errorCode: 'invalid_args' }
      return b.lookAt(t, opts && opts.force !== undefined ? !!opts.force : true).then(() => ({
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
