'use strict'
// bot/actions/collect.js — walk onto nearby dropped items so the server picks them up.
// Needs mineflayer-pathfinder for tight goals.
const { Movements, goals } = require('mineflayer-pathfinder')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

module.exports = function collectActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }
  function isItemEntity(e) {
    if (!e || !e.position) return false
    return e.kind === 'Drops' || /item/i.test(String(e.name || '')) || /Dropped/i.test(String(e.displayName || ''))
  }
  return {
    async collectNearby(opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      if (!b.pathfinder) return { success: false, errorCode: 'pathfinder_unavailable' }
      const radius = Number((opts && opts.radius) || 12)
      const maxItems = Number((opts && opts.maxItems) || 20)
      const visited = []
      const myPos = () => b.entity.position
      const nearby = () => Object.values(b.entities).filter(isItemEntity)
        .map((e) => ({ e, d: e.position.distanceTo(myPos()) }))
        .filter((o) => o.d <= radius)
        .sort((a, z) => a.d - z.d)
      for (let i = 0; i < maxItems; i++) {
        const list = nearby()
        if (list.length === 0) break
        const target = list[0]
        const p = target.e.position
        try { b.pathfinder.setMovements(new Movements(b)) } catch (e) { return { success: false, errorCode: 'movements_failed', data: { error: e.message } } }
        const goal = new goals.GoalNearXZ(Math.floor(p.x) + 0.5, Math.floor(p.z) + 0.5, 0.4)
        b.pathfinder.setGoal(goal)
        await new Promise((resolve) => {
          const timer = setTimeout(() => { b.removeListener('goal_reached', onG); resolve() }, 6000)
          const onG = () => { clearTimeout(timer); b.removeListener('goal_reached', onG); resolve() }
          b.on('goal_reached', onG)
        })
        b.pathfinder.setGoal(null)
        await sleep(700)
        visited.push({ x: Math.round(p.x * 10) / 10, y: Math.round(p.y * 10) / 10, z: Math.round(p.z * 10) / 10 })
      }
      const still = nearby().length
      return { success: true, data: { visited, remaining: still, collectedHint: still === 0 ? 'all nearby drops collected' : 'items still out of reach' } }
    },
  }
}
