'use strict'
// bot/actions/windows.js — in-game GUI / container window operations.
// Stateless MCP endpoint + stateful client windows: the window session lives in
// the bot process (bot.currentWindow); tools operate on "the current window".
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const KNOWN_BLOCKS = new Set(['chest', 'trapped_chest', 'ender_chest', 'furnace', 'lit_furnace',
  'dispenser', 'dropper', 'crafting_table', 'enchanting_table', 'anvil', 'brewing_stand',
  'hopper', 'trapped_chest', 'minecart_chest'])

module.exports = function windowActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }
  function activeWindow() {
    const b = botCtl.bot
    if (!b || !b.currentWindow) {
      // fall back: bot.currentWindow on some versions lives under bot.currentWindow
      return null
    }
    return b.currentWindow
  }
  function itemSection(w, slot) {
    if (w.inventorySlotRange) return slot >= w.inventorySlotRange.start ? 'player' : 'container'
    // Fallback: player portion is the trailing 36 slots of a container window.
    const playerStart = (w.slots && w.slots.length) ? w.slots.length - 36 : 36
    return slot >= playerStart ? 'player' : 'container'
  }

  return {
    // Open a container/block window at world coords. closeCurrent=true closes any
    // open window first (same semantics as MCC mcc_container_open_at).
    async openContainer(x, y, z, closeCurrent) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const vec3 = require('vec3')
      const block = b.blockAt(vec3(Math.floor(x), Math.floor(y), Math.floor(z)))
      if (!block || block.type === 0) {
        return { success: false, errorCode: 'block_not_found', data: { x: Math.floor(x), y: Math.floor(y), z: Math.floor(z) } }
      }
      if (closeCurrent !== false && b.currentWindow) {
        try { b.currentWindow.close() } catch (e) { /* ignore */ }
        await sleep(120)
      }
      try {
        await b.lookAt(block.position.offset(0.5, 0.5, 0.5))
        await sleep(80)
        // mineflayer 4.38 openContainer only accepts modern (1.13+) chest-like
        // window names; 1.12 names like crafting_table / furnace / enchanting_table
        // are rejected ("containerToOpen is neither a block nor an entity"). For
        // those, activate the block directly and wait for the window.
        const chestlike = new Set(['chest', 'trapped_chest', 'ender_chest', 'dispenser',
          'dropper', 'hopper', 'container', 'minecart_chest'])
        let window
        if (block.name && chestlike.has(block.name)) {
          window = await b.openContainer(block)
        } else {
          b.activateBlock(block)
          window = await new Promise((res, rej) => {
            const timer = setTimeout(() => rej(new Error('windowOpen timeout')), 6000)
            b.once('windowOpen', (w) => { clearTimeout(timer); res(w) })
          })
        }
        // Cuberite (1.8) processes window clicks and broadcasts slot updates but
        // never sends the Confirm Transaction (0x33) response that mineflayer
        // waits for by default; self-confirm locally instead (requiresConfirmation
        // gates the wait — see mineflayer inventory.js clickWindow).
        window.requiresConfirmation = false
        const slots = window.slots ? window.slots.length : 0
        return { success: true, data: { x: block.position.x, y: block.position.y, z: block.position.z,
          block: block.name, windowId: window.id, slotCount: slots, windowType: window.windowType || null } }
      } catch (e) {
        return { success: false, errorCode: 'open_failed', data: { error: e.message, x: Math.floor(x), y: Math.floor(y), z: Math.floor(z) } }
      }
    },

    // List the current window: container slots first, then player slots.
    windowSlots() {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const w = activeWindow()
      if (!w) return { success: false, errorCode: 'no_window_open' }
      const items = []
      if (w.slots && Array.isArray(w.slots)) {
        for (const slot of w.slots) {
          if (!slot) continue
          items.push({
            slot: slot.slot,
            section: itemSection(w, slot.slot),
            name: slot.name || slot.displayName || slot.type,
            displayName: slot.displayName || null,
            type: slot.type,
            count: slot.count,
          })
        }
      }
      const held = b.heldItem ? { name: b.heldItem.name || b.heldItem.type, type: b.heldItem.type, count: b.heldItem.count } : null
      return {
        success: true,
        data: {
          windowId: w.id,
          windowType: w.windowType || null,
          itemCount: items.length,
          items,
          heldItem: held,
        },
      }
    },

    // Generic window click. mode maps to mouseButton when clickMode is not
    // given (backwards compat); callers may pass clickMode explicitly.
    async clickWindowAction(slot, mouseButton, clickMode) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const w = activeWindow()
      if (!w) return { success: false, errorCode: 'no_window_open' }
      const s = Number(slot)
      const mb = mouseButton === undefined || mouseButton === null ? 0 : Number(mouseButton)
      const cm = clickMode === undefined || clickMode === null ? 0 : Number(clickMode)
      if (!Number.isInteger(s) || s < 0) return { success: false, errorCode: 'invalid_args', data: { slot } }
      try {
        await b.clickWindow(s, mb, cm)
      } catch (e) {
        return { success: false, errorCode: 'click_failed', data: { error: e.message } }
      }
      return { success: true, data: { slot: s, mouseButton: mb, clickMode: cm } }
    },

    // Deposit a named/counted item from the player inventory into the window.
    async deposit(itemType, count) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const w = activeWindow()
      if (!w) return { success: false, errorCode: 'no_window_open' }
      // Crafting stations are not containers: deposit/withdraw are meaningless.
      if (w.slots && w.slots.length === 46) {
        return { success: false, errorCode: 'not_a_container', data: { hint: 'crafting table is a crafting station, not a container; use mcc_inventory_window_action to fill the grid and click slot 0 for the result, or use mcc_craft' } }
      }
      const it = String(itemType)
      const n = (count === undefined || count === null) ? null : Number(count)
      // resolve name -> numeric type using the bot's registry
      let typeId = null
      if (/^\d+$/.test(it)) {
        typeId = Number(it)
      } else {
        const itemDef = b.registry && b.registry.itemsByName && b.registry.itemsByName[it]
        typeId = itemDef ? itemDef.id : null
      }
      if (typeId === null) {
        // fall back to matching the player's inventory items by name
        const owned = (b.inventory.items() || []).find((i) => i && (i.name === it || i.displayName === it))
        typeId = owned ? owned.type : null
      }
      if (typeId === null) return { success: false, errorCode: 'invalid_args', data: { itemType: it } }
      try {
        await w.deposit(typeId, null, n, null)
      } catch (e) {
        return { success: false, errorCode: 'deposit_failed', data: { error: e.message, itemType: it, count: n } }
      }
      return { success: true, data: { itemType: it, count: n, depositCount: n === null ? 1 : n } }
    },

    // Withdraw a named/counted item from the window into the player inventory.
    async withdraw(itemType, count) {
      const w = activeWindow()
      if (!w) return { success: false, errorCode: 'no_window_open' }
      if (w.slots && w.slots.length === 46) {
        return { success: false, errorCode: 'not_a_container', data: { hint: 'crafting table is a crafting station, not a container; withdraw only applies to chest-like containers' } }
      }
      const it = String(itemType)
      const n = (count === undefined || count === null) ? null : Number(count)
      let typeId = null
      if (/^\d+$/.test(it)) {
        typeId = Number(it)
      } else {
        const b = botCtl.bot
        const itemDef = b && b.registry && b.registry.itemsByName && b.registry.itemsByName[it]
        typeId = itemDef ? itemDef.id : null
      }
      if (typeId === null) return { success: false, errorCode: 'invalid_args', data: { itemType: it } }
      try {
        await w.withdraw(typeId, null, n, null)
      } catch (e) {
        return { success: false, errorCode: 'withdraw_failed', data: { error: e.message, itemType: it, count: n } }
      }
      return { success: true, data: { itemType: it, count: n, withdrawnCount: n === null ? 1 : n } }
    },

    // Close the current window.
    close() {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const w = activeWindow()
      if (!w) return { success: false, errorCode: 'no_window_open' }
      try {
        if (typeof w.close === 'function') { w.close() } else { b.closeWindow(w) }
      } catch (e) {
        return { success: false, errorCode: 'close_failed', data: { error: e.message } }
      }
      return { success: true, data: { closed: true } }
    },
  }
}
