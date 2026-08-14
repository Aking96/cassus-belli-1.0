-- src/campaign_ui.lua
-- Rendering + input for every non-battle campaign screen: commander select,
-- victory, the Field Supply shop, battle select, campaign complete, and
-- defeat. The battle screen itself is still src/ui.lua -- this module only
-- handles what wraps around it, sharing the animated Background so every
-- screen reads as the same command-map interface.

local Commander = require("src.commander")
local FX = require("src.fx")
local Background = require("src.background")
local UI = require("src.ui")
local CollectionUI = require("src.collection_ui")

local CampaignUI = {}

local PANEL_COLOR = { 0.55, 0.85, 0.95 }
local BUTTON_FILL = { 0.10, 0.16, 0.20 }
local BUTTON_BORDER = { 0.35, 0.75, 0.85 }
local BUTTON_HOVER_BORDER = { 0.0, 0.85, 1.0 }

local BUTTON_W, BUTTON_H, BUTTON_GAP = 140, 90, 12
local ACTION_BTN_W, ACTION_BTN_H = 180, 50

local titleFont, bodyFont

local function getTitleFont()
    if not titleFont then titleFont = love.graphics.newFont(28) end
    return titleFont
end

local function getBodyFont()
    if not bodyFont then bodyFont = love.graphics.newFont(14) end
    return bodyFont
end

local function drawTitle(text, y)
    local font = getTitleFont()
    local previous = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(PANEL_COLOR)
    love.graphics.printf(text, 0, y, love.graphics.getWidth(), "center")
    love.graphics.setFont(previous)
    love.graphics.setColor(1, 1, 1)
end

local function drawSubtitle(text, y)
    local font = getBodyFont()
    local previous = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(text, 0, y, love.graphics.getWidth(), "center")
    love.graphics.setFont(previous)
end

local function isOver(x, y, w, h, mx, my)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local function drawButton(x, y, w, h, label, hovered)
    love.graphics.setColor(BUTTON_FILL)
    love.graphics.rectangle("fill", x, y, w, h, 4, 4)
    love.graphics.setColor(hovered and BUTTON_HOVER_BORDER or BUTTON_BORDER)
    love.graphics.setLineWidth(hovered and 3 or 2)
    love.graphics.rectangle("line", x, y, w, h, 4, 4)

    local font = getBodyFont()
    local previous = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)
    local _, wrapped = font:getWrap(label, w - 8)
    local textH = #wrapped * font:getHeight()
    love.graphics.printf(label, x + 4, y + h / 2 - textH / 2, w - 8, "center")
    love.graphics.setFont(previous)
    love.graphics.setColor(1, 1, 1)
end

local function actionButtonRect(y)
    return { x = love.graphics.getWidth() / 2 - ACTION_BTN_W / 2, y = y, w = ACTION_BTN_W, h = ACTION_BTN_H }
end

-- Discoverable entry point for the Collection/Deck Inspection overlay
-- (src/collection_ui.lua) on the "between fights" screens -- Shop, Victory,
-- Battle Select. The hotkey (main.lua's "c") works everywhere else too;
-- this is just a visible affordance on the screens where reviewing/
-- rearranging Frontline vs Reserve is most relevant.
local COLLECTION_BTN_W, COLLECTION_BTN_H = 150, 36

local function collectionButtonRect()
    return { x = love.graphics.getWidth() - COLLECTION_BTN_W - 24, y = 24, w = COLLECTION_BTN_W, h = COLLECTION_BTN_H }
end

local function drawCollectionButton(mx, my)
    local btn = collectionButtonRect()
    drawButton(btn.x, btn.y, btn.w, btn.h, "COLLECTION", isOver(btn.x, btn.y, btn.w, btn.h, mx, my))
end

-- Layout for a block of commander buttons, shared between COMMANDER_SELECT
-- and BATTLE_SELECT -- wraps into rows of MAX_PER_ROW so it still fits the
-- window now that there are 11 commanders (a single row would overflow a
-- 1280-wide window). The whole block is vertically centered on centerY
-- (defaults to the window's center, used by BATTLE_SELECT which takes the
-- whole screen); each row is independently horizontally centered, so a
-- shorter final row still looks deliberate rather than left-aligned.
local COMMANDER_ROW_MAX = 6

local function commanderBlockHeight(count)
    local rows = math.max(1, math.ceil(count / COMMANDER_ROW_MAX))
    return rows * BUTTON_H + (rows - 1) * BUTTON_GAP
end

local function commanderButtonRects(names, centerY)
    centerY = centerY or (love.graphics.getHeight() / 2)
    local rects = {}
    local startY = centerY - commanderBlockHeight(#names) / 2

    for i, name in ipairs(names) do
        local row = math.floor((i - 1) / COMMANDER_ROW_MAX)
        local col = (i - 1) % COMMANDER_ROW_MAX
        local itemsInRow = math.min(COMMANDER_ROW_MAX, #names - row * COMMANDER_ROW_MAX)
        local rowWidth = itemsInRow * BUTTON_W + (itemsInRow - 1) * BUTTON_GAP
        local rowStartX = (love.graphics.getWidth() - rowWidth) / 2

        rects[i] = {
            x = rowStartX + col * (BUTTON_W + BUTTON_GAP),
            y = startY + row * (BUTTON_H + BUTTON_GAP),
            w = BUTTON_W, h = BUTTON_H, name = name,
        }
    end
    return rects
end

-- selectedNames (optional list) draws every matching button highlighted the
-- same as hovered -- used by COMMANDER_SELECT so every currently-picked
-- commander stays visibly marked, not just whichever one the mouse is over.
local function drawCommanderButtons(names, mx, my, centerY, selectedNames)
    for _, rect in ipairs(commanderButtonRects(names, centerY)) do
        local selected = selectedNames and contains(selectedNames, rect.name)
        local hovered = isOver(rect.x, rect.y, rect.w, rect.h, mx, my) or selected
        local label = rect.name .. "\n" .. (Commander.DESCRIPTIONS[rect.name] or "")
        drawButton(rect.x, rect.y, rect.w, rect.h, label, hovered)
    end
end

-- COMMANDER_SELECT's own layout: the button block sits a bit above true
-- center so there's room below it for the START BATTLE button -- single
-- source of truth shared by draw and click handling.
local COMMANDER_SELECT_CENTER_Y = 340

local function commanderSelectConfirmRect()
    local blockBottom = COMMANDER_SELECT_CENTER_Y + commanderBlockHeight(#Commander.ALL) / 2
    return actionButtonRect(blockBottom + 30)
end

local SHOP_CARD_GAP = 40
local SHOP_CARD_Y = 150

local function shopLayout(campaign)
    local cardW, cardH = UI.CARD_W, UI.CARD_H
    local totalWidth = #campaign.shop * cardW + (#campaign.shop - 1) * SHOP_CARD_GAP
    local startX = (love.graphics.getWidth() - totalWidth) / 2
    return cardW, cardH, startX
end

local function drawBackdrop()
    love.graphics.clear(0.02, 0.03, 0.05)
    Background.draw()
end

local WON_CARD_GAP = 16
local WON_ROW_GAP = 10

-- Draws `cards` centered, wrapping into rows of maxCols -- used for the
-- VICTORY screen's War-won cards, since a long battle can chain through
-- several Wars and grant more than one permanent recruit.
local function drawCardGrid(cards, topY, maxCols)
    local cardW, cardH = UI.CARD_W, UI.CARD_H
    local rows = math.ceil(#cards / maxCols)
    for row = 0, rows - 1 do
        local cols = math.min(maxCols, #cards - row * maxCols)
        local totalWidth = cols * cardW + (cols - 1) * WON_CARD_GAP
        local startX = (love.graphics.getWidth() - totalWidth) / 2
        local y = topY + row * (cardH + WON_ROW_GAP)
        for col = 1, cols do
            local card = cards[row * maxCols + col]
            UI.drawStaticCard(card, startX + (col - 1) * (cardW + WON_CARD_GAP), y, cardW, cardH)
        end
    end
    return topY + rows * (cardH + WON_ROW_GAP)
end

local WON_GRID_TOP_Y = 195
local WON_GRID_MAX_COLS = 6

-- Single source of truth for the VICTORY screen's CONTINUE button position,
-- which shifts down when there are War-won cards to show -- used by both
-- CampaignUI.draw and CampaignUI.handleClick so a click always matches what
-- was actually drawn.
local function victoryContinueY(campaign)
    local won = campaign.cardsWonThisBattle
    if #won == 0 then return 400 end
    local rows = math.ceil(#won / WON_GRID_MAX_COLS)
    return WON_GRID_TOP_Y + rows * (UI.CARD_H + WON_ROW_GAP) + 30
end


function CampaignUI.draw(campaign)
    drawBackdrop()
    local mx, my = love.mouse.getPosition()
    local STATE = campaign.STATE

    if campaign.state == STATE.COMMANDER_SELECT then
        drawTitle("SELECT YOUR COMMANDERS", 25)
        drawSubtitle(string.format("Choose up to %d to test how their abilities stack together",
            campaign.MAX_PLAYER_COMMANDERS), 60)
        drawSubtitle(string.format("%d / %d selected", #campaign.playerCommanders, campaign.MAX_PLAYER_COMMANDERS), 85)

        drawCommanderButtons(Commander.ALL, mx, my, COMMANDER_SELECT_CENTER_Y, campaign.playerCommanders)

        local btn = commanderSelectConfirmRect()
        local canStart = #campaign.playerCommanders > 0
        drawButton(btn.x, btn.y, btn.w, btn.h, canStart and "START BATTLE" or "PICK A COMMANDER",
            canStart and isOver(btn.x, btn.y, btn.w, btn.h, mx, my))

    elseif campaign.state == STATE.VICTORY then
        drawCollectionButton(mx, my)
        drawTitle("VICTORY", 80)
        drawSubtitle(string.format("+%d GOLD -- Total: %d G", campaign.VICTORY_GOLD, campaign.gold), 130)

        local won = campaign.cardsWonThisBattle
        if #won > 0 then
            drawSubtitle("PERMANENTLY RECRUITED FROM WAR", 165)
            drawCardGrid(won, WON_GRID_TOP_Y, WON_GRID_MAX_COLS)
        end

        local btn = actionButtonRect(victoryContinueY(campaign))
        drawButton(btn.x, btn.y, btn.w, btn.h, "CONTINUE", isOver(btn.x, btn.y, btn.w, btn.h, mx, my))

    elseif campaign.state == STATE.SHOP then
        drawCollectionButton(mx, my)
        drawTitle("FIELD SUPPLY", 40)
        drawSubtitle("GOLD: " .. campaign.gold, 85)

        local cardW, cardH, startX = shopLayout(campaign)
        for i, entry in ipairs(campaign.shop) do
            local x = startX + (i - 1) * (cardW + SHOP_CARD_GAP)
            UI.drawStaticCard(entry.card, x, SHOP_CARD_Y, cardW, cardH)

            if entry.purchased then
                love.graphics.setColor(0.5, 0.5, 0.5)
                local font = getBodyFont()
                local previous = love.graphics.getFont()
                love.graphics.setFont(font)
                love.graphics.printf("SOLD", x, SHOP_CARD_Y + cardH + 10, cardW, "center")
                love.graphics.setFont(previous)
                love.graphics.setColor(1, 1, 1)
            else
                local font = getBodyFont()
                local previous = love.graphics.getFont()
                love.graphics.setFont(font)
                love.graphics.setColor(1, 1, 1)
                love.graphics.printf(entry.price .. " G", x, SHOP_CARD_Y + cardH + 10, cardW, "center")
                love.graphics.setFont(previous)

                local canAfford = campaign.gold >= entry.price
                local by = SHOP_CARD_Y + cardH + 34
                drawButton(x, by, cardW, 32, canAfford and "BUY" or "NO GOLD",
                    canAfford and isOver(x, by, cardW, 32, mx, my))
            end
        end

        local btn = actionButtonRect(SHOP_CARD_Y + cardH + 90)
        drawButton(btn.x, btn.y, btn.w, btn.h, "CONTINUE", isOver(btn.x, btn.y, btn.w, btn.h, mx, my))

    elseif campaign.state == STATE.COMMANDER_RECRUIT then
        drawCollectionButton(mx, my)
        drawTitle("RECRUIT A COMMANDER", 40)
        drawSubtitle(string.format("%d / %d selected", #campaign.playerCommanders, campaign.MAX_PLAYER_COMMANDERS), 85)
        drawCommanderButtons(campaign.availableOpponents, mx, my)

    elseif campaign.state == STATE.BATTLE_SELECT then
        drawCollectionButton(mx, my)
        drawTitle("SELECT YOUR NEXT", 40)
        drawTitle("MILITARY ENGAGEMENT", 76)
        drawCommanderButtons(campaign.availableOpponents, mx, my)

    elseif campaign.state == STATE.CAMPAIGN_COMPLETE then
        drawTitle("CAMPAIGN COMPLETE", 80)
        drawSubtitle(table.concat(campaign.playerCommanders, ", "), 140)
        drawSubtitle("ALL COMMANDERS DEFEATED", 170)
        drawSubtitle(string.format("WINS: %d    GOLD: %d", campaign.wins, campaign.gold), 210)
        local btn = actionButtonRect(400)
        drawButton(btn.x, btn.y, btn.w, btn.h, "PLAY AGAIN", isOver(btn.x, btn.y, btn.w, btn.h, mx, my))

    elseif campaign.state == STATE.DEFEAT then
        drawTitle("YOUR ARMY HAS FALLEN", 150)
        drawSubtitle(string.format("This run: %d wins, %d gold", campaign.wins, campaign.gold), 210)
        local btn = actionButtonRect(400)
        drawButton(btn.x, btn.y, btn.w, btn.h, "START NEW RUN", isOver(btn.x, btn.y, btn.w, btn.h, mx, my))
    end

    FX.drawScanlines()
end

-- Call from love.mousepressed whenever campaign.state isn't STATE.BATTLE.
-- Returns true if the "restart the whole campaign" button was clicked --
-- main.lua creates a fresh Campaign in that case (Campaign itself has no
-- in-place reset; a fresh commander pool/deck IS Campaign.new()).
function CampaignUI.handleClick(campaign, mx, my)
    local STATE = campaign.STATE

    if campaign.state == STATE.COMMANDER_SELECT then
        for _, rect in ipairs(commanderButtonRects(Commander.ALL, COMMANDER_SELECT_CENTER_Y)) do
            if isOver(rect.x, rect.y, rect.w, rect.h, mx, my) then
                campaign:toggleCommander(rect.name)
                return false
            end
        end

        local btn = commanderSelectConfirmRect()
        if #campaign.playerCommanders > 0 and isOver(btn.x, btn.y, btn.w, btn.h, mx, my) then
            campaign:confirmCommanders()
        end

    elseif campaign.state == STATE.VICTORY then
        local collectionBtn = collectionButtonRect()
        if isOver(collectionBtn.x, collectionBtn.y, collectionBtn.w, collectionBtn.h, mx, my) then
            CollectionUI.open(campaign)
            return false
        end

        local btn = actionButtonRect(victoryContinueY(campaign))
        if isOver(btn.x, btn.y, btn.w, btn.h, mx, my) then
            campaign:enterShop()
        end

    elseif campaign.state == STATE.SHOP then
        local collectionBtn = collectionButtonRect()
        if isOver(collectionBtn.x, collectionBtn.y, collectionBtn.w, collectionBtn.h, mx, my) then
            CollectionUI.open(campaign)
            return false
        end

        local cardW, cardH, startX = shopLayout(campaign)
        for i, entry in ipairs(campaign.shop) do
            local x = startX + (i - 1) * (cardW + SHOP_CARD_GAP)
            if not entry.purchased then
                local by = SHOP_CARD_Y + cardH + 34
                if isOver(x, by, cardW, 32, mx, my) then
                    campaign:buyCard(i)
                    return false
                end
            end
        end

        local btn = actionButtonRect(SHOP_CARD_Y + cardH + 90)
        if isOver(btn.x, btn.y, btn.w, btn.h, mx, my) then
            campaign:leaveShop()
        end

    elseif campaign.state == STATE.COMMANDER_RECRUIT then
        local collectionBtn = collectionButtonRect()
        if isOver(collectionBtn.x, collectionBtn.y, collectionBtn.w, collectionBtn.h, mx, my) then
            CollectionUI.open(campaign)
            return false
        end

        for _, rect in ipairs(commanderButtonRects(campaign.availableOpponents)) do
            if isOver(rect.x, rect.y, rect.w, rect.h, mx, my) then
                campaign:recruitCommander(rect.name)
                return false
            end
        end

    elseif campaign.state == STATE.BATTLE_SELECT then
        local collectionBtn = collectionButtonRect()
        if isOver(collectionBtn.x, collectionBtn.y, collectionBtn.w, collectionBtn.h, mx, my) then
            CollectionUI.open(campaign)
            return false
        end

        for _, rect in ipairs(commanderButtonRects(campaign.availableOpponents)) do
            if isOver(rect.x, rect.y, rect.w, rect.h, mx, my) then
                campaign:selectOpponent(rect.name)
                return false
            end
        end

    elseif campaign.state == STATE.CAMPAIGN_COMPLETE or campaign.state == STATE.DEFEAT then
        local btn = actionButtonRect(400)
        if isOver(btn.x, btn.y, btn.w, btn.h, mx, my) then
            return true
        end
    end

    return false
end

return CampaignUI
