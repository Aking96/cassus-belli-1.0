-- conf.lua
-- LOVE2D window/runtime configuration for the Casus Belli prototype.

function love.conf(t)
    t.window.title = "Casus Belli - Prototype v0.1"
    t.window.width = 1280
    t.window.height = 800
    t.console = true -- helpful for debug prints on Windows
end
