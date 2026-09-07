'use strict'
// bot/config.js — configuration loader. Precedence: CLI arg (--config <file>),
// environment, defaults. Bot-side config is simple key=value INI (bot.ini).

const fs = require('fs')

const DEFAULTS = {
  host: '127.0.0.1',
  port: 25568,
  username: 'TestBot',
  randomUsername: true,
  version: '1.12.2',          // max Cuberite protocol; 1.9-1.12.2 chunks need patches/prismarine-chunk (postinstall applies it)
  mcpBind: '127.0.0.1',
  mcpPort: 33333,
  reconnectAttempts: 5,
  reconnectBaseDelayMs: 5000,
  chatBufferSize: 100,
}

function parseIni(text) {
  const out = {}
  let section = null
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim()
    if (line === '' || line.startsWith(';') || line.startsWith('#')) continue
    if (line.startsWith('[') && line.endsWith(']')) { section = line.slice(1, -1); continue }
    const eq = line.indexOf('=')
    if (eq === -1) continue
    const key = line.slice(0, eq).trim()
    const val = line.slice(eq + 1).trim()
    out[(section ? section + '.' : '') + key.toLowerCase()] = val
  }
  return out
}

function pick(configFile) {
  const argv = process.argv.slice(2)
  let file = configFile || null
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--config' && argv[i + 1]) file = argv[i + 1]
  }
  const cfg = { ...DEFAULTS }
  if (file && fs.existsSync(file)) {
    const ini = parseIni(fs.readFileSync(file, 'utf8'))
    const map = {
      'bot.host': 'host',
      'bot.port': 'port',
      'bot.username': 'username',
      'bot.randomusername': 'randomUsername',
      'bot.version': 'version',
      'bot.mcpbind': 'mcpBind',
      'bot.mcpport': 'mcpPort',
      'bot.reconnectattempts': 'reconnectAttempts',
      'bot.chatbuffersize': 'chatBufferSize',
    }
    for (const [iniKey, cfgKey] of Object.entries(map)) {
      if (ini[iniKey] !== undefined) cfg[cfgKey] = ini[iniKey]
    }
  }
  const envMap = { MCPS_BOT_HOST: 'host', MCPS_BOT_PORT: 'port', MCPS_BOT_USERNAME: 'username',
    MCPS_BOT_VERSION: 'version', MCPS_BOT_MCP_PORT: 'mcpPort', MCPS_BOT_MCP_BIND: 'mcpBind' }
  for (const [env, key] of Object.entries(envMap)) {
    if (process.env[env]) cfg[key] = process.env[env]
  }
  cfg.port = Number(cfg.port) || DEFAULTS.port
  cfg.mcpPort = Number(cfg.mcpPort) || DEFAULTS.mcpPort
  cfg.reconnectAttempts = Number(cfg.reconnectAttempts) || DEFAULTS.reconnectAttempts
  cfg.randomUsername = String(cfg.randomUsername).toLowerCase() !== 'false'
  return cfg
}

module.exports = { DEFAULTS, pick }
