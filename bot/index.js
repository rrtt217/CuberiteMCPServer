'use strict'
// bot/index.js — entry point: config → bot lifecycle → MCP endpoint → signals.
//   node index.js [--config <bot.ini>]
// Environment overrides also supported (MCPS_BOT_*).

const { pick } = require('./config')
const { BotHandle } = require('./bot')
const { makeServer } = require('./mcp')
const { buildRegistry } = require('./tools')

const cfg = pick()

function log(...a) { console.error('[bot]', ...a) }

log('starting pid=' + process.pid + ' cfg=' + JSON.stringify({ host: cfg.host, port: cfg.port,
  username: cfg.username, randomUsername: cfg.randomUsername, version: cfg.version,
  mcp: cfg.mcpBind + ':' + cfg.mcpPort }))

const botCtl = new BotHandle(cfg, log)
const registry = buildRegistry(botCtl)
const server = makeServer(registry, log)

botCtl.connect()

server.listen(cfg.mcpPort, cfg.mcpBind, () => {
  log('MCP endpoint listening on http://' + cfg.mcpBind + ':' + cfg.mcpPort + '/mcp (stateless)')
})

server.on('error', (e) => {
  log('MCP server error: ' + e.message)
  process.exit(1)
})

// Signals: quit gracefully (Node exits by default on SIGTERM; this makes the
// server see a clean disconnect instead of a timeout).
function shutdown(sig) {
  log('signal ' + sig + ' -> quitting bot')
  botCtl.stop('sigterm')
  server.close(() => process.exit(0))
  setTimeout(() => process.exit(0), 800).unref()
}
process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))
process.on('SIGQUIT', () => shutdown('SIGQUIT'))
process.on('uncaughtException', (e) => {
  log('uncaught exception: ' + (e && e.stack || e))
  // Keep the MCP endpoint alive; log and continue unless the bot is gone.
})
process.on('unhandledRejection', (r) => log('unhandled rejection: ' + (r && (r.stack || r.message) || r)))
