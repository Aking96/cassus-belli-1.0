-- main.lua
-- Entry point. Wires LOVE's callbacks to the Campaign (meta-state: commander
-- select, gold, shop, opponent roster) and, while a battle is in progress,
-- the Battle state machine + its UI. The Collection/Deck Inspection overlay
-- (src/collection_ui.lua) sits on top of either screen -- see love.draw/
-- love.update below. Contains no game rules itself.

local Campaign = require("src.campaign")
local CampaignUI = require("src.campaign_ui")
local UI = require("src.ui")
local CollectionUI = require("src.collection_ui")
local AnimationManager = require("src.animation_manager")
local FX = require("src.fx")
local Background = require("src.background")

local campaign
local lastBattleInstance -- identity-tracked so a fresh Battle (new fight) is
                          -- detectable without Campaign/Battle knowing anything
                          -- about rendering -- see the check in love.update.

function love.load()
    love.window.setTitle("Casus Belli - Prototype v0.1")
    love.graphics.setNewFont(14)
    love.math.setRandomSeed(os.time())
    Background.load()
    FX.load()
    campaign = Campaign.new()
end

function love.update(dt)
    Background.update(dt)
    FX.update(dt)

    -- Single per-frame driver for every CardView/tween in the game, run
    -- unconditionally now regardless of which screen is active. It used to
    -- run only during STATE.BATTLE (from inside UI.update), which was fine
    -- while nothing outside battle used the AnimationManager singleton --
    -- the Collection overlay's card hover/fan animations need it to keep
    -- advancing even when opened from Shop/Victory/etc, not just mid-fight.
    AnimationManager.update(dt)
    CollectionUI.update(campaign, dt)

    -- A new Battle table means a new fight just started -- give the
    -- background's territory colors a fresh random pair for it.
    if campaign.battle ~= lastBattleInstance then
        lastBattleInstance = campaign.battle
        if campaign.battle then
            Background.randomizeColors()
        end
    end

    -- The Collection overlay pauses the battle in place while it's open --
    -- opening it is pure inspection, so nothing about the fight (AI turns,
    -- reveal timers, War state) should advance underneath it.
    if campaign.state == campaign.STATE.BATTLE and not CollectionUI.isOpen() then
        campaign.battle:update(dt)
        UI.update(campaign.battle, dt)
        campaign:checkBattleOutcome()
        Background.setBattleIntensity(campaign.battle and campaign.battle:isInWar() and 2 or 1)
    elseif campaign.state ~= campaign.STATE.BATTLE then
        Background.setBattleIntensity(0)
    end
end

function love.draw()
    if campaign.state == campaign.STATE.BATTLE then
        UI.draw(campaign.battle)
    else
        CampaignUI.draw(campaign)
    end

    CollectionUI.draw(campaign)
end

function love.mousepressed(x, y, button)
    if button ~= 1 then return end

    if CollectionUI.isOpen() then
        CollectionUI.handleClick(campaign, x, y)
        return
    end

    if campaign.state == campaign.STATE.BATTLE then
        UI.handleClick(campaign.battle, x, y)
    else
        local restart = CampaignUI.handleClick(campaign, x, y)
        if restart then
            campaign = Campaign.new()
        end
    end
end

function love.wheelmoved(x, y)
    if CollectionUI.isOpen() then
        CollectionUI.wheelmoved(y)
    end
end

function love.keypressed(key)
    if key == "c" then
        CollectionUI.toggle(campaign)
        return
    end

    if CollectionUI.isOpen() then
        if key == "escape" then
            CollectionUI.handleEscape()
        end
        return
    end

    if campaign.state ~= campaign.STATE.BATTLE then return end

    if key == "q" then
        campaign.battle:switchToReserves("player")
    elseif key == "escape" then
        UI.cancelStaging()
    end
end
