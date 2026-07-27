-- jsonrpc.lua
-- JSON-RPC 2.0 dispatcher for the MCP server.
--
-- Requests arrive as HTTP POST bodies (parsed by http.lua). The dispatcher:
--   1. Decodes the JSON-RPC envelope with cJson.
--   2. Routes the method:
--        - initialize / notifications/initialized / tools/list / ping
--          are answered immediately on the network thread.
--        - tools/call is dispatched onto the world tick thread via QueueTask
--          so tool handlers can safely query world/player state. The handler
--          itself sends the HTTP response from inside the task.
--   3. Constructs JSON-RPC responses (or errors) and ships them back.

local PROTOCOL_VERSION = "2025-06-18"

-- Build a JSON-RPC 2.0 success response object (pure dict -> cJson-friendly).
local function rpcResult(a_ID, a_Result)
	return {
		jsonrpc = "2.0",
		id = a_ID,
		result = a_Result,
	}
end

-- Build a JSON-RPC 2.0 error response object.
local function rpcError(a_ID, a_Code, a_Message, a_Data)
	local err = { code = a_Code, message = a_Message }
	if a_Data ~= nil then
		err.data = a_Data
	end
	return { jsonrpc = "2.0", id = a_ID, error = err }
end

-- Build the MCP "content" result wrapper for a tool call.
-- a_Text: string output. a_IsError: bool.
local function toolResult(a_Text, a_IsError)
	return {
		content = { { type = "text", text = tostring(a_Text) } },
		isError = a_IsError == true,
	}
end

-- Serialize a Lua table to JSON, returning the string. On failure, returns
-- a JSON-encoded error envelope so the link still gets a response.
local function safeSerialize(a_Table)
	local s, err = cJson:Serialize(a_Table, { indentation = "" })
	if s then
		return s
	end
	LOGWARNING("[MCP] cJson:Serialize failed: " .. tostring(err))
	local fallback, _ = cJson:Serialize(
		rpcError(a_Table.id or 0, -32603, "Internal JSON serialization error"),
		{ indentation = "" })
	return fallback or '{"jsonrpc":"2.0","id":0,"error":{"code":-32603,"message":"unserializable"}}'
end

-- Handle a single parsed JSON-RPC request object.
-- a_Link is the cTCPLink to reply on; a_Req is the parsed table.
function DispatchJSONRPC(a_Link, a_Req)
	-- Validate envelope basics.
	if type(a_Req) ~= "table" then
		SendHTTPJSON(a_Link, safeSerialize(rpcError(0, -32600, "Invalid Request")))
		return
	end
	if a_Req.jsonrpc ~= "2.0" then
		SendHTTPJSON(a_Link, safeSerialize(rpcError(a_Req.id, -32600, "Invalid Request: jsonrpc must be \"2.0\"")))
		return
	end

	local method = a_Req.method
	local id = a_Req.id  -- may be nil for notifications
	local params = a_Req.params or {}

	--- Methods that need no world state: answer immediately. ---
	if method == "initialize" then
		local result = {
			protocolVersion = PROTOCOL_VERSION,
			capabilities = {
				tools = { listChanged = false },
			},
			serverInfo = {
				name = g_MCPConfig.ServerName,
				version = g_MCPConfig.ServerVersion,
			},
		}
		SendHTTPJSON(a_Link, safeSerialize(rpcResult(id, result)))
		return
	end

	if method == "notifications/initialized" then
		-- Notification: no id, no JSON-RPC response. Per MCP Streamable HTTP,
		-- the server MUST return HTTP 202 Accepted with no body.
		SendHTTP202(a_Link)
		return
	end

	if method == "ping" then
		SendHTTPJSON(a_Link, safeSerialize(rpcResult(id, {})))
		return
	end

	if method == "tools/list" then
		SendHTTPJSON(a_Link, safeSerialize(rpcResult(id, { tools = GetMCPToolDefinitions() })))
		return
	end

	if method == "tools/call" then
		local toolName = params.name
		local args = params.arguments or {}
		local tool = GetMCPTool(toolName)
		if not tool then
			SendHTTPJSON(a_Link, safeSerialize(rpcResult(id, toolResult("Unknown tool: " .. tostring(toolName), true))))
			return
		end
		-- Validate args minimally; full schema validation is out of scope for v1.
		if type(args) ~= "table" then
			SendHTTPJSON(a_Link, safeSerialize(rpcResult(id, toolResult("arguments must be an object", true))))
			return
		end
		-- Dispatch onto the world tick thread so handlers can query live state.
		-- The handler is responsible for returning a toolResult-shaped table.
		-- We capture id and link via upvalues; the task sends the response.
		local world = cRoot:Get():GetDefaultWorld()
		if not world then
			SendHTTPJSON(a_Link, safeSerialize(rpcResult(id, toolResult("No default world available", true))))
			return
		end
		world:QueueTask(function(a_World)
			local ok, res = pcall(tool.handler, a_World, args)
			local response
			if ok then
				response = rpcResult(id, res)
			else
				LOGWARNING("[MCP] tool '" .. toolName .. "' threw: " .. tostring(res))
				response = rpcResult(id, toolResult("Tool error: " .. tostring(res), true))
			end
			SendHTTPJSON(a_Link, safeSerialize(response))
		end)
		return
	end

	-- Unknown method.
	if id == nil then
		-- Unknown notification: silently close.
		a_Link:Shutdown()
		return
	end
	SendHTTPJSON(a_Link, safeSerialize(rpcError(id, -32601, "Method not found: " .. tostring(method))))
end

-- Top-level entry from the HTTP layer: parse the body and dispatch.
-- a_Body is the raw HTTP body string (a single JSON-RPC request object).
function HandleMCPBody(a_Link, a_Body)
	LOG("[MCP] HandleMCPBody " .. #a_Body .. " bytes: " .. a_Body:sub(1, 300))
	local parsed, perr = cJson:Parse(a_Body)
	if not parsed then
		LOG("[MCP] JSON parse error: " .. tostring(perr))
		SendHTTPJSON(a_Link, safeSerialize(rpcError(0, -32700, "Parse error: " .. tostring(perr))))
		return
	end
	-- v1 supports only single request objects (not batched arrays).
	if type(parsed) == "table" then
		LOG("[MCP] dispatch method=" .. tostring(parsed.method) .. " id=" .. tostring(parsed.id))
		DispatchJSONRPC(a_Link, parsed)
	else
		SendHTTPJSON(a_Link, safeSerialize(rpcError(0, -32600, "Invalid Request")))
	end
end

-- Handle a GET request by opening an SSE stream. This supports the legacy
-- HTTP+SSE transport (2024-11-05): the first event sent is "endpoint",
-- pointing the client at the URL to POST JSON-RPC messages to. After that
-- the stream stays open for server-to-client messages; since this server
-- has none to push, we just keep the connection alive until the client
-- disconnects or the server shuts down.
function HandleMCPGet(a_Link, a_Path)
	LOG("[MCP] HandleMCPGet path=" .. tostring(a_Path))
	local head = BuildHTTPStreamHead(
		"200 OK",
		{ "Content-Type: text/event-stream",
		  "Cache-Control: no-cache" })
	LOG("[MCP] sending SSE head " .. #head .. " bytes")
	a_Link:Send(head)
	-- Send the endpoint event so legacy clients know where to POST.
	-- The endpoint is the same path the client GET'd (the MCP endpoint).
	SendSSEEvent(a_Link, "endpoint", a_Path or "/")
	-- Keep the stream open; the client will close it when done. We do not
	-- Shutdown here. The link is closed when the client disconnects
	-- (OnRemoteClosed) or when the server stops.
end
