-- src/fx.lua
-- Event-driven visual feedback: ambient + burst particles, a reusable
-- pulsing hover glow, and a CRT scanline overlay. The ambient background
-- layer itself now lives in src/background.lua (a procedural geometric
-- shader) -- this module only draws things that react to something (a
-- resolution, a hover, a landed card) or sit as a final screen overlay.
--
-- Everything here is drawn with love.graphics primitives -- no image assets
-- required. This module is purely decorative: it never reads battle.lua and
-- never changes game state. ui.lua drives it via FX.load()/FX.update() and
-- calls the FX.draw*/FX.glow()/FX.burst() entry points at the right points
-- in its own draw order.

local FX = {}

local time = 0
local W, H = 800, 600 -- refreshed every FX.update()

-- =============================================================================
-- Particles -- ambient drifting motes plus short-lived bursts (e.g. fired
-- when an engagement resolves).
-- =============================================================================

local particles = {}
local ambientSpawnTimer = 0

local function spawnAmbientParticle()
    table.insert(particles, {
        x = love.math.random(0, W), y = H + 4,
        vx = love.math.random(-6, 6), vy = -love.math.random(10, 24),
        life = 0, maxLife = love.math.random(4, 8),
        size = love.math.random(1, 2),
        color = { 0.6, 0.9, 1 },
    })
end

-- Spawns a radial burst of particles at (x, y). Call this from ui.lua when
-- an engagement resolves.
function FX.burst(x, y, color, count)
    color = color or { 1, 0.9, 0.5 }
    for _ = 1, (count or 18) do
        local angle = love.math.random() * math.pi * 2
        local speed = love.math.random(40, 140)
        table.insert(particles, {
            x = x, y = y,
            vx = math.cos(angle) * speed, vy = math.sin(angle) * speed,
            life = 0, maxLife = 0.5 + love.math.random() * 0.4,
            size = love.math.random(2, 4),
            color = color,
        })
    end
end

local function updateParticles(dt)
    ambientSpawnTimer = ambientSpawnTimer - dt
    if ambientSpawnTimer <= 0 then
        ambientSpawnTimer = 0.3
        spawnAmbientParticle()
    end

    for i = #particles, 1, -1 do
        local particle = particles[i]
        particle.life = particle.life + dt
        if particle.life >= particle.maxLife then
            table.remove(particles, i)
        else
            particle.x = particle.x + particle.vx * dt
            particle.y = particle.y + particle.vy * dt
            local drag = math.min(1, dt * 1.5)
            particle.vx = particle.vx * (1 - drag)
            particle.vy = particle.vy * (1 - drag)
        end
    end
end

local function drawParticles()
    for _, particle in ipairs(particles) do
        local alpha = 1 - (particle.life / particle.maxLife)
        love.graphics.setColor(particle.color[1], particle.color[2], particle.color[3], alpha * 0.8)
        love.graphics.circle("fill", particle.x, particle.y, particle.size)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- =============================================================================
-- Animated glow -- reusable pulsing highlight rectangle, e.g. behind a
-- hovered card or a card sitting in a reveal slot. Draw this BEFORE the
-- card it's highlighting so the card renders on top of the glow.
-- =============================================================================

function FX.glow(x, y, w, h, color, pulseSpeed)
    color = color or { 1, 1, 0.6 }
    local pulse = 0.5 + 0.5 * math.sin(time * (pulseSpeed or 4))
    love.graphics.setColor(color[1], color[2], color[3], 0.15 + 0.15 * pulse)
    local pad = 6 + pulse * 4
    love.graphics.rectangle("fill", x - pad, y - pad, w + pad * 2, h + pad * 2, 10, 10)
    love.graphics.setColor(1, 1, 1, 1)
end

-- =============================================================================
-- Scanlines -- full-screen overlay, drawn last, on top of cards and text.
-- =============================================================================

local SCANLINE_GAP = 4

local function drawScanlines()
    love.graphics.setColor(0, 0, 0, 0.06)
    local offset = (time * 12) % SCANLINE_GAP
    local y = -offset
    while y < H do
        love.graphics.rectangle("fill", 0, y, W, 1)
        y = y + SCANLINE_GAP
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- =============================================================================
-- Public entry points
-- =============================================================================

-- Call once from love.load().
function FX.load()
    W, H = love.graphics.getWidth(), love.graphics.getHeight()
end

-- Call once per love.update(dt).
function FX.update(dt)
    W, H = love.graphics.getWidth(), love.graphics.getHeight()
    time = time + dt
    updateParticles(dt)
end

-- Call after cards/text, so bursts read as being "in front."
function FX.drawParticles()
    drawParticles()
end

-- Call last, over everything else.
function FX.drawScanlines()
    drawScanlines()
end

return FX
