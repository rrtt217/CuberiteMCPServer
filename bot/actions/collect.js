'use strict'
// bot/actions/collect.js — collect nearby dropped item entities.
// Primary engine: mineflayer-collectblock (@1.6.0) — pathfinds to each drop in
// distance order and waits for pickup; falls back to a legacy walk-to-drop loop
// if the plugin (or mineflayer-tool) cannot be loaded.
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
  function nearbyItems(b, radius) {
    const myPos = b.entity.position
    return Object.values(b.entities)
      .filter(isItemEntity)
      .map((e) => ({ e, d: e.position.distanceTo(myPos) }))
      .filter((o) => o.d <= radius)
      .sort((a, z) => a.d - z.d)
  }
  // Load mineflayer-tool + mineflayer-collectblock once per bot. Loading a
  // plugin twice is rejected by mineflayer, so guard on b.tool / b.collectBlock.
  async function ensureCollectBlock(b) {
    if (b.collectBlock && b.tool) return true
    try {
      // NOTE: both packages export { plugin, ... } — pass the inject fn itself.
      const collectPlugin = require('mineflayer-collectblock').plugin
      const toolPlugin = require('mineflayer-tool').plugin
      if (!b.tool) b.loadPlugin(toolPlugin)
      if (!b.collectBlock) b.loadPlugin(collectPlugin)
      return !!(b.collectBlock && b.tool)
    } catch (e) {
      return false
    }
  }
  // collectblock has no global timeout; an unreachable drop can make
  // GoalFollow spin indefinitely, so race against a wall clock and cancel.
  async function collectViaPlugin(b, items, timeoutMs) {
    // Capture the settle reason; mineflayer-collectblock can reject after the
    // drops are already picked up, so callers treat "all collected" as success.
    const starter = b.collectBlock.collect(items, { ignoreNoPath: true })
      .then(() => ({ status: 'done', error: null }),
            (e) => ({ status: 'error', error: (e && e.message) || String(e) }))
    let timer
    const guard = new Promise((resolve) => {
      timer = setTimeout(() => {
        try { b.collectBlock.cancelTask().catch(() => {}) } catch (e) { /* ignore */ }
        resolve({ status: 'timeout', error: null })
      }, timeoutMs)
    })
    const result = await Promise.race([starter, guard])
    clearTimeout(timer)
    return result
  }
  // Legacy fallback: walk onto each drop with a tight GoalNearXZ.
  async function collectLegacy(b, radius, maxItems) {
    const visited = []
    const map = () => nearbyItems(b, radius)
    for (let i = 0; i < maxItems; i++) {
      const list = map()
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
    const still = nearbyItems(b, radius).length
    return { success: true, data: { visited, remaining: still, collectedHint: still === 0 ? 'all nearby drops collected' : 'items still out of reach', engine: 'legacy' } }
  }
  return {
    async collectNearby(opts) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      if (!b.pathfinder) return { success: false, errorCode: 'pathfinder_unavailable' }
      const radius = Number((opts && opts.radius) || 12)
      const maxItems = Number((opts && opts.maxItems) || 20)
      const timeoutMs = Number((opts && opts.timeoutMs) || 30000)
      let list = nearbyItems(b, radius)
      if (list.length === 0) {
        return { success: true, data: { visited: [], remaining: 0, collectedHint: 'no drops found in range', engine: 'none' } }
      }
      list = list.slice(0, maxItems)
      if (await ensureCollectBlock(b)) {
        let result = await collectViaPlugin(b, list, timeoutMs)
        let still = nearbyItems(b, radius).length
        // Post-pickup pathfinder errors (GoalFollow touching a removed entity's
        // position) are noise when everything was actually collected. If items
        // remain after an error (e.g. entity merged mid-collect), retry once.
        if (result.status === 'error' && still > 0) {
          const fresh = nearbyItems(b, radius).slice(0, maxItems)
          if (fresh.length) result = await collectViaPlugin(b, fresh, timeoutMs)
          still = nearbyItems(b, radius).length
        }
        const effective = (result.status === 'error' && still === 0) ? 'done' : result.status
        return {
          success: true,
          data: {
            visited: list.map((o) => ({ x: Math.round(o.e.position.x * 10) / 10, y: Math.round(o.e.position.y * 10) / 10, z: Math.round(o.e.position.z * 10) / 10 })),
            remaining: still,
            collectedHint: still === 0 ? 'all nearby drops collected' : ('plugin finished, ' + still + ' still in range' + (result.status === 'timeout' ? ' (wall-clock timeout, task cancelled)' : '') + (result.error ? ' error: ' + result.error : '')),
            engine: 'collectblock',
            result,
          },
        }
      }
      return collectLegacy(b, radius, maxItems)
    },
  }
}
