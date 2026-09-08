'use strict'
// bot/actions/craft.js — high-level crafting via mineflayer's recipe engine.
// mcc_craft(itemType, count, table?): non-table recipes use the 2x2 inventory
// grid; table recipes require table:{x,y,z} of a placed crafting table (the
// window is opened and closed automatically by bot.craft). Relies on the
// Cuberite click patch (no Confirm-Transaction wait) in mineflayer's
// inventory.js.
//
// minecraft-data 1.12.2 recipes are incomplete: several component recipes
// (stick, crafting_table, pickaxes) only list the dark-oak plank variant.
// When no mcdata recipe matches the items actually in the inventory, we
// synthesize a vanilla-shaped recipe from FALLBACK_SHAPES using the metadata
// of the matching items in stock. The Cuberite server applies recipes by
// shape, so any wood type works.
const vec3 = require('vec3')

// Marker letters: P=planks(5), S=stick(280), C=cobblestone(4), '.'=empty cell
const FALLBACK_SHAPES = {
  280: { requiresTable: false, result: { id: 280, count: 4, metadata: 0 }, rows: ['P', 'P'] },
  58: { requiresTable: false, result: { id: 58, count: 1, metadata: 0 }, rows: ['PP', 'PP'] },
  270: { requiresTable: true, result: { id: 270, count: 1, metadata: 0 }, rows: ['PPP', '.S.', '.S.'] }, // wooden_pickaxe (sticks MIDDLE column)
  274: { requiresTable: true, result: { id: 274, count: 1, metadata: 0 }, rows: ['CCC', '.S.', '.S.'] }, // stone_pickaxe (sticks MIDDLE column)
}
const MARKER_IDS = { P: 5, S: 280, C: 4 }

console.error('[craft] loaded with FALLBACK_SHAPES keys:', Object.keys(FALLBACK_SHAPES).join(','))

module.exports = function craftActions(botCtl) {
  function assertOnline() {
    const b = botCtl.bot
    if (botCtl.state !== 'online' || !b) return null
    return b
  }

  // metadata of the first inventory item of this type (0 if absent/unset)
  function invMetaOf(b, typeId) {
    try {
      const found = (b.inventory.items() || []).find((i) => i && i.type === typeId)
      return found ? (found.metadata == null ? 0 : found.metadata) : 0
    } catch (e) { return 0 }
  }

  // Build a synthetic shaped recipe from the fallback table.
  function synthRecipe(b, typeId) {
    const fb = FALLBACK_SHAPES[typeId]
    if (!fb) return null
    const inShape = []
    for (const row of fb.rows) {
      const cells = []
      for (const ch of row) {
        if (ch === '.') { cells.push({ id: -1, metadata: 0 }); continue }
        const id = MARKER_IDS[ch]
        if (id === undefined) return null
        cells.push({ id, metadata: invMetaOf(b, id) })
      }
      inShape.push(cells)
    }
    return {
      requiresTable: fb.requiresTable,
      result: fb.result,
      inShape,
      delta: [],
      fallback: true,
    }
  }

  return {
    async craft(itemType, count, table) {
      const b = assertOnline()
      if (!b) return { success: false, errorCode: 'bot_offline' }
      const it = String(itemType || '')
      const n = (count === undefined || count === null) ? 1 : Math.max(1, Math.floor(Number(count)))
      // Resolve name -> numeric id (minecraft-data recipes are keyed by id).
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
      let usedFallback = false
      // Resolve an optional crafting table block so requiresTable recipes are
      // eligible (mineflayer's recipesFor filters them out when craftingTable
      // is null). After a teleport the target chunk may not be loaded yet, so
      // retry blockAt briefly before giving up.
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
          // Prefer a recipe whose ingredients exist in inventory with matching
          // metadata (regenerated 1.12 recipes have one variant per wood type).
          const usable = recipes.find(recipeUsable)
          if (usable) recipe = usable
        }
      } catch (e) { /* fall through to fallback */ }
      if (!recipe) {
        recipe = synthRecipe(b, typeId)
        usedFallback = !!recipe
      }
      if (!recipe) {
        return { success: false, errorCode: 'no_recipe', data: { itemType: it, fallbackCovered: !!FALLBACK_SHAPES[typeId] } }
      }

      const perResult = (recipe.result && recipe.result.count) || 1
      // bot.craft(recipe, count) runs the recipe 'count' times; convert the
      // requested item count into the number of craft cycles needed.
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
        return { success: false, errorCode: 'craft_failed', data: { itemType: it, count: n, error: e.message, requiresTable: recipe.requiresTable, fallback: usedFallback } }
      }
      let resultCount = 0
      try { resultCount = b.inventory.count(recipe.result.id, recipe.result.metadata === undefined ? null : recipe.result.metadata) } catch (e) { /* ignore */ }
      return {
        success: true,
        data: { itemType: it, resultName: (recipe.result && recipe.result.name) || String(typeId), resultCount, count: n, requiresTable: recipe.requiresTable, fallback: usedFallback },
      }
    },
  }
}
