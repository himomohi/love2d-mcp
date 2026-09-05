function love.conf(t)
    t.identity = 'love2d-mcp-development-lab'
    t.version = '11.4'
    t.console = true
    t.window.title = 'LÖVE2D MCP Development Lab'
    t.window.width, t.window.height = 960, 540
    t.window.resizable = false
    t.modules.audio = false
end
