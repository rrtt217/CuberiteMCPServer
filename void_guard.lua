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
-- next falling-position packet pulls the player back into the void. The only
-- reliable cure is HOOK_PLAYER_MOVING: refusing the movement by returning
-- true (so the new position is never stored) and teleporting the player back
-- up. While the hook is active the server force-syncs the position back to
-- the client, correcting the MCC client's stale local state ("sticky" fix:
-- once corrected, later deaths no longer re-trigger the loop).
--
-- Both actions are rate-limited per player (server uptime seconds), so a
-- client that keeps re-sending a stale below-threshold position (we measured
-- this happening every ~2 s indefinitely without a cooldown) cannot cause
-- per-tick teleport jitter or log spam.
--
-- Exposed globals (used by main.lua):
--   InitVoidGuard() -> (ok, msg)  read settings.ini and register the hook if enabled

local g_Enabled  = true   -- master switch, from settings.ini [VoidGuard] Enabled
local g_VoidY    = 40     -- below this Y the move is refused (configurable)
local g_SafeY    = 74     -- the Y the player is pulled back up to (configurable)
local g_Cooldown = 1.0    -- seconds between teleport rescues for the same player
local g_LogEvery = 30.0   -- seconds between LOG lines for the same stuck player
local g_NoReturnY = -500  -- past this the server handles the player itself; we stand down

-- Per-player state, keyed by the player's UUID so different players (real
-- players, several MCC bots) are throttled independently.
local g_LastRescue = {}   -- uuid -> server uptime seconds of the last teleport
local g_LastLog    = {}   -- uuid -> server uptime seconds of the last LOG line

----------------------------------------------------------------------
-- Hook handler
----------------------------------------------------------------------

-- HOOK_PLAYER_MOVING: refuse movement that would take the player below the
-- void threshold, and teleport them back up. Returning true prohibits the
-- movement; returning false lets it through untouched.
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

	-- Only the overworld: in the Nether/End y=40 is normal terrain or lava,
	-- not a void. The MCC bots (and this guard's purpose) live in the
	-- default overworld.
	if a_Player:GetWorld():GetDimension() ~= dimOverworld then
		return false
	end

	local newY = a_NewPos.y

	-- Fast path: above the threshold, all movement is normal.
	if newY >= g_VoidY then
		return false
	end

	-- Deep below the world's bottom edge: stand down and let the server
	-- handle the player itself (e.g. an admin deliberately voiding someone).
	if newY <= g_NoReturnY then
		return false
	end

	-- Only interfere while the player is actually descending. A player simply
	-- standing or swimming below the threshold is left alone. (Trade-off:
	-- a legitimate walkway descending below VoidY -- a deep cave or ravine --
	-- triggers the guard too; that is the accepted cost of a low, safe
	-- threshold, documented here for future tuning.)
	if newY >= a_OldPos.y then
		return false
	end

	-- Below the threshold and mid-fall: refuse the movement so the player
	-- cannot sink any further.
	local uuid = a_Player:GetUUID()
	local now = cRoot:Get():GetServerUpTime()
	local last = g_LastRescue[uuid]
	if (last ~= nil) and ((now - last) < g_Cooldown) then
		return true  -- held in place; the cooldown has not elapsed yet
	end

	-- Cooldown elapsed: pull the player back up to the safe height, keeping
	-- their x/z. The teleport also force-syncs the position back to the
	-- client, which is what corrects the MCC client's stale local state.
	g_LastRescue[uuid] = now
	a_Player:TeleportToCoords(a_NewPos.x, g_SafeY, a_NewPos.z)

	-- Log the rescue, but at most once per LogEvery seconds per player so a
	-- stuck client cannot flood the console.
	local lastLog = g_LastLog[uuid]
	if (lastLog == nil) or ((now - lastLog) >= g_LogEvery) then
		g_LastLog[uuid] = now
		LOG("[VoidGuard] rescued " .. a_Player:GetName() .. " from void fall (y=" .. string.format("%.1f", newY)
			.. "), teleported to y=" .. g_SafeY)
	end

	return true
end

----------------------------------------------------------------------
-- Module entry point (called from main.lua Initialize)
----------------------------------------------------------------------

-- Read settings.ini ([VoidGuard] section) and register the hook when enabled.
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
	LOG("[VoidGuard] enabled (VoidY=" .. g_VoidY .. ", SafeY=" .. g_SafeY .. ")")
	return true, "void guard enabled"
end
