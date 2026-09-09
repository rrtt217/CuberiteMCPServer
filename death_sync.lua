-- death_sync.lua
-- Death/respawn health re-sync for Cuberite clients.
--
-- Cuberite cPlayer::Respawn() (same-world death respawn) NEVER calls
-- cClientHandle::SendHealth(): SendHealth only fires on Heal(), SetFoodLevel(),
-- DoTakeDamage() or OnAddToWorld(). So after a death, the client's health bar
-- (and mineflayer's bot.health / isAlive state machine) stays stuck at 0 even
-- though the server already revived the player to full health. Vanilla clients
-- show the same stale 0 bar until the next heal/damage.
--
-- Fix: cClientHandle::HandleRespawn() explicitly raises HOOK_PLAYER_SPAWNED
-- right after cPlayer::Respawn(); our hook calls Player:Heal(0), which
-- unconditionally re-sends the current health to the client (SendHealth).
-- Verified end-to-end on this box: without it, mineflayer keeps isAlive=false
-- (health=0 on client) after respawn while the server shows health=20; with it,
-- the client snaps back to health=20 / isAlive=true on the next update_health.

local g_Hooked = false

-- @param a_Player cPlayer  the player that has just (re)spawned
-- @return false  (notification hook; no override)
local function OnPlayerSpawnedHealthResync(a_Player)
	if (a_Player ~= nil) then
		pcall(function()
			a_Player:Heal(0)  -- amount 0: heal no-op, but forces a health update packet
		end)
	end
	return false
end

-- Module entry point (called from main.lua Initialize).
-- @return boolean ok, string msg
function InitDeathSync()
	if g_Hooked then
		return true, "death-sync hook already registered"
	end
	cPluginManager:AddHook(cPluginManager.HOOK_PLAYER_SPAWNED, OnPlayerSpawnedHealthResync)
	g_Hooked = true
	LOG("[MCP] death-sync registered: HOOK_PLAYER_SPAWNED -> Heal(0) health re-send (fixes stuck health=0 after respawn)")
	return true, "death-sync hook registered"
end