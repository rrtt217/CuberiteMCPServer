-- void_guard.lua
-- Player void-fall loop guard.
--
-- Cuberite accepts client-reported player positions without validating them.
-- When an MCC (Minecraft Console Client) bot dies, its game client keeps
-- "falling": it keeps reporting a low Y position that the server accepts, so
-- the player sinks past y=-1000, taking void damage (type=14) in a 0..20
-- health cycle and never respawning properly -- a death/void loop caused by
-- the MCC client/Cuberite interaction, not by any plugin logic.
--
-- Remedial one-shot fixes (TeleportToCoords, SetPosition+SetHealth, Respawn,
-- the MCC-side respawn packet, "move" commands) all fail because the client's
-- next falling-position packet pulls the player back into the void. The
-- reliable cure is to refuse the reported movement AND hold the player still
-- long enough for the server to force-sync its real position back to the
-- client, correcting the client's stale local state.
--
-- Detection: the guard only acts when a player's movement would take their
-- body below VoidY while EMBEDDED in solid blocks (the client reporting a
-- position inside the terrain) -- the loop's signature. On this box the
-- stuck client froze at y=38.1 inside a solid stone column. A legitimate
-- player never has a solid block at head level (caves, slopes and water are
-- all air/water), so this check removes all false positives. VoidY marks
-- how deep an embedded player must be before the guard acts (default 40).
--
-- Response: the player is teleported back up to SafeY (x/z preserved) and a
-- per-player freeze counter is started at g_FreezeTicksInit world ticks.
-- While the counter is above zero, HOOK_PLAYER_MOVING refuses ALL movement,
-- holding the player at the safe spot so the client re-syncs; each
-- HOOK_WORLD_TICK decrements the counter by one until it reaches zero, at
-- which point movement is allowed again (and a still-stuck client simply
-- triggers a new rescue).
--
-- Logging is throttled (once per 30 s per player) so a client stuck in a
-- cycle cannot flood the console.
--
-- Exposed globals (used by main.lua):
--   InitVoidGuard() -> (ok, msg)  read settings.ini and register the hooks if enabled

local g_Enabled      = true   -- master switch, from settings.ini [VoidGuard] Enabled
local g_VoidY        = 40     -- below this Y an embedded player is rescued (configurable)
local g_SafeY        = 74     -- the Y the player is pulled back up to (configurable)
local g_NoReturnY    = -500   -- past this the server handles the player itself; we stand down
local g_FreezeTicksInit = 10  -- world ticks the player is held after each rescue
local g_LogEvery     = 30.0   -- seconds between LOG lines for the same stuck player

-- Per-player state, keyed by the player's UUID so different players (real
-- players, several MCC bots) are throttled independently.
local g_FreezeTicks = {}   -- uuid -> world ticks remaining; refuse ALL movement while > 0
local g_LastLog    = {}    -- uuid -> server uptime seconds of the last LOG line

----------------------------------------------------------------------
-- Hook handlers
----------------------------------------------------------------------

-- HOOK_PLAYER_MOVING: detect the void-fall stuck loop and hold the player.
-- Returning true prohibits the (whole) movement; returning false lets it
-- through untouched.
-- @param a_Player cPlayer  the player (already holds the new position)
-- @param a_OldPos Vector3d  the old position
-- @param a_NewPos Vector3d  the requested new position
-- @param a_PreviousIsOnGround boolean  whether the player was on a solid block
-- @return boolean  true = movement refused
local function OnPlayerMoving(a_Player, a_OldPos, a_NewPos, a_PreviousIsOnGround)
	if not g_Enabled then
		return false
	end

	-- Never touch frozen players (admin Freeze is an explicit request).
	if a_Player:IsFrozen() then
		return false
	end

	-- Only the overworld: in the Nether/End the danger-line Y is normal
	-- terrain or lava, not a void. The MCC bots (and this guard's purpose)
	-- live in the default overworld.
	if a_Player:GetWorld():GetDimension() ~= dimOverworld then
		return false
	end

	local uuid = a_Player:GetUUID()

	-- Freeze window active: refuse ALL movement. The player was just pulled
	-- up to SafeY, and every incoming move is rejected to hold them there
	-- while the server force-syncs the position back to the client.
	local ticks = g_FreezeTicks[uuid]
	if ticks and (ticks > 0) then
		return true
	end

	local newY = a_NewPos.y

	-- Fast path: above the danger line, all movement is normal.
	if newY >= g_VoidY then
		return false
	end

	-- Deep below the world's bottom edge: stand down and let the server
	-- handle the player itself (e.g. an admin deliberately voiding someone).
	if newY <= g_NoReturnY then
		return false
	end

	-- Detection: the player's body must be embedded in solid blocks. This is
	-- the signature of the MCC death/void loop: the client keeps reporting a
	-- position inside the terrain (we measured it frozen at y=38.1 inside a
	-- solid stone column), and the server accepts it, so the player is stuck
	-- taking damage forever without respawning. A legitimate player -- even
	-- deep underground, swimming or on a slope -- is always in air or water,
	-- never inside a solid block, so this check removes the false positives a
	-- raw Y threshold would cause. Check the block at head level: a standing
	-- player's head block is always air, an embedded player's is solid.
	-- (GetBlock returns 0 for unloaded chunks -> not solid -> no guard; fine.)
	local blockType = a_Player:GetWorld():GetBlock(Vector3i(
		math.floor(a_NewPos.x), math.floor(a_NewPos.y) + 1, math.floor(a_NewPos.z)))
	if not cBlockInfo:IsSolid(blockType) then
		return false
	end

	-- Detected a void-fall stuck loop: pull the player back up (restoring
	-- health lost to suffocation on the way down), start the freeze counter
	-- so ALL further movement is refused for the next ticks, and reject this
	-- move.
	a_Player:TeleportToCoords(a_NewPos.x, g_SafeY, a_NewPos.z)
	a_Player:SetHealth(a_Player:GetMaxHealth())
	g_FreezeTicks[uuid] = g_FreezeTicksInit

	-- Log the rescue, but at most once per LogEvery seconds per player so a
	-- stuck client cannot flood the console.
	local now = cRoot:Get():GetServerUpTime()
	local lastLog = g_LastLog[uuid]
	if (lastLog == nil) or ((now - lastLog) >= g_LogEvery) then
		g_LastLog[uuid] = now
		LOG("[VoidGuard] rescued " .. a_Player:GetName() .. " from void fall (y=" .. string.format("%.1f", newY)
			.. "), teleported to y=" .. g_SafeY .. ", frozen for " .. g_FreezeTicksInit .. " ticks")
	end

	return true
end

-- HOOK_WORLD_TICK: count the freeze timers down. Hooked on the default world
-- only so a multi-world server does not drain the counters faster than 20/s.
-- @param a_World cWorld  world that is ticking
-- @param a_TimeDelta number  milliseconds since the previous tick
local function OnWorldTick(a_World, a_TimeDelta)
	if a_World ~= cRoot:Get():GetDefaultWorld() then
		return
	end
	for uuid, ticks in pairs(g_FreezeTicks) do
		if ticks > 1 then
			g_FreezeTicks[uuid] = ticks - 1
		else
			g_FreezeTicks[uuid] = nil
		end
	end
end

----------------------------------------------------------------------
-- Module entry point (called from main.lua Initialize)
----------------------------------------------------------------------

-- Read settings.ini ([VoidGuard] section) and register the hooks when enabled.
-- Defaults are written into settings.ini on first run, like config.lua does.
-- @return boolean ok, string msg
function InitVoidGuard()
	local ini = cIniFile()
	local path = g_PluginFolder .. "/settings.ini"
	ini:ReadFile(path)
	-- NB: cIniFile:GetValueSetB does not parse "true"/"false" correctly in
	-- this Cuberite build (it returned false even for Enabled=true), so read
	-- the boolean as a string like config.lua does. The default is only
	-- written when the key is missing, so first-run users get Enabled=true.
	if ini:GetValue("VoidGuard", "Enabled", "") == "" then
		ini:SetValue("VoidGuard", "Enabled", "true")
	end
	g_Enabled = ini:GetValue("VoidGuard", "Enabled", "true"):lower() == "true"
	g_VoidY   = ini:GetValueSetI("VoidGuard", "VoidY", 40)
	g_SafeY   = ini:GetValueSetI("VoidGuard", "SafeY", 74)
	ini:WriteFile(path)

	if not g_Enabled then
		LOG("[VoidGuard] disabled in settings.ini (Enabled=false)")
		return true, "void guard disabled by config"
	end

	cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_MOVING, OnPlayerMoving)
	cPluginManager:AddHook(cPluginManager.HOOK_WORLD_TICK, OnWorldTick)
	LOG("[VoidGuard] enabled (VoidY=" .. g_VoidY .. ", SafeY=" .. g_SafeY
		.. ", freeze=" .. g_FreezeTicksInit .. " ticks)")
	return true, "void guard enabled"
end
