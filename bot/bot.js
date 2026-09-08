'use strict'
// bot/bot.js — mineflayer connection lifecycle: spawn/death/health/kicked/error/end,
// chat buffer, limited auto-reconnect (exponential backoff), and rebuild()
// (replace the bot instance — replaces MCC's "restart process with fresh identity").

const mineflayer = require('mineflayer')
const { pathfinder } = require('mineflayer-pathfinder')

class BotHandle {
  constructor(cfg, log) {
    this.cfg = cfg
    this.log = log || ((...a) => console.error('[bot]', ...a))
    this.bot = null
    this.state = 'stopped'        // stopped | connecting | online | reconnecting | dead-error
    this.chatBuffer = []
    this.reconnectCount = 0
    this.spawnedAt = null
    this.startedAt = Date.now()
    this.entityId = null
    this.lastError = null
    this.lastKickReason = null
    this.reconnectTimer = null
    this.suppressReconnect = false
  }

  _pushChat(txt) {
    if (!txt) return
    this.chatBuffer.push(txt)
    if (this.chatBuffer.length > this.cfg.chatBufferSize) this.chatBuffer.shift()
  }

  username() {
    const base = this.cfg.username || 'TestBot'
    if (this.cfg.randomUsername) return base + '_' + Math.floor(Math.random() * 9000 + 1000)
    return base
  }

  connect() {
    if (this.state === 'connecting' || this.state === 'online') return
    const username = this.username()
    this.state = 'connecting'
    this.lastKickReason = null
    this.log('connecting as ' + username + ' host=' + this.cfg.host + ':' + this.cfg.port +
      ' version=' + (this.cfg.version || 'auto'))
    const bot = mineflayer.createBot({
      host: this.cfg.host,
      port: this.cfg.port,
      username,
      auth: 'offline',
      version: this.cfg.version || undefined,
      respawn: true,
      hideErrors: true,
    })
    this.bot = bot
    try { bot.loadPlugin(pathfinder) } catch (e) { this.log('pathfinder load failed: ' + e.message) }
    // Cuberite never sends Confirm Transaction (0x33) responses.  Monkey-patch
    // every window (inventory + future container / crafting-table windows) so
    // clickWindow never waits for a transaction -> never hangs.
    try { bot.inventory.requiresConfirmation = false; bot.inventory.transactionRequiresConfirmation = () => false } catch (e) { /* ignore */ }
    bot.on('windowOpen', (window) => {
      try { window.requiresConfirmation = false; window.transactionRequiresConfirmation = () => false } catch (e) { /* ignore */ }
    })

    bot.once('spawn', () => {
      this.state = 'online'
      this.spawnedAt = Date.now()
      this.entityId = bot.entity ? bot.entity.id : null
      this.reconnectCount = 0
      this.log('SPAWNED username=' + username + ' pos=' + this.posStr() + ' after ' +
        (this.spawnedAt - this.startedAt) + 'ms')
    })

    bot.on('chat', (username2, msg) => { this._pushChat('<' + username2 + '> ' + msg) })
    bot.on('message', (m) => {
      try {
        const txt = typeof m === 'string' ? m : (m.toString ? m.toString() : String(m))
        this._pushChat(txt)
      } catch (e) { /* ignore */ }
    })
    bot.on('kicked', (reason, loggedIn) => {
      this.lastKickReason = String(reason)
      this.log('KICKED reason=' + this.lastKickReason)
      this._scheduleReconnect('kicked')
    })
    bot.on('error', (err) => {
      this.lastError = err && err.message ? err.message : String(err)
      if (this.state === 'online') {
        this.log('ERROR ' + this.lastError)
        this._scheduleReconnect('error')
      } else if (this.state === 'connecting') {
        this.log('CONNECT ERROR ' + this.lastError)
        this._scheduleReconnect('connect-error')
      }
    })
    bot.on('end', (reason) => {
      this.log('END reason=' + reason)
      if (this.state !== 'stopped' && !this.suppressReconnect) this._scheduleReconnect('end')
    })
    bot.on('death', () => this.log('DEATH pos=' + this.posStr()))
    bot.on('health', () => this.log('health=' + bot.health + ' food=' + bot.food))
  }

  _scheduleReconnect(why) {
    if (this.state === 'stopped' || this.suppressReconnect) return
    if (this.reconnectCount >= this.cfg.reconnectAttempts) {
      this.state = 'dead-error'
      this.log('reconnect attempts exhausted after ' + why + '; stopping (use rebuild)')
      return
    }
    this.reconnectCount++
    const delay = this.cfg.reconnectBaseDelayMs * Math.pow(2, this.reconnectCount - 1)
    this.state = 'reconnecting'
    this.log('reconnect ' + this.reconnectCount + '/' + this.cfg.reconnectAttempts +
      ' after ' + delay + 'ms (why=' + why + ')')
    this.reconnectTimer = setTimeout(() => this.connect(), delay)
  }

  // Replace the bot instance (fresh identity optional). Stateless MCP endpoint means
  // the HTTP side never notices; callers just get fresh tool results afterwards.
  rebuild(opts) {
    opts = opts || {}
    this.suppressReconnect = true
    this._clearTimer()
    this.chatBuffer = []
    if (this.bot) {
      try { this.bot.quit('rebuild') } catch (e) { /* ignore */ }
      try { this.bot.removeAllListeners() } catch (e) { /* ignore */ }
    }
    this.bot = null
    this.state = 'stopped'
    if (opts.username) this.cfg.username = opts.username
    if (opts.randomUsername !== undefined) this.cfg.randomUsername = !!opts.randomUsername
    this.reconnectCount = 0
    this.startedAt = Date.now()
    this.suppressReconnect = false
    this.connect()
    return { success: true, data: { action: 'rebuild', username: this.username() } }
  }

  stop(reason) {
    this._clearTimer()
    this.suppressReconnect = true
    this.state = 'stopped'
    if (this.bot) {
      try { this.bot.quit(reason || 'stop') } catch (e) { /* ignore */ }
      try { this.bot.removeAllListeners() } catch (e) { /* ignore */ }
      this.bot = null
    }
  }

  _clearTimer() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null }
  }

  pos() {
    const e = this.bot && this.bot.entity
    if (!e || !e.position) return null
    return { x: e.position.x, y: e.position.y, z: e.position.z }
  }

  posStr() {
    const p = this.pos()
    return p ? p.x.toFixed(1) + ',' + p.y.toFixed(1) + ',' + p.z.toFixed(1) : 'null'
  }

  status() {
    const b = this.bot
    return {
      enabled: true,
      running: this.state === 'online',
      state: this.state,
      username: b && b.username ? b.username : this.username(),
      usernameConfigured: this.cfg.username,
      randomUsername: !!this.cfg.randomUsername,
      version: this.cfg.version || (b && b.version) || null,
      host: this.cfg.host,
      port: this.cfg.port,
      mcp_port: this.cfg.mcpPort,
      pid: process.pid,
      spawned_at_ms: this.spawnedAt ? (Date.now() - this.spawnedAt) : null,
      uptime_ms: Date.now() - this.startedAt,
      reconnect_count: this.reconnectCount,
      last_error: this.lastError,
      last_kick: this.lastKickReason,
      health: b ? b.health : null,
      food: b ? b.food : null,
      position: this.pos(),
      held_item: b && b.heldItem ? (b.heldItem.displayName || b.heldItem.name) : null,
      time_of_day: b && b.time ? b.time.timeOfDay : null,
      dimension: b && b.game ? b.game.dimension : null,
      chat_buffer_len: this.chatBuffer.length,
    }
  }

  // Send chat/command. Returns { success, detail }.
  sendChat(text) {
    if (this.state !== 'online' || !this.bot) return { success: false, errorCode: 'bot_offline' }
    try { this.bot.chat(String(text)) } catch (e) { return { success: false, errorCode: 'send_failed', data: { error: e.message } } }
    return { success: true }
  }
}

module.exports = { BotHandle }
