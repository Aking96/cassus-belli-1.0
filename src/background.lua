-- src/background.lua
-- Procedural animated geometric background (see src/background.glsl): an
-- interlocking hexa-chevron / cube diamond lattice that shifts, pulses, and
-- fades per-cell, warm on the player's side and cool on the enemy's,
-- converging to a calm, subdued band right around the battlefield, with a
-- mouse-reactive "negative" hover effect. Rendered from a single LÖVE pixel
-- shader over a full-screen rectangle rather than per-block Lua objects, so
-- cost stays flat no matter how busy the grid looks.
--
-- Draw this FIRST, before the battlefield/cards/UI -- everything else
-- renders on top of it. The only "game state" this touches at all is being
-- told (via Background.randomizeColors) that a new battle started, and
-- (via Background.setBattleIntensity) roughly how tense the current moment
-- is -- main.lua/ui.lua call those, not any game-logic module, keeping
-- battle.lua/campaign.lua rendering-agnostic as always.

local Background = {}

local shader
local elapsed = 0
local enemyColor = { 0.55, 0.25, 0.85 }
local playerColor = { 0.85, 0.35, 0.15 }
local intensity = 0 -- 0 = normal (menus), 1 = battle, 2 = War -- see setBattleIntensity

-- Standard HSV -> RGB conversion (h in degrees, s/v in 0..1).
local function hsvToRgb(h, s, v)
    h = h % 360
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if h < 60 then r, g, b = c, x, 0
    elseif h < 120 then r, g, b = x, c, 0
    elseif h < 180 then r, g, b = 0, c, x
    elseif h < 240 then r, g, b = 0, x, c
    elseif h < 300 then r, g, b = x, 0, c
    else r, g, b = c, 0, x
    end
    return r + m, g + m, b + m
end

-- Picks a fresh random color pair for the two sides' territory tint, each
-- battle. The player's side always lands somewhere in the warm band (red /
-- red-orange / pink / magenta) and the enemy's in the cool band (cyan /
-- blue / violet / purple), per the background spec's "color by side" --
-- randomized within that band rather than a single fixed color each time.
function Background.randomizeColors()
    local playerHue = (love.math.random() * 60 - 20) % 360 -- ~340..360,0..40: red/orange/pink/magenta
    local enemyHue = 180 + love.math.random() * 120         -- 180..300: cyan/blue/violet/purple

    local pr, pg, pb = hsvToRgb(playerHue, 0.75, 0.85)
    local er, eg, eb = hsvToRgb(enemyHue, 0.75, 0.85)
    playerColor = { pr, pg, pb }
    enemyColor = { er, eg, eb }
end

-- Future/current game-state hook: 0 = normal (campaign menus), 1 = an
-- ordinary battle round, 2 = a War is active. Nudges animation speed,
-- brightness, and the mouse-hover reaction strength -- see background.glsl.
-- Called from main.lua each frame; battle.lua/campaign.lua never call this
-- themselves.
function Background.setBattleIntensity(value)
    intensity = value
end

function Background.load()
    shader = love.graphics.newShader("src/background.glsl")
    Background.randomizeColors()
end

function Background.update(dt)
    elapsed = elapsed + dt
end

function Background.draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local previousShader = love.graphics.getShader()
    local r, g, b, a = love.graphics.getColor()
    local mx, my = love.mouse.getPosition()

    love.graphics.setShader(shader)
    shader:send("time", elapsed)
    shader:send("resolution", { w, h })
    shader:send("enemyColor", enemyColor)
    shader:send("playerColor", playerColor)
    shader:send("mouse", { mx, my })
    shader:send("battleIntensity", intensity)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, w, h)

    love.graphics.setShader(previousShader)
    love.graphics.setColor(r, g, b, a)
end

return Background
