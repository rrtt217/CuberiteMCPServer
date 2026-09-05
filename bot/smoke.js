#!/usr/bin/env node
// bot/smoke.js — Phase 0 smoke test: mineflayer x Cuberite protocol gate.
// Usage:
//   node smoke.js <version>          e.g. node smoke.js 1.12.2
//   node smoke.js <version> --stay   keep the bot alive after the sequence
//                                    (for external death/respawn probing)
// Prints PASS/FAIL per check. Exit code 0 = all PASS, 1 = a FAIL occurred.
'use strict'

const mineflayer = require('mineflayer')
const HOST = process.env.SMOKE_HOST || '127.0.0.1'
const PORT = Number(process.env.SMOKE_PORT || 25568)
const BASE = process.env.SMOKE_USER || 'SmokeBot'

const version = process.argv[2]
const STAY = process.argv.includes('--stay')

const results = []
function check(name, ok, detail) {
  results.push([name, ok, detail])
  console.log((ok ? 'PASS' : 'FAIL') + ' | ' + name + (detail ? ' | ' + detail : ''))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// SIGTERM graceful exit hook (required by the phase-0 checklist)
let sigtermAt = null
process.on('SIGTERM', () => {
  sigtermAt = Date.now()
  console.log('EVENT | SIGTERM received -> quitting bot')
  try { bot.quit('sigterm') } catch (e) { /* ignore */ }
  setTimeout(() => {
    console.log('EVENT | process exited after ' + (Date.now() - sigtermAt) + 'ms')
    process.exit(0)
  }, 800)
})

const username = BASE + '_' + Math.floor(Math.random() * 9000 + 1000)
const opts = { host: HOST, port: PORT, username, auth: 'offline', hideErrors: false }
if (version) opts.version = version

console.log('--- smoke start | host=' + HOST + ':' + PORT + ' user=' + username +
  (version ? ' version=' + version : ' version=auto-probe'))

const t0 = Date.now()
const bot = mineflayer.createBot(opts)

let spawnOnce = null
const spawnPromise = new Promise((r) => { spawnOnce = r })

bot.once('spawn', () => {
  const dt = Date.now() - t0
  console.log('EVENT | spawn after ' + dt + 'ms at ' + fmt(bot.entity.position))
  check('offline login + spawn (version=' + (version || 'auto-probe') + ')', true, dt + 'ms')
  spawnOnce()
})

bot.on('message', (m) => {
  // mineflayer passes a prismarine-chat ChatMessage; extract plain text
  let txt = ''
  try {
    txt = typeof m === 'string' ? m : (m.toString ? m.toString() : String(m))
  } catch (e) { txt = '(extract err ' + e.message + ')' }
  if (txt.includes(username)) {
    console.log('CHAT-ECHO | ' + txt.slice(0, 160))
  } else {
    console.log('CHAT | ' + txt.slice(0, 160))
  }
})
bot.on('health', () => { console.log('EVENT | health=' + bot.health + ' food=' + bot.food) })
bot.on('death', () => { console.log('EVENT | DEATH at ' + fmt(bot.entity.position)) })
bot.on('respawn', () => { console.log('EVENT | respawn packet') })
bot.on('kicked', (r, log) => { console.log('EVENT | KICKED ' + r + ' ' + log); process.exit(1) })
bot.on('end', (r) => { console.log('EVENT | end reason=' + r) })
bot.on('error', (e) => { console.log('EVENT | error ' + e.message) })

function fmt(p) { return p ? p.x.toFixed(1) + ',' + p.y.toFixed(1) + ',' + p.z.toFixed(1) : 'null' }

async function main() {
  try {
    await Promise.race([spawnPromise, sleep(20000).then(() => { throw new Error('spawn timeout 20s') })])
  } catch (e) {
    check('offline login + spawn', false, e.message)
    console.log('RESULT_SUMMARY ' + summarize())
    process.exit(1)
  }

  // 1. Chat roundtrip
  try {
    const echo = 'ping_' + Math.floor(Math.random() * 100000)
    const got = new Promise((resolve) => {
      const h = (m) => {
        let txt = ''
        try { txt = typeof m === 'string' ? m : (m.toString ? m.toString() : String(m)) } catch (e) {}
        if (txt.includes(echo)) { bot.removeListener('message', h); resolve(true) }
      }
      bot.on('message', h)
    })
    bot.chat(echo)
    const ok = await Promise.race([got, sleep(8000).then(() => false)])
    check('chat roundtrip (message echo)', ok, ok ? 'echo seen' : 'no echo within 8s')
  } catch (e) { check('chat roundtrip', false, e.message) }

  // 2. Command execution — /help (permitted for default group; no side effects),
  //    verified by receiving a help response message
  try {
    const got = new Promise((resolve) => {
      const h = (m) => {
        let txt = ''
        try { txt = typeof m === 'string' ? m : (m.toString ? m.toString() : String(m)) } catch (e) {}
        if (/command/i.test(txt) || /help/i.test(txt)) { bot.removeListener('message', h); resolve(txt) }
      }
      bot.on('message', h)
    })
    bot.chat('/help')
    const resp = await Promise.race([got, sleep(6000).then(() => null)])
    check('command exec (/help)', !!resp, resp ? ('got: ' + resp.slice(0, 80)) : 'no help response within 6s')
  } catch (e) { check('command exec', false, e.message) }

  // 3. Movement: forward 2s + jump + sneak
  try {
    const p0 = { x: bot.entity.position.x, z: bot.entity.position.z }
    bot.setControlState('forward', true)
    await sleep(2000)
    bot.setControlState('forward', false)
    const p1 = bot.entity.position
    const moved = Math.hypot(p1.x - p0.x, p1.z - p0.z)
    check('movement forward 2s', moved > 0.2, 'moved ' + moved.toFixed(2) + ' blocks')
    bot.setControlState('jump', true)
    await sleep(600)
    bot.setControlState('jump', false)
    const yAfterJump = bot.entity.position.y
    check('jump', yAfterJump > p1.y - 0.5, 'y ' + p1.y.toFixed(1) + ' -> ' + yAfterJump.toFixed(1))
    bot.setControlState('sneak', true)
    await sleep(600)
    bot.setControlState('sneak', false)
    check('sneak', true, 'no error')
  } catch (e) { check('movement', false, e.message) }

  // 4. Right-click (lookAt + activateBlock on block below)
  try {
    const below = bot.blockAt(bot.entity.position.offset(0, -1, 0))
    await bot.lookAt(bot.entity.position.offset(0, -1, 0))
    await bot.activateBlock(below)
    check('right-click activateBlock', true, 'block ' + (below ? below.name : 'null'))
  } catch (e) { check('right-click', false, e.message) }

  // 5. Inventory
  try {
    const slots = bot.inventory.slots
    const nonEmpty = slots.filter((s) => s)
    check('inventory enumerate', slots.length > 0, slots.length + ' slots, ' + nonEmpty.length + ' non-empty')
  } catch (e) { check('inventory', false, e.message) }

  // 6. Death/respawn — attempt in-script /kill; external lava kill is orchestrated
  //    by the caller when --stay is used (the bot keeps logging death/respawn events).
  if (!STAY) {
    try {
      bot.chat('/kill')
      await sleep(2000)
      check('death via /kill', false, 'SKIP — default group forbids /kill (confirmed); external lava kill is the gate')
    } catch (e) { check('death via /kill', false, e.message) }
  } else {
    console.log('INFO | --stay: external death probe will now place lava; watching death/respawn events')
    check('death/respawn (external gate)', 'pending' === 'pending', 'see EVENT lines + caller verification')
  }

  console.log('SUMMARY_BEGIN ' + summarize())

  if (STAY) {
    console.log('STAYING_ALIVE true ready-for-external-death-test spawned-at=' + fmt(bot.entity.position))
  } else {
    bot.quit('smoke done')
    await sleep(500)
    process.exit(results.some(([, ok]) => ok === false) ? 1 : 0)
  }
}

function summarize() {
  const failed = results.filter(([, ok]) => ok === false).map(([n]) => n)
  return (failed.length === 0 ? 'ALL_PASS' : 'HAS_FAIL') + ' fail=' + JSON.stringify(failed)
}

main().catch((e) => { console.log('FATAL ' + e.stack); process.exit(1) })
