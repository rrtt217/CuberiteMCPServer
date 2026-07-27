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
}

g_MCPConfig = {}

function LoadMCPConfig(a_PluginFolder)
	local ini = cIniFile()
	local path = a_PluginFolder .. "/config.ini"
	if not ini:ReadFile(path) then
		-- No config file yet; write defaults out so the user can edit them.
		ini:SetValue("Network", "Port", g_Defaults.Port)
		ini:SetValue("Security", "AllowedIPPrefixes", "127.,::1")
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
