-- src/cardview.lua
-- Per-card VISUAL data: identity, position, rotation, and hover/flight
-- state -- NOT behaviour. All actual motion is performed by
-- src/animation_manager.lua, per the Animation System Specification: "Game
-- logic should never directly move cards... [the] Animation Manager
-- performs all movement."
--
-- Every view also runs a continuous idle "float" -- a small per-card sine
-- wave (position/rotation/scale) plus a cursor-tilt lean, per the Blissful
-- Card Animation Directive, so cards never look completely static even when
-- nothing is happening. Its parameters (phase, speed, amount) are
-- randomized per card so several on screen don't move in lockstep.
--
-- This module also registers the card-specific named animations ui.lua
-- requests by name:
--   "card_hover" -- sets the lift/scale targets; a continuous follow
--                   (started in CardView.new) does the actual easing.
--   "card_arc"   -- a card thrown from one slot to another: rises and
--                   settles in a parabolic arc, tilting slightly toward the
--                   direction of travel and leveling out on arrival, then
--                   automatically chains into "card_slam" on landing.
--   "card_slam"  -- the impact itself: a quick squash (wide/flat) followed
--                   by a springy bounce back to normal size. Playable on
--                   its own (e.g. a War-resolution impact on a card that's
--                   already in place) or as card_arc's landing.

local AnimationManager = require("src.animation_manager")

local CardView = {}
CardView.__index = CardView

local HOVER_LIFT = 13      -- px raised when hovered (directive's target: 10-15)
local HOVER_SCALE = 1.08
local IDLE_SCALE = 1
local FOLLOW_SPEED = 10    -- higher = snappier hover/reflow easing
local TILT_FOLLOW_SPEED = 8

local ARC_DURATION = 0.32
local ARC_HEIGHT = 55            -- px the card rises above a straight line mid-flight
local ARC_ROTATION_PEAK = math.rad(9) -- max tilt during flight, toward the travel direction

local SLAM_SQUASH_DURATION = 0.06
local SLAM_BOUNCE_DURATION = 0.16
local SLAM_SQUASH_X, SLAM_SQUASH_Y = 1.16, 0.84

-- Idle float tuning -- directive's own "good starting range" values.
local CURSOR_TILT_MAX = 0.08          -- radians
local CURSOR_TILT_SENSITIVITY = 0.0005
local BASE_SHADOW_OFFSET = 4
local HOVER_SHADOW_OFFSET = 5

function CardView.new(card, x, y, width, height)
    local self = setmetatable({}, CardView)

    self.card = card
    self.x, self.y = x, y
    self.width, self.height = width, height
    self.faceDown = false
    self.rotation = 0

    -- Resting slot position; x/y continuously drift toward this except
    -- while card_arc's flight tween owns them.
    self.homeX, self.homeY = x, y

    self.hoverOffset = 0
    self.hoverTargetOffset = 0
    self.scaleX = IDLE_SCALE
    self.scaleY = IDLE_SCALE
    self.hoverTargetScale = IDLE_SCALE

    -- Idle float: randomized per card so several on screen don't move in
    -- lockstep (Blissful Card Animation Directive, sec. 5-6).
    self.floatTime = love.math.random() * 20
    self.floatSpeed = 0.8 + love.math.random() * 0.4
    self.floatAmount = 1.5 + love.math.random() * 1.0
    self.rotationAmount = 0.01 + love.math.random() * 0.01
    self.floatX = 0
    self.floatY = 0
    self.floatRotation = 0
    self.floatScale = 1
    self.cursorTilt = 0
    self.shadowOffsetY = BASE_SHADOW_OFFSET

    self._hoverFollow = AnimationManager.follow(self, "hoverOffset",
        function() return self.hoverTargetOffset end, FOLLOW_SPEED)
    self._scaleXFollow = AnimationManager.follow(self, "scaleX",
        function() return self.hoverTargetScale end, FOLLOW_SPEED)
    self._scaleYFollow = AnimationManager.follow(self, "scaleY",
        function() return self.hoverTargetScale end, FOLLOW_SPEED)
    self._xFollow = AnimationManager.follow(self, "x", function() return self.homeX end, FOLLOW_SPEED)
    self._yFollow = AnimationManager.follow(self, "y", function() return self.homeY end, FOLLOW_SPEED)

    self._idleLoop = AnimationManager.loop(function(_elapsed, dt)
        self.floatTime = self.floatTime + dt

        local primary = math.sin(self.floatTime * self.floatSpeed) * self.floatAmount
        local secondary = math.sin(self.floatTime * 0.7) * 0.8
        self.floatY = primary + secondary
        self.floatX = math.sin(self.floatTime * 0.6) * 1.2
        self.floatRotation = math.sin(self.floatTime * 0.9) * self.rotationAmount
        self.floatScale = 1 + math.sin(self.floatTime * 0.8) * 0.008

        -- Cursor tilt fades in/out with hover fraction (0 = resting, 1 =
        -- fully hovered) so cards far from the cursor don't visibly lean
        -- toward it while just sitting idle.
        local hoverFraction = -self.hoverOffset / HOVER_LIFT
        local mx = love.mouse.getPosition()
        local dx = mx - self.homeX
        local targetTilt = math.max(-CURSOR_TILT_MAX, math.min(CURSOR_TILT_MAX, dx * CURSOR_TILT_SENSITIVITY))
        self.cursorTilt = self.cursorTilt + (targetTilt * hoverFraction - self.cursorTilt) * TILT_FOLLOW_SPEED * dt

        self.shadowOffsetY = BASE_SHADOW_OFFSET + hoverFraction * HOVER_SHADOW_OFFSET
    end)

    return self
end

-- Stops this view's continuous animations. Call when the view is discarded
-- (its card left the hand) so the manager doesn't keep updating an
-- abandoned target forever.
function CardView:destroy()
    self._hoverFollow:cancel()
    self._scaleXFollow:cancel()
    self._scaleYFollow:cancel()
    self._xFollow:cancel()
    self._yFollow:cancel()
    self._idleLoop:cancel()
end

-- Returns the on-screen draw rect (x, y, w, h) after applying hover lift,
-- idle float, and scale, centered on the card's base position. Rotation is
-- separate (see getRotation()) since it pivots around the center at draw
-- time rather than affecting this axis-aligned rect.
function CardView:getDrawRect()
    local w = self.width * self.scaleX * self.floatScale
    local h = self.height * self.scaleY * self.floatScale
    local drawX = self.x + self.floatX - (w - self.width) / 2
    local drawY = self.y + self.floatY + self.hoverOffset - (h - self.height) / 2
    return drawX, drawY, w, h
end

-- Returns this card's total rotation: card_arc's flight tilt (toward travel
-- direction, 0 at rest) plus the idle rock plus the cursor-tilt lean.
function CardView:getRotation()
    return self.rotation + self.floatRotation + self.cursorTilt
end

-- Returns the shadow's draw rect. Deliberately does NOT include hoverOffset
-- (the shadow stays near the resting position while the card itself rises),
-- so the growing gap between card and shadow is what sells "lifting off the
-- battlefield" -- see shadowOffsetY, which also grows a little with hover.
function CardView:getShadowRect()
    local w = self.width * self.floatScale
    local h = self.height * self.floatScale
    local shadowX = self.x + self.floatX - (w - self.width) / 2
    local shadowY = self.y + self.floatY + self.shadowOffsetY - (h - self.height) / 2
    return shadowX, shadowY, w, h
end

AnimationManager.register("card_hover", function(view, opts)
    view.hoverTargetOffset = opts.hovering and -HOVER_LIFT or 0
    view.hoverTargetScale = opts.hovering and HOVER_SCALE or IDLE_SCALE
end)

-- Impact: quick squash (wide/flat) then a springy bounce back to normal
-- size, via AnimationManager.EASE_OUT_BACK for the "quick bounce" the spec
-- asks for. Temporarily takes over scaleX/scaleY from the hover follow,
-- same cancel-then-restart pattern card_arc uses for x/y.
AnimationManager.register("card_slam", function(view, opts)
    view._scaleXFollow:cancel()
    view._scaleYFollow:cancel()

    local function restoreScaleFollows()
        view._scaleXFollow = AnimationManager.follow(view, "scaleX",
            function() return view.hoverTargetScale end, FOLLOW_SPEED)
        view._scaleYFollow = AnimationManager.follow(view, "scaleY",
            function() return view.hoverTargetScale end, FOLLOW_SPEED)
    end

    local remaining = 2
    local function onOneBounceDone()
        remaining = remaining - 1
        if remaining == 0 then
            restoreScaleFollows()
            if opts.onSettled then opts.onSettled() end
        end
    end

    AnimationManager.tween(view, "scaleX", SLAM_SQUASH_X, SLAM_SQUASH_DURATION, AnimationManager.EASE_OUT_QUAD,
        function()
            AnimationManager.tween(view, "scaleX", 1, SLAM_BOUNCE_DURATION, AnimationManager.EASE_OUT_BACK, onOneBounceDone)
        end)
    AnimationManager.tween(view, "scaleY", SLAM_SQUASH_Y, SLAM_SQUASH_DURATION, AnimationManager.EASE_OUT_QUAD,
        function()
            AnimationManager.tween(view, "scaleY", 1, SLAM_BOUNCE_DURATION, AnimationManager.EASE_OUT_BACK, onOneBounceDone)
        end)
end)

-- Thrown-card motion: rise and fall through a parabolic arc while tilting
-- toward the travel direction and leveling out, per the spec's "Lift...
-- rotate slightly toward the destination... travel in a smooth arc...
-- land with impact." Lands exactly on (opts.x, opts.y), zeroes rotation,
-- resumes the continuous home-follow, then chains into card_slam.
-- opts.onSettled, if given, fires once the ENTIRE arc+slam has finished --
-- used to chain "next card" in a staggered multi-card deployment.
AnimationManager.register("card_arc", function(view, opts)
    view.homeX, view.homeY = opts.x, opts.y
    view._xFollow:cancel()
    view._yFollow:cancel()

    local fromX, fromY = view.x, view.y
    local toX, toY = opts.x, opts.y
    local direction = (toX >= fromX) and 1 or -1
    local duration = opts.duration or ARC_DURATION

    AnimationManager.animate(duration, AnimationManager.EASE_OUT_QUAD, function(t)
        view.x = fromX + (toX - fromX) * t
        local straightY = fromY + (toY - fromY) * t
        local arcOffset = -ARC_HEIGHT * 4 * t * (1 - t) -- parabola: 0 at t=0/1, peak at t=0.5
        view.y = straightY + arcOffset
        view.rotation = ARC_ROTATION_PEAK * math.sin(t * math.pi) * direction
    end, function()
        view.x, view.y = toX, toY
        view.rotation = 0
        view._xFollow = AnimationManager.follow(view, "x", function() return view.homeX end, FOLLOW_SPEED)
        view._yFollow = AnimationManager.follow(view, "y", function() return view.homeY end, FOLLOW_SPEED)
        AnimationManager.play("card_slam", view, { onSettled = opts.onSettled })
    end)
end)

return CardView
