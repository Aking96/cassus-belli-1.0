-- src/animation_manager.lua
-- The single place that ever changes a visual's on-screen position,
-- rotation, scale, or transparency. Game/UI code never lerps a field
-- itself -- it calls AnimationManager.play(name, target, opts) and this
-- module performs the actual motion. Per the Animation System
-- Specification (v0.1): "Game logic should never directly move cards...
-- gameplay systems should request animations from the Animation Manager."
--
-- Three kinds of animation instance run side by side, all driven by
-- AnimationManager.update(dt):
--   - "tween"    -- fixed duration; eases target[field] from its current
--                   value to a given end value, then fires onComplete once
--                   and stops. Used for one-shot single-field moves (an
--                   impact squash, a fade-out, etc).
--   - "follow"   -- runs forever until cancelled; nudges target[field]
--                   toward getTarget() every frame via exponential decay.
--                   Used for continuous behaviour with no fixed end time --
--                   hover lift and hand-reflow drift are both "chase a
--                   value that may itself keep moving."
--   - "progress" -- fixed duration; calls onUpdate(easedT) every frame with
--                   nothing else touched automatically. Used when one
--                   motion needs to derive SEVERAL fields from a single
--                   eased timeline -- e.g. an arc's x, y, and rotation all
--                   come from the same progress value -- which a plain
--                   single-field tween can't express. See
--                   AnimationManager.animate().
--   "loop"     -- runs forever until cancelled; calls onUpdate(elapsed, dt)
--                   every frame with nothing else touched automatically.
--                   Used for continuous per-frame effects with no fixed
--                   duration AND no single "chase a value" target -- e.g.
--                   the idle card float, whose compound sine waves drive
--                   several fields (x, y, rotation, scale) from one clock,
--                   which neither tween nor follow expresses cleanly. See
--                   AnimationManager.loop().
--
-- Named animations (registered once via AnimationManager.register) are
-- factory functions that start whichever tweens/follows they need against
-- a target -- this is the data-driven, reusable-across-cards layer the
-- spec's Development Notes ask for ("do not hard-code animations into
-- individual cards... cards should expose animation requests").

local AnimationManager = {}

local registry = {}
local instances = {}

local function easeOutQuad(t)
    return 1 - (1 - t) * (1 - t)
end

-- "Back" easing: overshoots slightly past the target then settles -- a
-- cheap, standard way to get a springy "bounce" feel out of a plain tween.
local function easeOutBack(t)
    local c1 = 1.70158
    local c3 = c1 + 1
    return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

AnimationManager.EASE_LINEAR = function(t) return t end
AnimationManager.EASE_OUT_QUAD = easeOutQuad
AnimationManager.EASE_OUT_BACK = easeOutBack

-- Starts a one-shot tween of target[field] from its current value to `to`,
-- over `duration` seconds. Returns the instance (has :cancel()).
function AnimationManager.tween(target, field, to, duration, easing, onComplete)
    local instance = {
        kind = "tween",
        target = target,
        field = field,
        from = target[field],
        to = to,
        duration = duration,
        elapsed = 0,
        easing = easing or easeOutQuad,
        onComplete = onComplete,
    }
    function instance:cancel() self.dead = true end
    table.insert(instances, instance)
    return instance
end

-- Starts an ongoing follow: every frame, target[field] eases toward
-- getTarget() (a function, so the goal can itself keep changing -- e.g. a
-- hand slot that moves as the hand reflows) at `speed` (higher = snappier).
-- Runs until :cancel()'d.
function AnimationManager.follow(target, field, getTarget, speed)
    local instance = {
        kind = "follow",
        target = target,
        field = field,
        getTarget = getTarget,
        speed = speed,
    }
    function instance:cancel() self.dead = true end
    table.insert(instances, instance)
    return instance
end

-- Drives a fixed-duration progress value from 0 to 1 (eased), calling
-- onUpdate(easedT) every frame. Use this instead of tween() when a motion
-- needs to derive several fields from one progress value rather than
-- animating a single field directly. Returns the instance (has :cancel()).
function AnimationManager.animate(duration, easing, onUpdate, onComplete)
    local instance = {
        kind = "progress",
        duration = duration,
        elapsed = 0,
        easing = easing or easeOutQuad,
        onUpdate = onUpdate,
        onComplete = onComplete,
    }
    function instance:cancel() self.dead = true end
    table.insert(instances, instance)
    return instance
end

-- Runs forever (until cancelled), calling onUpdate(elapsedSeconds, dt) every
-- frame. Returns the instance (has :cancel()).
function AnimationManager.loop(onUpdate)
    local instance = {
        kind = "loop",
        elapsed = 0,
        onUpdate = onUpdate,
    }
    function instance:cancel() self.dead = true end
    table.insert(instances, instance)
    return instance
end

-- Registers a named animation: factory(target, opts) sets up whatever
-- tweens/follows it needs. Call sites never touch tween/follow directly for
-- a registered name -- they just play(name, target, opts).
function AnimationManager.register(name, factory)
    registry[name] = factory
end

-- Requests a registered animation by name against `target`.
function AnimationManager.play(name, target, opts)
    local factory = registry[name]
    if not factory then
        error("AnimationManager: no animation registered as '" .. tostring(name) .. "'")
    end
    return factory(target, opts or {})
end

-- Advances every active instance. Call once per love.update(dt).
function AnimationManager.update(dt)
    for i = #instances, 1, -1 do
        local instance = instances[i]
        if instance.dead then
            table.remove(instances, i)
        elseif instance.kind == "tween" then
            instance.elapsed = instance.elapsed + dt
            local t = math.min(1, instance.elapsed / instance.duration)
            local eased = instance.easing(t)
            instance.target[instance.field] = instance.from + (instance.to - instance.from) * eased
            if t >= 1 then
                table.remove(instances, i)
                if instance.onComplete then instance.onComplete() end
            end
        elseif instance.kind == "follow" then
            local current = instance.target[instance.field]
            local goal = instance.getTarget()
            local lerpT = math.min(1, dt * instance.speed)
            instance.target[instance.field] = current + (goal - current) * lerpT
        elseif instance.kind == "progress" then
            instance.elapsed = instance.elapsed + dt
            local t = math.min(1, instance.elapsed / instance.duration)
            instance.onUpdate(instance.easing(t))
            if t >= 1 then
                table.remove(instances, i)
                if instance.onComplete then instance.onComplete() end
            end
        elseif instance.kind == "loop" then
            instance.elapsed = instance.elapsed + dt
            instance.onUpdate(instance.elapsed, dt)
        end
    end
end

return AnimationManager
