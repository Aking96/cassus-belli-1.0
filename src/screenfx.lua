-- src/screenfx.lua
-- Full-screen effects layered over the whole game view: a darken overlay, a
-- zoom applied to the whole scene, and a big banner (e.g. "WAR", "PLAYER
-- WINS WAR"). Owns a small state table and registers named animations with
-- src/animation_manager.lua -- the same request/response pattern cards use.
-- This is the seed of the spec's "Camera Effects" system: shake, pan,
-- slow-motion, and freeze-frame are Phase 5; zoom + darken + banner are
-- enough for Phase 3's War drama.

local AnimationManager = require("src.animation_manager")

local ScreenFX = {}

local state = {
    zoom = 1,
    darken = 0,
    bannerAlpha = 0,
    bannerScale = 0.7,
    bannerText = "",
    bannerColor = { 1, 0.85, 0.2 },
}

local DEFAULT_BANNER_COLOR = { 1, 0.85, 0.2 } -- gold, the War banners' color

local ZOOM_DURATION = 0.4
local DARKEN_DURATION = 0.4
local BANNER_POP_DURATION = 0.25
local BANNER_HOLD_DURATION = 0.6
local BANNER_FADE_DURATION = 0.35

local bannerFont

local function getBannerFont()
    if not bannerFont then
        bannerFont = love.graphics.newFont(48)
    end
    return bannerFont
end

local function showBanner(text, color)
    state.bannerText = text
    state.bannerColor = color or DEFAULT_BANNER_COLOR
    state.bannerScale = 0.7
    state.bannerAlpha = 0
    AnimationManager.tween(state, "bannerAlpha", 1, BANNER_POP_DURATION, AnimationManager.EASE_OUT_QUAD)
    AnimationManager.tween(state, "bannerScale", 1, BANNER_POP_DURATION, AnimationManager.EASE_OUT_BACK, function()
        AnimationManager.animate(BANNER_HOLD_DURATION, AnimationManager.EASE_LINEAR, function() end, function()
            AnimationManager.tween(state, "bannerAlpha", 0, BANNER_FADE_DURATION, AnimationManager.EASE_OUT_QUAD)
        end)
    end)
end

-- "war_start" -- zooms in and darkens the battlefield and pops up a "WAR"
-- banner. The zoom/darken persist (banner fades on its own) until
-- "war_end" is played, so the whole War -- including any Recursive War
-- rounds and the spoil pick -- reads as one continuous "different mode."
AnimationManager.register("war_start", function(_target, opts)
    AnimationManager.tween(state, "zoom", opts.zoom or 1.06, ZOOM_DURATION, AnimationManager.EASE_OUT_QUAD)
    AnimationManager.tween(state, "darken", opts.darken or 0.18, DARKEN_DURATION, AnimationManager.EASE_OUT_QUAD)
    showBanner(opts.text or "WAR")
end)

-- "war_end" -- returns zoom/darken to normal. Call once a War (including
-- its spoil pick) has fully resolved and normal play resumes.
AnimationManager.register("war_end", function(_target, _opts)
    AnimationManager.tween(state, "zoom", 1, ZOOM_DURATION, AnimationManager.EASE_OUT_QUAD)
    AnimationManager.tween(state, "darken", 0, DARKEN_DURATION, AnimationManager.EASE_OUT_QUAD)
end)

-- "war_result_banner" -- "PLAYER WINS WAR" / "ENEMY WINS WAR", shown once a
-- War's winner has been decided.
AnimationManager.register("war_result_banner", function(_target, opts)
    showBanner(opts.text)
end)

-- "info_banner" -- the same pop/hold/fade banner, with no zoom/darken side
-- effects, for standalone announcements outside of War (e.g. switching to
-- reserves). opts.color lets callers pick a tint other than the War
-- banners' gold, so it reads as its own kind of event.
AnimationManager.register("info_banner", function(_target, opts)
    showBanner(opts.text or "", opts.color)
end)

-- Current whole-scene zoom factor; UI.draw wraps its scene drawing in a
-- scale transform using this, centered on the screen.
function ScreenFX.getZoom()
    return state.zoom
end

-- Draws the darken overlay and any active banner. Call this LAST, outside
-- the zoom transform, so it always covers the full screen crisply and the
-- banner's own pop-in scale isn't compounded with the scene zoom.
function ScreenFX.draw()
    if state.darken > 0 then
        love.graphics.setColor(0, 0, 0, state.darken)
        love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())
        love.graphics.setColor(1, 1, 1)
    end

    if state.bannerAlpha > 0 and state.bannerText ~= "" then
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        local previousFont = love.graphics.getFont()
        local font = getBannerFont()
        love.graphics.setFont(font)

        love.graphics.push()
        love.graphics.translate(w / 2, h / 2)
        love.graphics.scale(state.bannerScale, state.bannerScale)

        local c = state.bannerColor
        love.graphics.setColor(0, 0, 0, state.bannerAlpha * 0.6)
        love.graphics.printf(state.bannerText, -w / 2 + 3, -font:getHeight() / 2 + 3, w, "center")
        love.graphics.setColor(c[1], c[2], c[3], state.bannerAlpha)
        love.graphics.printf(state.bannerText, -w / 2, -font:getHeight() / 2, w, "center")

        love.graphics.pop()
        love.graphics.setFont(previousFont)
        love.graphics.setColor(1, 1, 1)
    end
end

return ScreenFX
