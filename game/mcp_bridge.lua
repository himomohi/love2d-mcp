-- Local development bridge. Original project: Copyright (c) 2025 Shay Arnett, MIT.
-- Game callbacks are trusted code; network clients get only explicit capabilities.
local socket = require("socket")
local json = require("mcp_json")
local M = { json = json }
local defaults = {
    host = "127.0.0.1", port = 12345, max_clients = 4,
    max_request_bytes = 262144, max_response_bytes = 4194304,
    max_string_bytes = 65536, max_serialize_items = 4000, max_serialize_depth = 8,
    requests_per_second = 120, client_idle_seconds = 60, auth_timeout_seconds = 5,
    max_requests_per_frame = 8, max_snapshot_bytes = 262144,
    allow_run_lua = false, allow_restore = false,
    lua_max_code_bytes = 16384, lua_instruction_limit = 200000, lua_hook_interval = 1000,
}
local config, server, clients = {}, nil, {}
local getter, setter, actionHandler, contextProvider, metadataProvider
local snapshotGetter, snapshotSetter, runtime
local actions, snapshots, snapshotOrder, logs = {}, {}, {}, {}
local sequence, globalWindow, globalCount, frameMs = 0, 0, 0, 0
local started, received, rejected = 0, 0, 0
local function now() return socket.gettime() end
local function copy(t) local r = {}; for k, v in next, t do r[k] = v end; return r end
local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function integer(n, lo, hi) return finite(n) and n % 1 == 0 and n >= lo and n <= hi end
local function fail(code, message) error({ code = code, message = message }, 0) end
local function text(v, max) return type(v) == "string" and #v > 0 and #v <= max end
local function redact(s)
    s = tostring(s)
    if config.token then s = s:gsub(config.token:gsub("(%W)", "%%%1"), "[redacted]") end
    if not json.validUTF8(s) then return "[non-UTF8 data]" end
    if #s > 4096 then s = s:sub(1, 4096); while not json.validUTF8(s) do s = s:sub(1, -2) end end
    return s
end
function M.log(level, message)
    if level ~= "debug" and level ~= "info" and level ~= "warn" and level ~= "error" then level = "info" end
    sequence = sequence + 1
    logs[#logs + 1] = { sequence = sequence, time = now(), level = level, message = redact(message) }
    if #logs > 200 then table.remove(logs, 1) end
end
local function sanitize(value, depth, state)
    depth, state = depth or 0, state or { seen = {}, count = 0, bytes = 0 }
    state.count = state.count + 1
    if state.count > (config.max_serialize_items or 4000) then return "<item-limit>" end
    if depth > (config.max_serialize_depth or 8) then return "<depth-limit>" end
    if value == json.null or value == nil then return json.null end
    local t = type(value)
    if t == "boolean" then return value end
    if t == "number" then return finite(value) and value or json.null end
    if t == "string" then
        if not json.validUTF8(value) then return "<non-UTF8>" end
        local maximum = math.min(config.max_string_bytes or 65536, math.max(0, 262144 - state.bytes))
        local result = value:sub(1, maximum)
        while not json.validUTF8(result) do result = result:sub(1, -2) end
        state.bytes = state.bytes + #result
        return #result < #value and (result .. "<truncated>") or result
    end
    if t ~= "table" then return "<" .. t .. ">" end
    if state.seen[value] then return "<cycle>" end
    state.seen[value] = true
    local r = json.isArray(value) and json.array() or {}
    for k, child in next, value do
        if state.count >= (config.max_serialize_items or 4000) then break end
        if (type(k) == "string" and #k <= 256) or integer(k, 1, 1000000) then
            if type(k) == "string" and k:lower():match("token") then r[k] = "<redacted>"
            elseif type(k) == "string" and (k:lower():match("password") or k:lower():match("secret")) then r[k] = "<redacted>"
            else r[k] = sanitize(child, depth + 1, state) end
        end
    end
    -- Mixed or sparse numeric keys must be encoded as JSON object keys.
    local count, max, numeric = 0, 0, true
    for k in next, r do count = count + 1; if type(k) == "number" then max = math.max(max, k) else numeric = false end end
    if not (numeric and max == count) then
        local object = {}; for k, v in next, r do object[tostring(k)] = v end; r = object
    end
    state.seen[value] = nil
    return r
end
local function response(id, ok, value, code)
    local body = { request_id = id or json.null, ok = ok }
    if ok then body.result = value == nil and json.null or value
    else body.code = code or "BRIDGE_ERROR"; body.error = redact(value) end
    local encoded_ok, encoded = pcall(json.encode, body, config.max_response_bytes or 4194304)
    if encoded_ok then return encoded end
    return json.encode({ request_id = id or json.null, ok = false, code = "SERIALIZATION_ERROR", error = "Result is not serializable or exceeds the response limit" })
end
local function equal_token(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a > 256 then return false end
    local mismatch = #a ~= #b
    for i = 1, #b do if a:byte(i) ~= b:byte(i) then mismatch = true end end
    return not mismatch
end
local function setcallback(value) assert(value == nil or type(value) == "function", "Expected function or nil"); return value end
function M.setObjectGetter(f) getter = setcallback(f) end
function M.setObjectSetter(f) setter = setcallback(f) end
function M.setActionHandler(f) actionHandler = setcallback(f) end
function M.setLuaContextProvider(f) contextProvider = setcallback(f) end
function M.setGameMetadataProvider(f) metadataProvider = setcallback(f) end
function M.setSnapshotHandlers(read, restore) snapshotGetter, snapshotSetter = setcallback(read), setcallback(restore) end
function M.setRuntime(adapter) assert(type(adapter) == "table", "Expected runtime adapter"); runtime = adapter end

-- Declarative, scalar action parameters are validated before a game callback runs.
function M.registerAction(name, spec, handler)
    assert(text(name, 128) and name:match("^[%w_.-]+$"), "Invalid action name")
    assert(type(spec) == "table" and type(handler) == "function", "Action needs specification and handler")
    assert(type(spec.description) == "string" and #spec.description <= 1024, "Action needs a bounded description")
    local params = spec.params or {}
    for key, rule in pairs(params) do
        assert(text(key, 128) and type(rule) == "table", "Invalid action parameter")
        assert(rule.type == "number" or rule.type == "string" or rule.type == "boolean", "Unsupported action parameter type")
        if rule.min ~= nil then assert(finite(rule.min), "Invalid minimum") end
        if rule.max ~= nil then assert(finite(rule.max), "Invalid maximum") end
    end
    actions[name] = { spec = json.decode(json.encode({ description = spec.description, params = params }, 16384)), handler = handler }
end
function M.unregisterAction(name) actions[name] = nil end
local function actionList()
    local list = json.array()
    for name, a in pairs(actions) do list[#list + 1] = { name = name, description = a.spec.description, params = a.spec.params } end
    table.sort(list, function(a, b) return a.name < b.name end)
    return { actions = list, legacy_handler = actionHandler ~= nil }
end
local function objectTable()
    if not getter then fail("NOT_CONFIGURED", "Register an object getter first") end
    local objects = getter()
    if type(objects) ~= "table" then fail("GAME_CALLBACK_ERROR", "Object getter must return a table") end
    return objects
end
local function lookup(objects, id)
    if not text(id, 256) then fail("INVALID_ARGUMENT", "Invalid object id") end
    local obj = rawget(objects, id)
    local n = tonumber(id)
    if obj == nil and n and tostring(n) == id then obj = rawget(objects, n) end
    if obj == nil then fail("NOT_FOUND", "Object not found: " .. id) end
    return obj
end
function M.listObjects(p)
    p = p or {}
    local offset, limit = p.offset or 0, p.limit or 100
    if not integer(offset, 0, 1000000) or not integer(limit, 1, 500) then fail("INVALID_ARGUMENT", "Invalid pagination") end
    if p.type ~= nil and not text(p.type, 128) then fail("INVALID_ARGUMENT", "Invalid object type filter") end
    if p.query ~= nil and (type(p.query) ~= "string" or #p.query > 256) then fail("INVALID_ARGUMENT", "Invalid search query") end
    local objects, ids, scanned = objectTable(), {}, 0
    for id, obj in next, objects do
        scanned = scanned + 1
        if scanned > 20000 then fail("SCENE_TOO_LARGE", "Expose at most 20000 objects per scene getter") end
        if (type(id) == "string" or type(id) == "number") and type(obj) == "table" then
            local label = tostring(id)
            if (not p.type or rawget(obj, "type") == p.type) and (not p.query or label:lower():find(p.query:lower(), 1, true)) then ids[#ids + 1] = label end
        end
    end
    table.sort(ids)
    local result = json.array()
    for i = offset + 1, math.min(#ids, offset + limit) do
        local obj = lookup(objects, ids[i])
        result[#result + 1] = { id = ids[i], type = rawget(obj, "type"), x = rawget(obj, "x"), y = rawget(obj, "y"), active = rawget(obj, "active") }
    end
    return { objects = sanitize(result), total = #ids, offset = offset, next_offset = offset + limit < #ids and offset + limit or json.null }
end
function M.getObject(id) return { object = sanitize(lookup(objectTable(), id)) } end
function M.getStatus()
    return {
        bridge_version = "2.1.0", protocol_version = 2, host = config.host, port = config.port,
        authenticated = true, run_lua_enabled = config.allow_run_lua == true,
        mutation_enabled = setter ~= nil, actions_enabled = actionHandler ~= nil or next(actions) ~= nil,
        restore_enabled = config.allow_restore == true and snapshotSetter ~= nil,
        connected_clients = #clients, metadata = sanitize(metadataProvider and metadataProvider() or {}),
        runtime = runtime and sanitize(runtime.status()) or { installed = false },
    }
end
local function invoke(name, params)
    if not text(name, 128) or type(params) ~= "table" or params == json.null or json.isArray(params) then fail("INVALID_ARGUMENT", "Action requires a name and object params") end
    local a = actions[name]
    local value
    if a then
        for k in next, params do if not a.spec.params[k] then fail("INVALID_ARGUMENT", "Unknown action parameter: " .. tostring(k)) end end
        for k, rule in pairs(a.spec.params) do
            local v = params[k]
            if v == nil then if rule.required then fail("INVALID_ARGUMENT", "Missing action parameter: " .. k) end
            elseif type(v) ~= rule.type then fail("INVALID_ARGUMENT", "Wrong action parameter type: " .. k)
            elseif rule.type == "number" and (not finite(v) or (rule.min and v < rule.min) or (rule.max and v > rule.max)) then fail("INVALID_ARGUMENT", "Action parameter outside range: " .. k)
            elseif rule.type == "string" and #v > (rule.maxLength or 1024) then fail("INVALID_ARGUMENT", "Action string too long: " .. k) end
            if v ~= nil and rule.enum then
                local found = false; for _, allowed in ipairs(rule.enum) do if v == allowed then found = true end end
                if not found then fail("INVALID_ARGUMENT", "Value not in action enum: " .. k) end
            end
        end
        value = a.handler(params)
    elseif actionHandler then value = actionHandler(name, params)
    else fail("ACTION_DENIED", "Unknown action; call list_actions first") end
    if value == false then fail("ACTION_DENIED", "Game rejected the action") end
    return sanitize(value == nil and { invoked = true } or value)
end
local function snapshotData()
    -- Explicit provider must return JSON-only data; no userdata/functions/cycles.
    return json.decode(json.encode(snapshotGetter and snapshotGetter() or objectTable(), config.max_snapshot_bytes), config.max_snapshot_bytes)
end
local function diff(before, after)
    local changes, truncated, visited = json.array(), false, 0
    local function walk(a, b, path, depth)
        visited = visited + 1
        if #changes >= 100 or depth > 16 or visited > 5000 then truncated = true; return end
        if type(a) == "table" and type(b) == "table" and a ~= json.null and b ~= json.null and json.isArray(a) == json.isArray(b) then
            local keys, seen = {}, {}
            for k in next, a do keys[#keys + 1] = k; seen[k] = true end
            for k in next, b do if not seen[k] then keys[#keys + 1] = k end end
            table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
            for _, k in ipairs(keys) do
                walk(a[k], b[k], path .. "/" .. tostring(k):gsub("~", "~0"):gsub("/", "~1"), depth + 1)
                if truncated then break end
            end
        elseif a ~= b then
            changes[#changes + 1] = { path = path, kind = a == nil and "added" or (b == nil and "removed" or "changed"), before = sanitize(a), after = sanitize(b) }
        end
    end
    walk(before, after, "", 0)
    return { changes = changes, truncated = truncated }
end
function M.runLua(code)
    if not config.allow_run_lua then return false, "run_lua is disabled" end
    if not text(code, config.lua_max_code_bytes) or code:byte(1) == 27 then return false, "Only bounded Lua source text is allowed" end
    if not debug or not debug.sethook or not debug.gethook then return false, "Execution hook unavailable" end
    local context = sanitize(contextProvider and contextProvider() or {})
    local env = { context = context, pairs = pairs, ipairs = ipairs, next = next, type = type, tonumber = tonumber, tostring = tostring }
    env.math = { abs = math.abs, min = math.min, max = math.max, floor = math.floor, ceil = math.ceil, sqrt = math.sqrt }
    env.table = { insert = table.insert, remove = table.remove, sort = table.sort, concat = table.concat }
    local fn, err
    if loadstring then fn, err = loadstring(code, "mcp-query"); if fn then setfenv(fn, env) end
    else fn, err = load(code, "mcp-query", "t", env) end
    if not fn then return false, redact(err) end
    if jit and jit.off then jit.off(fn, true) end
    local old, mask, count = debug.gethook()
    local spent = 0
    local function guard() spent = spent + config.lua_hook_interval; if spent >= config.lua_instruction_limit then debug.sethook(); error("Lua instruction budget exceeded", 0) end end
    debug.sethook(guard, "", config.lua_hook_interval)
    local ok, result = pcall(fn)
    debug.sethook(old, mask, count)
    if not ok then return false, redact(result) end
    return true, { result = sanitize(result) }
end
local execute
execute = function(c)
    local name = c.command
    if name == "ping" then return { pong = true, time = now() }
    elseif name == "get_status" then return M.getStatus()
    elseif name == "list_objects" then return M.listObjects(c)
    elseif name == "get_object" then return M.getObject(c.id)
    elseif name == "list_actions" then return actionList()
    elseif name == "set_object_property" then
        if not setter then fail("MUTATION_DENIED", "Register an allowlisted setter first") end
        if not text(c.id, 256) or not text(c.property, 128) or c.value == nil then fail("INVALID_ARGUMENT", "id, property and value are required") end
        local v = c.value
        if v ~= json.null and type(v) ~= "string" and type(v) ~= "boolean" and not finite(v) then fail("INVALID_ARGUMENT", "Only scalar values are accepted") end
        if type(v) == "string" and #v > config.max_string_bytes then fail("INVALID_ARGUMENT", "Property value too long") end
        if v == json.null then v = nil end
        local result = setter(c.id, c.property, v)
        if result == false then fail("MUTATION_DENIED", "Game rejected property update") end
        return sanitize(result == nil and { updated = true } or result)
    elseif name == "invoke_action" then return invoke(c.action, c.params or {})
    elseif name == "run_lua" then local ok, value = M.runLua(c.code); if not ok then fail("LUA_DENIED", value) end; return value
    elseif name == "get_logs" then
        local after, limit = c.after or 0, c.limit or 50
        if not integer(after, 0, 9007199254740991) or not integer(limit, 1, 200) then fail("INVALID_ARGUMENT", "Invalid log cursor or limit") end
        local result = json.array()
        for _, entry in ipairs(logs) do if entry.sequence > after and #result < limit then result[#result + 1] = entry end end
        return { entries = result, next_cursor = #result > 0 and result[#result].sequence or after, dropped = #logs > 0 and after < logs[1].sequence - 1 }
    elseif name == "get_metrics" then
        local metrics = { uptime = now() - started, requests = received, rejected = rejected, bridge_update_ms = frameMs, lua_memory_kb = collectgarbage("count") }
        if love and love.timer then metrics.fps = love.timer.getFPS() end
        metrics.runtime = runtime and sanitize(runtime.status()) or { installed = false }
        return metrics
    elseif name == "capture_screenshot" or name == "poll_screenshot" or name == "send_input" or name == "control_game" then
        if not runtime then fail("NOT_CONFIGURED", "Install the optional mcp_runtime adapter in your game") end
        return runtime.dispatch(name, c)
    elseif name == "save_snapshot" then
        if not text(c.name, 64) then fail("INVALID_ARGUMENT", "Snapshot name required (1–64 bytes)") end
        local data = snapshotData()
        if not snapshots[c.name] then snapshotOrder[#snapshotOrder + 1] = c.name end
        snapshots[c.name] = data
        if #snapshotOrder > 8 then snapshots[table.remove(snapshotOrder, 1)] = nil end
        return { saved = c.name, count = #snapshotOrder, restore_enabled = config.allow_restore and snapshotSetter ~= nil }
    elseif name == "diff_snapshot" or name == "restore_snapshot" then
        if not text(c.name, 64) or not snapshots[c.name] then fail("NOT_FOUND", "Snapshot not found in this game process") end
        if name == "diff_snapshot" then return diff(snapshots[c.name], snapshotData()) end
        if not config.allow_restore or not snapshotSetter then fail("RESTORE_DENIED", "Restore requires allow_restore and a game-defined restore callback") end
        local result = snapshotSetter(json.decode(json.encode(snapshots[c.name], config.max_snapshot_bytes), config.max_snapshot_bytes))
        if result == false then fail("RESTORE_DENIED", "Game rejected the snapshot") end
        return { restored = c.name }
    elseif name == "batch" then
        if not json.isArray(c.commands) or #c.commands < 1 or #c.commands > 16 then fail("INVALID_ARGUMENT", "Batch requires 1–16 commands") end
        if c.stop_on_error ~= nil and type(c.stop_on_error) ~= "boolean" then fail("INVALID_ARGUMENT", "stop_on_error must be boolean") end
        local allowed = { ping=true, get_status=true, list_objects=true, get_object=true, list_actions=true, set_object_property=true, invoke_action=true, get_metrics=true, get_logs=true }
        for _, item in ipairs(c.commands) do
            if type(item) ~= "table" or not allowed[item.command] or item.token or item.request_id then fail("INVALID_ARGUMENT", "Unsupported batch command") end
        end
        local results = json.array()
        for i, item in ipairs(c.commands) do
            local ok, value = pcall(execute, item)
            results[#results + 1] = { index = i, ok = ok, result = ok and value or json.null, error = not ok and redact(type(value) == "table" and value.message or value) or json.null }
            if not ok and c.stop_on_error ~= false then break end
        end
        return { results = results, completed = #results, atomic = false }
    end
    fail("UNKNOWN_COMMAND", "Unknown command")
end
function M.handleCommand(line, state)
    local ok, c = pcall(json.decode, line, config.max_request_bytes)
    if not ok or type(c) ~= "table" or c == json.null or json.isArray(c) then return response(nil, false, "Malformed JSON request", "BAD_JSON") end
    if not text(c.request_id, 128) then return response(nil, false, "Invalid request_id", "INVALID_REQUEST_ID") end
    if not server then return response(c.request_id, false, "Bridge is not initialized", "NOT_INITIALIZED") end
    if not equal_token(c.token, config.token) then
        if state then state.close_after_write = true end
        rejected = rejected + 1; return response(c.request_id, false, "Authentication failed", "UNAUTHORIZED")
    end
    if state then state.authenticated = true end
    local current = now()
    if current - globalWindow >= 1 or current < globalWindow then globalWindow, globalCount = current, 0 end
    local cost = c.command == "batch" and type(c.commands) == "table" and math.min(#c.commands, 16) or 1
    globalCount = globalCount + math.max(1, cost)
    if globalCount > config.requests_per_second then rejected = rejected + 1; return response(c.request_id, false, "Global request rate exceeded", "RATE_LIMITED") end
    received = received + 1
    local success, value = pcall(execute, c)
    if success then return response(c.request_id, true, value) end
    rejected = rejected + 1
    local code = type(value) == "table" and value.code or "GAME_CALLBACK_ERROR"
    local message = type(value) == "table" and value.message or "Game callback failed; check local logs"
    M.log("error", code .. ": " .. redact(type(value) == "table" and message or value))
    return response(c.request_id, false, message, code)
end
local function close_client(i)
    local state = clients[i]; if not state then return end
    pcall(function() state.socket:close() end); table.remove(clients, i)
    local active = false; for _, c in ipairs(clients) do if c.authenticated then active = true end end
    if state.authenticated and not active and runtime then pcall(runtime.resetInput) end
end
function M.init(options)
    if server then return true end
    options = type(options) == "number" and { port = options } or (options or {})
    assert(type(options) == "table", "Bridge options must be a table")
    local candidate = copy(defaults)
    for k, v in pairs(options) do assert(defaults[k] ~= nil or k == "token", "Unknown bridge option: " .. tostring(k)); candidate[k] = v end
    candidate.token = options.token or os.getenv("LOVE2D_MCP_TOKEN")
    if candidate.host == "localhost" then candidate.host = "127.0.0.1" end
    assert(candidate.host == "127.0.0.1" or candidate.host == "::1", "Loopback host required")
    local token = candidate.token
    assert(type(token) == "string" and #token >= 32 and #token <= 256 and token:match("^[!-~]+$") and not token:lower():find("replace-with", 1, true), "A random 32–256 character ASCII token is required")
    for k, value in pairs(defaults) do
        if type(value) == "number" then assert(integer(candidate[k], 1, math.max(value * 4, 65535)), "Invalid integer option: " .. k)
        elseif type(value) == "boolean" then assert(type(candidate[k]) == "boolean", "Invalid boolean option: " .. k) end
    end
    assert(candidate.port <= 65535 and candidate.max_clients <= 16 and candidate.max_requests_per_frame <= 32, "Bridge limit out of range")
    assert(candidate.max_serialize_depth <= 16 and candidate.max_serialize_items <= 10000, "Serialization limit out of range")
    assert(candidate.max_response_bytes >= 1024 and candidate.max_request_bytes >= 1024, "Byte limits too small")
    local tcp = candidate.host == "::1" and socket.tcp6 or socket.tcp
    assert(tcp, "IPv6 sockets unavailable in this LuaSocket build")
    local s = assert(tcp())
    local success, err = pcall(function()
        s:setoption("reuseaddr", true); assert(s:bind(candidate.host, candidate.port)); assert(s:listen(candidate.max_clients)); s:settimeout(0)
    end)
    if not success then s:close(); error(err, 0) end
    config, server = candidate, s
    started, globalWindow, globalCount, received, rejected = now(), now(), 0, 0, 0
    M.log("info", "Bridge ready on " .. config.host .. ":" .. config.port)
    return true
end
function M.update()
    if not server then return end
    local begin = now()
    local accepted = server:accept()
    if accepted then
        if #clients >= config.max_clients then accepted:close()
        else accepted:settimeout(0); clients[#clients + 1] = { socket = accepted, buffer = "", output = "", sent = 0, since = now(), last = now() } end
    end
    local budget = config.max_requests_per_frame
    for i = #clients, 1, -1 do
        local c = clients[i]
        if now() - c.last > config.client_idle_seconds or (not c.authenticated and now() - c.since > config.auth_timeout_seconds) then close_client(i)
        else
            if #c.output == 0 and not c.close_after_write then
                local data, err, partial = c.socket:receive(8192)
                local chunk = data or partial
                if chunk and #chunk > 0 then c.buffer = c.buffer .. chunk; c.last = now() end
                if err == "closed" then c.eof = true end
                local endline = c.buffer:find("\n", 1, true)
                if #c.buffer > config.max_request_bytes * 2 or (endline and endline - 1 > config.max_request_bytes) or (not endline and #c.buffer > config.max_request_bytes) then
                    c.close_after_write = true; c.output = response(nil, false, "Request exceeded size limit", "REQUEST_TOO_LARGE") .. "\n"
                elseif endline and budget > 0 then
                    local line = c.buffer:sub(1, endline - 1); c.buffer = c.buffer:sub(endline + 1); budget = budget - 1
                    c.output = M.handleCommand(line, c) .. "\n"; c.sent = 0
                end
            end
            if #c.output > 0 then
                -- LuaSocket returns the absolute last byte index, even on partial sends.
                local last, err, partial = c.socket:send(c.output, c.sent + 1, math.min(#c.output, c.sent + 65536))
                c.sent = last or partial or c.sent
                if err and err ~= "timeout" then c.close_after_write = true; c.output = "" end
                if c.sent >= #c.output then c.output, c.sent = "", 0 end
            end
            if (#c.output == 0 and c.close_after_write) or (#c.output == 0 and c.eof and not c.buffer:find("\n", 1, true)) then close_client(i) end
        end
    end
    frameMs = (now() - begin) * 1000
end
function M.shutdown()
    for i = #clients, 1, -1 do close_client(i) end
    if server then server:close(); server = nil end
    if runtime then pcall(runtime.resetInput) end
    config, snapshots, snapshotOrder, logs = {}, {}, {}, {}
end
return M
