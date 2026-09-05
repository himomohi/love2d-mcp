package.path = "./game/?.lua;" .. package.path
local time, incoming, bound, bindFail = 100, {}, nil, false
local function serverSocket()
    return {
        setoption = function() return true end,
        bind = function(_, host, port) bound = {host, port}; if bindFail then return nil, 'test bind failure' end; return true end,
        listen = function() return true end, settimeout = function() end, close = function() end,
        accept = function() return table.remove(incoming, 1) end,
    }
end
package.preload.socket = function() return { gettime = function() return time end, tcp = serverSocket, tcp6 = serverSocket } end
local J = require('mcp_json')
local M = require('mcp_bridge')
local R = require('mcp_runtime')
local token = string.rep('a', 64)
local passed = 0
local function eq(actual, expected) assert(actual == expected, tostring(actual) .. ' ~= ' .. tostring(expected)) end
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then print('FAIL: ' .. name .. ' - ' .. tostring(err)); os.exit(1) end
    passed = passed + 1; print('PASS: ' .. name)
end
local objects
local function init(opts)
    M.shutdown(); incoming = {}; time = time + 2; bindFail = false
    objects = { player = { type = 'player', x = 0, health = 100 }, [7] = { type = 'enemy', x = 7 } }
    M.setObjectGetter(function() return objects end); M.setObjectSetter(nil); M.setActionHandler(nil)
    M.setSnapshotHandlers(nil, nil); M.setLuaContextProvider(nil); M.setGameMetadataProvider(nil)
    opts = opts or {}; opts.token = token; M.init(opts)
end
local requestNo = 0
local function call(command, args, auth)
    requestNo = requestNo + 1
    local c = args or {}; c.command = command; c.token = auth or token; c.request_id = tostring(requestNo)
    return J.decode(M.handleCommand(J.encode(c)), 4194304)
end
local function peer(data, sendSize)
    local p = { input = data, output = '', closed = false, eof = false }
    function p:settimeout() end
    function p:receive(n)
        if #self.input > 0 then local s = self.input:sub(1, n); self.input = self.input:sub(n + 1); return nil, 'timeout', s end
        return nil, self.eof and 'closed' or 'timeout', ''
    end
    function p:send(s, first, last)
        last = math.min(last or #s, first + (sendSize or 9999999) - 1)
        self.output = self.output .. s:sub(first, last)
        return nil, 'timeout', last
    end
    function p:close() self.closed = true end
    return p
end
local function wire(command, id)
    return J.encode({command=command, token=token, request_id=id}) .. '\n'
end

test('JSON preserves empty arrays and objects', function() eq(J.encode(J.decode('[]')), '[]'); eq(J.encode(J.decode('{}')), '{}') end)
test('JSON preserves null array positions', function() eq(J.encode(J.decode('[null,false,null]')), '[null,false,null]') end)
test('JSON handles Korean and surrogate pairs', function() eq(J.decode('"\\ud55c\\uae00 \\ud83d\\ude3a"'), '한글 😺') end)
test('JSON encodes every control byte', function() local s=''; for i=0,31 do s=s..string.char(i) end; eq(J.decode(J.encode(s)),s) end)
test('JSON preserves UTF8', function() eq(J.decode(J.encode('한글 😺 / \\ "')), '한글 😺 / \\ "') end)
for _, s in ipairs({'01','+1','1.','1e','[1,]','{"a":1,}','"\\q"','"\\ud800"','"\\udc00"','{"a":1,"a":2}','true false','1e999'}) do
    test('JSON rejects malformed input '..s, function() eq(pcall(J.decode,s),false) end)
end
test('JSON rejects invalid UTF8', function() eq(pcall(J.decode,'"'..string.char(255)..'"'),false) end)
test('JSON bounds nesting', function() eq(pcall(J.decode,string.rep('[',40)..'0'..string.rep(']',40)),false) end)
test('JSON bounds encoded bytes', function() eq(pcall(J.encode,{a=string.rep('x',100)},32),false) end)
test('JSON rejects cycles and infinity', function() local t={};t.a=t; eq(pcall(J.encode,t),false);eq(pcall(J.encode,math.huge),false) end)
test('Init binds literal loopback and rejects remote host', function() init();eq(bound[1],'127.0.0.1');M.shutdown();eq(pcall(M.init,{token=token,host='192.0.2.1'}),false) end)
test('Init rejects placeholder tokens and invalid limits', function() M.shutdown();eq(pcall(M.init,{token='replace-with-at-least-32-random-characters'}),false);eq(pcall(M.init,{token=token,port=1.5}),false);eq(pcall(M.init,{token=token,max_clients=0}),false) end)
test('Failed bind is recoverable', function() M.shutdown();bindFail=true;eq(pcall(M.init,{token=token}),false);bindFail=false;eq(M.init({token=token}),true) end)
test('Authentication rejected without losing request ID', function() init();local r=call('ping',{},string.rep('b',64));eq(r.ok,false);eq(r.request_id,tostring(requestNo));eq(r.code,'UNAUTHORIZED') end)
test('No commands before init', function() M.shutdown();eq(call('ping').code,'NOT_INITIALIZED') end)
test('Capability query never returns token', function() init();local r=call('get_status');eq(r.ok,true);eq(r.result.run_lua_enabled,false);assert(not J.encode(r):find(token,1,true)) end)
test('Numeric object IDs round trip', function() init();eq(call('get_object',{id='7'}).result.object.x,7) end)
test('Stable filtered pagination', function() init();local r=call('list_objects',{limit=1}).result;eq(r.objects[1].id,'7');eq(r.next_offset,1);eq(call('list_objects',{type='player',query='PLAY'}).result.total,1) end)
test('Empty scene list stays JSON array', function() init();objects={};local r=call('list_objects');eq(J.encode(r.result.objects),'[]') end)
test('Missing object errors retain correlation', function() init();local r=call('get_object',{id='missing'});eq(r.ok,false);eq(r.code,'NOT_FOUND');eq(r.request_id,tostring(requestNo)) end)
test('State output handles cycles functions secrets non-finite', function() init();objects.player.self=objects.player;objects.player.fn=function()end;objects.player.api_token='secret';objects.player.n=math.huge;local o=call('get_object',{id='player'}).result.object;eq(o.self,'<cycle>');eq(o.fn,'<function>');eq(o.api_token,'<redacted>');eq(o.n,J.null) end)
test('Setter allowlist and null conversion', function() init();eq(call('set_object_property',{id='player',property='x',value=1}).ok,false);M.setObjectSetter(function(id,key,value) if key~='x' then return false end;objects[id][key]=value end);eq(call('set_object_property',{id='player',property='x',value=5}).ok,true);eq(objects.player.x,5);eq(call('set_object_property',{id='player',property='x',value=J.null}).ok,true);eq(objects.player.x,nil) end)
test('Registered action discovery and range validation', function() init();local invoked=0;M.registerAction('damage',{description='Test',params={amount={type='number',min=0,max=25,required=true}}},function(p) invoked=invoked+1;return {amount=p.amount} end);eq(call('invoke_action',{action='damage',params={amount=-1}}).ok,false);eq(invoked,0);eq(call('invoke_action',{action='damage',params={amount=5}}).ok,true);eq(invoked,1);assert(#call('list_actions').result.actions>0) end)
test('Batch stops on errors and is non-atomic', function() init();local r=call('batch',{commands=J.array({{command='ping'},{command='get_object',id='missing'},{command='ping'}})});eq(r.result.completed,2);eq(r.result.atomic,false);eq(r.result.results[2].ok,false) end)
test('Batch forbids nested and privileged commands', function() init();eq(call('batch',{commands=J.array({{command='run_lua',code='return 1'}})}).ok,false) end)
test('Snapshot diff and restore require explicit permission', function() init();M.setSnapshotHandlers(function()return {player=objects.player}end,nil);eq(call('save_snapshot',{name='before'}).ok,true);objects.player.x=5;local r=call('diff_snapshot',{name='before'});eq(r.result.changes[1].path,'/player/x');eq(call('restore_snapshot',{name='before'}).code,'RESTORE_DENIED') end)
test('Snapshot restoration and slot eviction', function() init({allow_restore=true});M.setSnapshotHandlers(function()return {player=objects.player}end,function(state)objects.player=state.player end);call('save_snapshot',{name='s0'});objects.player.x=5;eq(call('restore_snapshot',{name='s0'}).ok,true);eq(objects.player.x,0);for i=1,8 do call('save_snapshot',{name='s'..i}) end;eq(call('diff_snapshot',{name='s0'}).code,'NOT_FOUND') end)
test('Snapshot rejects non-data values', function() init();M.setSnapshotHandlers(function()return {fn=function()end}end,nil);eq(call('save_snapshot',{name='bad'}).ok,false) end)
test('Log ring redacts tokens and reports missed cursor', function() init();for i=1,205 do M.log('info','log '..i..' '..token) end;local r=call('get_logs',{limit=200}).result;eq(#r.entries,200);eq(r.dropped,true);assert(not J.encode(r):find(token,1,true)) end)
test('Rate limit is global rather than per connection', function() init({requests_per_second=2});eq(call('ping').ok,true);eq(call('ping').ok,true);eq(call('ping').code,'RATE_LIMITED') end)
test('Lua remains disabled unless opted in', function() init();eq(call('run_lua',{code='return 1'}).code,'LUA_DENIED') end)
test('Lua query gets a detached data-only context and restores hook', function() init({allow_run_lua=true});local source={x=2,fn=function()end};M.setLuaContextProvider(function()return source end);local hook=function()end;debug.sethook(hook,'',1000000);local ok,r=M.runLua('context.x=8;return {x=context.x,fn=type(context.fn),has_love=type(love)}');eq(ok,true);eq(source.x,2);eq(r.result.fn,'string');eq(r.result.has_love,'nil');eq(debug.gethook(),hook);debug.sethook() end)
test('Lua instruction budget restores the prior hook', function() init({allow_run_lua=true,lua_instruction_limit=5000});local ok=M.runLua('local s=0;for i=1,1000000 do s=s+i end;return s');eq(ok,false);eq(debug.gethook(),nil) end)
test('Nonblocking partial writes retain all response bytes', function() init();local p=peer(wire('ping','partial'),7);incoming={p};for i=1,100 do M.update() end;local r=J.decode(p.output);eq(r.request_id,'partial');eq(r.ok,true) end)
test('Pipelined lines remain processable without fresh bytes', function() init();local p=peer(wire('ping','a')..wire('ping','b'));incoming={p};for i=1,5 do M.update() end;local count=0;for line in p.output:gmatch('[^\n]+')do eq(J.decode(line).ok,true);count=count+1 end;eq(count,2) end)
test('Unauthenticated idle clients expire', function() init();local p=peer('');incoming={p};M.update();time=time+6;M.update();eq(p.closed,true) end)
test('Remote auth failure closes after sending denial', function() init();local p=peer(J.encode({command='ping',token='bad',request_id='bad'})..'\n',5);incoming={p};for i=1,100 do M.update() end;eq(p.closed,true);eq(J.decode(p.output).code,'UNAUTHORIZED') end)
test('Partial EOF is closed rather than held indefinitely', function() init();local p=peer('{');p.eof=true;incoming={p};M.update();M.update();eq(p.closed,true) end)

love = {keyboard={isDown=function()return false end},mouse={isDown=function()return false end},timer={getFPS=function()return 60 end,getTime=function()return time end}}
test('Runtime input is opt-in', function() init();R.attach(M,{});eq(call('send_input',{event='key_down',key='w'}).code,'CAPABILITY_DISABLED') end)
test('Runtime input and frame-step integration', function() init();local r=R.attach(M,{input=true,control=true});eq(call('send_input',{event='key_down',key='w'}).ok,true);eq(r.isDown('w'),true);call('control_game',{operation='pause'});call('control_game',{operation='step',frames=6,dt=0.01});local ticks,total=0,0;r.advance(1,function(dt)ticks=ticks+1;total=total+dt end);eq(ticks,4);r.advance(1,function(dt)ticks=ticks+1;total=total+dt end);eq(ticks,6);assert(math.abs(total-0.06)<0.000001);eq(r.status().steps_remaining,0);call('send_input',{event='reset'});eq(r.isDown('w'),false) end)
test('Last authenticated disconnect releases virtual keys', function() init();local r=R.attach(M,{input=true});local p=peer(wire('ping','input'));incoming={p};M.update();call('send_input',{event='key_down',key='w'});eq(r.isDown('w'),true);p.eof=true;M.update();eq(r.isDown('w'),false) end)
test('Real screenshot API is deferred and memory-only', function() init();local deferred, released, filenames = nil,0,0
    love.graphics={isActive=function()return true end,getPixelDimensions=function()return 20,10 end,captureScreenshot=function(cb)eq(type(cb),'function');deferred=cb end}
    love.data={encode=function(kind,encoding,data)eq(kind,'string');eq(encoding,'base64');return 'ZmFrZQ==' end}
    local r=R.attach(M,{screenshots=true});local pending=call('capture_screenshot').result;eq(pending.status,'pending');eq(call('poll_screenshot',{ticket=pending.ticket}).result.status,'pending')
    deferred({encode=function(_,format,name)eq(format,'png');eq(name,nil);return {getSize=function()return 5 end,release=function()released=released+1 end}end,getWidth=function()return 20 end,getHeight=function()return 10 end,release=function()released=released+1 end})
    local image=call('poll_screenshot',{ticket=pending.ticket}).result;eq(image.status,'ready');eq(image.width,20);eq(released,2);eq(call('poll_screenshot',{ticket=pending.ticket}).code,'NOT_FOUND')
end)
M.shutdown()
print(string.format('\n%d Lua tests passed',passed))
