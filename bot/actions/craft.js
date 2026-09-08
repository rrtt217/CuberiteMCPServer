'use strict'
// bot/actions/craft.js — high-level crafting via mineflayer's recipe engine.
// mcc_craft(itemType, count, table?): non-table recipes use the 2x2 inventory
// grid; table recipes require table:{x,y,z} of a placed crafting table (the
// window is opened and closed automatically by bot.craft). Relies on the
// Cuberite click patch (no Confirm-Transaction wait) in mineflayer's
// inventory.js.
//
// Recipe data source is minecraft-data pc/1.12 (regenerated + installed via
// patch-package: patches/minecraft-data+3.115.0.patch expands every plank-based
// recipe to the 6 wood variants, fixes boat, adds missing stairs/fence). There
// is intentionally NO client-side recipe fallback anymore. If the data ever
// looks unpatched (fewer than 6 wood variants), a loud startup warning is
// logged so a regression fails visibly instead of silently.
const vec3 = require('vec3')

let dataGuardChecked = false
function checkRecipeDataGuard(b) {
  if (dataGuardChecked) return
  dataGuardChecked = true
  try {
    const Recipe = require('prismarine-recipe')(b.registry).Recipe
    const shaped = (Recipe.find(270, null) || []).filter((r) => r.inShape)
    if (shaped.length < 6) {
      console.error('[craft] WARNING: minecraft-data 1.12 recipes look unpatched: '
        + 'wooden_pickaxe variants=' + shaped.length + ' (expected 6). '
        + 'Run "npm install" (postinstall patch-package) or check '
        + 'patches/minecraft-data+3.115.0.patch is applied — crafting for non-dark-oak '
        + 'woods may fail with no_recipe.')
    } else {
      console.error('[craft] recipe data ok: wooden_pickaxe variants=' + shaped.length)
    }
  } catch (e) {
    console.error('[craft] could not run recipe-data guard:', e.message)
  }
}

module.exports = function craftActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }

  return {
    async craft(itemType, count, table) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      checkRecipeDataGuard(b)
      const it = String(itemType || '')
      const n = (count === undefined || count === null) ? 1 : Math.max(1, Math.floor(Number(count)))
      let typeId = null
      if (/^\d+$/.test(it)) {
        typeId = Number(it)
      } else if (b.registry && b.registry.itemsByName && b.registry.itemsByName[it]) {
        typeId = b.registry.itemsByName[it].id
      } else if (b.registry && b.registry.items) {
        const hit = Object.values(b.registry.items).find((i) => i && (i.name === it || i.displayName === it))
        if (hit) typeId = hit.id
      }
      if (typeId === null) {
        return { success: false, errorCode: 'no_recipe', data: { itemType: it, hint: 'unknown item name' } }
      }

      let recipe = null
      let tableBlock = null
      if (table && Number.isFinite(Number(table.x))) {
        const tpos = vec3(Math.floor(Number(table.x)), Math.floor(Number(table.y)), Math.floor(Number(table.z)))
        for (let attempt = 0; attempt < 10 && !tableBlock; attempt++) {
          try {
            const blk = b.blockAt(tpos)
            if (blk && blk.type === 58) tableBlock = blk
          } catch (e) { /* keep null */ }
          if (!tableBlock) await new Promise((r) => setTimeout(r, 250))
        }
      }
      const recipeUsable = (r) => {
        if (!r.inShape) return true
        const owned = b.inventory.items()
        for (const row of r.inShape) {
          for (const cell of row) {
            if (cell === null || cell === undefined) continue
            const cid = typeof cell === 'object' ? cell.id : cell
            if (cid === -1) continue // empty cell (prismarine-recipe normalizes null -> {id:-1})
            const cmeta = typeof cell === 'object' ? cell.metadata : null
            if (!owned.some((i) => i && i.type === cid && (cmeta == null || i.metadata === cmeta))) return false
          }
        }
        return true
      }
      try {
        const recipes = b.recipesFor(typeId, null, n, tableBlock)
        if (recipes && recipes.length > 0) {
          const usable = recipes.find(recipeUsable)
          if (usable) recipe = usable
        }
      } catch (e) { /* treat as no recipe below */ }
      if (!recipe) {
        return { success: false, errorCode: 'no_recipe',
          data: { itemType: it, hint: 'no usable recipe in minecraft-data. If the wood-variant data is missing, the minecraft-data patch may not be applied (check patches/minecraft-data+3.115.0.patch).' } }
      }

      const perResult = (recipe.result && recipe.result.count) || 1
      const cycles = Math.ceil(n / perResult)
      try {
        if (recipe.requiresTable) {
          if (!table || !Number.isFinite(Number(table.x))) {
            return { success: false, errorCode: 'needs_table', data: { itemType: it, hint: 'pass table:{x,y,z} of a placed crafting table' } }
          }
          const block = b.blockAt(vec3(Math.floor(Number(table.x)), Math.floor(Number(table.y)), Math.floor(Number(table.z))))
          if (!block || block.type !== 58) {
            return { success: false, errorCode: 'no_table_block', data: { table } }
          }
          await b.craft(recipe, cycles, block)
        } else {
          await b.craft(recipe, cycles)
        }
      } catch (e) {
        return { success: false, errorCode: 'craft_failed', data: { itemType: it, count: n, error: e.message, requiresTable: recipe.requiresTable } }
      }
      let resultCount = 0
      try { resultCount = b.inventory.count(recipe.result.id, recipe.result.metadata === undefined ? null : recipe.result.metadata) } catch (e) { /* ignore */ }
      return {
        success: true,
        data: { itemType: it, resultName: (recipe.result && recipe.result.name) || String(typeId), resultCount, count: n, requiresTable: recipe.requiresTable },
      }
    },
  }
}
