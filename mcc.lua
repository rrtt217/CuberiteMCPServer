-- mcc.lua
-- MCC (Minecraft Console Client) lifecycle management.
--
-- Extracted from main.lua so the MCP server core stays focused on HTTP/JSON
-- dispatch. This module owns the MCC child process: it builds the launch
-- command, starts/stops the process, and reports status.
--
-- Exposed globals (used by main.lua, tools.lua, Info.lua):
--   StartMCC(opts)        -> (ok, msg)   launch the MCC bot
--     opts.random_name:   "force"  -> always randomize the username suffix
--                          "fixed"  -> never randomize (use base username)
--                          nil      -> honor the RandomUsername config
--   StopMCC()             -> (ok, msg)   terminate the MCC bot
--   RestartMCC(opts)      -> (ok, msg)   stop then start (opts passed to StartMCC)
--   GetMCCStatus()        -> table       status snapshot for tools/commands
--   HandleConsoleMCC(a_Split) -> (true, msg)  console command handler

local g_MCCPid = nil  -- PID of the MCC child process, or nil if not running

----------------------------------------------------------------------
-- Command construction
----------------------------------------------------------------------

-- Build the MCC command line from config. Returns a string ready for
-- os.execute / io.popen, or (nil, err) on failure.
-- a_Opts (optional table):
--   random_name = "force" | "fixed" | nil  -- overrides the RandomUsername
--                                              config for this launch only.
local function BuildMCCCommand(a_Opts)
	a_Opts = a_Opts or {}
	local cfg = g_MCPConfig.MCC
	local path = cfg.Path
	if path == "" then
		return nil, "MCC.Path is not configured"
	end

	-- Resolve the actual username. The random_name override takes precedence
	-- over the RandomUsername config:
	--   "force" -> always append a random suffix
	--   "fixed" -> never append a suffix (use the base username)
	--   nil     -> honor the RandomUsername config
	-- A random suffix gives each MCC launch a fresh identity, which works
	-- around a Cuberite bug where a dead player that fell into the void
	-- cannot respawn properly — a new name means a fresh player entity.
	local username = cfg.Username
	local doRandom = cfg.RandomUsername
	if a_Opts.random_name == "force" then
		doRandom = true
	elseif a_Opts.random_name == "fixed" then
		doRandom = false
	end
	if doRandom then
		local suffix = tostring(math.random(1000, 9999))
		username = cfg.Username .. "_" .. suffix
		LOG("[MCP] Using randomized username: " .. username)
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
	f:write("Account = { Login = \"" .. username .. "\", Password = \"-\" }\n")
	f:write("Server = { Host = \"" .. cfg.ServerHost .. "\", Port = " .. cfg.ServerPort .. " }\n")
	f:write("AccountType = \"mojang\"\n")
	f:write("[Main.Advanced]\n")
	f:write("MinecraftVersion = \"" .. cfg.MinecraftVersion .. "\"\n")
	f:write("BotOwners = [ \"" .. username .. "\", ]\n")
	f:write("TerrainAndMovements = true\n")
	f:write("InventoryHandling = true\n")
	f:write("EntityHandling = true\n")
	f:write("TemporaryFixBadpacket = false\n")
	f:write("AutoRespawn = true\n")
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

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

-- Launch the MCC bot as a background child process.
-- a_Opts is optional; see BuildMCCCommand for the recognized fields.
function StartMCC(a_Opts)
	if g_MCCPid then
		LOG("[MCP] MCC already running (PID " .. g_MCCPid .. ")")
		return false, "already running"
	end
	local cfg = g_MCPConfig.MCC
	if not cfg.Enabled then
		LOG("[MCP] MCC integration is disabled in config")
		return false, "MCC disabled in config"
	end
	local cmd, err = BuildMCCCommand(a_Opts)
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

-- Terminate the running MCC bot via SIGTERM.
function StopMCC()
	if not g_MCCPid then
		return false, "MCC not running"
	end
	-- Send SIGTERM to the MCC process.
	os.execute("kill " .. g_MCCPid .. " 2>/dev/null")
	LOG("[MCP] Sent SIGTERM to MCC PID " .. g_MCCPid)
	g_MCCPid = nil
	return true, "MCC stopped"
end

-- Stop then start. Useful after config changes.
-- a_Opts is optional; forwarded to StartMCC (e.g. random_name override).
function RestartMCC(a_Opts)
	if g_MCCPid then
		StopMCC()
	end
	return StartMCC(a_Opts)
end

-- Return MCC status info for tools and console commands.
function GetMCCStatus()
	local cfg = g_MCPConfig.MCC
	local status = {
		enabled         = cfg.Enabled,
		autostart       = cfg.AutoStart,
		running         = g_MCCPid ~= nil,
		pid             = g_MCCPid,
		username        = cfg.Username,
		random_username = cfg.RandomUsername,
		mcp_port        = cfg.McpPort,
	}
	return status
end

----------------------------------------------------------------------
-- Console command handler: `mcc <start|stop|restart|status>`
----------------------------------------------------------------------

-- Parse an optional random-name flag from the console argument tail.
-- Recognized tokens (case-insensitive): "random" -> "force", "norandom" /
-- "fixed" -> "fixed". Returns nil if no flag is present.
local function ParseRandomNameFlag(a_Split)
	for i = 3, #a_Split do
		local tok = a_Split[i]:lower()
		if tok == "random" then
			return "force"
		elseif tok == "norandom" or tok == "fixed" then
			return "fixed"
		end
	end
	return nil
end

function HandleConsoleMCC(a_Split)
	local sub = a_Split[2] or "status"
	if sub == "start" then
		local ok, msg = StartMCC({ random_name = ParseRandomNameFlag(a_Split) })
		return true, msg
	elseif sub == "stop" then
		local ok, msg = StopMCC()
		return true, msg
	elseif sub == "restart" then
		local ok, msg = RestartMCC({ random_name = ParseRandomNameFlag(a_Split) })
		return true, msg
	elseif sub == "status" then
		local s = GetMCCStatus()
		if s.running then
			return true, "MCC is running (PID " .. tostring(s.pid) .. ", user " .. tostring(s.username) .. ", mcp_port " .. tostring(s.mcp_port) .. ")"
		end
		if s.enabled then
			return true, "MCC is enabled but not running"
		end
		return true, "MCC is disabled in config"
	end
	return true, "Usage: mcc <start|stop|restart|status> [random|norandom]"
end
