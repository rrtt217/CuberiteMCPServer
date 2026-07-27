-- http.lua
-- Minimal HTTP/1.1 request parser + response writer for the MCP server.
--
-- Each connection owns a state table with a buffer accumulator. Data arrives
-- in chunks via OnReceivedData; we accumulate until a full request (headers
-- + Content-Length body) is available, then hand the body to a dispatcher
-- callback. The dispatcher is expected to call SendHTTPResponse (possibly
-- later, from the tick thread) and then close the link.
--
-- Supports both POST (JSON-RPC) and GET (SSE stream) per the MCP Streamable
-- HTTP transport (2025-06-18) and the legacy HTTP+SSE transport (2024-11-05).

-- Build an HTTP/1.1 response string with a complete body (Content-Length).
-- a_Body must be a complete string (usually JSON).
function BuildHTTPResponse(a_StatusLine, a_Headers, a_Body)
	local lines = { "HTTP/1.1 " .. a_StatusLine }
	for _, h in ipairs(a_Headers) do
		lines[#lines + 1] = h
	end
	-- Always include Content-Length and a close-connection header for v1.
	lines[#lines + 1] = "Content-Length: " .. #a_Body
	lines[#lines + 1] = "Connection: close"
	lines[#lines + 1] = "MCP-Protocol-Version: " .. g_MCPConfig.ProtocolVersion
	lines[#lines + 1] = ""
	lines[#lines + 1] = ""
	return table.concat(lines, "\r\n") .. a_Body
end

-- Build the head of a chunked/streaming HTTP response (no Content-Length,
-- no terminating blank line). The caller appends body chunks afterwards.
function BuildHTTPStreamHead(a_StatusLine, a_Headers)
	local lines = { "HTTP/1.1 " .. a_StatusLine }
	for _, h in ipairs(a_Headers) do
		lines[#lines + 1] = h
	end
	lines[#lines + 1] = "Connection: close"
	lines[#lines + 1] = "MCP-Protocol-Version: " .. g_MCPConfig.ProtocolVersion
	lines[#lines + 1] = ""
	lines[#lines + 1] = ""
	return table.concat(lines, "\r\n")
end

-- Convenience: send a JSON body with 200 OK and shut the link down.
function SendHTTPJSON(a_Link, a_JSONString)
	LOG("[MCP] SendHTTPJSON " .. #a_JSONString .. " bytes: " .. a_JSONString:sub(1, 200))
	local resp = BuildHTTPResponse(
		"200 OK",
		{ "Content-Type: application/json",
		  "Accept: application/json, text/event-stream" },
		a_JSONString)
	local ok = a_Link:Send(resp)
	LOG("[MCP] Send returned " .. tostring(ok) .. ", shutting down link " .. tostring(a_Link))
	a_Link:Shutdown()
end

-- Send a 4xx/5xx error response with a plain-text body.
function SendHTTPError(a_Link, a_StatusLine, a_Body)
	LOG("[MCP] SendHTTPError " .. a_StatusLine .. ": " .. a_Body)
	local resp = BuildHTTPResponse(a_StatusLine, { "Content-Type: text/plain" }, a_Body)
	a_Link:Send(resp)
	a_Link:Shutdown()
end

-- Send a 202 Accepted response with no body, for JSON-RPC notifications.
-- Per MCP Streamable HTTP: notifications must return 202 with no body.
function SendHTTP202(a_Link)
	local resp = BuildHTTPResponse("202 Accepted", {}, "")
	a_Link:Send(resp)
	a_Link:Shutdown()
end

-- Send a single Server-Sent Event on a link. The link must already have the
-- SSE response head sent (see BuildHTTPStreamHead). a_Event is the event
-- name (may be nil for the default "message" event); a_Data is the payload
-- string. Each line of a_Data is emitted as a "data:" line per the SSE spec.
function SendSSEEvent(a_Link, a_Event, a_Data)
	local frame = ""
	if a_Event then
		frame = frame .. "event: " .. a_Event .. "\r\n"
	end
	-- SSE: each line of the payload becomes a "data:" line. A trailing
	-- newline in the data produces an empty final data line, which is fine.
	for line in (a_Data .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		frame = frame .. "data: " .. line .. "\r\n"
	end
	frame = frame .. "\r\n"  -- blank line terminates the event
	LOG("[MCP] SendSSEEvent event=" .. tostring(a_Event) .. " data=" .. tostring(a_Data) .. " frame=" .. #frame .. " bytes")
	a_Link:Send(frame)
end

-- Try to parse a complete HTTP request out of a buffer string.
-- Returns: bodyString, bytesConsumed  if a full request is available
--          nil, 0                     if more data is needed
--          false, bytesConsumed       if the request is malformed
function ParseHTTPRequest(a_Buf)
	-- Find end-of-headers marker.
	local headerEnd = a_Buf:find("\r\n\r\n", 1, true)
	if not headerEnd then
		-- Headers not complete yet. Bail out if buffer grows unreasonably.
		if #a_Buf > 65536 then
			return false, #a_Buf
		end
		return nil, 0
	end
	local headerSection = a_Buf:sub(1, headerEnd - 1)
	local bodyStart = headerEnd + 4

	-- Parse the request line.
	local firstLine = headerSection:match("^(.-)\r\n")
	if not firstLine then
		return false, headerEnd + 2
	end
	local method, path, version = firstLine:match("^(%u+)%s+(%S+)%s+(HTTP/%d%.%d)$")
	if not method then
		return false, headerEnd + 2
	end
	if method ~= "POST" and method ~= "GET" then
		-- We only handle POST (JSON-RPC) for v1; GET would be SSE which we skip.
		return false, headerEnd + 2
	end

	-- Parse Content-Length (case-insensitive). Default to 0.
	local contentLength = 0
	for line in headerSection:gmatch("\r\n([^\r\n]+)") do
		local name, value = line:match("^([^:]+):%s*(.*)$")
		if name and value and name:lower() == "content-length" then
			contentLength = tonumber(value) or 0
			break
		end
	end

	-- Validate body completeness.
	local totalLen = bodyStart + contentLength - 1
	if #a_Buf < totalLen then
		return nil, 0  -- need more data
	end

	local body = a_Buf:sub(bodyStart, totalLen)
	return body, totalLen, method, path
end
