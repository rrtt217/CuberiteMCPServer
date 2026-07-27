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
