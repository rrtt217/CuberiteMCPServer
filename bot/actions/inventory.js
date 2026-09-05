'use strict'
// bot/actions/inventory.js — inventory read & manipulation

function slotToObj(slot) {
  if (!slot) return null
  return {
    slot: slot.slot,
    type: slot.type || (slot.name || null),
    id: slot.type,
    count: slot.count,
    name: slot.name || slot.displayName || slot.type,
    displayName: slot.displayName || null,
  }
}

module.exports = function inventoryActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }
  return {
    snapshot() {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const slots = (b.inventory.slots || []).map(slotToObj).filter((s) => s && s.id && s.id !== -1 && s.count > 0)
      return {
        success: true,
        data: {
          count: slots.length,
          inventoryName: b.inventory.windowType || 'player_inventory',
          heldItem: b.heldItem ? slotToObj(b.heldItem) : null,
          items: slots,
        },
      }
    },
    search(query, limit) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const q = String(query || '').toLowerCase()
      const slots = (b.inventory.slots || []).map(slotToObj).filter((s) => s && s.id > 0 && s.count > 0)
      const matched = slots.filter((s) => (s.name && s.name.toLowerCase().includes(q)) ||
        (s.displayName && s.displayName.toLowerCase().includes(q)))
      return { success: true, data: { total: slots.length, count: matched.length, items: matched.slice(0, (limit || 100)) } }
    },
    async selectItem(itemType, preferredSlot) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const hay = (b.inventory.items() || [])
      const q = String(itemType).toLowerCase()
      const found = hay.find((it) => (it.name && it.name.toLowerCase().includes(q)) ||
        (it.displayName && it.displayName.toLowerCase().includes(q)) ||
        (it.type && String(it.type) === q))
      if (!found) return { success: false, errorCode: 'invalid_args', data: { itemType } }
      try {
        if (preferredSlot && preferredSlot >= 0 && preferredSlot <= 8) await b.setQuickBarSlot(preferredSlot)
        await b.equip(found, 'hand')
      } catch (e) { return { success: false, errorCode: 'equip_failed', data: { error: e.message } } }
      return { success: true, data: { itemType: found.name, slot: found.slot, held: slotToObj(b.heldItem) } }
    },
    async changeHotbarSlot(slot) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const s = Number(slot)
      if (!Number.isInteger(s) || s < 1 || s > 9) return { success: false, errorCode: 'invalid_args', data: { slot, min: 1, max: 9 } }
      try { await b.setQuickBarSlot(s - 1) } catch (e) { return { success: false, errorCode: 'slot_failed', data: { error: e.message } } }
      return { success: true, data: { slot: s, held: b.heldItem ? slotToObj(b.heldItem) : null } }
    },
  }
}
