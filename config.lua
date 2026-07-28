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
	-- MCC (Minecraft Console Client) integration.
	MCC = {
		Enabled = false,
		Path = "",
		WorkDir = "",
		Username = "TestBot",
		ServerHost = "127.0.0.1",
		ServerPort = 25568,
		MinecraftVersion = "1.12.2",
		McpPort = 33333,
	},
}

g_MCPConfig = {}

function LoadMCPConfig(a_PluginFolder)
	local ini = cIniFile()
	local path = a_PluginFolder .. "/config.ini"
	local isNew = not ini:ReadFile(path)

	-- Always write defaults for any missing sections so the user can edit them.
	if isNew or ini:GetValue("Network", "Port", "") == "" then
		ini:SetValue("Network", "Port", tostring(g_Defaults.Port))
	end
	if isNew or ini:GetValue("Security", "AllowedIPPrefixes", "") == "" then
		ini:SetValue("Security", "AllowedIPPrefixes", "127.,::1")
	end
	if isNew or ini:GetValue("MCC", "Enabled", "") == "" then
		ini:SetValue("MCC", "Enabled", g_Defaults.MCC.Enabled and "true" or "false")
		ini:SetValue("MCC", "Path", g_Defaults.MCC.Path)
		ini:SetValue("MCC", "WorkDir", g_Defaults.MCC.WorkDir)
		ini:SetValue("MCC", "Username", g_Defaults.MCC.Username)
		ini:SetValue("MCC", "ServerHost", g_Defaults.MCC.ServerHost)
		ini:SetValue("MCC", "ServerPort", tostring(g_Defaults.MCC.ServerPort))
		ini:SetValue("MCC", "MinecraftVersion", g_Defaults.MCC.MinecraftVersion)
		ini:SetValue("MCC", "McpPort", tostring(g_Defaults.MCC.McpPort))
		ini:WriteFile(path)
	end

	g_MCPConfig.Port = tonumber(ini:GetValue("Network", "Port", tostring(g_Defaults.Port))) or g_Defaults.Port
	g_MCPConfig.ServerName = ini:GetValue("Identity", "ServerName", g_Defaults.ServerName)
	g_MCPConfig.ServerVersion = ini:GetValue("Identity", "ServerVersion", g_Defaults.ServerVersion)
	g_MCPConfig.ProtocolVersion = ini:GetValue("Identity", "ProtocolVersion", g_Defaults.ProtocolVersion)

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
	g_MCPConfig.MCC.Path = ini:GetValue("MCC", "Path", g_Defaults.MCC.Path)
	g_MCPConfig.MCC.WorkDir = ini:GetValue("MCC", "WorkDir", g_Defaults.MCC.WorkDir)
	g_MCPConfig.MCC.Username = ini:GetValue("MCC", "Username", g_Defaults.MCC.Username)
	g_MCPConfig.MCC.ServerHost = ini:GetValue("MCC", "ServerHost", g_Defaults.MCC.ServerHost)
	g_MCPConfig.MCC.ServerPort = tonumber(ini:GetValue("MCC", "ServerPort", tostring(g_Defaults.MCC.ServerPort))) or g_Defaults.MCC.ServerPort
	g_MCPConfig.MCC.MinecraftVersion = ini:GetValue("MCC", "MinecraftVersion", g_Defaults.MCC.MinecraftVersion)
	g_MCPConfig.MCC.McpPort = tonumber(ini:GetValue("MCC", "McpPort", tostring(g_Defaults.MCC.McpPort))) or g_Defaults.MCC.McpPort
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
