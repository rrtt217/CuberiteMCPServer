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
-- Process helpers
----------------------------------------------------------------------

-- Whether the given PID is alive (kill -0). Handles both Lua 5.1
-- (numeric exit code) and 5.2+ (boolean) os.execute return values.
-- @param a_Pid number
-- @return boolean
local function IsPidAlive(a_Pid)
	if not a_Pid then
		return false
	end
	local ok = os.execute("kill -0 " .. a_Pid .. " 2>/dev/null")
	return (ok == 0) or (ok == true)
end

-- Whether the given PID is alive AND still the MCC process we launched.
-- The cmdline check guards against killing an unrelated process after a
-- PID got reused.
-- @param a_Pid number
-- @return boolean
local function IsMCCProcess(a_Pid)
	if not IsPidAlive(a_Pid) then
		return false
	end
	local f = io.popen("tr '\\0' ' ' < /proc/" .. a_Pid .. "/cmdline 2>/dev/null")
	local cmdline = ""
	if f then
		cmdline = f:read("*a") or ""
		f:close()
	end
	-- If the cmdline cannot be read (e.g. no /proc), fall back to liveness.
	if cmdline == "" then
		return true
	end
	local cfg = g_MCPConfig.MCC
	return (cfg.Path ~= "") and (cmdline:find(cfg.Path, 1, true) ~= nil)
end

-- Busy-wait until the process is gone, up to a_Seconds seconds, sleeping
-- a_Sleep seconds between polls. Blocks the calling thread (world tick),
-- so keep the budgets small. Returns true if the process exited.
-- @param a_Pid number
-- @param a_Seconds number
-- @param a_Sleep number
-- @return boolean
local function WaitForExit(a_Pid, a_Seconds, a_Sleep)
	local deadline = (a_Seconds / a_Sleep) + 0.5
	for _ = 1, math.floor(deadline) do
		if not IsPidAlive(a_Pid) then
			return true
		end
		os.execute("sleep " .. tostring(a_Sleep))
	end
	return not IsPidAlive(a_Pid)
end

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
	a_Opts = a_Opts or {}
	-- A "force" launch is an explicit request for a fresh player: terminate
	-- the existing bot first instead of refusing (the old MCC keeps its
	-- server session alive otherwise).
	if g_MCCPid and a_Opts.random_name == "force" then
		LOG("[MCP] Force launch requested, stopping existing MCC (PID " .. g_MCCPid .. ")")
		StopMCC()
	end
	-- Reap a stale tracked PID: the bot may have exited on its own while
	-- we still remembered it.
	if g_MCCPid and not IsMCCProcess(g_MCCPid) then
		LOGWARNING("[MCP] Stale PID " .. g_MCCPid .. " is no longer running, clearing it")
		g_MCCPid = nil
	end
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
	-- The launch wrapper closes every inherited file descriptor above 2
	-- before exec'ing MCC. Without this the child inherits Cuberite's
	-- listening sockets (game / webadmin / MCP ports); if Cuberite dies
	-- while MCC keeps running, the orphaned MCC holds those ports and
	-- Cuberite cannot restart ("address already in use").
	-- Run in background with &, capture PID via $! (the subshell PID is
	-- preserved through exec, so it is the MCC PID).
	local fullCmd = '{ for fd in /proc/self/fd/*; do n=${fd##*/}; case "$n" in 0|1|2) ;; *) eval "exec $n>&-" 2>/dev/null ;; esac; done; exec ' .. cmd .. ' > "' .. logFile .. '" 2>&1; } & echo $!'
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

-- Signal ladder used by StopMCC: catchable signals first, SIGKILL last.
-- MCC ignores SIGTERM/SIGINT/SIGQUIT (its runtime installs handlers that do
-- nothing) and dies ungracefully on SIGHUP/SIGUSR1, so no single signal
-- yields a clean shutdown; this ladder gives every catchable signal a chance
-- and only escalates to SIGKILL once the process refused all of them.
-- Each entry: { name, kill invocation, wait seconds }.
local g_StopLadder = {
	{ "SIGTERM", "kill %d",       1.5 },
	{ "SIGHUP",  "kill -HUP %d",  1.5 },
	{ "SIGUSR1", "kill -USR1 %d", 1.0 },
	{ "SIGKILL", "kill -9 %d",    1.0 },
}

-- Terminate the running MCC bot: walk the signal ladder (SIGTERM -> SIGHUP
-- -> SIGUSR1 -> SIGKILL), waiting between steps, and only drop the tracked
-- PID once the process is confirmed gone.
function StopMCC()
	if not g_MCCPid then
		return false, "MCC not running"
	end
	local pid = g_MCCPid
	LOG("[MCP] Stopping MCC (PID " .. pid .. ")")
	if IsMCCProcess(pid) then
		local exited = false
		for i, step in ipairs(g_StopLadder) do
			os.execute(string.format(step[2], pid) .. " 2>/dev/null")
			if WaitForExit(pid, step[3], 0.1) then
				exited = true
				break
			end
			if i < #g_StopLadder then
				LOGWARNING("[MCP] MCC PID " .. pid .. " ignored " .. step[1] .. ", escalating to " .. g_StopLadder[i + 1][1])
			else
				-- Defunct zombies can linger; they cannot hold ports or
				-- connect, so continue with the PID cleared.
				LOGWARNING("[MCP] MCC PID " .. pid .. " still present after SIGKILL (zombie?); continuing")
			end
		end
	else
		LOGWARNING("[MCP] MCC PID " .. pid .. " was not running anymore")
	end
	g_MCCPid = nil
	LOG("[MCP] MCC stopped")
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
	-- Reap stale PIDs so status reports stay truthful.
	if g_MCCPid and not IsMCCProcess(g_MCCPid) then
		g_MCCPid = nil
	end
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
