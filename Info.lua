
-- Info.lua

-- Implements the g_PluginInfo standard plugin description

g_PluginInfo =
{
	Name = "MCPServer",
	Version = "0.1",
	Date = "2026-07-27",
	Description = [[Exposes Cuberite as an MCP (Model Context Protocol) server over Streamable HTTP, so LLM hosts can call server tools.]],

	Commands =
	{
	},

	ConsoleCommands =
	{
		mcp =
		{
			Subcommands =
			{
				start =
				{
					HelpString = "Start the MCP HTTP server",
					Handler = HandleConsoleMCP,
					ParameterCombinations =
					{
						{ Params = "", Help = "Starts listening on the configured port (default 8765, loopback only)." },
					},
				},
				stop =
				{
					HelpString = "Stop the MCP HTTP server",
					Handler = HandleConsoleMCP,
					ParameterCombinations =
					{
						{ Params = "", Help = "Closes the listening socket and drops active connections." },
					},
				},
				status =
				{
					HelpString = "Report MCP server status",
					Handler = HandleConsoleMCP,
					ParameterCombinations =
					{
						{ Params = "", Help = "Prints whether the MCP server is running and on which port." },
					},
				},
			},
		},
	},
}
