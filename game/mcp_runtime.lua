-- Optional LÖVE-only adapter: virtual input, fixed-step control, in-memory screenshots.
-- Never generates operating-system input or reads the desktop/files/clipboard.
local R = {}
function R.attach(bridge, options)
    options = options or {}
    local keys, buttons = {}, {}
    local mouseX, mouseY = 0, 0
    local paused, remaining, fixedDt, stepped = false, 0, 1 / 60, 0
    local ticket, capture, nextCapture, lastCapture = nil, nil, 0, -math.huge
    local function failure(code, message) error({ code = code, message = message }, 0) end
    local function number(n, lo, hi) return type(n) == "number" and n == n and n >= lo and n <= hi end
    local function callback(name, ...)
        if love and type(love[name]) == "function" then love[name](...) end
    end
    local adapter = {}
    function adapter.resetInput()
        local oldKeys, oldButtons = keys, buttons
        keys, buttons = {}, {}
        for key in pairs(oldKeys) do pcall(callback, "keyreleased", key, key) end
        for button in pairs(oldButtons) do pcall(callback, "mousereleased", mouseX, mouseY, button, false, 1) end
    end
    function adapter.status()
        return { installed = true, input_enabled = options.input == true, control_enabled = options.control == true,
            screenshots_enabled = options.screenshots == true, paused = paused, steps_remaining = remaining, stepped_frames = stepped }
    end
    function adapter.isDown(key) return keys[key] == true or (love.keyboard and love.keyboard.isDown(key)) or false end
    function adapter.isMouseDown(button) return buttons[button] == true or (love.mouse and love.mouse.isDown(button)) or false end
    function adapter.mousePosition() return mouseX, mouseY end
    function adapter.advance(dt, update)
        if remaining > 0 then
            -- At most four simulation ticks per render frame: the MCP loop keeps running.
            for _ = 1, math.min(remaining, 4) do
                local ok, err = pcall(update, fixedDt)
                if not ok then
                    remaining = 0; paused = true; bridge.log("error", tostring(err)); error(err, 0)
                end
                remaining, stepped = remaining - 1, stepped + 1
            end
        elseif not paused then update(dt) end
    end
    function adapter.dispatch(command, p)
        if command == "control_game" then
            if options.control ~= true then failure("CAPABILITY_DISABLED", "Frame control is not enabled by the game") end
            if p.operation == "pause" then paused, remaining = true, 0
            elseif p.operation == "resume" then paused, remaining = false, 0
            elseif p.operation == "step" then
                if not paused then failure("INVALID_STATE", "Pause before stepping") end
                if remaining > 0 then failure("BUSY", "A frame-step request is still running") end
                local frames, dt = p.frames or 1, p.dt or 1 / 60
                if not number(frames, 1, 120) or frames % 1 ~= 0 or not number(dt, 0.001, 0.05) then failure("INVALID_ARGUMENT", "Invalid frame count or fixed delta") end
                remaining, fixedDt = frames, dt
            else failure("INVALID_ARGUMENT", "operation must be pause, resume, or step") end
            return adapter.status()
        elseif command == "send_input" then
            if options.input ~= true then failure("CAPABILITY_DISABLED", "Virtual input is not enabled by the game") end
            local kind = p.event
            if kind == "reset" then adapter.resetInput()
            elseif kind == "key_down" or kind == "key_up" then
                if type(p.key) ~= "string" or #p.key > 32 or not p.key:match("^[%w_]+$") then failure("INVALID_ARGUMENT", "Invalid key name") end
                if kind == "key_down" then
                    if not keys[p.key] then keys[p.key] = true; callback("keypressed", p.key, p.key, false) end
                else keys[p.key] = nil; callback("keyreleased", p.key, p.key) end
            elseif kind == "mouse_move" then
                if not number(p.x, -100000, 100000) or not number(p.y, -100000, 100000) then failure("INVALID_ARGUMENT", "Invalid mouse position") end
                local dx, dy = p.x - mouseX, p.y - mouseY
                mouseX, mouseY = p.x, p.y; callback("mousemoved", mouseX, mouseY, dx, dy, false)
            elseif kind == "mouse_down" or kind == "mouse_up" then
                if not number(p.button, 1, 5) or p.button % 1 ~= 0 then failure("INVALID_ARGUMENT", "Invalid mouse button") end
                if kind == "mouse_down" then
                    if not buttons[p.button] then buttons[p.button] = true; callback("mousepressed", mouseX, mouseY, p.button, false, 1) end
                else buttons[p.button] = nil; callback("mousereleased", mouseX, mouseY, p.button, false, 1) end
            elseif kind == "text" then
                if type(p.text) ~= "string" or #p.text > 1024 then failure("INVALID_ARGUMENT", "Text must be at most 1024 bytes") end
                callback("textinput", p.text)
            else failure("INVALID_ARGUMENT", "Unknown virtual input event") end
            return { applied = true, event = kind, scope = "game-only" }
        elseif command == "capture_screenshot" then
            if options.screenshots ~= true then failure("CAPABILITY_DISABLED", "Screenshots are not enabled by the game") end
            if not love.graphics or not love.graphics.isActive() or not love.data then failure("GRAPHICS_UNAVAILABLE", "Game graphics are not active") end
            local current = love.timer.getTime()
            if ticket and current - lastCapture > 10 then ticket, capture = nil, nil end
            if ticket and capture == nil then failure("BUSY", "A screenshot is already pending") end
            if current - lastCapture < 0.5 then failure("RATE_LIMITED", "Screenshots are limited to two per second") end
            local w, h = love.graphics.getPixelDimensions()
            if w * h > 4194304 then failure("SCREENSHOT_TOO_LARGE", "Reduce the game window to at most 4 megapixels") end
            nextCapture = nextCapture + 1; ticket = tostring(nextCapture); capture = nil; lastCapture = current
            local requested = ticket
            love.graphics.captureScreenshot(function(image)
                local png
                local ok, result = pcall(function()
                    png = image:encode("png")
                    if png:getSize() > 2097152 then failure("SCREENSHOT_TOO_LARGE", "PNG exceeds 2 MiB; reduce the game window") end
                    return { status = "ready", mimeType = "image/png", data = love.data.encode("string", "base64", png), width = image:getWidth(), height = image:getHeight() }
                end)
                if png then png:release() end
                image:release()
                if ticket == requested then capture = ok and result or { status = "failed", error = type(result) == "table" and result.message or "Capture failed" } end
            end)
            return { status = "pending", ticket = ticket }
        elseif command == "poll_screenshot" then
            if type(p.ticket) ~= "string" or p.ticket ~= ticket or love.timer.getTime() - lastCapture > 10 then failure("NOT_FOUND", "Screenshot ticket expired") end
            local result = capture or { status = "pending", ticket = ticket }
            if capture then ticket, capture = nil, nil end -- Release base64 memory after one retrieval.
            return result
        end
        failure("UNKNOWN_COMMAND", "Unsupported runtime operation")
    end
    bridge.setRuntime(adapter)
    return adapter
end
return R
