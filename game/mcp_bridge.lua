-- Security-hardened MCP bridge for LÖVE2D.
--
-- Security defaults:
--   * loopback-only binding
--   * authentication token required
--   * arbitrary Lua execution disabled
--   * no direct love/os/io/package/debug exposure to run_lua
--   * request/response size limits and basic rate limiting

local socket = require("socket")

local mcp_bridge = {}
local server = nil
local clients = {}
local objectGetter = nil
local objectSetter = nil
local actionHandler = nil
local luaContextProvider = nil
local gameMetadataProvider = nil

local config = {
    host = "127.0.0.1",
    port = 12345,
    token = nil,
    max_clients = 2,
    max_request_bytes = 256 * 1024,
    max_response_bytes = 1024 * 1024,
    max_string_bytes = 64 * 1024,
    max_serialize_items = 1000,
    requests_per_second = 30,
    client_idle_seconds = 30,
    allow_run_lua = false,
    lua_max_code_bytes = 64 * 1024,
    lua_instruction_limit = 500000,
    lua_hook_interval = 10000,
    max_serialize_depth = 6,
}

local json = {}

local function now()
    if socket.gettime then return socket.gettime() end
    return os.time()
end

local function shallow_copy(source)
    local result = {}
    for k, v in pairs(source or {}) do result[k] = v end
    return result
end

local function constant_time_equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local max_len = math.max(#a, #b)
    local diff = #a == #b and 0 or 1
    for i = 1, max_len do
        local aa = i <= #a and string.byte(a, i) or 0
        local bb = i <= #b and string.byte(b, i) or 0
        if aa ~= bb then diff = 1 end
    end
    return diff == 0
end

local function response(request_id, ok, payload, code)
    local body = { request_id = request_id, ok = ok }
    if ok then
        body.result = payload
    else
        body.error = tostring(payload)
        body.code = code or "BRIDGE_ERROR"
    end

    local encoded = json.encode(body)
    if #encoded > config.max_response_bytes then
        encoded = json.encode({
            request_id = request_id,
            ok = false,
            error = "Response exceeded size limit",
            code = "RESPONSE_TOO_LARGE",
        })
    end
    return encoded
end

local function sanitize(value, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if depth > config.max_serialize_depth then return "<max-depth>" end

    local value_type = type(value)
    if value_type == "nil" or value_type == "boolean" or value_type == "number" then
        return value
    end
    if value_type == "string" then
        if #value > config.max_string_bytes then
            return string.sub(value, 1, config.max_string_bytes) .. "<truncated>"
        end
        return value
    end
    if value_type ~= "table" then
        return "<" .. value_type .. ">"
    end
    if seen[value] then return "<cycle>" end
    seen[value] = true

    local output = {}
    local item_count = 0
    for key, child in pairs(value) do
        item_count = item_count + 1
        if item_count > config.max_serialize_items then
            output["<truncated>"] = true
            break
        end
        local key_type = type(key)
        if key_type == "number" then
            output[key] = sanitize(child, depth + 1, seen)
        elseif key_type == "string" and #key <= 256 then
            output[key] = sanitize(child, depth + 1, seen)
        end
    end
    seen[value] = nil
    return output
end

local function read_env_token()
    if os and os.getenv then
        local value = os.getenv("LOVE2D_MCP_TOKEN")
        if value and #value > 0 then return value end
    end
    return nil
end

function mcp_bridge.init(options)
    if server then return true end

    if type(options) == "number" then
        options = { port = options }
    elseif type(options) ~= "table" then
        options = {}
    end

    local next_config = shallow_copy(config)
    for key, value in pairs(options) do
        if next_config[key] ~= nil then next_config[key] = value end
    end
    next_config.token = options.token or read_env_token()

    if next_config.host ~= "127.0.0.1" and next_config.host ~= "::1" and next_config.host ~= "localhost" then
        error("MCP bridge only permits loopback binding; use 127.0.0.1")
    end
    if type(next_config.token) ~= "string" or #next_config.token < 32 then
        error("MCP bridge requires LOVE2D_MCP_TOKEN (minimum 32 characters)")
    end
    if type(next_config.port) ~= "number" or next_config.port < 1 or next_config.port > 65535 then
        error("Invalid MCP bridge port")
    end

    config = next_config
    server = assert(socket.tcp())
    server:setoption("reuseaddr", true)
    assert(server:bind(config.host, config.port))
    assert(server:listen(config.max_clients))
    server:settimeout(0)

    print(string.format(
        "MCP Bridge listening on %s:%d (auth=required, run_lua=%s)",
        config.host,
        config.port,
        tostring(config.allow_run_lua)
    ))
    return true
end

function mcp_bridge.setObjectGetter(getter)
    assert(type(getter) == "function" or getter == nil, "object getter must be a function or nil")
    objectGetter = getter
end

function mcp_bridge.setObjectSetter(setter)
    assert(type(setter) == "function" or setter == nil, "object setter must be a function or nil")
    objectSetter = setter
end

function mcp_bridge.setActionHandler(handler)
    assert(type(handler) == "function" or handler == nil, "action handler must be a function or nil")
    actionHandler = handler
end

function mcp_bridge.setLuaContextProvider(provider)
    assert(type(provider) == "function" or provider == nil, "Lua context provider must be a function or nil")
    luaContextProvider = provider
end

function mcp_bridge.setGameMetadataProvider(provider)
    assert(type(provider) == "function" or provider == nil, "metadata provider must be a function or nil")
    gameMetadataProvider = provider
end

local function close_client(index, reason)
    local client_state = clients[index]
    if not client_state then return end
    pcall(function() client_state.socket:close() end)
    table.remove(clients, index)
    if reason then print("MCP client disconnected: " .. reason) end
end

local function allow_request(client_state)
    local current = now()
    if current - client_state.window_started >= 1 then
        client_state.window_started = current
        client_state.window_count = 0
    end
    client_state.window_count = client_state.window_count + 1
    client_state.last_seen = current
    return client_state.window_count <= config.requests_per_second
end

function mcp_bridge.update()
    if not server then return end

    local accepted = server:accept()
    if accepted then
        if #clients >= config.max_clients then
            accepted:close()
        else
            accepted:settimeout(0)
            table.insert(clients, {
                socket = accepted,
                buffer = "",
                last_seen = now(),
                window_started = now(),
                window_count = 0,
            })
            print("MCP client connected")
        end
    end

    for i = #clients, 1, -1 do
        local state = clients[i]
        if now() - state.last_seen > config.client_idle_seconds then
            close_client(i, "idle timeout")
        else
            local chunk, err, partial = state.socket:receive(4096)
            local data = chunk or partial
            if data and #data > 0 then
                state.buffer = state.buffer .. data
                state.last_seen = now()
                if #state.buffer > config.max_request_bytes then
                    state.socket:send(response(nil, false, "Request exceeded size limit", "REQUEST_TOO_LARGE") .. "\n")
                    close_client(i, "request too large")
                else
                    while true do
                        local newline = string.find(state.buffer, "\n", 1, true)
                        if not newline then break end
                        local line = string.sub(state.buffer, 1, newline - 1)
                        state.buffer = string.sub(state.buffer, newline + 1)

                        if not allow_request(state) then
                            state.socket:send(response(nil, false, "Rate limit exceeded", "RATE_LIMITED") .. "\n")
                        elseif #line > 0 then
                            local ok, result = pcall(mcp_bridge.handleCommand, line)
                            if not ok then
                                result = response(nil, false, result, "INTERNAL_ERROR")
                            end
                            state.socket:send(result .. "\n")
                        end
                    end
                end
            elseif err == "closed" then
                close_client(i, "closed")
            end
        end
    end
end

function mcp_bridge.handleCommand(line)
    if type(line) ~= "string" or #line > config.max_request_bytes then
        return response(nil, false, "Invalid request", "INVALID_REQUEST")
    end

    local ok, command = pcall(json.decode, line)
    if not ok or type(command) ~= "table" then
        return response(nil, false, "Malformed JSON", "BAD_JSON")
    end

    local request_id = command.request_id
    if type(request_id) ~= "string" or #request_id > 128 then
        return response(nil, false, "Missing or invalid request_id", "INVALID_REQUEST_ID")
    end
    if not constant_time_equal(command.token, config.token) then
        return response(request_id, false, "Authentication failed", "UNAUTHORIZED")
    end

    if command.command == "ping" then
        return response(request_id, true, { pong = true, time = now() })
    elseif command.command == "get_status" then
        return response(request_id, true, mcp_bridge.getStatus())
    elseif command.command == "list_objects" then
        return response(request_id, true, mcp_bridge.listObjects())
    elseif command.command == "get_object" then
        return response(request_id, true, mcp_bridge.getObject(command.id))
    elseif command.command == "set_object_property" then
        local success, result_or_error = mcp_bridge.setObjectProperty(command.id, command.property, command.value)
        if not success then return response(request_id, false, result_or_error, "MUTATION_DENIED") end
        return response(request_id, true, result_or_error)
    elseif command.command == "invoke_action" then
        local success, result_or_error = mcp_bridge.invokeAction(command.action, command.params)
        if not success then return response(request_id, false, result_or_error, "ACTION_DENIED") end
        return response(request_id, true, result_or_error)
    elseif command.command == "run_lua" then
        local success, result_or_error = mcp_bridge.runLua(command.code)
        if not success then return response(request_id, false, result_or_error, "LUA_DENIED") end
        return response(request_id, true, result_or_error)
    end

    return response(request_id, false, "Unknown command: " .. tostring(command.command), "UNKNOWN_COMMAND")
end

function mcp_bridge.getStatus()
    local metadata = {}
    if gameMetadataProvider then
        local ok, result = pcall(gameMetadataProvider)
        if ok and type(result) == "table" then metadata = sanitize(result) end
    end
    return {
        bridge_version = "2.0.0",
        host = config.host,
        port = config.port,
        authenticated = true,
        run_lua_enabled = config.allow_run_lua,
        mutation_enabled = objectSetter ~= nil,
        actions_enabled = actionHandler ~= nil,
        connected_clients = #clients,
        metadata = metadata,
    }
end

function mcp_bridge.listObjects()
    if not objectGetter then return { objects = {}, warning = "No object getter configured" } end
    local ok, objects = pcall(objectGetter)
    if not ok or type(objects) ~= "table" then error("Object getter failed") end

    local result = {}
    for id, obj in pairs(objects) do
        if type(obj) == "table" then
            table.insert(result, {
                id = tostring(id),
                type = sanitize(obj.type),
                x = sanitize(obj.x),
                y = sanitize(obj.y),
                active = sanitize(obj.active),
            })
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return { objects = result }
end

function mcp_bridge.getObject(id)
    if type(id) ~= "string" or #id == 0 or #id > 256 then error("Invalid object id") end
    if not objectGetter then error("No object getter configured") end
    local objects = objectGetter()
    local obj = objects[id]
    if not obj then error("Object not found: " .. id) end
    return { object = sanitize(obj) }
end

function mcp_bridge.setObjectProperty(id, property, value)
    if not objectSetter then return false, "No object setter configured" end
    if type(id) ~= "string" or #id == 0 or #id > 256 then return false, "Invalid object id" end
    if type(property) ~= "string" or #property == 0 or #property > 128 then return false, "Invalid property" end
    local value_type = type(value)
    if value ~= nil and value_type ~= "string" and value_type ~= "number" and value_type ~= "boolean" then
        return false, "Only scalar property values are accepted"
    end
    local ok, result = pcall(objectSetter, id, property, value)
    if not ok then return false, result end
    if result == false then return false, "Setter rejected the mutation" end
    return true, sanitize(result == nil and { updated = true } or result)
end

function mcp_bridge.invokeAction(action, params)
    if not actionHandler then return false, "No action handler configured" end
    if type(action) ~= "string" or #action == 0 or #action > 128 then return false, "Invalid action" end
    if params ~= nil and type(params) ~= "table" then return false, "params must be an object" end
    local ok, result = pcall(actionHandler, action, params or {})
    if not ok then return false, result end
    if result == false then return false, "Action rejected" end
    return true, sanitize(result == nil and { invoked = true } or result)
end

local SAFE_TABLE = {
    concat = table.concat,
    insert = table.insert,
    remove = table.remove,
    sort = table.sort,
}

local SAFE_STRING = {
    byte = string.byte,
    char = string.char,
    find = string.find,
    format = string.format,
    gmatch = string.gmatch,
    gsub = string.gsub,
    len = string.len,
    lower = string.lower,
    match = string.match,
    rep = string.rep,
    reverse = string.reverse,
    sub = string.sub,
    upper = string.upper,
}

local SAFE_MATH = shallow_copy(math)
SAFE_MATH.randomseed = nil

function mcp_bridge.runLua(code)
    if not config.allow_run_lua then return false, "run_lua is disabled by bridge configuration" end
    if type(code) ~= "string" or #code == 0 then return false, "Lua code is required" end
    if #code > config.lua_max_code_bytes then return false, "Lua code exceeds size limit" end

    local func, compile_error = loadstring(code)
    if not func then return false, "Syntax error: " .. tostring(compile_error) end

    local context = {}
    if luaContextProvider then
        local ok, provided = pcall(luaContextProvider)
        if not ok then return false, "Lua context provider failed" end
        if type(provided) == "table" then context = provided end
    end

    local env = {
        context = context,
        pairs = pairs,
        ipairs = ipairs,
        next = next,
        select = select,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        assert = assert,
        error = error,
        pcall = pcall,
        table = SAFE_TABLE,
        math = SAFE_MATH,
        string = SAFE_STRING,
    }
    setfenv(func, env)

    if not debug or type(debug.sethook) ~= "function" then
        return false, "run_lua requires debug.sethook so execution can be bounded"
    end

    local executed = 0
    local function instruction_guard()
        executed = executed + config.lua_hook_interval
        if executed > config.lua_instruction_limit then
            error("Lua instruction limit exceeded")
        end
    end

    debug.sethook(instruction_guard, "", config.lua_hook_interval)
    local ok, result = pcall(func)
    debug.sethook()

    if not ok then return false, "Runtime error: " .. tostring(result) end
    return true, { result = sanitize(result) }
end

function mcp_bridge.shutdown()
    for i = #clients, 1, -1 do close_client(i) end
    if server then
        server:close()
        server = nil
        print("MCP Bridge shut down")
    end
end

-- Small dependency-free JSON implementation. It is intentionally scoped to the
-- bridge protocol and rejects trailing garbage.
function json.encode(obj)
    local value_type = type(obj)
    if value_type == "table" then
        local parts = {}
        local is_array = true
        local max_index = 0
        local count = 0
        for key, _ in pairs(obj) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                is_array = false
                break
            end
            count = count + 1
            if key > max_index then max_index = key end
        end
        if is_array and count == max_index and count > 0 then
            for i = 1, max_index do parts[#parts + 1] = json.encode(obj[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for key, value in pairs(obj) do
            parts[#parts + 1] = json.encode(tostring(key)) .. ":" .. json.encode(value)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif value_type == "string" then
        local escaped = obj
            :gsub("\\", "\\\\")
            :gsub('"', '\\"')
            :gsub("\b", "\\b")
            :gsub("\f", "\\f")
            :gsub("\n", "\\n")
            :gsub("\r", "\\r")
            :gsub("\t", "\\t")
        return '"' .. escaped .. '"'
    elseif value_type == "number" then
        if obj ~= obj or obj == math.huge or obj == -math.huge then return "null" end
        return tostring(obj)
    elseif value_type == "boolean" then
        return obj and "true" or "false"
    elseif value_type == "nil" then
        return "null"
    end
    return json.encode("<" .. value_type .. ">")
end

function json.decode(str)
    local pos = 1

    local function skip_whitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    end

    local function decode_string()
        if str:sub(pos, pos) ~= '"' then error("Expected string") end
        pos = pos + 1
        local result = ""
        while pos <= #str do
            local char = str:sub(pos, pos)
            if char == '"' then
                pos = pos + 1
                return result
            elseif char == "\\" then
                pos = pos + 1
                local escape = str:sub(pos, pos)
                local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ["\\"] = "\\", ['"'] = '"', ["/"] = "/" }
                if escape == "u" then
                    error("Unicode escape sequences are not supported by the embedded decoder")
                end
                result = result .. (map[escape] or escape)
                pos = pos + 1
            else
                result = result .. char
                pos = pos + 1
            end
        end
        error("Unterminated string")
    end

    local decode_value
    decode_value = function()
        skip_whitespace()
        local char = str:sub(pos, pos)
        if char == '"' then
            return decode_string()
        elseif char == "{" then
            local object = {}
            pos = pos + 1
            skip_whitespace()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return object end
            while true do
                skip_whitespace()
                local key = decode_string()
                skip_whitespace()
                if str:sub(pos, pos) ~= ":" then error("Expected :") end
                pos = pos + 1
                object[key] = decode_value()
                skip_whitespace()
                char = str:sub(pos, pos)
                if char == "}" then pos = pos + 1; return object end
                if char ~= "," then error("Expected , or }") end
                pos = pos + 1
            end
        elseif char == "[" then
            local array = {}
            pos = pos + 1
            skip_whitespace()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return array end
            while true do
                array[#array + 1] = decode_value()
                skip_whitespace()
                char = str:sub(pos, pos)
                if char == "]" then pos = pos + 1; return array end
                if char ~= "," then error("Expected , or ]") end
                pos = pos + 1
            end
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4; return nil
        end

        local start = pos
        while pos <= #str and str:sub(pos, pos):match("[%d%+%-%.eE]") do pos = pos + 1 end
        if pos > start then
            local number_value = tonumber(str:sub(start, pos - 1))
            if number_value == nil then error("Invalid number") end
            return number_value
        end
        error("Invalid JSON value at position " .. tostring(pos))
    end

    local value = decode_value()
    skip_whitespace()
    if pos <= #str then error("Trailing JSON data") end
    return value
end

mcp_bridge.json = json
return mcp_bridge
