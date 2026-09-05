local mcp = require("mcp_bridge")

local objects = {
    player = { id = "player", type = "player", x = 320, y = 240, health = 100, speed = 180 },
    enemy_1 = { id = "enemy_1", type = "enemy", x = 500, y = 240, health = 40 },
}

local MUTABLE_PROPERTIES = { x = true, y = true, health = true }
local ACTIONS = { reset_scene = true, damage_player = true }

function love.load()
    mcp.setObjectGetter(function() return objects end)

    mcp.setObjectSetter(function(id, property, value)
        local object = objects[id]
        if not object then return false end
        if not MUTABLE_PROPERTIES[property] then return false end
        object[property] = value
        return { updated = true, id = id, property = property, value = value }
    end)

    mcp.setActionHandler(function(action, params)
        if not ACTIONS[action] then return false end
        if action == "reset_scene" then
            objects.player.x, objects.player.y, objects.player.health = 320, 240, 100
            return { reset = true }
        elseif action == "damage_player" then
            local amount = tonumber(params.amount) or 1
            objects.player.health = math.max(0, objects.player.health - math.min(amount, 25))
            return { health = objects.player.health }
        end
    end)

    mcp.setGameMetadataProvider(function()
        return { title = "love2d-mcp secure example", object_count = 2 }
    end)

    -- run_lua remains OFF. To enable it deliberately, pass allow_run_lua = true
    -- and expose only a narrow context through setLuaContextProvider().
    mcp.init({ port = 12345 })
end

function love.update(dt)
    mcp.update()
end

function love.draw()
    love.graphics.print("Secure love2d-mcp bridge is running", 20, 20)
    love.graphics.print("Player health: " .. tostring(objects.player.health), 20, 45)
    love.graphics.circle("fill", objects.player.x, objects.player.y, 16)
    love.graphics.circle("line", objects.enemy_1.x, objects.enemy_1.y, 16)
end

function love.quit()
    mcp.shutdown()
end
