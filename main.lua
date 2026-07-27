-- main.lua
-- MCPServer plugin: exposes Cuberite as an MCP (Model Context Protocol)
-- server over Streamable HTTP, so an LLM host can call Cuberite tools.
--
-- Architecture:
--   cNetwork:Listen(port, ...) accepts TCP connections on the network IO
--   thread. OnIncomingConnection filters by remote IP (loopback only by
--   default). Each connection gets its own per-link state table; data is
--   accumulated and parsed as HTTP/1.1 (http.lua). Complete request bodies
--   are handed to the JSON-RPC dispatcher (jsonrpc.lua). tools/call requests
--   are queued onto the world tick thread via cWorld:QueueTask so handlers
--   can safely read/write world and player state; the handler sends the HTTP
--   response back from inside the task (a_Link:Send is async + thread-safe).
--
-- See plan in the project root for details.

local g_ServerHandle = nil  -- cServerHandle, kept alive to keep listening
local g_PluginFolder = nil

----------------------------------------------------------------------
-- Per-connection state and callbacks
----------------------------------------------------------------------

-- Build a fresh LinkCallbacks table for a new connection. Each connection
-- needs its own accumulator buffer, hence the closure.
local function MakeLinkCallbacks()
	local buf = ""
	return {
		OnError = function(a_Link, a_ErrCode, a_ErrMsg)
			LOG("[MCP] Link error " .. tostring(a_ErrCode) .. ": " .. tostring(a_ErrMsg))
		end,

		OnReceivedData = function(a_Link, a_Data)
			LOG("[MCP] recv " .. #a_Data .. " bytes on link " .. tostring(a_Link))
			buf = buf .. a_Data
			-- Try to parse one complete HTTP request; loop in case the buffer
			-- contains pipelined requests (rare, but cheap to handle).
			while true do
				local body, consumed, method, path = ParseHTTPRequest(buf)
				if body == nil then
					-- Need more data.
					LOG("[MCP] need more data (buf=" .. #buf .. " bytes)")
					return
				end
				if body == false then
					-- Malformed request.
					LOG("[MCP] malformed request, buf head: " .. buf:sub(1, 120):gsub("\r", "\\r"):gsub("\n", "\\n"))
					SendHTTPError(a_Link, "400 Bad Request", "Malformed HTTP request\n")
					return
				end
				-- We have a complete request. Dispatch by method:
				--   GET  -> open an SSE stream (legacy HTTP+SSE transport)
				--   POST -> JSON-RPC dispatch (Streamable HTTP transport)
				-- The dispatcher owns the link lifecycle and closes it once
				-- the response is fully sent.
				LOG("[MCP] parsed " .. tostring(method) .. " " .. tostring(path) .. " body=" .. #body .. " bytes consumed=" .. consumed)
				if method == "GET" then
					HandleMCPGet(a_Link, path)
				else
					HandleMCPBody(a_Link, body)
				end
				-- Remove the consumed bytes; the link will be closed by the
				-- dispatcher once the response is sent, so further pipelined
				-- requests are ignored.
				buf = buf:sub(consumed + 1)
				return
			end
		end,

		OnRemoteClosed = function(a_Link)
			LOG("[MCP] remote closed link " .. tostring(a_Link))
		end,
	}
end

----------------------------------------------------------------------
-- Listen / stop
----------------------------------------------------------------------

local function StartMCPServer()
	if g_ServerHandle and g_ServerHandle:IsListening() then
		LOG("[MCP] Already listening on port " .. g_MCPConfig.Port)
		return false, "already listening"
	end
	local listenCallbacks = {
		OnIncomingConnection = function(a_RemoteIP, a_RemotePort, a_LocalPort)
			if not IsIPAllowed(a_RemoteIP) then
				LOGWARNING("[MCP] Rejected connection from " .. tostring(a_RemoteIP) .. ":" .. tostring(a_RemotePort))
				return nil  -- drop the connection
			end
			return MakeLinkCallbacks()
		end,
		OnAccepted = function(a_Link)
			LOG("[MCP] accepted connection from " .. a_Link:GetRemoteIP() .. ":" .. a_Link:GetRemotePort())
		end,
		OnError = function(a_ErrCode, a_ErrMsg)
			LOGWARNING("[MCP] Listen error " .. tostring(a_ErrCode) .. ": " .. tostring(a_ErrMsg))
		end,
	}
	local srv = cNetwork:Listen(g_MCPConfig.Port, listenCallbacks)
	if not srv:IsListening() then
		LOGWARNING("[MCP] Failed to listen on port " .. g_MCPConfig.Port)
		return false, "listen failed"
	end
	g_ServerHandle = srv
	LOG("[MCP] Listening on port " .. g_MCPConfig.Port .. " (loopback only by default)")
	return true, "listening on " .. g_MCPConfig.Port
end

local function StopMCPServer()
	if g_ServerHandle then
		g_ServerHandle:Close()
		g_ServerHandle = nil
		LOG("[MCP] Stopped listening")
		return true, "stopped"
	end
	return false, "not listening"
end

----------------------------------------------------------------------
-- Console commands
----------------------------------------------------------------------

function HandleConsoleMCP(a_Split)
	-- /mcp with no subcommand -> status
	local sub = a_Split[2] or "status"
	if sub == "start" then
		local ok, msg = StartMCPServer()
		return true, msg
	elseif sub == "stop" then
		local ok, msg = StopMCPServer()
		return true, msg
	elseif sub == "status" then
		if g_ServerHandle and g_ServerHandle:IsListening() then
			return true, "MCP server listening on port " .. g_MCPConfig.Port
		end
		return true, "MCP server is not running"
	end
	return true, "Usage: mcp <start|stop|status>"
end

----------------------------------------------------------------------
-- Plugin lifecycle
----------------------------------------------------------------------

function Initialize(a_Plugin)
	g_PluginFolder = a_Plugin:GetLocalFolder()

	-- Load config (writes defaults on first run).
	LoadMCPConfig(g_PluginFolder)

	-- Load support files. dofile is the conventional way to load additional
	-- .lua files in a Cuberite plugin (they share the plugin's Lua state).
	dofile(g_PluginFolder .. "/http.lua")
	dofile(g_PluginFolder .. "/jsonrpc.lua")
	dofile(g_PluginFolder .. "/tools.lua")

	-- Register console commands via the shared InfoReg helper.
	dofile(cPluginManager:GetPluginsPath() .. "/InfoReg.lua")
	RegisterPluginInfoConsoleCommands()

	-- Autostart the server.
	StartMCPServer()

	LOG("[MCP] MCPServer plugin initialized (port " .. g_MCPConfig.Port .. ")")
	return true
end

function OnDisable()
	StopMCPServer()
	LOG("[MCP] MCPServer plugin disabled")
end
