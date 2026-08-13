-- src/ui.lua
-- Rendering + mouse hit-testing. Card faces use the PNG-cards-1.3 art
-- (assets/cards/) via src/cardart.lua; hand cards and the reveal/war-pick
-- spots animate via src/animation_manager.lua ("card_hover"/"card_arc"
-- requests against src/cardview.lua views) -- this module never lerps a
-- position/scale itself, per the Animation System Specification; everything
-- else (backs, badges, sidebar, war-reveal row, spoil grid) is still drawn
-- directly from battle state each frame.

local Commander = require("src.commander")
local CardArt = require("src.cardart")
local CardView = require("src.cardview")
local AnimationManager = require("src.animation_manager")
local ScreenFX = require("src.screenfx")
local Battlefield = require("src.battlefield")
local FX = require("src.fx")
local Background = require("src.background")

local UI = {}

local CARD_W, CARD_H = 90, 125
local CARD_GAP = 12
local PLAYER_HAND_Y = 630
local ENEMY_HAND_Y = 50
local SELECTION_Y = 430
local PLAY_ANIM_DURATION = 0.25
local ENEMY_WAR_DEPLOY_DELAY = 0.18 -- pause between each enemy War card's arc+slam

-- The Twinbinder's staging lift: first/second staged card lift by different
-- amounts so, with two staged, they read as staggered rather than identical.
-- Well above the normal hover lift (13px) so staging is unmistakable.
local STAGE_LIFT_1 = 55
local STAGE_LIFT_2 = 80
local STAGE_SCALE = 1.06

local TWINBINDER_PLAY_BTN_W, TWINBINDER_PLAY_BTN_H = 140, 30
local TWINBINDER_PLAY_BTN_Y = PLAYER_HAND_Y + CARD_H + 8

local function twinbinderPlayButtonRect()
    local x = love.graphics.getWidth() / 2 - TWINBINDER_PLAY_BTN_W / 2
    return x, TWINBINDER_PLAY_BTN_Y, TWINBINDER_PLAY_BTN_W, TWINBINDER_PLAY_BTN_H
end

-- Flat row layout, matching the mockup: horizontal spacing is CARD_W +
-- CARD_GAP, centered on screen, no vertical stagger and no isometric grid.
local function rowStartX(count)
    local totalWidth = count * CARD_W + math.max(0, count - 1) * CARD_GAP
    return (love.graphics.getWidth() - totalWidth) / 2
end

local function rowPositions(count, y)
    local startX = rowStartX(count)
    local positions = {}
    for i = 1, count do
        positions[i] = { x = startX + (i - 1) * (CARD_W + CARD_GAP), y = y }
    end
    return positions
end

-- Returns the 1-based index under (mx, my) within a row of `count` slots at
-- y, or nil.
local function indexAtRow(count, y, mx, my)
    for i, pos in ipairs(rowPositions(count, y)) do
        if mx >= pos.x and mx <= pos.x + CARD_W and my >= pos.y and my <= pos.y + CARD_H then
            return i
        end
    end
    return nil
end

-- Computes a padded bounding box {x, y, w, h} around a list of {x, y}
-- top-left card positions (each CARD_W x CARD_H) -- used to size a
-- Battlefield pad around whatever row(s) are actually on screen.
local function rowBounds(positions, margin)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, pos in ipairs(positions) do
        minX = math.min(minX, pos.x)
        minY = math.min(minY, pos.y)
        maxX = math.max(maxX, pos.x + CARD_W)
        maxY = math.max(maxY, pos.y + CARD_H)
    end
    return minX - margin, minY - margin, (maxX - minX) + margin * 2, (maxY - minY) + margin * 2
end

-- War-specific rows: the player's own war hand (building it during
-- WAR_SELECT, or fully revealed during WAR_REVEAL) sits where the normal
-- selection cards would; the enemy's war hand gets a row above it, revealed
-- one card at a time.
local WAR_ROW_Y = 430
local WAR_ENEMY_ROW_Y = 175

-- The War spoil pool can hold every card revealed across however many
-- Recursive War rounds it took (Design Bible 3.8) -- easily more than fits
-- in one row -- so it's laid out as a wrapping grid starting near the top,
-- with the normal hand rows hidden for that one screen to give it room.
local SPOIL_GRID_Y = 60
local SPOIL_GRID_COLS = 6
local SPOIL_ROW_GAP = 10

-- Commander cards: compact (not a big portrait) since the player can now
-- hold up to Campaign.MAX_PLAYER_COMMANDERS (5) at once -- see
-- Battle:assignCommanders -- and they stack as a vertical column of small
-- cards in the corner rather than one big card. The enemy always holds
-- exactly one, so its "stack" is always a single card. FRONTLINE/RESERVE
-- deck-pile indicators sit below whichever side's stack.
local COMMANDER_CARD_W, COMMANDER_CARD_H = 150, 62
local COMMANDER_STACK_GAP = 4
local COMMANDER_X = 25
local ENEMY_COMMANDER_Y = 20

local DECK_ICON_W, DECK_ICON_H = 60, 70
local DECK_ICON_GAP = 8
local ENEMY_DECK_ROW_Y = ENEMY_COMMANDER_Y + COMMANDER_CARD_H + 10
-- Fixed near the bottom of the window, independent of how many commanders
-- are currently stacked above it (see playerCommanderCardY).
local PLAYER_DECK_ROW_Y = 710

-- Y for the i-th (1-based, top-to-bottom) card in the player's commander
-- stack, given `count` total -- anchored so the BOTTOM of the stack always
-- sits just above the deck-pile icons, regardless of count.
local function playerCommanderCardY(i, count)
    local stackHeight = count * COMMANDER_CARD_H + (count - 1) * COMMANDER_STACK_GAP
    local stackTop = PLAYER_DECK_ROW_Y - 10 - stackHeight
    return stackTop + (i - 1) * (COMMANDER_CARD_H + COMMANDER_STACK_GAP)
end

-- The player's RESERVE icon (second of the two deck-pile icons above the
-- player's commander card) doubles as a clickable button for
-- Battle:switchToReserves -- same trade the Q key triggers, just also
-- reachable by clicking the pile itself. Shared by the draw call and
-- UI.handleClick so a click always lands on exactly what's drawn.
local function playerReserveIconRect()
    return COMMANDER_X + DECK_ICON_W + DECK_ICON_GAP, PLAYER_DECK_ROW_Y, DECK_ICON_W, DECK_ICON_H
end

-- True while clicking (or pressing Q for) the player's reserve pile would
-- actually do something -- mirrors Battle:switchToReserves's own guards so
-- the hover glow never promises a click that would silently no-op.
local function reserveSwitchAvailable(battle)
    return battle.phase == battle.PHASE.SELECT
        and not battle.playerReserveUsed
        and not battle.playerSelection
        and not battle.playerReserveDeck:isEmpty()
end

local ACCENT_PLAYER = { 0.0, 0.85, 1.0 }  -- cyan, matches the player's battlefield/glow accent
local ACCENT_ENEMY = { 1.0, 0.25, 0.55 }  -- red/magenta, matches the enemy's accent

-- Status/log sidebar: a bordered "BATTLE LOG" panel, kept clear of the card
-- columns and drawn in a smaller font so it doesn't compete with the cards
-- for attention.
local SIDEBAR_X = 1070
local SIDEBAR_Y = 20
local SIDEBAR_W = 190
local SIDEBAR_PAD = 12
local SIDEBAR_PANEL_H = 760
local MAX_LOG_LINES = 8
local LOG_TITLE_COLOR = { 0.55, 0.85, 0.95 }
local LOG_BORDER_COLOR = { 0.35, 0.75, 0.85, 0.6 }

local BUFF_BADGE_SIZE = 22
local BUFF_COLOR_VLAD = { 0.80, 0.12, 0.12 }    -- red
local BUFF_COLOR_JOAN = { 0.90, 0.35, 0.55 }    -- pink
local BUFF_COLOR_PANCHO = { 0.95, 0.55, 0.10 }  -- amber
local BUFF_COLOR_ARISTOCRAT = { 0.75, 0.65, 0.95 } -- lavender
local BUFF_COLOR_STANDARD_BEARER = { 0.55, 0.85, 0.55 } -- green
local BUFF_COLOR_STACKED = { 1.0, 0.95, 0.4 } -- gold, when 2+ commanders both contributed
local BUFF_COLORS = {
    [Commander.VLAD] = BUFF_COLOR_VLAD,
    [Commander.PANCHO] = BUFF_COLOR_PANCHO,
    [Commander.ARISTOCRAT] = BUFF_COLOR_ARISTOCRAT,
    [Commander.STANDARD_BEARER] = BUFF_COLOR_STANDARD_BEARER,
}

-- id -> CardView, for cards currently sitting in each hand.
local playerViews = {}
local enemyViews = {}
-- left-to-right draw/hit-test order, refreshed each UI.update.
local playerOrdered = {}
local enemyOrdered = {}
-- the single card each side has committed to the current normal engagement.
local playerPlayView = nil
local enemyPlayView = nil
-- up to battle.WAR_HAND_SIZE views, index = war-hand slot position.
local playerWarViews = {}
-- the enemy's War-hand views (face-down while deploying/selecting, flipped
-- progressively during WAR_REVEAL), same index convention as playerWarViews.
local enemyWarViews = {}
-- edge-trigger flags for one-shot War-transition events (see UI.update).
local wasInWar = false
local wasFreshWarRound = false
-- edge-trigger flag for the reserve-switch confirmation banner/burst below.
local wasPlayerReserveUsed = false
-- The Twinbinder: while Battle:canCombine() is true, clicking a Number Card
-- in hand stages it (hand index) instead of playing it immediately -- it
-- lifts out of the hand row, staggered higher than a second staged card.
-- A PLAY button appears once >=1 is staged; clicking it commits whichever
-- it is (a normal single play, or Battle:combinePlayerCards for two).
-- Face Cards/Aces can't combine, so clicking one still plays it immediately
-- as long as nothing's staged yet (see handleStagingClick).
local stagedIndices = {}
-- card.id of the player hand card currently under the mouse, for FX.glow.
local hoveredPlayerId = nil
-- tracks battle.log length so a new line triggers an FX.burst exactly once.
local lastLogCount = 0

local infoFont

local function getInfoFont()
    if not infoFont then
        infoFont = love.graphics.newFont(11)
    end
    return infoFont
end

-- Small colored circle in a card's top-right corner marking an active
-- commander buff, distinctly colored per source so Vlad's and Joan's bonuses
-- read differently at a glance. w is the card's current drawn width (which
-- can be bigger than CARD_W while hovered), so the badge tracks the corner.
local function drawBuffBadge(x, y, w, amount, color)
    local bx = x + w - BUFF_BADGE_SIZE - 4
    local by = y + 4
    love.graphics.setColor(color)
    love.graphics.circle("fill", bx + BUFF_BADGE_SIZE / 2, by + BUFF_BADGE_SIZE / 2, BUFF_BADGE_SIZE / 2)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", bx + BUFF_BADGE_SIZE / 2, by + BUFF_BADGE_SIZE / 2, BUFF_BADGE_SIZE / 2)

    local font = getInfoFont()
    local previousFont = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.printf("+" .. amount, bx, by + 5, BUFF_BADGE_SIZE, "center")
    love.graphics.setFont(previousFont)
end

-- Draws `card` at an explicit rect (x, y, w, h), optionally rotated around
-- its own center (used mid-flight by card_arc) -- used directly by anything
-- animated (hover-scaled hand cards, in-flight tweens), and via the drawCard
-- wrapper below for everything still drawn at a fixed CARD_W x CARD_H slot.
-- commanders (if given) is the list held by this card's owner, for the buff
-- badge; opponentCard is what it's matched against, needed for Vlad's
-- matchup-conditional bonus and only shown once actually knowable (see call
-- sites -- passing nil here always safely suppresses it); ownerHand is the
-- owner's current hand (array of Card), needed for the Standard-Bearer/
-- Aristocrat "while holding X" bonuses.
local function drawCardRect(card, x, y, w, h, faceDown, commanders, opponentCard, rotation, ownerHand)
    love.graphics.push()
    love.graphics.translate(x + w / 2, y + h / 2)
    love.graphics.rotate(rotation or 0)
    love.graphics.translate(-w / 2, -h / 2)
    -- Everything below draws in local (0,0)-(w,h) space, unaffected by the
    -- rotation math above -- rotation is applied once, to the whole card.

    if faceDown then
        love.graphics.setColor(1, 1, 1)
        local backImage = CardArt.getBack()
        love.graphics.draw(backImage, 0, 0, 0, w / backImage:getWidth(), h / backImage:getHeight())
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("line", 0, 0, w, h, 6, 6)
        love.graphics.setColor(1, 1, 1)
        love.graphics.pop()
        return
    end

    love.graphics.setColor(1, 1, 1)
    local image = CardArt.get(card)
    love.graphics.draw(image, 0, 0, 0, w / image:getWidth(), h / image:getHeight())

    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("line", 0, 0, w, h, 6, 6)
    love.graphics.setColor(1, 1, 1)

    if commanders then
        local bonus, sources = Commander.buffSources(card, commanders, opponentCard, ownerHand)
        if bonus > 0 then
            local color = BUFF_COLOR_STACKED
            if #sources == 1 then
                color = BUFF_COLORS[sources[1]] or BUFF_COLOR_JOAN
            end
            drawBuffBadge(0, 0, w, bonus, color)
        end
    end

    love.graphics.pop()
end

local function drawCard(card, x, y, faceDown, commanders, opponentCard)
    drawCardRect(card, x, y, CARD_W, CARD_H, faceDown, commanders, opponentCard, 0)
end

-- Exposed so other screens outside the battle view (e.g. campaign_ui.lua's
-- shop, collection_ui.lua's card table) can draw a plain static card at an
-- arbitrary size without duplicating the CardArt rendering logic above.
-- rotation (radians, optional) lets the Collection menu give its dense card
-- rows a slight physical tilt without needing its own draw path.
function UI.drawStaticCard(card, x, y, w, h, rotation)
    drawCardRect(card, x, y, w, h, false, nil, nil, rotation or 0)
end

UI.CARD_W, UI.CARD_H = CARD_W, CARD_H

local SHADOW_COLOR = { 0, 0, 0, 0.35 }

-- Soft drop shadow beneath a CardView -- deliberately not rotated/tilted
-- with the card (a shadow stays flat on the battlefield); see
-- CardView:getShadowRect() for why it doesn't track hoverOffset either.
local function drawCardShadow(x, y, w, h)
    love.graphics.setColor(SHADOW_COLOR)
    love.graphics.rectangle("fill", x + 4, y + h - 8, w - 8, 14, 6, 6)
    love.graphics.setColor(1, 1, 1)
end

-- Draws a CardView's shadow, then the card itself at its current animated
-- rect/rotation (idle float + hover + any in-flight arc, all combined).
-- faceDownOverride, if not nil, wins over the view's own stored faceDown --
-- needed for the normal engagement's play views, whose face-up/down state
-- depends on battle.phase each frame (see the no-early-reveal rule below),
-- not on a fixed flag. ownerHand -- see drawCardRect.
local function drawCardView(view, faceDownOverride, commanders, opponentCard, ownerHand)
    local sx, sy, sw, sh = view:getShadowRect()
    drawCardShadow(sx, sy, sw, sh)

    local x, y, w, h = view:getDrawRect()
    local faceDown = view.faceDown
    if faceDownOverride ~= nil then faceDown = faceDownOverride end
    drawCardRect(view.card, x, y, w, h, faceDown, commanders, opponentCard, view:getRotation(), ownerHand)
end

-- Drops any tracked view whose card is no longer in `cards`, stopping its
-- continuous animations first so the manager isn't left updating an
-- abandoned target forever.
local function pruneViews(views, cards)
    local present = {}
    for _, c in ipairs(cards) do present[c.id] = true end
    for id, view in pairs(views) do
        if not present[id] then
            view:destroy()
            views[id] = nil
        end
    end
end

-- Ensures every card in `cards` has a CardView, assigns each one its real
-- flat hand-row slot as a home position (so reflow animates instead of
-- snapping), and returns them in left-to-right order for drawing.
local function syncHandViews(views, cards, handY, faceDown)
    pruneViews(views, cards)
    local positions = rowPositions(#cards, handY)
    local ordered = {}
    for i, card in ipairs(cards) do
        local pos = positions[i]
        local view = views[card.id]
        if not view then
            view = CardView.new(card, pos.x, pos.y, CARD_W, CARD_H)
            view.faceDown = faceDown
            views[card.id] = view
        end
        view.homeX, view.homeY = pos.x, pos.y
        ordered[i] = view
    end
    return ordered
end

local compactNameFont

local function getCompactNameFont()
    if not compactNameFont then
        compactNameFont = love.graphics.newFont(13)
    end
    return compactNameFont
end

-- Draws one compact commander card (name + short ability text) at an
-- explicit rect -- small enough that up to Campaign.MAX_PLAYER_COMMANDERS
-- of them can stack in a column. name == nil draws an empty placeholder
-- (shouldn't normally happen -- Battle always assigns at least one -- but
-- keeps this safe to call defensively).
local function drawCommanderCard(name, x, y, w, h, accent)
    love.graphics.setColor(0.06, 0.09, 0.12, 0.92)
    love.graphics.rectangle("fill", x, y, w, h, 5, 5)
    love.graphics.setColor(accent)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, h, 5, 5)

    if not name then
        love.graphics.setColor(1, 1, 1)
        return
    end

    local previousFont = love.graphics.getFont()

    love.graphics.setFont(getCompactNameFont())
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(name, x + 8, y + 5, w - 16, "left")

    love.graphics.setFont(getInfoFont())
    love.graphics.setColor(0.75, 0.82, 0.88, 0.95)
    local desc = Commander.DESCRIPTIONS[name]
    if desc then
        love.graphics.printf(desc, x + 8, y + 25, w - 16, "left")
    end

    love.graphics.setFont(previousFont)
    love.graphics.setColor(1, 1, 1)
end

-- Draws a side's full commander stack: a label above, then one compact card
-- per name at cardY(i, count) -- see playerCommanderCardY for the player's
-- bottom-anchored version; the enemy (always exactly one) just passes a
-- function returning the fixed ENEMY_COMMANDER_Y.
local function drawCommanderStack(names, x, accent, sideLabel, cardY)
    local font = getInfoFont()
    local previousFont = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(accent)
    local labelY = cardY(1, math.max(1, #names)) - font:getHeight() - 4
    love.graphics.printf(sideLabel, x, labelY, COMMANDER_CARD_W, "center")
    love.graphics.setFont(previousFont)
    love.graphics.setColor(1, 1, 1)

    if #names == 0 then
        drawCommanderCard(nil, x, cardY(1, 1), COMMANDER_CARD_W, COMMANDER_CARD_H, accent)
        return
    end

    for i, name in ipairs(names) do
        drawCommanderCard(name, x, cardY(i, #names), COMMANDER_CARD_W, COMMANDER_CARD_H, accent)
    end
end

-- Draws one small labeled deck-pile indicator (a bordered rect with a
-- diamond mark and a count) -- used for the FRONTLINE/RESERVE piles flanking
-- each side's commander card.
local function drawDeckIndicator(label, x, y, w, h, accent, count)
    local font = getInfoFont()
    local previousFont = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(accent)
    love.graphics.printf(label, x - 15, y - font:getHeight() - 3, w + 30, "center")

    love.graphics.setColor(0.05, 0.08, 0.10, 0.85)
    love.graphics.rectangle("fill", x, y, w, h, 4, 4)
    love.graphics.setColor(accent)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", x, y, w, h, 4, 4)

    local cx, cy = x + w / 2, y + h / 2 - 6
    local dr = math.min(w, h) * 0.16
    love.graphics.polygon("line", cx, cy - dr, cx + dr, cy, cx, cy + dr, cx - dr, cy)

    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(tostring(count), x, y + h - font:getHeight() - 5, w, "center")

    love.graphics.setFont(previousFont)
    love.graphics.setColor(1, 1, 1)
end

-- Draws empty dashed placeholders (at their real row positions) for
-- war-hand slots not yet filled by an animated CardView.
local function drawEmptyWarSlots(fromIndex, slotCount, y)
    local positions = rowPositions(slotCount, y)
    for i = fromIndex, slotCount do
        local pos = positions[i]
        love.graphics.setColor(1, 1, 1, 0.25)
        love.graphics.rectangle("line", pos.x, pos.y, CARD_W, CARD_H, 6, 6)
        love.graphics.setColor(1, 1, 1)
    end
end

-- Lays cards out in rows of SPOIL_GRID_COLS, wrapping downward -- used for
-- the War spoil choice, whose count isn't bounded to a hand-sized row.
local function drawSpoilGrid(cards, topY)
    local rowCount = #cards
    local rows = math.ceil(rowCount / SPOIL_GRID_COLS)
    for row = 0, rows - 1 do
        local cols = math.min(SPOIL_GRID_COLS, rowCount - row * SPOIL_GRID_COLS)
        local startX = rowStartX(cols)
        local y = topY + row * (CARD_H + SPOIL_ROW_GAP)
        for col = 1, cols do
            local card = cards[row * SPOIL_GRID_COLS + col]
            local x = startX + (col - 1) * (CARD_W + CARD_GAP)
            drawCard(card, x, y, false)
        end
    end
end

-- Returns the 1-based index under (mx, my) into a drawSpoilGrid layout, or nil.
local function indexAtSpoilGrid(count, topY, mx, my)
    if my < topY then return nil end
    local row = math.floor((my - topY) / (CARD_H + SPOIL_ROW_GAP))
    local rowTopY = topY + row * (CARD_H + SPOIL_ROW_GAP)
    if my > rowTopY + CARD_H then return nil end -- in the gap between rows

    local cols = math.min(SPOIL_GRID_COLS, count - row * SPOIL_GRID_COLS)
    if cols <= 0 then return nil end

    local startX = rowStartX(cols)
    for col = 1, cols do
        local cx = startX + (col - 1) * (CARD_W + CARD_GAP)
        if mx >= cx and mx <= cx + CARD_W then
            return row * SPOIL_GRID_COLS + col
        end
    end
    return nil
end

local function phaseHint(battle)
    if #stagedIndices > 0 then
        return string.format("Twinbinder: %d/2 staged -- click PLAY to commit (Esc to cancel).", #stagedIndices)
    end
    if battle.phase == battle.PHASE.WAR_SELECT then
        return string.format("War! Pick %d cards from your hand, in reveal order (%d/%d chosen).",
            battle.WAR_HAND_SIZE, #battle.playerWarHand, battle.WAR_HAND_SIZE)
    elseif battle.phase == battle.PHASE.WAR_REVEAL then
        return string.format("War reveal -- wins so far: You %d, Enemy %d",
            battle.warPlayerWins, battle.warEnemyWins)
    elseif battle.phase == battle.PHASE.WAR_SPOIL then
        return string.format("You won the War! Click one of the %d cards to recruit it.",
            #battle.warSpoilChoices)
    end
    return nil
end

-- Draws a small centered flourish label (e.g. "YOUR HAND") flanked by
-- diamond marks, matching the mockup's section headers.
local function drawSectionLabel(text, y)
    local font = getInfoFont()
    local previousFont = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(LOG_TITLE_COLOR)
    love.graphics.printf("\226\151\134  " .. text .. "  \226\151\134", 0, y, love.graphics.getWidth(), "center")
    love.graphics.setFont(previousFont)
    love.graphics.setColor(1, 1, 1)
end

-- Draws phase/deck-count/log info in a bordered "BATTLE LOG" panel, in a
-- smaller font than the rest of the UI, well clear of the card columns. The
-- panel background/border/title are drawn first (fixed height, generous
-- enough for MAX_LOG_LINES) so the log text always draws on top of it. Line
-- spacing is measured from the font's own word-wrap so long log lines never
-- overlap the line below them.
local function drawSidebar(battle)
    local font = getInfoFont()
    local previousFont = love.graphics.getFont()

    love.graphics.setColor(0.04, 0.06, 0.09, 0.55)
    love.graphics.rectangle("fill", SIDEBAR_X, SIDEBAR_Y, SIDEBAR_W, SIDEBAR_PANEL_H, 6, 6)
    love.graphics.setColor(LOG_BORDER_COLOR)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", SIDEBAR_X, SIDEBAR_Y, SIDEBAR_W, SIDEBAR_PANEL_H, 6, 6)

    love.graphics.setFont(font)
    love.graphics.setColor(LOG_TITLE_COLOR)
    love.graphics.printf("BATTLE LOG", SIDEBAR_X, SIDEBAR_Y + 10, SIDEBAR_W, "center")
    love.graphics.setColor(0.35, 0.75, 0.85, 0.4)
    love.graphics.line(SIDEBAR_X + 10, SIDEBAR_Y + 30, SIDEBAR_X + SIDEBAR_W - 10, SIDEBAR_Y + 30)

    local innerX = SIDEBAR_X + SIDEBAR_PAD
    local innerW = SIDEBAR_W - SIDEBAR_PAD * 2
    local lineHeight = font:getHeight()
    local y = SIDEBAR_Y + 38

    local function printLine(text, color)
        love.graphics.setColor(color or { 1, 1, 1 })
        local _, wrapped = font:getWrap(text, innerW)
        love.graphics.printf(text, innerX, y, innerW)
        y = y + math.max(1, #wrapped) * lineHeight
    end

    printLine("Phase: " .. battle.phase)
    local hint = phaseHint(battle)
    if hint then
        printLine(hint)
    end
    y = y + lineHeight * 0.5

    printLine("Player deck: " .. battle.playerDeck:count())
    printLine("Enemy deck: " .. battle.enemyDeck:count())
    y = y + lineHeight * 0.5

    if battle.playerReserveUsed then
        printLine("Reserves: used")
    else
        printLine("Reserves: " .. battle.playerReserveDeck:count() .. " (Q or click RESERVE)")
    end
    y = y + lineHeight * 0.5

    if Commander.hasCommander(battle.playerCommanders, Commander.TWINBINDER) then
        local left = Commander.TWINBINDER_USES_PER_BATTLE - battle.playerCombinesUsed
        printLine("Twinbinder combines: " .. left .. " left (click a Number Card)")
        y = y + lineHeight * 0.5
    end

    local startIndex = math.max(1, #battle.log - MAX_LOG_LINES + 1)
    for i = startIndex, #battle.log do
        local line = battle.log[i]
        local color = { 0.85, 0.85, 0.9 }
        if line:find("^player wins") or line:find("^You win") or line:find("^You permanently recruit") then
            color = { 0.4, 0.85, 1.0 }
        elseif line:find("^enemy wins") or line:find("^Enemy wins") or line:find("^Enemy permanently recruits") then
            color = { 1.0, 0.5, 0.85 }
        end
        printLine(line, color)
    end

    love.graphics.setFont(previousFont)
    love.graphics.setColor(1, 1, 1)
end

-- Returns the 1-based hand index under (mx, my), or nil.
function UI.getHandCardIndexAt(hand, handY, mx, my)
    return indexAtRow(#hand.cards, handY, mx, my)
end

-- Destroys and clears every view in a war-hand-view table (used whenever a
-- War round ends or restarts, so stale views don't linger or leak follows).
local function clearWarViews(views)
    for _, view in pairs(views) do view:destroy() end
end

-- Deploys the enemy's War-hand cards face-down, one at a time, per the
-- spec's "War Card Deployment": arc, slam, short delay, repeat. The cards
-- are already secretly chosen (battle.enemyWarHand is fully populated the
-- moment the round starts) -- this only stages their VISUAL entrance, it
-- doesn't touch game state. Recurses via card_arc's onSettled callback.
local function deployEnemyWarCard(battle, index)
    if index > #battle.enemyWarHand then return end

    local card = battle.enemyWarHand[index]
    local slot = rowPositions(battle.WAR_HAND_SIZE, WAR_ENEMY_ROW_Y)[index]
    local view = CardView.new(card, love.graphics.getWidth() / 2, ENEMY_HAND_Y, CARD_W, CARD_H)
    view.faceDown = true
    enemyWarViews[index] = view

    AnimationManager.play("card_arc", view, {
        x = slot.x,
        y = slot.y,
        onSettled = function()
            Battlefield.spawnGlow(slot.x, slot.y, CARD_W, CARD_H, "enemy")
            Battlefield.ripple(slot.x + CARD_W / 2, slot.y + CARD_H / 2, "enemy")
            AnimationManager.animate(ENEMY_WAR_DEPLOY_DELAY, AnimationManager.EASE_LINEAR, function() end, function()
                deployEnemyWarCard(battle, index + 1)
            end)
        end,
    })
end

-- Fires an FX.burst() for every battle.log line added since the last check,
-- colored by what happened, at wherever the reveal cards currently sit (or
-- the Battle Pad center if nothing's there right now, e.g. a War log line).
local function checkForResolutionBurst(battle)
    if #battle.log < lastLogCount then lastLogCount = 0 end -- battle was restarted

    local burstX, burstY
    if playerPlayView then
        burstX, burstY = playerPlayView.x + CARD_W / 2, playerPlayView.y + CARD_H / 2
    else
        local cx = love.graphics.getWidth() / 2
        burstX, burstY = cx, SELECTION_Y + CARD_H / 2
    end

    for i = lastLogCount + 1, #battle.log do
        local line = battle.log[i]
        local color = { 1, 0.9, 0.4 } -- War / default
        if line:find("^player wins") or line:find("^You win") or line:find("^You permanently recruit") then
            color = { 0.0, 0.85, 1.0 } -- cyan, matches the player accent elsewhere
        elseif line:find("^enemy wins") or line:find("^Enemy wins") or line:find("^Enemy permanently recruits") then
            color = { 1.0, 0.15, 0.85 } -- magenta, matches the enemy accent elsewhere
        end
        FX.burst(burstX, burstY, color, 22)
    end
    lastLogCount = #battle.log
end

-- Call once per love.update(dt), alongside battle:update(dt). Order between
-- the two doesn't matter -- this only reads battle state. Issues this
-- frame's animation requests (hover, fly-to-slot for a newly committed
-- engagement card or a newly picked War-hand card), then advances the
-- AnimationManager so everything requested actually moves this frame.
function UI.update(battle, dt)
    checkForResolutionBurst(battle)

    -- Confirms a reserve switch actually happened -- a banner plus a burst
    -- at the RESERVE icon, triggered the instant Battle:switchToReserves
    -- flips this flag, regardless of whether it was Q or a click that did
    -- it (see main.lua's keypressed and UI.handleClick).
    if battle.playerReserveUsed and not wasPlayerReserveUsed then
        local rx, ry, rw, rh = playerReserveIconRect()
        FX.burst(rx + rw / 2, ry + rh / 2, { ACCENT_PLAYER[1], ACCENT_PLAYER[2], ACCENT_PLAYER[3] }, 26)
        AnimationManager.play("info_banner", nil, { text = "RESERVES DEPLOYED", color = ACCENT_PLAYER })
    end
    wasPlayerReserveUsed = battle.playerReserveUsed

    -- Safety net: if cards are somehow still staged when combining is no
    -- longer valid (phase moved on, uses ran out), drop them rather than
    -- leave a stale selection hint on screen.
    if #stagedIndices > 0 and not battle:canCombine() then
        UI.cancelStaging()
    end

    -- Capture "where was this card in the hand" BEFORE syncHandViews prunes
    -- it out (selecting a card removes it from Hand immediately), so any
    -- new card_arc request starts from the real slot instead of a
    -- guessed spot.
    local capturedPlayerFrom = battle.playerSelection and playerViews[battle.playerSelection.id]
    local capturedEnemyFrom = battle.enemySelection and enemyViews[battle.enemySelection.id]
    local capturedWarFrom = {}
    for i, card in ipairs(battle.playerWarHand) do
        if not playerWarViews[i] then
            capturedWarFrom[i] = playerViews[card.id]
        end
    end

    playerOrdered = syncHandViews(playerViews, battle.playerHand.cards, PLAYER_HAND_Y, false)
    enemyOrdered = syncHandViews(enemyViews, battle.enemyHand.cards, ENEMY_HAND_Y, true)

    -- Hover lift on the player's hand, only while clicking a card there
    -- would actually do something (playing an engagement card, or still
    -- picking War-hand cards). Staged cards (Twinbinder) are excluded --
    -- they get a fixed staggered lift instead, driven directly below,
    -- rather than fighting the hover follow every frame.
    local canClickHand = battle.phase == battle.PHASE.SELECT
        or (battle.phase == battle.PHASE.WAR_SELECT and #battle.playerWarHand < battle.WAR_HAND_SIZE)
    local mx, my = love.mouse.getPosition()
    hoveredPlayerId = nil
    for i, view in ipairs(playerOrdered) do
        local stagedSlot = nil
        for slot, index in ipairs(stagedIndices) do
            if index == i then stagedSlot = slot end
        end

        if stagedSlot then
            view.hoverTargetOffset = -(stagedSlot == 1 and STAGE_LIFT_1 or STAGE_LIFT_2)
            view.hoverTargetScale = STAGE_SCALE
        else
            local isOver = canClickHand
                and mx >= view.homeX and mx <= view.homeX + CARD_W
                and my >= PLAYER_HAND_Y and my <= PLAYER_HAND_Y + CARD_H
            AnimationManager.play("card_hover", view, { hovering = isOver })
            if isOver then hoveredPlayerId = view.card.id end
        end
    end

    -- Normal-engagement fly-in: requested the moment a selection appears,
    -- dropped once battle clears it (end of the REVEAL hold or a tie into War).
    local revealSlots = rowPositions(2, SELECTION_Y)
    local playerSlot, enemySlot = revealSlots[1], revealSlots[2]

    if battle.playerSelection and not playerPlayView then
        local from = capturedPlayerFrom
        playerPlayView = CardView.new(battle.playerSelection,
            from and from.x or playerSlot.x, from and from.y or PLAYER_HAND_Y, CARD_W, CARD_H)
        AnimationManager.play("card_arc", playerPlayView, {
            x = playerSlot.x, y = playerSlot.y, duration = PLAY_ANIM_DURATION,
            onSettled = function()
                Battlefield.spawnGlow(playerSlot.x, playerSlot.y, CARD_W, CARD_H, "player")
                Battlefield.ripple(playerSlot.x + CARD_W / 2, playerSlot.y + CARD_H / 2, "player")
            end,
        })
    elseif not battle.playerSelection and playerPlayView then
        playerPlayView:destroy()
        playerPlayView = nil
    end

    if battle.enemySelection and not enemyPlayView then
        local from = capturedEnemyFrom
        enemyPlayView = CardView.new(battle.enemySelection,
            from and from.x or enemySlot.x, from and from.y or ENEMY_HAND_Y, CARD_W, CARD_H)
        AnimationManager.play("card_arc", enemyPlayView, {
            x = enemySlot.x, y = enemySlot.y, duration = PLAY_ANIM_DURATION,
            onSettled = function()
                Battlefield.spawnGlow(enemySlot.x, enemySlot.y, CARD_W, CARD_H, "enemy")
                Battlefield.ripple(enemySlot.x + CARD_W / 2, enemySlot.y + CARD_H / 2, "enemy")
            end,
        })
    elseif not battle.enemySelection and enemyPlayView then
        enemyPlayView:destroy()
        enemyPlayView = nil
    end

    -- War-wide screen drama (Design Bible 3.8 / Animation Spec "War
    -- Animation"): zoom+darken+"WAR" banner fire once on entering any of the
    -- War phases, and relax back to normal (plus a result banner) once we
    -- leave them -- this spans every Recursive War round and the spoil pick
    -- as one continuous "different mode," not re-triggered per round.
    local isInWar = battle:isInWar()
    if isInWar and not wasInWar then
        AnimationManager.play("war_start", nil, {})
    elseif not isInWar and wasInWar then
        AnimationManager.play("war_end", nil, {})
        if battle.warWinner then
            local text = battle.warWinner == "player" and "PLAYER WINS WAR" or "ENEMY WINS WAR"
            AnimationManager.play("war_result_banner", nil, { text = text })
        end
    end
    wasInWar = isInWar

    -- War-hand fly-ins: one per chosen card, flying to its slot index.
    -- Reset at the start of each fresh War round (including a Recursive War
    -- restart) so stale views from a prior round don't linger. The enemy's
    -- side gets its own staggered face-down deployment (see
    -- deployEnemyWarCard) triggered on the same fresh-round edge, so it
    -- replays for every Recursive War round too, not just the first.
    local isFreshWarRound = battle.phase == battle.PHASE.WAR_SELECT and #battle.playerWarHand == 0
    if isFreshWarRound and not wasFreshWarRound then
        clearWarViews(playerWarViews)
        playerWarViews = {}
        clearWarViews(enemyWarViews)
        enemyWarViews = {}
        deployEnemyWarCard(battle, 1)
    end
    wasFreshWarRound = isFreshWarRound

    if battle.phase == battle.PHASE.WAR_SELECT or battle.phase == battle.PHASE.WAR_REVEAL then
        local playerWarSlots = rowPositions(battle.WAR_HAND_SIZE, WAR_ROW_Y)
        for i, card in ipairs(battle.playerWarHand) do
            if not playerWarViews[i] then
                local from = capturedWarFrom[i]
                local slot = playerWarSlots[i]
                local view = CardView.new(card,
                    from and from.x or slot.x, from and from.y or PLAYER_HAND_Y, CARD_W, CARD_H)
                AnimationManager.play("card_arc", view, {
                    x = slot.x, y = slot.y, duration = PLAY_ANIM_DURATION,
                    onSettled = function()
                        Battlefield.spawnGlow(slot.x, slot.y, CARD_W, CARD_H, "player")
                        Battlefield.ripple(slot.x + CARD_W / 2, slot.y + CARD_H / 2, "player")
                    end,
                })
                playerWarViews[i] = view
            end
        end

        -- Safety net: if WAR_REVEAL arrives before the enemy's staggered
        -- deployment finished (a very fast player), fill in any missing
        -- views instantly rather than showing gaps during the reveal.
        if battle.phase == battle.PHASE.WAR_REVEAL then
            local enemyWarSlots = rowPositions(#battle.enemyWarHand, WAR_ENEMY_ROW_Y)
            for i, card in ipairs(battle.enemyWarHand) do
                if not enemyWarViews[i] then
                    local slot = enemyWarSlots[i]
                    local view = CardView.new(card, slot.x, slot.y, CARD_W, CARD_H)
                    view.faceDown = true
                    enemyWarViews[i] = view
                end
            end
        end
    else
        if next(playerWarViews) then
            clearWarViews(playerWarViews)
            playerWarViews = {}
        end
        if next(enemyWarViews) then
            clearWarViews(enemyWarViews)
            enemyWarViews = {}
        end
    end

    -- AnimationManager.update(dt) is driven once per frame from main.lua's
    -- love.update now (not here) -- src/collection_ui.lua also drives
    -- CardViews through the same singleton AnimationManager, including while
    -- this battle screen isn't even the active one, so it needs to advance
    -- every frame regardless of campaign.state, not just during BATTLE.
end

function UI.draw(battle)
    love.graphics.clear(0.02, 0.03, 0.05) -- dark navy command-map backdrop

    -- War Animation: the whole scene zooms slightly toward center while a
    -- War is active (see ScreenFX/"war_start"). Applied as a transform
    -- around everything below; the darken overlay and banner are drawn
    -- afterward, outside this transform, so they stay crisp full-screen.
    local zoom = ScreenFX.getZoom()
    love.graphics.push()
    if zoom ~= 1 then
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        love.graphics.translate(w / 2, h / 2)
        love.graphics.scale(zoom, zoom)
        love.graphics.translate(-w / 2, -h / 2)
    end

    -- Procedural animated geometric background (src/background.lua) --
    -- purely decorative, reads no battle state, drawn before everything else.
    Background.draw()

    if battle.phase == battle.PHASE.WAR_SPOIL then
        -- Full screen given to the (potentially large) spoil grid; the
        -- ongoing hands aren't relevant to this one choice screen.
        drawSpoilGrid(battle.warSpoilChoices, SPOIL_GRID_Y)
    else
        -- The Battle Pad (normal engagements) and War Pad (Wars) are two
        -- distinct zones on the field -- only one is ever active at a time
        -- (they'd otherwise overlap the same vertical band), so whichever
        -- matches the current phase is drawn behind the cards.
        local isWarPhase = battle.phase == battle.PHASE.WAR_SELECT
            or battle.phase == battle.PHASE.WAR_REVEAL
        if isWarPhase then
            local positions = rowPositions(battle.WAR_HAND_SIZE, WAR_ENEMY_ROW_Y)
            for _, pos in ipairs(rowPositions(battle.WAR_HAND_SIZE, WAR_ROW_Y)) do
                table.insert(positions, pos)
            end
            local padX, padY, padW, padH = rowBounds(positions, 70)
            Battlefield.drawPad(padX, padY, padW, padH, "WAR ZONE")
        else
            local padX, padY, padW, padH = rowBounds(rowPositions(2, SELECTION_Y), 70)
            Battlefield.drawPad(padX, padY, padW, padH, "BATTLEFIELD")
        end
        Battlefield.drawRipples()

        drawSectionLabel("YOUR HAND", PLAYER_HAND_Y - 22)

        for _, view in ipairs(enemyOrdered) do drawCardView(view) end

        -- Glow behind the hovered hand card, drawn under it.
        for _, view in ipairs(playerOrdered) do
            if view.card.id == hoveredPlayerId then
                local x, y, w, h = view:getDrawRect()
                FX.glow(x, y, w, h, { 0.0, 0.85, 1.0 }, 5)
            end
        end
        -- Amber glow on cards currently staged for The Twinbinder.
        for i, view in ipairs(playerOrdered) do
            for _, stagedIndex in ipairs(stagedIndices) do
                if stagedIndex == i then
                    local x, y, w, h = view:getDrawRect()
                    FX.glow(x, y, w, h, { 1.0, 0.75, 0.15 }, 6)
                end
            end
        end
        for _, view in ipairs(playerOrdered) do drawCardView(view, nil, battle.playerCommanders, nil, battle.playerHand.cards) end

        if #stagedIndices > 0 then
            local bx, by, bw, bh = twinbinderPlayButtonRect()
            local mx, my = love.mouse.getPosition()
            local hovered = mx >= bx and mx <= bx + bw and my >= by and my <= by + bh

            love.graphics.setColor(0.10, 0.16, 0.20)
            love.graphics.rectangle("fill", bx, by, bw, bh, 5, 5)
            love.graphics.setColor(hovered and { 1.0, 0.85, 0.2 } or { 0.75, 0.6, 0.15 })
            love.graphics.setLineWidth(hovered and 3 or 2)
            love.graphics.rectangle("line", bx, by, bw, bh, 5, 5)

            local font = getInfoFont()
            local previousFont = love.graphics.getFont()
            love.graphics.setFont(font)
            love.graphics.setColor(1, 1, 1)
            local label = #stagedIndices == 2 and "PLAY COMBINED" or "PLAY"
            love.graphics.printf(label, bx, by + bh / 2 - font:getHeight() / 2, bw, "center")
            love.graphics.setFont(previousFont)
            love.graphics.setColor(1, 1, 1)
        end

        drawCommanderStack(battle.enemyCommanders, COMMANDER_X, ACCENT_ENEMY, "ENEMY COMMANDER",
            function(_, _) return ENEMY_COMMANDER_Y end)
        drawDeckIndicator("FRONTLINE", COMMANDER_X, ENEMY_DECK_ROW_Y, DECK_ICON_W, DECK_ICON_H, ACCENT_ENEMY, battle.enemyDeck:count())
        drawDeckIndicator("RESERVE", COMMANDER_X + DECK_ICON_W + DECK_ICON_GAP, ENEMY_DECK_ROW_Y, DECK_ICON_W, DECK_ICON_H, ACCENT_ENEMY, battle.enemyReserveDeck:count())

        drawDeckIndicator("FRONTLINE", COMMANDER_X, PLAYER_DECK_ROW_Y, DECK_ICON_W, DECK_ICON_H, ACCENT_PLAYER, battle.playerDeck:count())

        local reserveX, reserveY, reserveW, reserveH = playerReserveIconRect()
        if reserveSwitchAvailable(battle) then
            local mx, my = love.mouse.getPosition()
            local hovered = mx >= reserveX and mx <= reserveX + reserveW and my >= reserveY and my <= reserveY + reserveH
            FX.glow(reserveX, reserveY, reserveW, reserveH, ACCENT_PLAYER, hovered and 6 or 2.5)
        end
        drawDeckIndicator("RESERVE", reserveX, reserveY, reserveW, reserveH, ACCENT_PLAYER, battle.playerReserveDeck:count())
        drawCommanderStack(battle.playerCommanders, COMMANDER_X, ACCENT_PLAYER,
            #battle.playerCommanders > 1 and "PLAYER COMMANDERS" or "PLAYER COMMANDER", playerCommanderCardY)

        if battle.phase == battle.PHASE.WAR_SELECT then
            -- Always face-up: these are the player's own picks, no info to
            -- hide. No opponent cards exist yet this round, so only Joan's
            -- unconditional Hearts buff (not Vlad's matchup-based one) shows.
            for _, view in ipairs(playerWarViews) do
                drawCardView(view, false, battle.playerCommanders, nil, battle.playerHand.cards)
            end
            drawEmptyWarSlots(#playerWarViews + 1, battle.WAR_HAND_SIZE, WAR_ROW_Y)

            -- The enemy's committed cards deploy face-down, one at a time
            -- (see deployEnemyWarCard) -- visible proof they've committed,
            -- without leaking what they played.
            for _, view in ipairs(enemyWarViews) do
                drawCardView(view, true)
            end

        elseif battle.phase == battle.PHASE.WAR_REVEAL then
            -- The player's own row only gets Vlad's opponent-matchup bonus
            -- for positions the enemy card has actually been revealed at --
            -- otherwise seeing "+3" would tip off that the hidden enemy card
            -- is a Heart before it's supposed to be visible.
            local revealedEnemyCards = {}
            for i = 1, #battle.enemyWarHand do
                revealedEnemyCards[i] = (i <= battle.warRevealIndex) and battle.enemyWarHand[i] or nil
            end
            for i, view in ipairs(playerWarViews) do
                drawCardView(view, false, battle.playerCommanders, revealedEnemyCards[i], battle.playerHand.cards)
            end
            for i, view in ipairs(enemyWarViews) do
                local faceDown = i > battle.warRevealIndex
                drawCardView(view, faceDown, battle.enemyCommanders, battle.playerWarHand[i], battle.enemyHand.cards)
            end

        else
            -- Normal engagement selection/reveal/resolve. Neither side's card
            -- is shown face-up until both are locked in (REVEAL phase
            -- onward) -- otherwise whichever side commits first (usually the
            -- AI, which picks almost instantly) would leak its card to the
            -- other side while they're still deciding. The play views' own
            -- faceDown is overridden every frame from `revealed` rather than
            -- trusted as a fixed flag, specifically to preserve that rule.
            local revealed = battle.phase == battle.PHASE.REVEAL
                or battle.phase == battle.PHASE.RESOLVE
                or battle.phase == battle.PHASE.GAME_OVER

            if playerPlayView then
                local x, y, w, h = playerPlayView:getDrawRect()
                FX.glow(x, y, w, h, ACCENT_PLAYER, 3)
                drawCardView(playerPlayView, not revealed, battle.playerCommanders, battle.enemySelection, battle.playerHand.cards)
            end
            if enemyPlayView then
                local x, y, w, h = enemyPlayView:getDrawRect()
                FX.glow(x, y, w, h, ACCENT_ENEMY, 3)
                drawCardView(enemyPlayView, not revealed, battle.enemyCommanders, battle.playerSelection, battle.enemyHand.cards)
            end
        end

        -- Landing glows draw over the cards -- a flash reacting to the
        -- card, not sitting underneath it.
        Battlefield.drawGlows()

        -- Ambient + resolution-burst particles, drawn over cards so bursts
        -- read as being "in front."
        FX.drawParticles()
    end

    drawSidebar(battle)

    if battle.phase == battle.PHASE.GAME_OVER then
        love.graphics.printf("GAME OVER -- Winner: " .. battle.winner .. "  (press R to restart)",
            0, love.graphics.getHeight() / 2, love.graphics.getWidth(), "center")
    end

    love.graphics.pop() -- close the zoom transform opened at the top

    -- Darken overlay + "WAR"/"...WINS WAR" banner, drawn full-screen and
    -- outside the zoom so they're always crisp regardless of zoom level.
    ScreenFX.draw()

    -- Scanlines are a screen/monitor artifact, not part of the in-world
    -- scene -- drawn last, outside the zoom, so they never scale with it.
    FX.drawScanlines()
end

-- Clears any in-progress Twinbinder staging without playing anything --
-- called on Escape (main.lua's keypressed) and as a safety net in UI.update.
function UI.cancelStaging()
    stagedIndices = {}
end

-- Commits whatever's currently staged: a normal single play if only one
-- card was staged, or Battle:combinePlayerCards if two were. Called when
-- the PLAY button is clicked.
local function commitStaged(battle)
    if #stagedIndices == 1 then
        if battle.phase == battle.PHASE.SELECT then
            battle:playerChoose(stagedIndices[1])
        elseif battle.phase == battle.PHASE.WAR_SELECT then
            battle:pickWarCard(stagedIndices[1])
        end
    elseif #stagedIndices == 2 then
        battle:combinePlayerCards(stagedIndices[1], stagedIndices[2])
    end
    stagedIndices = {}
end

-- Handles a hand-card click while Battle:canCombine() is true. A Number
-- Card toggles staged/unstaged (up to 2 at once); a Face Card or Ace can
-- never combine, so it plays immediately if nothing's staged yet, or gets
-- rejected (not silently ignored) if something already is.
local function handleStagingClick(battle, index)
    local card = battle.playerHand.cards[index]
    if not card then return end

    for slot, stagedIndex in ipairs(stagedIndices) do
        if stagedIndex == index then
            table.remove(stagedIndices, slot)
            return
        end
    end

    if not card:isNumberCard() then
        if #stagedIndices == 0 then
            if battle.phase == battle.PHASE.SELECT then
                battle:playerChoose(index)
            else
                battle:pickWarCard(index)
            end
        else
            AnimationManager.play("info_banner", nil, { text = "NUMBER CARDS ONLY", color = { 1.0, 0.3, 0.3 } })
        end
        return
    end

    if #stagedIndices >= 2 then return end
    table.insert(stagedIndices, index)
end

-- Call from love.mousepressed. Hit-testing stays index-based against the
-- static hand grid (independent of any hover/tween animation offset), so
-- clicks stay accurate regardless of what's mid-animation.
function UI.handleClick(battle, mx, my)
    if #stagedIndices > 0 then
        local bx, by, bw, bh = twinbinderPlayButtonRect()
        if mx >= bx and mx <= bx + bw and my >= by and my <= by + bh then
            commitStaged(battle)
            return
        end
    end

    if battle.phase == battle.PHASE.SELECT then
        if reserveSwitchAvailable(battle) then
            local rx, ry, rw, rh = playerReserveIconRect()
            if mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh then
                battle:switchToReserves("player")
                return
            end
        end

        local index = UI.getHandCardIndexAt(battle.playerHand, PLAYER_HAND_Y, mx, my)
        if index then
            if battle:canCombine() then
                handleStagingClick(battle, index)
            else
                battle:playerChoose(index)
            end
        end

    elseif battle.phase == battle.PHASE.WAR_SELECT then
        local index = UI.getHandCardIndexAt(battle.playerHand, PLAYER_HAND_Y, mx, my)
        if index then
            if battle:canCombine() then
                handleStagingClick(battle, index)
            else
                battle:pickWarCard(index)
            end
        end

    elseif battle.phase == battle.PHASE.WAR_SPOIL then
        local index = indexAtSpoilGrid(#battle.warSpoilChoices, SPOIL_GRID_Y, mx, my)
        if index then
            battle:chooseWarSpoil(index)
        end
    end
end

return UI
