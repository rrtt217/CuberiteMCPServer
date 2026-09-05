// docs/capture-baseline.mjs — capture the live MCC MCP tool baseline for the
// mineflayer migration handoff (§5 of docs/handoff-mineflayer-migration.md).
//
// Usage: node docs/capture-baseline.mjs [--sample]
//   --sample  additionally runs one representative sample call per tool.
// Requires the MCC bot to be online with its embedded MCP server on :33333.

const URL = process.env.MCP_URL || 'http://127.0.0.1:33333/mcp'
const PROTO = '2025-06-18'
const SAMPLE = process.argv.includes('--sample')

async function post(body, sessionId) {
  const headers = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
  }
  if (sessionId) headers['Mcp-Session-Id'] = sessionId
  const res = await fetch(URL, { method: 'POST', headers, body: JSON.stringify(body) })
  const sid = res.headers.get('mcp-session-id')
  const text = await res.text()
  // MCC frames responses as SSE (event: message\ndata: {...}); the harness
  // bridge (mcp-mcc.mjs) expects plain JSON and would fail here — note that.
  let json = null
  try { json = JSON.parse(text) } catch { /* maybe SSE */ }
  if (!json) {
    const data = text.split(/\n/).filter((l) => l.startsWith('data:'))
      .map((l) => l.slice(5).trim()).join('')
    if (data) { try { json = JSON.parse(data) } catch { /* unrecoverable */ } }
  }
  return { res, text, json, sid }
}

function render(content) {
  if (!Array.isArray(content)) return String(content ?? '')
  return content.filter((b) => b && b.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text).join('\n')
}

const init = await post({ jsonrpc: '2.0', id: 1, method: 'initialize',
  params: { protocolVersion: PROTO, capabilities: {},
    clientInfo: { name: 'baseline-capture', version: '1.0' } } }, null)
console.log('=== initialize ===')
console.log('http:', init.res.status, '| content-type:', init.res.headers.get('content-type'),
  '| session-id:', init.sid)
console.log('raw:', init.text.trim())
let sessionId = init.sid || null

if (init.json && !init.json.error) {
  await post({ jsonrpc: '2.0', method: 'notifications/initialized' }, sessionId)
    .catch((e) => console.log('initialized notify err:', e.message))

  const tl = await post({ jsonrpc: '2.0', id: 2, method: 'tools/list' }, sessionId)
  console.log('\n=== tools/list ===')
  console.log('http:', tl.res.status)
  if (tl.json && tl.json.result && Array.isArray(tl.json.result.tools)) {
    const tools = tl.json.result.tools
    console.log('TOOLS_COUNT=' + tools.length)
    for (const t of tools) {
      console.log('\n## ' + t.name)
      console.log('description:', t.description)
      console.log('inputSchema:', JSON.stringify(t.inputSchema))
      console.log('outputSchema:', JSON.stringify(t.outputSchema))
    }
    if (SAMPLE) {
      console.log('\n=== sample calls ===')
      for (const t of tools) {
        const params = t.inputSchema && t.inputSchema.properties || {}
        const args = {}
        for (const [k, v] of Object.entries(params)) {
          if (v && v.type === 'boolean') { args[k] = false; continue }
          if (v && (v.type === 'number' || v.type === 'integer')) { args[k] = 0; continue }
          if (v && v.type === 'string') {
            if (v.enum && v.enum.length) { args[k] = v.enum[0]; continue }
            if (/command|cmd/i.test(k)) { args[k] = 'list'; continue }
            args[k] = 'ping'
            continue
          }
          args[k] = null
        }
        if (Object.keys(args).length === 0) args.__probe = true
        const call = await post({ jsonrpc: '2.0', id: 3, method: 'tools/call',
          params: { name: t.name, arguments: args } }, sessionId)
        const head = (call.text || '').trim().split('\n').slice(0, 40).join('\n')
        console.log('\n## call ' + t.name + ' args=' + JSON.stringify(args))
        console.log('http:', call.res.status)
        if (call.json && call.json.error) {
          console.log('error:', JSON.stringify(call.json.error))
        } else {
          console.log('result:', head || '(empty)')
        }
      }
    }
  } else {
    console.log('tools/list raw:', tl.text.trim())
  }
} else {
  console.log('initialize raw:', init.text.trim())
}
