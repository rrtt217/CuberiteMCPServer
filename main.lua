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
g_PluginFolder = nil        -- set in Initialize, used by tools.lua
local g_MCCPid = nil        -- PID of the MCC child process, or nil if not running

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
-- MCC (Minecraft Console Client) lifecycle
----------------------------------------------------------------------

-- Build the MCC command line from config. Returns a string ready for os.execute.
local function BuildMCCCommand()
	local cfg = g_MCPConfig.MCC
	local path = cfg.Path
	if path == "" then
		return nil, "MCC.Path is not configured"
	end
	-- Build a temporary ini file with the right settings so we don't
	-- clobber the user's main MinecraftClient.ini.
	local tmpIni = g_PluginFolder .. "/mcc_temp.ini"
	local f = io.open(tmpIni, "w")
	if not f then
		return nil, "Cannot write " .. tmpIni
	end
	f:write("[Main]\n")
	f:write("[Main.General]\n")
	f:write("Account = { Login = \"" .. cfg.Username .. "\", Password = \"-\" }\n")
	f:write("Server = { Host = \"" .. cfg.ServerHost .. "\", Port = " .. cfg.ServerPort .. " }\n")
	f:write("AccountType = \"mojang\"\n")
	f:write("[Main.Advanced]\n")
	f:write("MinecraftVersion = \"" .. cfg.MinecraftVersion .. "\"\n")
	f:write("BotOwners = [ \"" .. cfg.Username .. "\", ]\n")
	f:write("[ChatBot.RemoteControl]\n")
	f:write("Enabled = true\n")
	f:write("AutoTpaccept = true\n")
	f:write("AutoTpaccept_Everyone = true\n")
	f:write("[ChatBot.McpServer]\n")
	f:write("Enabled = true\n")
	f:write("[ChatBot.McpServer.Transport]\n")
	f:write("BindHost = \"127.0.0.1\"\n")
	f:write("Port = " .. cfg.McpPort .. "\n")
	f:write("Route = \"/mcp\"\n")
	f:write("RequireAuthToken = false\n")
	f:write("[ChatBot.McpServer.Capabilities]\n")
	f:write("SessionStatus = true\n")
	f:write("ChatAndCommands = true\n")
	f:write("Movement = true\n")
	f:write("Inventory = true\n")
	f:write("EntityWorld = true\n")
	f:close()
	-- Quote the path in case it contains spaces.
	return '"' .. path .. '" "' .. tmpIni .. '"'
end

local function StartMCC()
	if g_MCCPid then
		LOG("[MCP] MCC already running (PID " .. g_MCCPid .. ")")
		return false, "already running"
	end
	local cfg = g_MCPConfig.MCC
	if not cfg.Enabled then
		LOG("[MCP] MCC integration is disabled in config")
		return false, "MCC disabled in config"
	end
	local cmd, err = BuildMCCCommand()
	if not cmd then
		LOGWARNING("[MCP] Cannot start MCC: " .. err)
		return false, err
	end
	-- Use io.popen to launch MCC in the background. We redirect stdout/stderr
	-- to a log file so it doesn't clutter the Cuberite console.
	local logFile = g_PluginFolder .. "/mcc_output.log"
	-- Run in background with &, capture PID via $!
	local fullCmd = cmd .. ' > "' .. logFile .. '" 2>&1 & echo $!'
	LOG("[MCP] Starting MCC: " .. cmd)
	local f = io.popen(fullCmd)
	if not f then
		LOGWARNING("[MCP] io.popen failed for MCC")
		return false, "io.popen failed"
	end
	local pidStr = f:read("*a")
	f:close()
	pidStr = pidStr:match("^(%d+)")
	if not pidStr then
		LOGWARNING("[MCP] Could not read MCC PID")
		return false, "could not read PID"
	end
	g_MCCPid = tonumber(pidStr)
	LOG("[MCP] MCC started with PID " .. g_MCCPid .. ", output -> " .. logFile)
	return true, "MCC started (PID " .. g_MCCPid .. ")"
end

local function StopMCC()
	if not g_MCCPid then
		return false, "MCC not running"
	end
	-- Send SIGTERM to the MCC process.
	os.execute("kill " .. g_MCCPid .. " 2>/dev/null")
	LOG("[MCP] Sent SIGTERM to MCC PID " .. g_MCCPid)
	g_MCCPid = nil
	return true, "MCC stopped"
end

-- Return MCC status info for tools.
function GetMCCStatus()
	local cfg = g_MCPConfig.MCC
	local status = {
		enabled  = cfg.Enabled,
		running  = g_MCCPid ~= nil,
		pid      = g_MCCPid,
		username = cfg.Username,
		mcp_port = cfg.McpPort,
	}
	return status
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

	-- Autostart MCC if enabled, but delay it so the server port is ready.
	if g_MCPConfig.MCC.Enabled then
		cRoot:Get():GetDefaultWorld():ScheduleTask(60, function()
			StartMCC()
		end)
		LOG("[MCP] MCC scheduled to start in 60 ticks (~3s)")
	end

	LOG("[MCP] MCPServer plugin initialized (port " .. g_MCPConfig.Port .. ")")
	return true
end

function OnDisable()
	StopMCC()
	StopMCPServer()
	LOG("[MCP] MCPServer plugin disabled")
end
