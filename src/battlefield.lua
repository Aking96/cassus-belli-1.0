-- src/battlefield.lua
-- Two visual "pads" -- a Battle Pad for normal engagements and a War Pad
-- for Wars -- rendered as a flat bordered panel with corner brackets and a
-- faint crosshair/diamond watermark, plus the landing glow/ripple triggered
-- when a card lands on either. Purely presentational: battle.lua has no
-- concept of board position, so these are fixed screen regions matching the
-- existing reveal-slot / War-row coordinates, styled per the cyan (player) /
-- magenta (enemy) command-map palette from the visual system directive.

local AnimationManager = require("src.animation_manager")

local Battlefield = {}

local GRID_LINE_COLOR = { 0.25, 0.55, 0.65, 0.35 }
local PAD_BORDER_COLOR = { 0.35, 0.75, 0.85, 0.55 }
local LABEL_COLOR = { 0.55, 0.85, 0.95, 0.8 }
local CORNER_TICK = 16

local GLOW_PLAYER_COLOR = { 0.0, 0.85, 1.0 }
local GLOW_ENEMY_COLOR = { 1.0, 0.15, 0.85 }
local GLOW_DURATION = 0.45
local GLOW_MAX_PAD = 14 -- px the glow rect grows past the card at full expansion

-- Ripple: a simple expanding, fading ring centered where a card lands.
-- Duration lands in the directive's 0.5-1.5s range.
local RIPPLE_DURATION = 0.9
local RIPPLE_MAX_RADIUS = 90

local activeGlows = {}
local activeRipples = {}
local labelFont

local function getLabelFont()
    if not labelFont then
        labelFont = love.graphics.newFont(11)
    end
    return labelFont
end

local function drawCornerBracket(px, py, signX, signY)
    love.graphics.line(px, py, px + signX * CORNER_TICK, py)
    love.graphics.line(px, py, px, py + signY * CORNER_TICK)
end

-- Draws a bordered flat panel -- a faint crosshair and diamond watermark at
-- its center, corner brackets, and a small caption above it -- the zone a
-- card visually sits in.
function Battlefield.drawPad(x, y, w, h, label)
    local cx, cy = x + w / 2, y + h / 2

    love.graphics.setColor(GRID_LINE_COLOR)
    love.graphics.setLineWidth(1)
    love.graphics.line(x + 10, cy, x + w - 10, cy)
    love.graphics.line(cx, y + 10, cx, y + h - 10)

    local dr = math.min(w, h) * 0.22
    love.graphics.polygon("line", cx, cy - dr, cx + dr, cy, cx, cy + dr, cx - dr, cy)

    love.graphics.setColor(PAD_BORDER_COLOR)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)

    drawCornerBracket(x, y, 1, 1)
    drawCornerBracket(x + w, y, -1, 1)
    drawCornerBracket(x, y + h, 1, -1)
    drawCornerBracket(x + w, y + h, -1, -1)

    if label then
        local font = getLabelFont()
        local previousFont = love.graphics.getFont()
        love.graphics.setFont(font)
        love.graphics.setColor(LABEL_COLOR)
        love.graphics.printf("\226\151\134  " .. label .. "  \226\151\134", x, y - font:getHeight() - 3, w, "center")
        love.graphics.setFont(previousFont)
    end

    love.graphics.setColor(1, 1, 1)
end

-- Spawns a brief grid-corner glow burst around (x, y, w, h) -- call when a
-- card lands on the field. owner is "player" or "enemy", picking the
-- cyan/magenta accent.
function Battlefield.spawnGlow(x, y, w, h, owner)
    local glow = {
        x = x, y = y, w = w, h = h,
        alpha = 1,
        pad = 0,
        color = (owner == "enemy") and GLOW_ENEMY_COLOR or GLOW_PLAYER_COLOR,
    }
    table.insert(activeGlows, glow)
    AnimationManager.tween(glow, "alpha", 0, GLOW_DURATION, AnimationManager.EASE_OUT_QUAD)
    AnimationManager.tween(glow, "pad", GLOW_MAX_PAD, GLOW_DURATION, AnimationManager.EASE_OUT_QUAD, function()
        for i, g in ipairs(activeGlows) do
            if g == glow then
                table.remove(activeGlows, i)
                break
            end
        end
    end)
end

-- Draws every active landing glow as an expanding, fading grid-corner
-- bracket. Call after cards so the flash reads as a reaction to the card
-- rather than sitting under it.
function Battlefield.drawGlows()
    for _, glow in ipairs(activeGlows) do
        local gx, gy = glow.x - glow.pad, glow.y - glow.pad
        local gw, gh = glow.w + glow.pad * 2, glow.h + glow.pad * 2
        local tick = 8

        love.graphics.setColor(glow.color[1], glow.color[2], glow.color[3], glow.alpha * 0.9)
        love.graphics.setLineWidth(2)
        love.graphics.line(gx, gy + tick, gx, gy, gx + tick, gy)
        love.graphics.line(gx + gw - tick, gy, gx + gw, gy, gx + gw, gy + tick)
        love.graphics.line(gx + gw, gy + gh - tick, gx + gw, gy + gh, gx + gw - tick, gy + gh)
        love.graphics.line(gx + tick, gy + gh, gx, gy + gh, gx, gy + gh - tick)
    end
    love.graphics.setColor(1, 1, 1)
end

-- Spawns an expanding ring, centered on (x, y) -- call alongside spawnGlow
-- when a card lands, for the "tile pulse -> energy ripple" sequence. owner
-- picks the cyan/magenta accent, same convention as spawnGlow.
function Battlefield.ripple(x, y, owner)
    local ripple = {
        x = x, y = y,
        radius = 6,
        alpha = 0.85,
        color = (owner == "enemy") and GLOW_ENEMY_COLOR or GLOW_PLAYER_COLOR,
    }
    table.insert(activeRipples, ripple)
    AnimationManager.tween(ripple, "radius", RIPPLE_MAX_RADIUS, RIPPLE_DURATION, AnimationManager.EASE_OUT_QUAD)
    AnimationManager.tween(ripple, "alpha", 0, RIPPLE_DURATION, AnimationManager.EASE_OUT_QUAD, function()
        for i, r in ipairs(activeRipples) do
            if r == ripple then
                table.remove(activeRipples, i)
                break
            end
        end
    end)
end

-- Draws every active ripple as a simple expanding, fading ring.
function Battlefield.drawRipples()
    for _, ripple in ipairs(activeRipples) do
        love.graphics.setColor(ripple.color[1], ripple.color[2], ripple.color[3], ripple.alpha)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", ripple.x, ripple.y, ripple.radius)
    end
    love.graphics.setColor(1, 1, 1)
end

return Battlefield
