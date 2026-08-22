-- tools.lua
-- MCP tool registry. Each tool has:
--   name        : string (MCP tool name)
--   description : string (shown to the LLM)
--   inputSchema : table (JSON Schema object, pure-dict for cJson)
--   handler     : function(World, args) -> MCP result table
--                 { content = { {type="text", text=...} }, isError = bool }
--
-- Handlers run on the world tick thread (queued by jsonrpc.lua), so they may
-- safely call World:ForEachPlayer, World:GetBlock, cRoot:Get(), etc.
-- They MUST NOT store Cuberite object references beyond the call; everything
-- is serialized to text before the task returns.

-- Dimension / gamemode / weather enum -> human string mappings.
local DIM_NAMES = {
	[dimOverworld] = "overworld",
	[dimNether]    = "nether",
	[dimEnd]       = "end",
}
local GM_NAMES = {
	[gmSurvival]   = "survival",
	[gmCreative]   = "creative",
	[gmAdventure]  = "adventure",
	[gmSpectator]  = "spectator",
}
local GM_FROM_NAME = {
	survival   = gmSurvival,
	creative   = gmCreative,
	adventure  = gmAdventure,
	spectator  = gmSpectator,
}
local WEATHER_NAMES = {
	[wSunny] = "sunny",
	[wRain]  = "rain",
	[wStorm] = "storm",
}

-- Helper: build a successful text tool result.
local function textOK(s)
	return { content = { { type = "text", text = tostring(s) } }, isError = false }
end
-- Helper: build an error tool result (still 200 OK at the RPC layer).
local function textErr(s)
	return { content = { { type = "text", text = tostring(s) } }, isError = true }
end

-- Helper: serialize a Lua table to a compact JSON string for tool output.
local function toJsonString(t)
	local s = cJson:Serialize(t, { indentation = "" })
	return s or "<unserializable>"
end

----------------------------------------------------------------------
-- Tool definitions
----------------------------------------------------------------------

local g_Tools = {
	----------------------------------------------------------------------
	-- Read-only query tools
	----------------------------------------------------------------------
	{
		name = "get_server_info",
		description = "Return high-level Cuberite server info: description, online/max player count, uptime in seconds, and total loaded chunk count.",
		inputSchema = { type = "object", properties = {}, required = {} },
		handler = function(a_World, a_Args)
			local root = cRoot:Get()
			local server = root:GetServer()
			local info = {
				description    = server:GetDescription(),
				online_players = server:GetNumPlayers(),
				max_players    = server:GetMaxPlayers(),
				uptime_seconds = root:GetServerUpTime(),
				loaded_chunks  = root:GetTotalChunkCount(),
				hardcore       = server:IsHardcore(),
				authenticating = server:ShouldAuthenticate(),
			}
			return textOK(toJsonString(info))
		end,
	},

	{
		name = "list_players",
		description = "List all players currently online in the default world. Returns an array of objects with name, position (x,y,z), health, and gamemode.",
		inputSchema = { type = "object", properties = {}, required = {} },
		handler = function(a_World, a_Args)
			local players = {}
			a_World:ForEachPlayer(function(a_Player)
				local gm = a_Player:GetGameMode()
				players[#players + 1] = {
					name     = a_Player:GetName(),
					x        = a_Player:GetPosX(),
					y        = a_Player:GetPosY(),
					z        = a_Player:GetPosZ(),
					health   = a_Player:GetHealth(),
					gamemode = GM_NAMES[gm] or tostring(gm),
				}
				return false  -- continue enumeration
			end)
			return textOK(toJsonString({ count = #players, players = players }))
		end,
	},

	{
		name = "get_player",
		description = "Return details about a single online player (case-insensitive partial name match).",
		inputSchema = {
			type = "object",
			properties = { name = { type = "string", description = "Player name (partial, case-insensitive)" } },
			required = { "name" },
		},
		handler = function(a_World, a_Args)
			local name = a_Args.name
			if not name or name == "" then
				return textErr("name is required")
			end
			local found = nil
			a_World:ForEachPlayer(function(a_Player)
				if a_Player:GetName():lower():find(name:lower(), 1, true) then
					local gm = a_Player:GetGameMode()
					found = {
						name     = a_Player:GetName(),
						x        = a_Player:GetPosX(),
						y        = a_Player:GetPosY(),
						z        = a_Player:GetPosZ(),
						health   = a_Player:GetHealth(),
						gamemode = GM_NAMES[gm] or tostring(gm),
					}
					return true  -- abort enumeration
				end
				return false
			end)
			if not found then
				return textErr("No online player matching '" .. name .. "'")
			end
			return textOK(toJsonString(found))
		end,
	},

	{
		name = "get_world_info",
		description = "Return info about the default world: name, dimension, time of day (ticks), world age (ticks), and current weather.",
		inputSchema = { type = "object", properties = {}, required = {} },
		handler = function(a_World, a_Args)
			local dim = a_World:GetDimension()
			local w = a_World:GetWeather()
			local info = {
				name           = a_World:GetName(),
				dimension      = DIM_NAMES[dim] or tostring(dim),
				time_of_day    = a_World:GetTimeOfDay(),
				world_age      = a_World:GetWorldAge(),
				weather        = WEATHER_NAMES[w] or tostring(w),
			}
			return textOK(toJsonString(info))
		end,
	},

	{
		name = "get_block",
		description = "Return the block type and metadata at the given coordinates in the default world. Returns blockType=0 if the chunk is not loaded.",
		inputSchema = {
			type = "object",
			properties = {
				x = { type = "integer" },
				y = { type = "integer" },
				z = { type = "integer" },
			},
			required = { "x", "y", "z" },
		},
		handler = function(a_World, a_Args)
			local x, y, z = tonumber(a_Args.x), tonumber(a_Args.y), tonumber(a_Args.z)
			if not x or not y or not z then
				return textErr("x, y, z must be integers")
			end
			local valid, blockType, blockMeta = a_World:GetBlockTypeMeta(x, y, z)
			if not valid then
				return textErr("Chunk not loaded at (" .. x .. "," .. y .. "," .. z .. ")")
			end
			return textOK(toJsonString({ x = x, y = y, z = z, blockType = blockType, blockMeta = blockMeta }))
		end,
	},

	----------------------------------------------------------------------
	-- Player operation tools
	----------------------------------------------------------------------
	{
		name = "teleport_player",
		description = "Teleport an online player to the given coordinates in their current world.",
		inputSchema = {
			type = "object",
			properties = {
				name = { type = "string", description = "Player name (partial, case-insensitive)" },
				x = { type = "number" },
				y = { type = "number" },
				z = { type = "number" },
			},
			required = { "name", "x", "y", "z" },
		},
		handler = function(a_World, a_Args)
			local name = a_Args.name
			local x, y, z = tonumber(a_Args.x), tonumber(a_Args.y), tonumber(a_Args.z)
			if not name or not x or not y or not z then
				return textErr("name, x, y, z are required")
			end
			local done = false
			a_World:ForEachPlayer(function(a_Player)
				if a_Player:GetName():lower():find(name:lower(), 1, true) then
					a_Player:TeleportToCoords(x, y, z)
					done = true
					return true
				end
				return false
			end)
			if not done then
				return textErr("No online player matching '" .. name .. "'")
			end
			return textOK("Teleported " .. name .. " to (" .. x .. "," .. y .. "," .. z .. ")")
		end,
	},

	{
		name = "set_player_gamemode",
		description = "Set the gamemode of an online player. gamemode must be one of: survival, creative, adventure, spectator.",
		inputSchema = {
			type = "object",
			properties = {
				name     = { type = "string" },
				gamemode = { type = "string", enum = { "survival", "creative", "adventure", "spectator" } },
			},
			required = { "name", "gamemode" },
		},
		handler = function(a_World, a_Args)
			local name = a_Args.name
			local gmName = a_Args.gamemode
			if not name or not gmName then
				return textErr("name and gamemode are required")
			end
			local gm = GM_FROM_NAME[gmName]
			if not gm then
				return textErr("Unknown gamemode '" .. tostring(gmName) .. "'. Use survival/creative/adventure/spectator.")
			end
			local done = false
			a_World:ForEachPlayer(function(a_Player)
				if a_Player:GetName():lower():find(name:lower(), 1, true) then
					a_Player:SetGameMode(gm)
					done = true
					return true
				end
				return false
			end)
			if not done then
				return textErr("No online player matching '" .. name .. "'")
			end
			return textOK("Set " .. name .. " gamemode to " .. gmName)
		end,
	},

	{
		name = "kick_player",
		description = "Kick an online player from the server with an optional reason message.",
		inputSchema = {
			type = "object",
			properties = {
				name   = { type = "string" },
				reason = { type = "string", description = "Kick reason shown to the player (optional)" },
			},
			required = { "name" },
		},
		handler = function(a_World, a_Args)
			local name = a_Args.name
			local reason = a_Args.reason or "Kicked by MCP"
			if not name then
				return textErr("name is required")
			end
			local done = false
			a_World:ForEachPlayer(function(a_Player)
				if a_Player:GetName():lower():find(name:lower(), 1, true) then
					a_Player:GetClientHandle():Kick(reason)
					done = true
					return true
				end
				return false
			end)
			if not done then
				return textErr("No online player matching '" .. name .. "'")
			end
			return textOK("Kicked " .. name .. ": " .. reason)
		end,
	},

	{
		name = "send_player_message",
		description = "Send a private chat message to an online player.",
		inputSchema = {
			type = "object",
			properties = {
				name    = { type = "string" },
				message = { type = "string" },
			},
			required = { "name", "message" },
		},
		handler = function(a_World, a_Args)
			local name = a_Args.name
			local msg = a_Args.message
			if not name or not msg then
				return textErr("name and message are required")
			end
			local done = false
			a_World:ForEachPlayer(function(a_Player)
				if a_Player:GetName():lower():find(name:lower(), 1, true) then
					a_Player:SendMessage(msg)
					done = true
					return true
				end
				return false
			end)
			if not done then
				return textErr("No online player matching '" .. name .. "'")
			end
			return textOK("Sent message to " .. name)
		end,
	},

	----------------------------------------------------------------------
	-- Chat & command tools
	----------------------------------------------------------------------
	{
		name = "broadcast_chat",
		description = "Broadcast a chat message to all players on the server.",
		inputSchema = {
			type = "object",
			properties = { message = { type = "string" } },
			required = { "message" },
		},
		handler = function(a_World, a_Args)
			local msg = a_Args.message
			if not msg or msg == "" then
				return textErr("message is required")
			end
			cRoot:Get():BroadcastChat(msg)
			return textOK("Broadcasted: " .. msg)
		end,
	},

	{
		name = "run_console_command",
		description = "Execute a console command on the server (as if typed in the server terminal). Returns the command's text output. Use sparingly; prefer dedicated tools when available.",
		inputSchema = {
			type = "object",
			properties = {
				command = { type = "string", description = "Full command line WITHOUT leading slash, e.g. 'say Hello' or 'time set day'" },
			},
			required = { "command" },
		},
		handler = function(a_World, a_Args)
			local cmd = a_Args.command
			if not cmd or cmd == "" then
				return textErr("command is required")
			end
			-- ExecuteConsoleCommand is a static method on cPluginManager.
			-- Using ":" on the class passes the class as self; returns (success:bool, output:string).
			local ok, output = cPluginManager:ExecuteConsoleCommand(cmd)
			local result = {
				command = cmd,
				success = ok == true,
				output  = output or "",
			}
			return textOK(toJsonString(result))
		end,
	},

	----------------------------------------------------------------------
	-- MCC (Minecraft Console Client) management tools
	----------------------------------------------------------------------
	{
		name = "mcc_status",
		description = "Return the status of the MCC (Minecraft Console Client) bot managed by this plugin. Shows whether MCC is enabled, running, its PID, username, and MCP port.",
		inputSchema = { type = "object", properties = {}, required = {} },
		handler = function(a_World, a_Args)
			local status = GetMCCStatus()
			return textOK(toJsonString(status))
		end,
	},
	{
		name = "mcc_start",
		description = "Start (summon) the MCC (Minecraft Console Client) bot managed by this plugin. Launches MCC as a background child process using the configured settings. Pass random_name='force' to always randomize the bot username suffix — this also terminates any running MCC first so a fresh player is summoned. Pass random_name='fixed' to use the base username. With no random_name, the RandomUsername config is honored and the call does nothing if MCC is already running.",
		inputSchema = {
			type = "object",
			properties = {
				random_name = { type = "string", enum = { "force", "fixed" }, description = "Override username randomization for this launch: 'force' always appends a random suffix, 'fixed' uses the base username. Omit to honor the RandomUsername config." },
			},
			required = {},
		},
		handler = function(a_World, a_Args)
			local opts = {}
			if a_Args.random_name == "force" or a_Args.random_name == "fixed" then
				opts.random_name = a_Args.random_name
			end
			local ok, msg = StartMCC(opts)
			return textOK(toJsonString({ success = ok == true, message = msg }))
		end,
	},
	{
		name = "mcc_stop",
		description = "Stop (terminate) the running MCC (Minecraft Console Client) bot managed by this plugin. Sends SIGTERM, escalates to SIGKILL if the process does not exit within about 1.5 seconds, waits for it to die, then clears the tracked PID. Does nothing if MCC is not running.",
		inputSchema = { type = "object", properties = {}, required = {} },
		handler = function(a_World, a_Args)
			local ok, msg = StopMCC()
			return textOK(toJsonString({ success = ok == true, message = msg }))
		end,
	},
	{
		name = "mcc_restart",
		description = "Restart the MCC (Minecraft Console Client) bot managed by this plugin. Stops the running bot (if any) and starts a fresh one. Useful after changing MCC configuration. Pass random_name='force' to always randomize the bot username suffix, or 'fixed' to use the base username, overriding the RandomUsername config for the new launch.",
		inputSchema = {
			type = "object",
			properties = {
				random_name = { type = "string", enum = { "force", "fixed" }, description = "Override username randomization for the new launch: 'force' always appends a random suffix, 'fixed' uses the base username. Omit to honor the RandomUsername config." },
			},
			required = {},
		},
		handler = function(a_World, a_Args)
			local opts = {}
			if a_Args.random_name == "force" or a_Args.random_name == "fixed" then
				opts.random_name = a_Args.random_name
			end
			local ok, msg = RestartMCC(opts)
			return textOK(toJsonString({ success = ok == true, message = msg }))
		end,
	},

	----------------------------------------------------------------------
	-- World manipulation tools
	----------------------------------------------------------------------
	{
		name = "set_time",
		description = "Set the time of day in the default world. time can be a number (0-23999 ticks), or a named value: 'day' (1000), 'noon' (6000), 'sunset' (12000), 'night' (13000), 'midnight' (18000).",
		inputSchema = {
			type = "object",
			properties = {
				time = { type = "string", description = "Time value: a number (0-23999) or named value (day/noon/sunset/night/midnight)" },
			},
			required = { "time" },
		},
		handler = function(a_World, a_Args)
			local timeNames = { day = 1000, noon = 6000, sunset = 12000, night = 13000, midnight = 18000 }
			local t = a_Args.time
			if not t then return textErr("time is required") end
			local ticks = tonumber(t) or timeNames[t:lower()]
			if not ticks then
				return textErr("Invalid time '" .. t .. "'. Use a number (0-23999) or day/noon/sunset/night/midnight.")
			end
			a_World:SetTimeOfDay(ticks)
			return textOK("Set time to " .. ticks .. " ticks")
		end,
	},

	{
		name = "set_weather",
		description = "Set the weather in the default world. weather must be one of: sunny, rain, storm.",
		inputSchema = {
			type = "object",
			properties = {
				weather = { type = "string", enum = { "sunny", "rain", "storm" } },
			},
			required = { "weather" },
		},
		handler = function(a_World, a_Args)
			local wmap = { sunny = wSunny, rain = wRain, storm = wStorm }
			local w = wmap[a_Args.weather]
			if not w then return textErr("weather must be sunny, rain, or storm") end
			a_World:SetWeather(w)
			return textOK("Set weather to " .. a_Args.weather)
		end,
	},

	{
		name = "set_block",
		description = "Set a block at the given coordinates in the default world. blockType is the numeric block ID (e.g. 1=stone, 2=grass, 3=dirt, 5=planks, 20=glass, 57=diamond_block). blockMeta is optional (default 0).",
		inputSchema = {
			type = "object",
			properties = {
				x = { type = "integer" },
				y = { type = "integer" },
				z = { type = "integer" },
				blockType = { type = "integer", description = "Numeric block type ID" },
				blockMeta = { type = "integer", description = "Block metadata (optional, default 0)" },
			},
			required = { "x", "y", "z", "blockType" },
		},
		handler = function(a_World, a_Args)
			local x, y, z = tonumber(a_Args.x), tonumber(a_Args.y), tonumber(a_Args.z)
			local bt = tonumber(a_Args.blockType)
			local bm = tonumber(a_Args.blockMeta) or 0
			if not x or not y or not z or not bt then
				return textErr("x, y, z, blockType must be integers")
			end
			a_World:SetBlock(x, y, z, bt, bm)
			return textOK("Set block at (" .. x .. "," .. y .. "," .. z .. ") to type=" .. bt .. " meta=" .. bm)
		end,
	},

	----------------------------------------------------------------------
	-- Plugin development tools
	----------------------------------------------------------------------
	{
		name = "list_plugins",
		description = "List all Cuberite plugins with their load status (loaded/disabled/error).",
		inputSchema = { type = "object", properties = {}, required = {} },
		handler = function(a_World, a_Args)
			local pm = cPluginManager
			local plugins = {}
			pm:ForEachPlugin(function(a_Plugin)
				local name = a_Plugin:GetName()
				local folder = a_Plugin:GetLocalFolder()
				local status = "loaded"
				-- Cuberite doesn't expose a direct "is loaded" check, but
				-- ForEachPlugin only iterates loaded plugins.
				plugins[#plugins + 1] = { name = name, folder = folder, status = status }
				return false
			end)
			return textOK(toJsonString({ count = #plugins, plugins = plugins }))
		end,
	},

	{
		name = "reload_plugin",
		description = "Reload a specific Cuberite plugin by name. Queues the reload on the main tick thread (async). Note: reloading MCPServer itself will briefly disconnect the MCP client.",
		inputSchema = {
			type = "object",
			properties = {
				name = { type = "string", description = "Plugin name to reload (e.g. 'Core', 'MCPServer')" },
			},
			required = { "name" },
		},
		handler = function(a_World, a_Args)
			local name = a_Args.name
			if not name or name == "" then return textErr("name is required") end
			local pm = cPluginManager:Get()
			if not pm:IsPluginLoaded(name) then
				return textOK(toJsonString({ plugin = name, success = false, output = "plugin is not loaded" }))
			end
			pm:ReloadPlugin(name)
			return textOK(toJsonString({ plugin = name, success = true, output = "reload queued" }))
		end,
	},

	{
		name = "execute_lua",
		description = "Execute a Lua expression or statement on the Cuberite server. The code runs in the server's Lua context with access to all Cuberite APIs. Returns the captured output (print/LOG calls). Use with caution.",
		inputSchema = {
			type = "object",
			properties = {
				code = { type = "string", description = "Lua code to execute. Use print() or LOG() for output." },
			},
			required = { "code" },
		},
		handler = function(a_World, a_Args)
			local code = a_Args.code
			if not code or code == "" then return textErr("code is required") end
			-- Execute Lua code directly via loadstring() instead of the 'lua'
			-- console command (which may not be available if the Core plugin
			-- is not loaded). Capture print() output by temporarily replacing
			-- the global print function.
			local output = {}
			local oldPrint = print
			print = function(...)
				local parts = {}
				for i = 1, select("#", ...) do
					local v = select(i, ...)
					parts[i] = tostring(v)
				end
				output[#output + 1] = table.concat(parts, "\t")
				if oldPrint then oldPrint(...) end
			end
			local ok, err = pcall(function()
				local fn, loadErr = loadstring(code)
				if not fn then
					error(loadErr)
				end
				local results = { fn() }
				if #results > 0 then
					local parts = {}
					for i, v in ipairs(results) do
						parts[i] = tostring(v)
					end
					output[#output + 1] = table.concat(parts, "\t")
				end
			end)
			print = oldPrint
			local result = {
				success = ok,
				output = table.concat(output, "\n"),
			}
			if not ok then
				result.error = tostring(err)
			end
			return textOK(toJsonString(result))
		end,
	},

	{
		name = "read_server_log",
		description = "Read the last N lines from the Cuberite server log file. Useful for debugging plugin issues.",
		inputSchema = {
			type = "object",
			properties = {
				lines = { type = "integer", description = "Number of recent log lines to return (default: 50, max: 500)" },
			},
			required = {},
		},
		handler = function(a_World, a_Args)
			local n = tonumber(a_Args.lines) or 50
			if n < 1 then n = 1 end
			if n > 500 then n = 500 end
			-- Find the most recent log file.
			local logDir = cRoot:Get():GetServer():GetDescription() -- not useful, use filesystem
			-- Use io.popen to find and read the latest log.
			local f = io.popen('ls -t "' .. g_PluginFolder .. '/../logs/LOG_*.txt" 2>/dev/null | head -1')
			if not f then return textErr("Cannot list log files") end
			local latest = f:read("*l")
			f:close()
			if not latest or latest == "" then
				return textErr("No log files found")
			end
			f = io.popen('tail -n ' .. n .. ' "' .. latest .. '"')
			if not f then return textErr("Cannot read log file") end
			local content = f:read("*a")
			f:close()
			return textOK(content or "(empty)")
		end,
	},
}

----------------------------------------------------------------------
-- Registry accessors (called by jsonrpc.lua)
----------------------------------------------------------------------

-- cJson serializes an empty Lua table {} as JSON null, because it cannot tell
-- whether {} is meant to be an empty array or an empty object. MCP clients
-- reject schemas where `required` is null (it must be an array). To work
-- around this, we normalize each schema before sending:
--   - `required`  : if empty/missing, omit the field (JSON Schema treats a
--                   missing `required` as an empty array, which is valid).
--   - `properties`: if empty/missing, omit the field (an object with no
--                   properties is valid).
-- We also recurse into nested `properties` so per-property schemas with their
-- own empty `required`/`properties` are normalized too.
local function normalizeSchema(a_Schema)
	if type(a_Schema) ~= "table" then
		return a_Schema
	end
	local out = {}
	for k, v in pairs(a_Schema) do
		if k == "required" then
			-- Only keep `required` if it has at least one entry; otherwise drop
			-- it so cJson doesn't emit null.
			if type(v) == "table" and next(v) ~= nil then
				out.required = v
			end
		elseif k == "properties" then
			if type(v) == "table" and next(v) ~= nil then
				-- Recurse into each property's schema.
				local props = {}
				for pname, pschema in pairs(v) do
					props[pname] = normalizeSchema(pschema)
				end
				out.properties = props
			end
		elseif type(v) == "table" then
			out[k] = normalizeSchema(v)
		else
			out[k] = v
		end
	end
	return out
end

-- Return the array of tool definitions for tools/list. Each entry is a pure
-- dict {name=, description=, inputSchema=}, which cJson can serialize.
function GetMCPToolDefinitions()
	local defs = {}
	for _, t in ipairs(g_Tools) do
		defs[#defs + 1] = {
			name        = t.name,
			description = t.description,
			inputSchema = normalizeSchema(t.inputSchema),
		}
	end
	return defs
end

-- Return the tool with the given name, or nil.
function GetMCPTool(a_Name)
	for _, t in ipairs(g_Tools) do
		if t.name == a_Name then
			return t
		end
	end
	return nil
end
