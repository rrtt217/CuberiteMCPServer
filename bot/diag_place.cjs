
'use strict'
const mineflayer = require('mineflayer')
const username = 'DiagBot' + Math.floor(Math.random() * 9000 + 1000)
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25568, username, auth: 'offline', version: '1.8.9' })
bot.once('spawn', async () => {
  console.log('DIAG_SPAWNED ' + username + ' at ' + bot.entity.position.toString())
  // Poll for the console-injected stone item (up to 20s)
  let stone = null
  for (let i = 0; i < 40; i++) {
    stone = bot.inventory.findInventoryItem(1, null) // type 1
    if (stone) break
    await new Promise((r) => setTimeout(r, 500))
  }
  try {
    console.log('inventory:', (bot.inventory.items() || []).map(i => i.name + 'x' + i.count).join(',') || '(empty)')
    if (!stone) { console.log('NO_STONE'); process.exit(0) }
    await bot.equip(stone, 'hand')
      console.log('held:', bot.heldItem && bot.heldItem.name)
      // instrument the outbound packet by wrapping _client.write
      // capture raw serialized bytes for block_place
      try {
        bot._client.serializer.on('data', (buf) => {
          // serializer emits packet id + payload (frame sans length prefix? inspect both)
          const hex = buf.toString('hex')
          if (hex.includes('080108000003') || /^0809/.test(hex) || hex.startsWith('08')) {
            // find the 0x08 packet: search for the payload start heuristically
            console.log('RAW_PKT len=' + buf.length + ' head=' + hex.slice(0, 80) + ' ... tail=' + hex.slice(-16))
          }
        })
      } catch (e) { console.log('serializer hook err ' + e.message) }
      const origWrite = bot._client.write.bind(bot._client)
      let attempt = 0
      bot._client.write = (name2, params, writeCb) => {
        if (name2 === 'block_place') {
          attempt++
          // experiment: clamp cursor values to the 0-15 range servers expect
          const p2 = { ...params, cursorX: 8, cursorY: attempt === 1 ? 8 : 15, cursorZ: 8 }
          console.log('OUT block_place v' + attempt + '=%j', p2)
          return origWrite(name2, p2, writeCb)
        }
        return origWrite(name2, params, writeCb)
      }
      // target at ground level +1 in z (ref = (tx, ty-1, tz) is the ground block)
      const p = bot.entity.position
      const tx = Math.floor(p.x), tz = Math.floor(p.z) + 2
      const ty = Math.floor(p.y)
      await bot.lookAt(bot.entity.position.offset(0, 0, 1))
      const ref = bot.blockAt(require('vec3')(tx, ty - 1, tz))
      console.log('ref block at (' + tx + ',' + (ty-1) + ',' + tz + ') = ' + (ref ? ref.name + ' t=' + ref.type : 'null'))
      const t0 = Date.now()
      try {
        await bot.placeBlock(ref, require('vec3')(0, 1, 0))
        console.log('PLACE_OK after ' + (Date.now() - t0) + 'ms')
        const placed = bot.blockAt({ x: tx, y: ty, z: tz })
        console.log('placed:', placed && placed.name, placed && placed.type)
      } catch (e) {
        console.log('PLACE_FAIL: ' + e.message)
      }
    } catch (e) { console.log('DIAG_ERR ' + e.message) }
    setTimeout(() => process.exit(0), 2000)
})
bot.on('kicked', (r) => { console.log('KICKED ' + r); process.exit(0) })
bot.on('error', (e) => { console.log('ERR ' + e.message) })
setTimeout(() => { console.log('DIAG_TIMEOUT'); process.exit(0) }, 15000)