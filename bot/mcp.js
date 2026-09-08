'use strict'
// bot/mcp.js — stateless HTTP JSON-RPC (MCP Streamable-HTTP-subset) endpoint.
//
// Contract (see docs/handoff-mineflayer-migration.md §4, and the actual consumer
// ~/.dsh/.agent-presets/cuberite/mcp-mcc.mjs):
//   - POST /mcp only (no GET/SSE push; the bridge is POST-only and JSON.parse()s
//     the body directly → we ALWAYS answer plain JSON, never SSE framing).
//   - Stateless: never send/accept session ids (kills the "restart invalidates
//     session" class of bugs forever).
//   - Methods: initialize, notifications/initialized, tools/list, tools/call, ping.
//   - tools/list must never return an empty array (bridge throws otherwise) —
//     'ping' is always registered as a fail-safe.
//   - tools/call result: { content: [{ type: 'text', text }], isError?: bool }.
//   - Response headers: Content-Length, Connection: close, MCP-Protocol-Version.

const http = require('http')
const PROTOCOL_VERSION = '2025-06-18'

function makeServer(registry, log) {
  const server = http.createServer((req, res) => {
    if (req.method === 'GET') {
      res.writeHead(405, { 'Content-Type': 'application/json', Connection: 'close' })
      res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32601, message: 'GET not supported; use POST /mcp' } }))
      return
    }
    if (req.method !== 'POST') {
      res.writeHead(405, { 'Content-Type': 'application/json', Connection: 'close' })
      res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32601, message: 'method not allowed' } }))
      return
    }
    let body = ''
    req.on('data', (c) => { body += c })
    req.on('end', () => {
      let msg
      try { msg = JSON.parse(body) } catch (e) {
        send(res, { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } })
        return
      }
      handle(msg, res)
    })
    req.on('error', () => { try { res.destroy() } catch (e) { /* ignore */ } })
  })

  function send(res, obj) {
    const payload = JSON.stringify(obj)
    const headers = {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload),
      'Connection': 'close',
      'MCP-Protocol-Version': PROTOCOL_VERSION,
    }
    res.writeHead(200, headers)
    res.end(payload)
  }

  function handle(msg, res) {
    if (!msg || msg.jsonrpc !== '2.0') {
      send(res, { jsonrpc: '2.0', id: msg && msg.id !== undefined ? msg.id : null, error: { code: -32600, message: 'invalid request' } })
      return
    }
    const method = msg.method
    const id = msg.id !== undefined ? msg.id : null

    if (method === 'initialize') {
      const clientProto = msg.params && msg.params.protocolVersion
      send(res, {
        jsonrpc: '2.0', id,
        result: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: 'mcpserver-bot', version: require('./package.json').version },
        },
      })
      return
    }
    if (method === 'notifications/initialized' || method === 'notifications/cancelled' ||
        method === 'notifications/tools/list_changed' || method === 'notifications/progress') {
      // Standard MCP notifications are fire-and-forget, but our bridge client
      // (mcp-mcc.mjs) AWAITS this POST and would otherwise sit on Node's
      // requestTimeout (300s) before Node replies 408. Always answer with a
      // minimal result so both await-ing and fire-and-forget clients unblock
      // instantly. (id echo, or null for notifications.)
      send(res, { jsonrpc: '2.0', id, result: {} })
      return
    }
    if (method === 'tools/list') {
      send(res, { jsonrpc: '2.0', id, result: { tools: registry.list() } })
      return
    }
    if (method === 'tools/call') {
      const name = msg.params && msg.params.name
      const args = (msg.params && msg.params.arguments) || {}
      const tool = registry.get(name)
      if (!tool) {
        send(res, { jsonrpc: '2.0', id, error: { code: -32602, message: 'unknown tool: ' + name } })
        return
      }
      Promise.resolve()
        .then(() => tool.handler(args))
        .then((result) => {
          // Accepted result shapes:
          //   { text, isError? }                       — pre-formatted text
          //   { success, data?, errorCode? }           — raw action result:
          //     serialized to the MCC-style JSON text so handlers can return
          //     action results directly.
          let text = ''
          let isError = false
          if (result && typeof result.text === 'string') {
            text = result.text
            isError = !!result.isError
          } else if (result && result.success !== undefined) {
            const o = { success: !!result.success }
            if (result.errorCode) o.errorCode = result.errorCode
            if (result.errorCode === undefined && result.data !== undefined) o.data = result.data
            if (result.data !== undefined) o.data = result.data
            text = JSON.stringify(o)
            isError = result.success === false
          } else {
            text = JSON.stringify(result)
          }
          const content = [{ type: 'text', text: String(text != null ? text : '') }]
          send(res, { jsonrpc: '2.0', id, result: { content, isError } })
        })
        .catch((err) => {
          send(res, { jsonrpc: '2.0', id, error: { code: -32603, message: err.message || String(err) } })
        })
      return
    }
    if (method === 'ping') {
      send(res, { jsonrpc: '2.0', id, result: {} })
      return
    }
    send(res, { jsonrpc: '2.0', id, error: { code: -32601, message: 'method not found: ' + method } })
  }

  return server
}

module.exports = { makeServer, PROTOCOL_VERSION }
