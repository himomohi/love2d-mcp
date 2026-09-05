local mcp = require('mcp_bridge')
local runtime = require('mcp_runtime').attach(mcp, { input = true, control = true, screenshots = true })
local initial = { player = { id='player',type='player',x=320,y=300,health=100,speed=180 }, enemy_1 = { id='enemy_1',type='enemy',x=670,y=300,health=40 } }
local objects = mcp.json.decode(mcp.json.encode(initial))
local function validObject(o)
    return type(o)=='table' and type(o.x)=='number' and o.x>=20 and o.x<=940 and type(o.y)=='number' and o.y>=130 and o.y<=520 and type(o.health)=='number' and o.health>=0 and o.health<=100
end
function love.load()
    mcp.setObjectGetter(function() return objects end)
    mcp.setObjectSetter(function(id, property, value)
        local o=objects[id]
        if not o or type(value)~='number' then return false end
        local ranges={x={20,940},y={130,520},health={0,100}}
        local range=ranges[property]
        if not range or value<range[1] or value>range[2] then return false end
        o[property]=value; mcp.log('info','Changed '..id..'.'..property)
        return {updated=true,id=id,property=property,value=value}
    end)
    mcp.registerAction('damage_player',{description='Apply 0–25 test damage to the player.',params={amount={type='number',min=0,max=25,required=true}}},function(p)
        objects.player.health=math.max(0,objects.player.health-p.amount)
        mcp.log('info','Applied test damage');return {health=objects.player.health}
    end)
    mcp.registerAction('reset_scene',{description='Reset the demo scene.',params={}},function()
        objects=mcp.json.decode(mcp.json.encode(initial));runtime.resetInput();return {reset=true}
    end)
    mcp.setGameMetadataProvider(function()return {title='LÖVE2D MCP / Development Lab',object_count=2}end)
    mcp.setSnapshotHandlers(function()return objects end,function(state)
        if type(state)~='table' or not validObject(state.player) or not validObject(state.enemy_1) then return false end
        for _,id in ipairs({'player','enemy_1'}) do for _,key in ipairs({'x','y','health'}) do objects[id][key]=state[id][key] end end
        runtime.resetInput();return true
    end)
    -- Only this disposable demo opts into restoration. Library default remains false.
    mcp.init({port=tonumber(os.getenv('LOVE2D_MCP_PORT')) or 12345,allow_restore=true})
end
local function simulate(dt)
    local p=objects.player
    if runtime.isDown('left') or runtime.isDown('a') then p.x=math.max(20,p.x-p.speed*dt) end
    if runtime.isDown('right') or runtime.isDown('d') then p.x=math.min(940,p.x+p.speed*dt) end
    if runtime.isDown('up') or runtime.isDown('w') then p.y=math.max(130,p.y-p.speed*dt) end
    if runtime.isDown('down') or runtime.isDown('s') then p.y=math.min(520,p.y+p.speed*dt) end
end
function love.update(dt) mcp.update();runtime.advance(dt,simulate) end
function love.focus(focused) if not focused then runtime.resetInput() end end
function love.draw()
    local g=love.graphics
    g.clear(0.035,0.045,0.07)
    g.setColor(0.09,0.12,0.18);g.rectangle('fill',0,0,960,110)
    g.setColor(0.82,0.89,1);g.print('LOVE2D MCP   /   DEVELOPMENT LAB',28,22,0,1.6,1.6)
    local status=runtime.status()
    g.setColor(0.35,0.86,0.74);g.print('LOCAL + AUTHENTICATED   |   LUA EVAL OFF   |   '..(status.paused and 'PAUSED' or 'LIVE'),28,64)
    g.setColor(0.10,0.13,0.19)
    for x=0,960,40 do g.line(x,110,x,540) end
    for y=140,540,40 do g.line(0,y,960,y) end
    g.setColor(0.27,0.83,0.75);g.circle('fill',objects.player.x,objects.player.y,18)
    g.setColor(0.95,0.53,0.41);g.circle('line',objects.enemy_1.x,objects.enemy_1.y,22)
    g.setColor(0.90,0.94,1);g.print('player  /  HP '..objects.player.health,objects.player.x-48,objects.player.y+30)
    g.print('enemy_1',objects.enemy_1.x-25,objects.enemy_1.y+32)
    g.setColor(0.60,0.69,0.80);g.print('WASD / arrows to move   |   Use MCP to pause, step, capture, inspect and restore.',28,507)
end
function love.quit() mcp.shutdown() end
