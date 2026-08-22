
-- Info.lua

-- Implements the g_PluginInfo standard plugin description

g_PluginInfo =
{
	Name = "MCPServer",
	Version = "0.1",
	Date = "2026-07-27",
	Description = [[Exposes Cuberite as an MCP (Model Context Protocol) server over
		Streamable HTTP, so LLM hosts can call server tools. Includes a configurable
		void-fall guard (HOOK_PLAYER_MOVING) that protects MCC bots and players from
		death/void loops (settings.ini).]],

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
	mcc =
	{
		Subcommands =
		{
			start =
			{
				HelpString = "Start the MCC (Minecraft Console Client) bot",
				Handler = HandleConsoleMCC,
				ParameterCombinations =
				{
					{ Params = "", Help = "Launches the MCC bot as a background child process using the configured settings." },
				},
			},
			stop =
			{
				HelpString = "Stop the running MCC bot",
				Handler = HandleConsoleMCC,
				ParameterCombinations =
				{
					{ Params = "", Help = "Sends SIGTERM to the MCC process and clears its tracked PID." },
				},
			},
			restart =
			{
				HelpString = "Restart the MCC bot",
				Handler = HandleConsoleMCC,
				ParameterCombinations =
				{
					{ Params = "", Help = "Stops the running MCC bot (if any) and starts a fresh one." },
				},
			},
			status =
			{
				HelpString = "Report MCC bot status",
				Handler = HandleConsoleMCC,
				ParameterCombinations =
				{
					{ Params = "", Help = "Prints whether the MCC bot is enabled/running, its PID, username, and MCP port." },
				},
			},
		},
	},
}
