-- Bounded JSON codec for Lua 5.1/LuaJIT and Lua 5.4. No eval or global state.
local J = {}
J.null = setmetatable({}, { __tostring = function() return "null" end })
local array_mt = {}
function J.array(t) return setmetatable(t or {}, array_mt) end
function J.isArray(t) return type(t) == "table" and getmetatable(t) == array_mt end
local function finite(n) return n == n and n ~= math.huge and n ~= -math.huge end
local function utf8(cp)
    if cp < 128 then return string.char(cp) end
    if cp < 2048 then return string.char(192 + math.floor(cp / 64), 128 + cp % 64) end
    if cp < 65536 then return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64) end
    return string.char(240 + math.floor(cp / 262144), 128 + math.floor(cp / 4096) % 64, 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
end
local function valid_utf8(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local n, cp, minimum = 1, b, 0
        if b >= 194 and b <= 223 then n, cp, minimum = 2, b - 192, 128
        elseif b >= 224 and b <= 239 then n, cp, minimum = 3, b - 224, 2048
        elseif b >= 240 and b <= 244 then n, cp, minimum = 4, b - 240, 65536
        elseif b >= 128 then return false end
        for k = 1, n - 1 do
            local c = s:byte(i + k)
            if not c or c < 128 or c > 191 then return false end
            cp = cp * 64 + c - 128
        end
        if cp < minimum or cp > 1114111 or (cp >= 55296 and cp <= 57343) then return false end
        i = i + n
    end
    return true
end
J.validUTF8 = valid_utf8
function J.encode(value, max_bytes)
    local parts, seen, bytes, nodes = {}, {}, 0, 0
    local function emit(s)
        bytes = bytes + #s
        if bytes > (max_bytes or 4 * 1024 * 1024) then error("JSON byte limit exceeded", 0) end
        parts[#parts + 1] = s
    end
    local function quote(s)
        if not valid_utf8(s) then error("Invalid UTF-8 string", 0) end
        return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
            if c == '"' then return '\\"' end
            if c == '\\' then return '\\\\' end
            return string.format('\\u%04x', c:byte())
        end) .. '"'
    end
    local encode
    encode = function(v, depth)
        nodes = nodes + 1
        if depth > 32 or nodes > 20000 then error("JSON complexity limit exceeded", 0) end
        if v == J.null or v == nil then emit("null")
        elseif type(v) == "boolean" then emit(v and "true" or "false")
        elseif type(v) == "number" then
            if not finite(v) then error("Non-finite number", 0) end
            emit(string.format("%.17g", v))
        elseif type(v) == "string" then emit(quote(v))
        elseif type(v) == "table" then
            if seen[v] then error("Cyclic JSON data", 0) end
            seen[v] = true
            local count, maximum, is_array = 0, 0, true
            for k in next, v do
                count = count + 1
                if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then is_array = false
                else maximum = math.max(maximum, k) end
            end
            is_array = (J.isArray(v) or count > 0) and is_array and count == maximum
            if J.isArray(v) and not is_array then error("Invalid array shape", 0) end
            emit(is_array and "[" or "{")
            if is_array then
                for i = 1, maximum do if i > 1 then emit(",") end; encode(v[i], depth + 1) end
            else
                local keys = {}
                for k in next, v do
                    if type(k) ~= "string" then error("JSON object keys must be strings", 0) end
                    keys[#keys + 1] = k
                end
                table.sort(keys)
                for i, k in ipairs(keys) do
                    if i > 1 then emit(",") end
                    emit(quote(k)); emit(":"); encode(v[k], depth + 1)
                end
            end
            emit(is_array and "]" or "}"); seen[v] = nil
        else error("Unsupported JSON value: " .. type(v), 0) end
    end
    encode(value, 0)
    return table.concat(parts)
end
function J.decode(s, max_bytes)
    if type(s) ~= "string" or #s > (max_bytes or 256 * 1024) then error("JSON byte limit exceeded", 0) end
    local pos, nodes = 1, 0
    local function bad(message) error(message .. " at byte " .. pos, 0) end
    local function ws() while s:sub(pos, pos):match("[ \t\r\n]") do pos = pos + 1 end end
    local function hex4()
        local h = s:sub(pos, pos + 3)
        if #h ~= 4 or not h:match("^%x%x%x%x$") then bad("Invalid Unicode escape") end
        pos = pos + 4; return tonumber(h, 16)
    end
    local function str()
        if s:sub(pos, pos) ~= '"' then bad("Expected string") end
        pos = pos + 1
        local parts, start = {}, pos
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == '"' then
                parts[#parts + 1] = s:sub(start, pos - 1); pos = pos + 1
                local result = table.concat(parts)
                if not valid_utf8(result) then bad("Invalid UTF-8") end
                return result
            elseif c == "\\" then
                parts[#parts + 1] = s:sub(start, pos - 1); pos = pos + 1
                local e = s:sub(pos, pos); pos = pos + 1
                local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if e == 'u' then
                    local cp = hex4()
                    if cp >= 55296 and cp <= 56319 then
                        if s:sub(pos, pos + 1) ~= '\\u' then bad("Missing low surrogate") end
                        pos = pos + 2; local low = hex4()
                        if low < 56320 or low > 57343 then bad("Invalid low surrogate") end
                        cp = 65536 + (cp - 55296) * 1024 + low - 56320
                    elseif cp >= 56320 and cp <= 57343 then bad("Unexpected low surrogate") end
                    parts[#parts + 1] = utf8(cp)
                elseif escapes[e] then parts[#parts + 1] = escapes[e]
                else bad("Invalid escape") end
                start = pos
            elseif c:byte() < 32 then bad("Unescaped control character")
            else pos = pos + 1 end
        end
        bad("Unterminated string")
    end
    local value
    value = function(depth)
        nodes = nodes + 1
        if depth > 32 or nodes > 20000 then bad("JSON complexity limit exceeded") end
        ws(); local c = s:sub(pos, pos)
        if c == '"' then return str() end
        if c == '{' or c == '[' then
            pos = pos + 1; ws()
            local arr = c == '['; local result = arr and J.array() or {}; local close = arr and ']' or '}'
            if s:sub(pos, pos) == close then pos = pos + 1; return result end
            while true do
                ws(); local key
                if arr then key = #result + 1 else
                    key = str(); ws()
                    if result[key] ~= nil then bad("Duplicate object key") end
                    if s:sub(pos, pos) ~= ':' then bad("Expected colon") end
                    pos = pos + 1
                end
                result[key] = value(depth + 1); ws()
                local sep = s:sub(pos, pos); pos = pos + 1
                if sep == close then return result end
                if sep ~= ',' then bad("Expected separator") end
            end
        end
        for literal, result in pairs({ ['true'] = true, ['false'] = false, ['null'] = J.null }) do
            if s:sub(pos, pos + #literal - 1) == literal then pos = pos + #literal; return result end
        end
        local start = pos
        if c == '-' then pos = pos + 1 end
        local int = s:sub(pos, pos)
        if int == '0' then pos = pos + 1
        elseif int:match('[1-9]') then
            repeat pos = pos + 1 until not s:sub(pos, pos):match('%d')
        else bad("Invalid value") end
        if s:sub(pos, pos) == '.' then
            pos = pos + 1
            if not s:sub(pos, pos):match('%d') then bad("Invalid fraction") end
            repeat pos = pos + 1 until not s:sub(pos, pos):match('%d')
        end
        if s:sub(pos, pos):match('[eE]') then
            pos = pos + 1
            if s:sub(pos, pos):match('[+-]') then pos = pos + 1 end
            if not s:sub(pos, pos):match('%d') then bad("Invalid exponent") end
            repeat pos = pos + 1 until not s:sub(pos, pos):match('%d')
        end
        local n = tonumber(s:sub(start, pos - 1))
        if not n or not finite(n) then bad("Non-finite number") end
        return n
    end
    local result = value(0); ws()
    if pos <= #s then bad("Trailing JSON data") end
    return result
end
return J
