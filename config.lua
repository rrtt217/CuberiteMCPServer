-- config.lua
-- Loads and exposes MCP server configuration.

local g_Defaults = {
	Port = 8765,
	-- IP prefixes allowed to connect (loopback only by default).
	AllowedIPPrefixes = { "127.", "::1" },
	-- Server identification reported in the MCP initialize handshake.
	ServerName = "cuberite-mcp",
	ServerVersion = "0.1",
	-- MCP protocol version advertised.
	ProtocolVersion = "2025-06-18",
	-- Bot engine: "mineflayer" (default) or "mcc".
	-- mineflayer covers the full Cuberite protocol range (1.8 - 1.12.2, needs
	-- the prismarine-chunk patch in bot/patches). "mcc" (Minecraft Console
	-- Client) is DEPRECATED and kept only as a manual fallback; see
	-- docs/handoff-mineflayer-migration.md and docs/version-compat-matrix.md.
	Engine = "mineflayer",
	-- MCC (Minecraft Console Client) integration. DEPRECATED - fallback engine
	-- only; the mineflayer bot is the default. Kept for manual rollback via
	-- [Engine] Engine = mcc.
	MCC = {
		Enabled = false,
		AutoStart = true,  -- when Enabled, launch MCC automatically on plugin init
		Path = "",
		WorkDir = "",
		Username = "TestBot",
		RandomUsername = false,
		ServerHost = "127.0.0.1",
		ServerPort = 25568,
		MinecraftVersion = "1.12.2",
		McpPort = 33333,
	},
	-- Mineflayer bot integration (used when Engine = "mineflayer").
	Bot = {
		Enabled = false,
		AutoStart = true,      -- when Enabled, launch the bot on plugin init
		NodePath = "",          -- empty = use "node" from PATH
		BotDir = "bot",         -- relative to the plugin folder (resolved at load)
		Username = "TestBot",
		RandomUsername = true,
		ServerHost = "127.0.0.1",
		ServerPort = 25568,
		MinecraftVersion = "1.12.2",  -- max Cuberite protocol; 1.9+ chunks need the prismarine-chunk patch
		McpPort = 33333,
	},
	-- Void-fall loop guard (HOOK_PLAYER_MOVING). Off by default: the mineflayer
	-- engine respawns cleanly and never falls into the void; the guard exists
	-- for the deprecated MCC engine and for broken terrain edge cases.
	VoidGuard = {
		Enabled = false,
		VoidY = 40,
		SafeY = 74,
	},
}

g_MCPConfig = {}

function LoadMCPConfig(a_PluginFolder)
	local ini = cIniFile()
	local path = a_PluginFolder .. "/config.ini"
	local isNew = not ini:ReadFile(path)

	-- Always write defaults for any missing sections so the user can edit them.
	if isNew or ini:GetValue("Engine", "Engine", "") == "" then
		ini:SetValue("Engine", "Engine", g_Defaults.Engine)
	end
	if isNew or ini:GetValue("Network", "Port", "") == "" then
		ini:SetValue("Network", "Port", tostring(g_Defaults.Port))
	end
	if isNew or ini:GetValue("Security", "AllowedIPPrefixes", "") == "" then
		ini:SetValue("Security", "AllowedIPPrefixes", "127.,::1")
	end
	if isNew or ini:GetValue("MCC", "Enabled", "") == "" then
		ini:SetValue("MCC", "Enabled", g_Defaults.MCC.Enabled and "true" or "false")
		ini:SetValue("MCC", "AutoStart", g_Defaults.MCC.AutoStart and "true" or "false")
		ini:SetValue("MCC", "Path", g_Defaults.MCC.Path)
		ini:SetValue("MCC", "WorkDir", g_Defaults.MCC.WorkDir)
		ini:SetValue("MCC", "Username", g_Defaults.MCC.Username)
		ini:SetValue("MCC", "RandomUsername", g_Defaults.MCC.RandomUsername and "true" or "false")
		ini:SetValue("MCC", "ServerHost", g_Defaults.MCC.ServerHost)
		ini:SetValue("MCC", "ServerPort", tostring(g_Defaults.MCC.ServerPort))
		ini:SetValue("MCC", "MinecraftVersion", g_Defaults.MCC.MinecraftVersion)
		ini:SetValue("MCC", "McpPort", tostring(g_Defaults.MCC.McpPort))
		ini:WriteFile(path)
	end
	if isNew or ini:GetValue("Bot", "Enabled", "") == "" then
		ini:SetValue("Bot", "Enabled", g_Defaults.Bot.Enabled and "true" or "false")
		ini:SetValue("Bot", "AutoStart", g_Defaults.Bot.AutoStart and "true" or "false")
		ini:SetValue("Bot", "NodePath", g_Defaults.Bot.NodePath)
		ini:SetValue("Bot", "BotDir", g_Defaults.Bot.BotDir)
		ini:SetValue("Bot", "Username", g_Defaults.Bot.Username)
		ini:SetValue("Bot", "RandomUsername", g_Defaults.Bot.RandomUsername and "true" or "false")
		ini:SetValue("Bot", "ServerHost", g_Defaults.Bot.ServerHost)
		ini:SetValue("Bot", "ServerPort", tostring(g_Defaults.Bot.ServerPort))
		ini:SetValue("Bot", "MinecraftVersion", g_Defaults.Bot.MinecraftVersion)
		ini:SetValue("Bot", "McpPort", tostring(g_Defaults.Bot.McpPort))
		ini:WriteFile(path)
	end
	if isNew or ini:GetValue("VoidGuard", "Enabled", "") == "" then
		ini:SetValue("VoidGuard", "Enabled", g_Defaults.VoidGuard.Enabled and "true" or "false")
		ini:SetValue("VoidGuard", "VoidY", tostring(g_Defaults.VoidGuard.VoidY))
		ini:SetValue("VoidGuard", "SafeY", tostring(g_Defaults.VoidGuard.SafeY))
		ini:WriteFile(path)
	end

	g_MCPConfig.Port = tonumber(ini:GetValue("Network", "Port", tostring(g_Defaults.Port))) or g_Defaults.Port
	g_MCPConfig.ServerName = ini:GetValue("Identity", "ServerName", g_Defaults.ServerName)
	g_MCPConfig.ServerVersion = ini:GetValue("Identity", "ServerVersion", g_Defaults.ServerVersion)
	g_MCPConfig.ProtocolVersion = ini:GetValue("Identity", "ProtocolVersion", g_Defaults.ProtocolVersion)
	g_MCPConfig.Engine = ini:GetValue("Engine", "Engine", g_Defaults.Engine):lower()

	-- Parse comma-separated prefix list into a table.
	local prefixesStr = ini:GetValue("Security", "AllowedIPPrefixes", "127.,::1")
	g_MCPConfig.AllowedIPPrefixes = {}
	for prefix in prefixesStr:gmatch("[^,]+") do
		prefix = prefix:match("^%s*(.-)%s*$")  -- trim whitespace
		if prefix ~= "" then
			g_MCPConfig.AllowedIPPrefixes[#g_MCPConfig.AllowedIPPrefixes + 1] = prefix
		end
	end

	-- MCC configuration.
	g_MCPConfig.MCC = {}
	g_MCPConfig.MCC.Enabled = ini:GetValue("MCC", "Enabled", "false"):lower() == "true"
	g_MCPConfig.MCC.AutoStart = ini:GetValue("MCC", "AutoStart", "true"):lower() == "true"
	g_MCPConfig.MCC.Path = ini:GetValue("MCC", "Path", g_Defaults.MCC.Path)
	g_MCPConfig.MCC.WorkDir = ini:GetValue("MCC", "WorkDir", g_Defaults.MCC.WorkDir)
	g_MCPConfig.MCC.Username = ini:GetValue("MCC", "Username", g_Defaults.MCC.Username)
	g_MCPConfig.MCC.RandomUsername = ini:GetValue("MCC", "RandomUsername", "false"):lower() == "true"
	g_MCPConfig.MCC.ServerHost = ini:GetValue("MCC", "ServerHost", g_Defaults.MCC.ServerHost)
	g_MCPConfig.MCC.ServerPort = tonumber(ini:GetValue("MCC", "ServerPort", tostring(g_Defaults.MCC.ServerPort))) or g_Defaults.MCC.ServerPort
	g_MCPConfig.MCC.MinecraftVersion = ini:GetValue("MCC", "MinecraftVersion", g_Defaults.MCC.MinecraftVersion)
	g_MCPConfig.MCC.McpPort = tonumber(ini:GetValue("MCC", "McpPort", tostring(g_Defaults.MCC.McpPort))) or g_Defaults.MCC.McpPort

	-- Mineflayer bot configuration.
	g_MCPConfig.Bot = {}
	g_MCPConfig.Bot.Enabled = ini:GetValue("Bot", "Enabled", "false"):lower() == "true"
	g_MCPConfig.Bot.AutoStart = ini:GetValue("Bot", "AutoStart", "true"):lower() == "true"
	g_MCPConfig.Bot.NodePath = ini:GetValue("Bot", "NodePath", g_Defaults.Bot.NodePath)
	g_MCPConfig.Bot.BotDir = ini:GetValue("Bot", "BotDir", g_Defaults.Bot.BotDir)
	g_MCPConfig.Bot.Username = ini:GetValue("Bot", "Username", g_Defaults.Bot.Username)
	g_MCPConfig.Bot.RandomUsername = ini:GetValue("Bot", "RandomUsername", "true"):lower() == "true"
	g_MCPConfig.Bot.ServerHost = ini:GetValue("Bot", "ServerHost", g_Defaults.Bot.ServerHost)
	g_MCPConfig.Bot.ServerPort = tonumber(ini:GetValue("Bot", "ServerPort", tostring(g_Defaults.Bot.ServerPort))) or g_Defaults.Bot.ServerPort
	g_MCPConfig.Bot.MinecraftVersion = ini:GetValue("Bot", "MinecraftVersion", g_Defaults.Bot.MinecraftVersion)
	g_MCPConfig.Bot.McpPort = tonumber(ini:GetValue("Bot", "McpPort", tostring(g_Defaults.Bot.McpPort))) or g_Defaults.Bot.McpPort

	-- VoidGuard configuration (consolidated here from settings.ini).
	g_MCPConfig.VoidGuard = {}
	g_MCPConfig.VoidGuard.Enabled = ini:GetValue("VoidGuard", "Enabled", "false"):lower() == "true"
	g_MCPConfig.VoidGuard.VoidY = tonumber(ini:GetValue("VoidGuard", "VoidY", tostring(g_Defaults.VoidGuard.VoidY))) or g_Defaults.VoidGuard.VoidY
	g_MCPConfig.VoidGuard.SafeY = tonumber(ini:GetValue("VoidGuard", "SafeY", tostring(g_Defaults.VoidGuard.SafeY))) or g_Defaults.VoidGuard.SafeY

	-- Resolve relative paths against the plugin folder so config examples can
	-- stay portable (e.g. BotDir = bot, MCC Path = ../MinecraftConsoleClient).
	-- Absolute paths (starting with "/") and empty values pass through.
	local function ResolvePath(a_Path)
		if (a_Path == "") or a_Path:match("^/") then
			return a_Path
		end
		return a_PluginFolder .. "/" .. a_Path
	end
	g_MCPConfig.MCC.Path = ResolvePath(g_MCPConfig.MCC.Path)
	g_MCPConfig.MCC.WorkDir = ResolvePath(g_MCPConfig.MCC.WorkDir)

	-- NodePath: empty -> "node" on PATH; bare names (no slash) also resolve
	-- via PATH; path-like values resolve against the plugin folder. The
	-- server launches the bot via os.execute (CWD = server dir), which cannot
	-- resolve plugin-relative paths itself, so everything becomes absolute.
	local function ResolveExecutable(a_Path)
		if (a_Path == "") or a_Path:match("^/") or not a_Path:match("/") then
			return a_Path
		end
		return a_PluginFolder .. "/" .. a_Path
	end
	local np = g_MCPConfig.Bot.NodePath
	if np == "" then
		np = "node"  -- assume node is on PATH
	end
	g_MCPConfig.Bot.NodePath = ResolveExecutable(np)
	g_MCPConfig.Bot.BotDir = ResolvePath(g_MCPConfig.Bot.BotDir)
end

function IsIPAllowed(a_RemoteIP)
	-- Normalize IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) to plain IPv4
	-- so the default "127." prefix matches loopback connections that arrive
	-- as "::ffff:127.0.0.1" on a dual-stack listening socket.
	local ip = a_RemoteIP
	local mapped = ip:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
	if mapped then
		ip = mapped
	end
	for _, prefix in ipairs(g_MCPConfig.AllowedIPPrefixes) do
		if ip:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end
