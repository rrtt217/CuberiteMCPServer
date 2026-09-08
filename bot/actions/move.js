'use strict'
// bot/actions/move.js — movement & view
// mcc_move_to uses mineflayer-pathfinder (A*) with a goal-type abstraction so
// the AI can express intent instead of raw coordinates:
//   goalType 'near'  -> GoalNear     (arrive within range, default 1)
//   goalType 'xz'    -> GoalNearXZ   (region-level, Y-agnostic; robust long-range)
//   goalType 'block' -> GoalGetToBlock (stand ADJACENT to a block: chests, tables)
//   goalType 'face'  -> GoalLookAtBlock (enter dig/place/use range + visible face)
//   goalType 'any'   -> GoalCompositeAny (nearest of many candidates; AI passes a set)
// Result shape stays compatible with the MCC baseline plus richer diagnostics
// (reached / moved / isMovingAtEnd / reason).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const { Movements, goals } = require('mineflayer-pathfinder')
const Vec3 = require('vec3')

// A single Movements instance per bot process: avoids rebuilding cost tables and
// keeps the scaffold-inventory counter coherent. The 2.4.5 defaults already
// enable canDig/sprint/parkour/1x1towers; 'walk' mode disables the disruptive ones.
let sharedMovements = null
function movementsFor(b, mode) {
  if (!sharedMovements || sharedMovements.bot !== b) {
    sharedMovements = new Movements(b)
  }
  const dig = mode !== 'walk'
  sharedMovements.canDig = dig
  sharedMovements.allowSprinting = dig
  sharedMovements.allowParkour = dig
  sharedMovements.allow1by1towers = dig
  return sharedMovements
}

module.exports = function moveActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }

  function buildGoal(b, goalType, x, y, z, range, candidates) {
    switch (goalType) {
      case 'xz':
        return new goals.GoalNearXZ(Math.floor(Number(x)), Math.floor(Number(z)), (range == null ? 2 : Number(range)))
      case 'block':
        return new goals.GoalGetToBlock(Math.floor(Number(x)), Math.floor(Number(y)), Math.floor(Number(z)))
      case 'face': {
        const opts = { reach: range == null ? 4.5 : Number(range) }
        return new goals.GoalLookAtBlock(new Vec3(Math.floor(Number(x)), Math.floor(Number(y)), Math.floor(Number(z))), b.world, opts)
      }
      case 'any': {
        const list = Array.isArray(candidates) ? candidates : []
        if (list.length === 0) throw new Error('goalType=any requires candidates array')
        const myY = Math.floor(b.entity.position.y)
        const sub = list.map((c) => {
          const r = (c && c.range != null) ? Number(c.range) : (range == null ? 2 : Number(range))
          if (c && c.y != null) return new goals.GoalNear(Number(c.x), Number(c.y), Number(c.z), r)
          return new goals.GoalNearXZ(Number(c.x), Number(c.z), r)
        })
        return new goals.GoalCompositeAny(sub)
      }
      case 'near':
      default:
        return new goals.GoalNear(Math.floor(Number(x)), Math.floor(Number(y)), Math.floor(Number(z)), (range == null ? 1 : Number(range)))
    }
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

    // Pathfind toward a target with an intent-based goal type. Times out
    // (default 30s) if unreachable or budget exhausted.
    async moveTo(x, y, z, opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      if (!b.pathfinder) return { success: false, errorCode: 'pathfinder_unavailable', data: { hint: 'mineflayer-pathfinder not loaded' } }
      const goalType = String((opts && opts.goalType) || 'near')
      if (!['near', 'xz', 'block', 'face', 'any'].includes(goalType)) {
        return { success: false, errorCode: 'invalid_args', data: { goalType } }
      }
      const target = { x: Number(x), y: Number(y), z: Number(z) }
      for (const k of ['x', 'y', 'z']) {
        if (!Number.isFinite(target[k])) return { success: false, errorCode: 'invalid_args', data: { x, y, z } }
      }
      const range = (opts && opts.range != null) ? Number(opts.range) : null
      const timeoutMs = Math.min(120000, Math.max(5000, Number((opts && opts.timeoutMs) || 30000)))
      try { await b.lookAt(new Vec3(target.x, target.y + 1, target.z)) } catch (e) { /* non-fatal */ }

      let movements
      let goal
      try {
        movements = movementsFor(b, opts && opts.mode)
        goal = buildGoal(b, goalType, target.x, target.y, target.z, range, opts && opts.candidates)
      } catch (e) {
        return { success: false, errorCode: 'goal_build_failed', data: { goalType, error: e.message } }
      }
      try { b.pathfinder.setMovements(movements) } catch (e) {
        return { success: false, errorCode: 'movements_failed', data: { error: e.message } }
      }

      const from = botCtl.pos()
      const startMs = Date.now()
      return new Promise((resolve) => {
        let settled = false
        const finish = (reachState, reason) => {
          if (settled) return
          settled = true
          b.removeListener('goal_reached', onReached)
          clearTimeout(timer)
          if (reachState !== 'goal_reached') { try { b.pathfinder.setGoal(null) } catch (e) { /* ignore */ } }
          const to = botCtl.pos()
          const moved = from ? Math.hypot(to.x - from.x, to.y - from.y, to.z - from.z) : 0
          let isMovingAtEnd = false
          try { isMovingAtEnd = b.pathfinder.isMoving() } catch (e) { /* ignore */ }
          resolve({
            success: reachState === 'goal_reached',
            data: {
              mode: 'pathfinder',
              goalType,
              target: goalType === 'any' ? null : target,
              range: range == null ? null : range,
              from,
              to,
              traveled: moved,
              moved,
              reached: reachState,
              isMovingAtEnd,
              budgetMs: Date.now() - startMs,
              ...(reason ? { reason } : {}),
            },
          })
        }
        const onReached = () => finish('goal_reached')
        b.on('goal_reached', onReached)
        try { b.pathfinder.setGoal(goal, false) } catch (e) {
          finish('stopped', 'set_goal_failed: ' + e.message)
          return
        }
        const timer = setTimeout(() => finish('timeout'), timeoutMs)
      })
    },

    // Bounded reachability probe (one-shot A* with wall-clock budget). Returns
    // status: success | noPath | partial | timeout, pathLength, estimated cost.
    canReach(x, y, z, opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      if (!b.pathfinder) return { success: false, errorCode: 'pathfinder_unavailable' }
      const range = (opts && opts.range != null) ? Number(opts.range) : 2
      const budgetMs = Math.min(5000, Math.max(200, Number((opts && opts.budgetMs) || 1500)))
      const goal = new goals.GoalNear(Math.floor(Number(x)), Math.floor(Number(y)), Math.floor(Number(z)), range)
      const movements = movementsFor(b, opts && opts.mode)
      const startMs = Date.now()
      try {
        const gen = b.pathfinder.getPathFromTo(movements, b.entity.position, goal, { timeout: budgetMs, tickTimeout: 40, searchRadius: -1 })
        let result = null
        for (;;) {
          const { value } = gen.next()
          result = value.result
          if (result.status !== 'partial') break
          if (Date.now() - startMs > budgetMs) break
        }
        return {
          success: true,
          data: {
            x: Math.floor(Number(x)), y: Math.floor(Number(y)), z: Math.floor(Number(z)),
            status: result.status,
            pathLength: result.path ? result.path.length : 0,
            cost: result.cost,
            time: result.time,
            budgetMs: Date.now() - startMs,
          },
        }
      } catch (e) {
        return { success: false, errorCode: 'probe_failed', data: { error: e.message } }
      }
    },

    // Reflect on the current pathfinder state for AI diagnosis.
    pathStatus() {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      if (!b.pathfinder) return { success: false, errorCode: 'pathfinder_unavailable' }
      let g = null
      try { g = b.pathfinder.goal } catch (e) { /* ignore */ }
      const goalType = g && g.constructor ? g.constructor.name.replace(/^Goal/, '') : null
      let isMoving = false, isMining = false, isBuilding = false
      try { isMoving = b.pathfinder.isMoving(); isMining = b.pathfinder.isMining(); isBuilding = b.pathfinder.isBuilding() } catch (e) { /* ignore */ }
      return { success: true, data: { hasGoal: !!g, goalType, isMoving, isMining, isBuilding, position: botCtl.pos() } }
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
      return b.lookAt(new Vec3(t.x, t.y, t.z), opts && opts.force !== undefined ? !!opts.force : true).then(() => ({
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
