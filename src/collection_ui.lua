-- src/collection_ui.lua
-- Card Collection / Deck Inspection overlay: lets the player review their
-- full persistent collection (src/campaign.lua's Campaign.deck -- the ONE
-- source of truth for card ownership) split into FRONTLINE / RESERVE / ALL
-- CARDS, and move cards between Frontline and Reserve for their next battle.
-- Pure inspection until a MOVE button is explicitly clicked: opening,
-- closing, switching tabs, sorting, and scrolling never touch Campaign
-- state.
--
-- This is an overlay, not a campaign STATE -- it draws on top of whatever
-- screen main.lua already rendered (battle or a campaign_ui screen) and
-- intercepts input while open, same idea as ScreenFX's darken/banner layer
-- but interactive. Reuses the game's existing systems rather than building
-- parallel ones: CardArt for faces (via UI.drawStaticCard), CardView +
-- AnimationManager for the hover-lift "picked up off the table" feel
-- already used for hand cards, and ScreenFX's "info_banner" animation for
-- move confirmations.

local Card = require("src.card")
local CardView = require("src.cardview")
local AnimationManager = require("src.animation_manager")
local UI = require("src.ui")
local ScreenFX = require("src.screenfx")
local Campaign = require("src.campaign")

local CollectionUI = {}

-- ===== Palette (matches ui.lua/campaign_ui.lua's existing cyan command-map look) =====
local ACCENT_PLAYER = { 0.0, 0.85, 1.0 }
local BTN_FILL = { 0.08, 0.13, 0.17 }
local BTN_BORDER = { 0.35, 0.75, 0.85 }
local BTN_ACTIVE_BORDER = { 0.0, 0.85, 1.0 }
local BTN_ACTIVE_FILL = { 0.05, 0.35, 0.42 }
local SHADOW_COLOR = { 0, 0, 0, 0.35 }

-- ===== Layout constants =====
local PANEL_MARGIN = 30
local HEADER_H = 148
local GRID_PAD = 18
local CARD_W, CARD_H = 76, 106
local COL_STEP = CARD_W * 0.66 -- horizontal distance between card starts in a row (~34% overlap)
local ROW_GAP = 24
local MAX_TILT_DEG = 4

local MODAL_W, MODAL_H = 340, 480
local MODAL_CARD_W, MODAL_CARD_H = 150, 210
local MODAL_BTN_W, MODAL_BTN_H, MODAL_BTN_GAP = 260, 38, 10

local TABS = {
    { id = "FRONTLINE", label = "FRONTLINE" },
    { id = "RESERVE", label = "RESERVE" },
    { id = "ALL", label = "ALL CARDS" },
}
local SORT_MODES = { "RANK", "SUIT", "STRENGTH", "TYPE" }
local FILTER_MODES = { "ALL", "FRONTLINE", "RESERVE" }
local RANK_ORDER = Card.RANK_STRENGTH
local SUIT_ORDER = { Hearts = 1, Diamonds = 2, Clubs = 3, Spades = 4 }

-- ===== Module state (a single overlay instance, same convention ui.lua
-- uses for its own module-level playerViews/enemyViews etc.) =====
local isOpenFlag = false
local activeTab = "FRONTLINE"
local sortMode = "RANK"
local scrollY = 0
local contentHeight, visibleHeight = 0, 0
local selectedGroupKey = nil -- non-nil while the inspect modal is open
local hoveredKey = nil
local groupViews = {} -- group key -> CardView, for the dense card table
local state = { openProgress = 0, gridOffsetY = 0 } -- AnimationManager tween targets

-- ===== Fonts (cached, same lazy-getter pattern as ui.lua/campaign_ui.lua) =====
local titleFont, tabFont, statFont, smallFont

local function getTitleFont()
    if not titleFont then titleFont = love.graphics.newFont(22) end
    return titleFont
end
local function getTabFont()
    if not tabFont then tabFont = love.graphics.newFont(15) end
    return tabFont
end
local function getStatFont()
    if not statFont then statFont = love.graphics.newFont(13) end
    return statFont
end
local function getSmallFont()
    if not smallFont then smallFont = love.graphics.newFont(11) end
    return smallFont
end

-- ===== Small pure helpers =====
local function isOver(rect, mx, my)
    return mx >= rect.x and mx <= rect.x + rect.w and my >= rect.y and my <= rect.y + rect.h
end

-- Stable per-group tilt (radians), derived from the group's own identity
-- key rather than re-rolled every frame, so the "physical table" jitter
-- doesn't flicker or reshuffle on every redraw.
local function seededAngle(key)
    local hash = 0
    for i = 1, #key do
        hash = (hash * 31 + string.byte(key, i)) % 1000003
    end
    local t = (hash % 1000) / 1000
    return math.rad((t - 0.5) * 2 * MAX_TILT_DEG)
end

local function panelRect()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    return PANEL_MARGIN, PANEL_MARGIN, w - PANEL_MARGIN * 2, h - PANEL_MARGIN * 2
end

local function gridRect()
    local px, py, pw, ph = panelRect()
    return px + GRID_PAD, py + HEADER_H, pw - GRID_PAD * 2, ph - HEADER_H - GRID_PAD
end

-- ===== Header control rects -- single source of truth shared by draw and
-- handleClick, same idiom as campaign_ui.lua's commanderButtonRects/
-- actionButtonRect. =====
local function tabRects(px, py, pw)
    local w, h, gap = 200, 32, 14
    local totalW = w * 3 + gap * 2
    local startX = px + (pw - totalW) / 2
    local y = py + 34
    local rects = {}
    for i, tab in ipairs(TABS) do
        rects[i] = { x = startX + (i - 1) * (w + gap), y = y, w = w, h = h, id = tab.id, label = tab.label }
    end
    return rects
end

local function statRects(px, py, pw)
    local w, gap = 260, 20
    local totalW = w * 3 + gap * 2
    local startX = px + (pw - totalW) / 2
    local y = py + 74
    return {
        { x = startX, y = y, w = w, h = 36, label = "FRONTLINE" },
        { x = startX + (w + gap), y = y, w = w, h = 36, label = "RESERVE" },
        { x = startX + (w + gap) * 2, y = y, w = w, h = 36, label = "TOTAL" },
    }
end

local function sortRects(px, py, pw)
    local w, h, gap = 84, 22, 8
    local startX = px + GRID_PAD + 50
    local y = py + 118
    local rects = {}
    for i, mode in ipairs(SORT_MODES) do
        rects[i] = { x = startX + (i - 1) * (w + gap), y = y, w = w, h = h, mode = mode }
    end
    return rects
end

local function filterRects(px, py, pw)
    local w, h, gap = 84, 22, 8
    local totalW = w * 3 + gap * 2
    local startX = px + pw - GRID_PAD - totalW
    local y = py + 118
    local rects = {}
    for i, mode in ipairs(FILTER_MODES) do
        rects[i] = { x = startX + (i - 1) * (w + gap), y = y, w = w, h = h, mode = mode }
    end
    return rects
end

local function closeButtonRect(px, py, pw)
    return { x = px + pw - 40, y = py + 10, w = 30, h = 26 }
end

-- ===== Grouping -- computed fresh every call from Campaign.deck, never
-- cached, so it can never drift out of sync with the real collection. =====

-- Frontline/Reserve/Total for one group key, scanned against the FULL deck
-- regardless of which tab is active, so the info panel/inspect modal always
-- show the true numbers no matter where you're browsing from.
local function summarizeGroup(campaign, key)
    local frontlineIds, reserveIds, representative = {}, {}, nil
    for _, card in ipairs(campaign.deck) do
        if Campaign.cardGroupKey(card) == key then
            if not representative then representative = card end
            if campaign:isInReserve(card.id) then
                table.insert(reserveIds, card.id)
            else
                table.insert(frontlineIds, card.id)
            end
        end
    end
    return {
        key = key,
        card = representative,
        frontlineIds = frontlineIds,
        reserveIds = reserveIds,
        frontlineCount = #frontlineIds,
        reserveCount = #reserveIds,
        totalCount = #frontlineIds + #reserveIds,
    }
end

local function poolForTab(campaign, tab)
    if tab == "FRONTLINE" then return campaign:frontlineCards()
    elseif tab == "RESERVE" then return campaign:reserveCards()
    else return campaign.deck end
end

-- Groups the current tab's pool by identity (rank+suit+strength+upgrade+
-- tags -- see Campaign.cardGroupKey), each entry annotated with its true
-- Frontline/Reserve/Total counts (via summarizeGroup) plus displayCount,
-- how many copies THIS tab's pool contains (the quantity badge number).
local function computeGroups(campaign, tab)
    local pool = poolForTab(campaign, tab)
    local order, seen, displayCounts = {}, {}, {}
    for _, card in ipairs(pool) do
        local key = Campaign.cardGroupKey(card)
        if not seen[key] then
            seen[key] = true
            table.insert(order, key)
            displayCounts[key] = 0
        end
        displayCounts[key] = displayCounts[key] + 1
    end

    local groups = {}
    for _, key in ipairs(order) do
        local g = summarizeGroup(campaign, key)
        g.displayCount = displayCounts[key]
        table.insert(groups, g)
    end
    return groups
end

local function typeRank(card)
    if card:isNumberCard() then return 1
    elseif card:isFaceCard() then return 2
    else return 3 end -- Ace
end

local function sortGroups(groups, mode)
    table.sort(groups, function(a, b)
        if mode == "SUIT" then
            if SUIT_ORDER[a.card.suit] ~= SUIT_ORDER[b.card.suit] then
                return SUIT_ORDER[a.card.suit] < SUIT_ORDER[b.card.suit]
            end
            return RANK_ORDER[a.card.rank] < RANK_ORDER[b.card.rank]
        elseif mode == "STRENGTH" then
            if a.card.currentStrength ~= b.card.currentStrength then
                return a.card.currentStrength > b.card.currentStrength
            end
            return RANK_ORDER[a.card.rank] < RANK_ORDER[b.card.rank]
        elseif mode == "TYPE" then
            local ta, tb = typeRank(a.card), typeRank(b.card)
            if ta ~= tb then return ta < tb end
            return RANK_ORDER[a.card.rank] < RANK_ORDER[b.card.rank]
        else -- RANK
            if RANK_ORDER[a.card.rank] ~= RANK_ORDER[b.card.rank] then
                return RANK_ORDER[a.card.rank] < RANK_ORDER[b.card.rank]
            end
            return SUIT_ORDER[a.card.suit] < SUIT_ORDER[b.card.suit]
        end
    end)
end

-- Drops any tracked CardView whose group is no longer in the current tab's
-- list -- same pattern as ui.lua's pruneViews for hand cards.
local function pruneGroupViews(groups)
    local present = {}
    for _, g in ipairs(groups) do present[g.key] = true end
    for key, view in pairs(groupViews) do
        if not present[key] then
            view:destroy()
            groupViews[key] = nil
        end
    end
end

-- Computes each visible group's row/column slot this frame (row-major,
-- wrapping to fit the panel width, with the current scroll offset already
-- baked into .y), and defensively clamps scrollY to the resulting content
-- height. Called fresh from update/draw/handleClick -- it's cheap (a few
-- dozen groups at most) and guarantees layout can never drift between them.
local function layoutGroups(campaign)
    local groups = computeGroups(campaign, activeTab)
    sortGroups(groups, sortMode)

    local gx, gy, gw, gh = gridRect()
    local perRow = math.max(1, math.floor((gw - CARD_W) / COL_STEP) + 1)
    local rows = math.ceil(#groups / perRow)
    contentHeight = rows > 0 and (rows * (CARD_H + ROW_GAP)) or 0
    visibleHeight = gh

    local maxScroll = math.max(0, contentHeight - visibleHeight)
    if scrollY > maxScroll then scrollY = maxScroll end
    if scrollY < 0 then scrollY = 0 end

    for i, g in ipairs(groups) do
        local col = (i - 1) % perRow
        local row = math.floor((i - 1) / perRow)
        g.slot = { x = gx + col * COL_STEP, y = gy + row * (CARD_H + ROW_GAP) - scrollY }
    end

    return groups
end

-- Returns the topmost group under (mx, my) within the grid's visible
-- bounds, or nil. Iterated back-to-front (later-drawn cards overlap earlier
-- ones in the same row) so an overlap region resolves to whichever card is
-- actually drawn on top. Shared by hover (update) and click (handleClick)
-- so both always agree with what's on screen.
local function hitTestGroups(groups, mx, my, gx, gy, gw, gh)
    for i = #groups, 1, -1 do
        local slot = groups[i].slot
        if slot.y + CARD_H >= gy and slot.y <= gy + gh
            and mx >= slot.x and mx <= slot.x + CARD_W
            and my >= slot.y and my <= slot.y + CARD_H then
            return groups[i].key
        end
    end
    return nil
end

local function findGroup(groups, key)
    for _, g in ipairs(groups) do
        if g.key == key then return g end
    end
    return nil
end

-- ===== Drawing =====

local function drawShadow(x, y, w, h)
    love.graphics.setColor(SHADOW_COLOR)
    love.graphics.rectangle("fill", x + 3, y + h - 6, w - 6, 10, 5, 5)
    love.graphics.setColor(1, 1, 1)
end

local function drawQuantityBadge(x, y, w, h, count)
    if count <= 1 then return end
    local bw, bh = 28, 16
    local bx, by = x + w - bw + 6, y + h - bh + 6
    love.graphics.setColor(0.05, 0.06, 0.08, 0.92)
    love.graphics.rectangle("fill", bx, by, bw, bh, 4, 4)
    love.graphics.setColor(ACCENT_PLAYER)
    love.graphics.setLineWidth(1.2)
    love.graphics.rectangle("line", bx, by, bw, bh, 4, 4)
    love.graphics.setColor(1, 1, 1)
    local prevFont = love.graphics.getFont()
    love.graphics.setFont(getSmallFont())
    love.graphics.printf("x" .. count, bx, by + 2, bw, "center")
    love.graphics.setFont(prevFont)
end

local function drawGroupCard(g)
    local view = groupViews[g.key]
    if not view then return end
    local sx, sy, sw, sh = view:getShadowRect()
    drawShadow(sx, sy, sw, sh)
    local x, y, w, h = view:getDrawRect()
    UI.drawStaticCard(g.card, x, y, w, h, view:getRotation())
    drawQuantityBadge(x, y, w, h, g.displayCount)
end

local function drawTabButton(rect, active, hovered)
    love.graphics.setColor(active and BTN_ACTIVE_FILL or BTN_FILL)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h, 5, 5)
    love.graphics.setColor((active or hovered) and BTN_ACTIVE_BORDER or BTN_BORDER)
    love.graphics.setLineWidth(active and 3 or 2)
    love.graphics.rectangle("line", rect.x, rect.y, rect.w, rect.h, 5, 5)
    love.graphics.setColor(1, 1, 1)
    local font = getTabFont()
    love.graphics.setFont(font)
    love.graphics.printf(rect.label, rect.x, rect.y + rect.h / 2 - font:getHeight() / 2, rect.w, "center")
end

local function drawSmallButton(label, rect, active, hovered)
    love.graphics.setColor(active and BTN_ACTIVE_FILL or BTN_FILL)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h, 3, 3)
    love.graphics.setColor((active or hovered) and BTN_ACTIVE_BORDER or BTN_BORDER)
    love.graphics.setLineWidth(active and 2 or 1.5)
    love.graphics.rectangle("line", rect.x, rect.y, rect.w, rect.h, 3, 3)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(label, rect.x, rect.y + rect.h / 2 - 6, rect.w, "center")
end

local function drawStatsRow(campaign, px, py, pw)
    local counts = campaign:collectionCounts()
    local keyed = { FRONTLINE = counts.frontline, RESERVE = counts.reserve, TOTAL = counts.total }

    for _, rect in ipairs(statRects(px, py, pw)) do
        love.graphics.setColor(0.06, 0.09, 0.12, 0.9)
        love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h, 4, 4)
        love.graphics.setColor(0.35, 0.75, 0.85, 0.6)
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", rect.x, rect.y, rect.w, rect.h, 4, 4)

        local c = keyed[rect.label]
        love.graphics.setColor(0.55, 0.85, 0.95)
        love.graphics.print(rect.label, rect.x + 10, rect.y + 3)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(string.format("Cards: %d    Unique: %d", c.cards, c.unique), rect.x + 10, rect.y + 18)
    end
end

local function drawHeader(campaign, px, py, pw)
    local prevFont = love.graphics.getFont()

    love.graphics.setFont(getTitleFont())
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("DECK COLLECTION", px, py + 8, pw, "center")

    local mx, my = love.mouse.getPosition()

    drawSmallButton("X", closeButtonRect(px, py, pw), false, isOver(closeButtonRect(px, py, pw), mx, my))

    for _, rect in ipairs(tabRects(px, py, pw)) do
        drawTabButton(rect, activeTab == rect.id, isOver(rect, mx, my))
    end

    love.graphics.setFont(getStatFont())
    drawStatsRow(campaign, px, py, pw)

    love.graphics.setFont(getSmallFont())
    love.graphics.setColor(0.55, 0.85, 0.95)
    love.graphics.print("SORT:", px + GRID_PAD, py + 121)
    for _, rect in ipairs(sortRects(px, py, pw)) do
        drawSmallButton(rect.mode, rect, sortMode == rect.mode, isOver(rect, mx, my))
    end

    local frects = filterRects(px, py, pw)
    love.graphics.setColor(0.55, 0.85, 0.95)
    love.graphics.print("FILTER:", frects[1].x - 58, py + 121)
    for _, rect in ipairs(frects) do
        drawSmallButton(rect.mode, rect, activeTab == rect.mode, isOver(rect, mx, my))
    end

    love.graphics.setFont(prevFont)
    love.graphics.setColor(1, 1, 1)
end

local function drawInfoPanel(g, gx, gy, gh)
    local pw, ph = 230, 152
    local px, py = gx, gy + gh - ph

    love.graphics.setColor(0.04, 0.06, 0.09, 0.95)
    love.graphics.rectangle("fill", px, py, pw, ph, 6, 6)
    love.graphics.setColor(ACCENT_PLAYER)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", px, py, pw, ph, 6, 6)
    love.graphics.setColor(1, 1, 1)

    local prevFont = love.graphics.getFont()
    local font = getStatFont()
    love.graphics.setFont(font)
    local lh = font:getHeight() + 5
    local ty = py + 10
    local card = g.card

    love.graphics.printf(string.upper(card:getLabel()), px + 12, ty, pw - 24, "left")
    ty = ty + lh + 4
    love.graphics.printf("Strength: " .. card.currentStrength, px + 12, ty, pw - 24, "left")
    ty = ty + lh
    local typeLabel = card:isNumberCard() and "Number Card" or (card:isFaceCard() and "Face Card" or "Ace")
    love.graphics.printf("Type: " .. typeLabel, px + 12, ty, pw - 24, "left")
    ty = ty + lh + 6
    love.graphics.setColor(0.55, 0.85, 0.95)
    love.graphics.printf("Frontline: " .. g.frontlineCount, px + 12, ty, pw - 24, "left")
    ty = ty + lh
    love.graphics.printf("Reserve:   " .. g.reserveCount, px + 12, ty, pw - 24, "left")
    ty = ty + lh
    love.graphics.printf("Total:     " .. g.totalCount, px + 12, ty, pw - 24, "left")

    love.graphics.setFont(prevFont)
    love.graphics.setColor(1, 1, 1)
end

local function drawEmptyState(gx, gy, gw, gh)
    local prevFont = love.graphics.getFont()
    love.graphics.setFont(getStatFont())
    love.graphics.setColor(0.6, 0.75, 0.8, 0.8)
    love.graphics.printf("No cards here yet.", gx, gy + gh / 2 - 10, gw, "center")
    love.graphics.setFont(prevFont)
    love.graphics.setColor(1, 1, 1)
end

local function drawScrollHint(gx, gy, gw, gh)
    if contentHeight <= visibleHeight then return end
    local prevFont = love.graphics.getFont()
    love.graphics.setFont(getSmallFont())
    love.graphics.setColor(0.55, 0.85, 0.95, 0.65)
    love.graphics.printf("SCROLL FOR MORE", gx, gy + gh - 16, gw, "right")
    love.graphics.setFont(prevFont)
    love.graphics.setColor(1, 1, 1)
end

-- ===== Inspect modal =====

-- Single source of truth for the modal's geometry -- shared by draw and
-- handleClick, same idiom as the header rects above.
local function modalButtonRects(modalX, topY, g, campaign)
    local centerX = modalX + MODAL_W / 2
    local rects = {}
    local y = topY

    -- Mirrors Campaign:moveToReserve's own "never empty Frontline" guard so
    -- this button is never shown promising a click that would silently
    -- no-op.
    if g.frontlineCount > 0 and #campaign:frontlineCards() > 1 then
        rects.toReserve = { x = centerX - MODAL_BTN_W / 2, y = y, w = MODAL_BTN_W, h = MODAL_BTN_H }
        y = y + MODAL_BTN_H + MODAL_BTN_GAP
    end
    if g.reserveCount > 0 then
        rects.toFrontline = { x = centerX - MODAL_BTN_W / 2, y = y, w = MODAL_BTN_W, h = MODAL_BTN_H }
        y = y + MODAL_BTN_H + MODAL_BTN_GAP
    end
    rects.close = { x = centerX - MODAL_BTN_W / 2, y = y, w = MODAL_BTN_W, h = MODAL_BTN_H }

    return rects
end

local function modalLayout(campaign, key)
    local g = summarizeGroup(campaign, key)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local mx, my = w / 2 - MODAL_W / 2, h / 2 - MODAL_H / 2
    local cardX, cardY = mx + MODAL_W / 2 - MODAL_CARD_W / 2, my + 24
    local font = getStatFont()
    local textTop = cardY + MODAL_CARD_H + 16
    local buttonsTop = textTop + font:getHeight() * 2 + 34

    return {
        g = g, mx = mx, my = my, mw = MODAL_W, mh = MODAL_H,
        cardX = cardX, cardY = cardY, cardW = MODAL_CARD_W, cardH = MODAL_CARD_H,
        textTop = textTop,
        rects = g.card and modalButtonRects(mx, buttonsTop, g, campaign) or {},
    }
end

local function drawModalButton(label, rect, hovered)
    love.graphics.setColor(hovered and BTN_ACTIVE_FILL or BTN_FILL)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h, 5, 5)
    love.graphics.setColor(hovered and BTN_ACTIVE_BORDER or BTN_BORDER)
    love.graphics.setLineWidth(hovered and 3 or 2)
    love.graphics.rectangle("line", rect.x, rect.y, rect.w, rect.h, 5, 5)
    love.graphics.setColor(1, 1, 1)
    local font = getTabFont()
    love.graphics.setFont(font)
    love.graphics.printf(label, rect.x, rect.y + rect.h / 2 - font:getHeight() / 2, rect.w, "center")
end

local function drawInspectModal(campaign)
    local layout = modalLayout(campaign, selectedGroupKey)
    if not layout.g.card then
        selectedGroupKey = nil
        return
    end

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, w, h)

    love.graphics.setColor(0.04, 0.06, 0.09, 0.98)
    love.graphics.rectangle("fill", layout.mx, layout.my, layout.mw, layout.mh, 8, 8)
    love.graphics.setColor(ACCENT_PLAYER)
    love.graphics.setLineWidth(2.5)
    love.graphics.rectangle("line", layout.mx, layout.my, layout.mw, layout.mh, 8, 8)
    love.graphics.setColor(1, 1, 1)

    UI.drawStaticCard(layout.g.card, layout.cardX, layout.cardY, layout.cardW, layout.cardH)

    local prevFont = love.graphics.getFont()
    local font = getStatFont()
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)

    local ty = layout.textTop
    love.graphics.printf(string.upper(layout.g.card:getLabel()), layout.mx, ty, layout.mw, "center")
    ty = ty + font:getHeight() + 8

    local typeLabel = layout.g.card:isNumberCard() and "Number Card"
        or (layout.g.card:isFaceCard() and "Face Card" or "Ace")
    love.graphics.printf(string.format("Strength: %d   Type: %s", layout.g.card.currentStrength, typeLabel),
        layout.mx, ty, layout.mw, "center")
    ty = ty + font:getHeight() + 10

    love.graphics.setColor(0.55, 0.85, 0.95)
    love.graphics.printf(string.format("Frontline: %d      Reserve: %d      Total: %d",
        layout.g.frontlineCount, layout.g.reserveCount, layout.g.totalCount), layout.mx, ty, layout.mw, "center")
    love.graphics.setColor(1, 1, 1)

    local mx, my = love.mouse.getPosition()
    if layout.rects.toReserve then
        drawModalButton("MOVE TO RESERVE", layout.rects.toReserve, isOver(layout.rects.toReserve, mx, my))
    end
    if layout.rects.toFrontline then
        drawModalButton("MOVE TO FRONTLINE", layout.rects.toFrontline, isOver(layout.rects.toFrontline, mx, my))
    end
    drawModalButton("CLOSE", layout.rects.close, isOver(layout.rects.close, mx, my))

    love.graphics.setFont(prevFont)
    love.graphics.setColor(1, 1, 1)
end

-- ===== Tab/sort switching + move actions =====

-- Brief settle-in "pop" on the whole grid, covering both appearing and
-- disappearing cards for a tab/sort change without needing to track a
-- per-card exit animation.
local function triggerSwitchFade()
    state.gridOffsetY = 10
    AnimationManager.tween(state, "gridOffsetY", 0, 0.22, AnimationManager.EASE_OUT_BACK)
end

local function switchTab(newTab)
    activeTab = newTab
    scrollY = 0
    triggerSwitchFade()
end

-- Moves exactly one physical copy (the group's first eligible card id) and
-- fires the same "info_banner" confirmation ui.lua already uses for
-- "RESERVES DEPLOYED".
local function performMove(campaign, g, direction)
    local ids = direction == "reserve" and g.frontlineIds or g.reserveIds
    local id = ids[1]
    if not id then return end

    local ok
    if direction == "reserve" then
        ok = campaign:moveToReserve(id)
    else
        ok = campaign:moveToFrontline(id)
    end

    if ok then
        local text = direction == "reserve" and "MOVED TO RESERVE" or "MOVED TO FRONTLINE"
        AnimationManager.play("info_banner", nil, { text = text, color = ACCENT_PLAYER })
    end
end

-- ===== Public API =====

function CollectionUI.isOpen()
    return isOpenFlag
end

-- Opening never touches Campaign state -- it only resets this module's own
-- view/scroll/selection bookkeeping and kicks off the fade/pop-in tween.
function CollectionUI.open(campaign)
    if isOpenFlag then return end
    isOpenFlag = true
    selectedGroupKey = nil
    hoveredKey = nil
    scrollY = 0
    state.openProgress = 0
    state.gridOffsetY = 0
    AnimationManager.tween(state, "openProgress", 1, 0.28, AnimationManager.EASE_OUT_QUAD)
end

function CollectionUI.close()
    if not isOpenFlag then return end
    isOpenFlag = false
    selectedGroupKey = nil
    hoveredKey = nil
    for key, view in pairs(groupViews) do
        view:destroy()
        groupViews[key] = nil
    end
end

function CollectionUI.toggle(campaign)
    if isOpenFlag then
        CollectionUI.close()
    else
        CollectionUI.open(campaign)
    end
end

-- Escape: closes the inspect modal if one is open, else closes the whole
-- overlay. No-ops if the overlay isn't open (main.lua calls this
-- unconditionally whenever Escape is pressed while open).
function CollectionUI.handleEscape()
    if not isOpenFlag then return end
    if selectedGroupKey then
        selectedGroupKey = nil
    else
        CollectionUI.close()
    end
end

function CollectionUI.wheelmoved(dy)
    if not isOpenFlag or selectedGroupKey then return end
    scrollY = scrollY - dy * 44
    local maxScroll = math.max(0, contentHeight - visibleHeight)
    if scrollY < 0 then scrollY = 0 end
    if scrollY > maxScroll then scrollY = maxScroll end
end

-- Call once per love.update(dt) whenever campaign.state isn't relevant --
-- i.e. always; this no-ops immediately if the overlay isn't open. Drives
-- hover state and keeps every visible group's CardView's home slot current
-- (their continuous follow -- started in CardView.new -- glides them there,
-- giving the "cards settle into place" reflow for free on tab/sort/scroll
-- changes, exactly like ui.lua's hand-card reflow).
function CollectionUI.update(campaign, dt)
    if not isOpenFlag then return end

    if selectedGroupKey then
        hoveredKey = nil
        return
    end

    local groups = layoutGroups(campaign)
    pruneGroupViews(groups)

    local gx, gy, gw, gh = gridRect()
    local mx, my = love.mouse.getPosition()
    hoveredKey = hitTestGroups(groups, mx, my, gx, gy, gw, gh)

    for _, g in ipairs(groups) do
        local view = groupViews[g.key]
        if not view then
            -- Spawns a little below its resting slot so the continuous
            -- home-follow carries it up into place -- the same mechanism
            -- ui.lua's hand cards use to reflow, reused here to give new
            -- stacks a free "settle onto the table" arrival.
            view = CardView.new(g.card, g.slot.x, g.slot.y + 34, CARD_W, CARD_H)
            view.rotation = seededAngle(g.key)
            groupViews[g.key] = view
        end
        view.homeX, view.homeY = g.slot.x, g.slot.y
        AnimationManager.play("card_hover", view, { hovering = (g.key == hoveredKey) })
    end
end

function CollectionUI.draw(campaign)
    if not isOpenFlag then return end

    local w, h = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setColor(0, 0, 0, 0.72 * state.openProgress)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(1, 1, 1)

    if state.openProgress <= 0.02 then
        ScreenFX.draw()
        return
    end

    local px, py, pw, ph = panelRect()

    love.graphics.setColor(0.03, 0.05, 0.07, 0.97 * state.openProgress)
    love.graphics.rectangle("fill", px, py, pw, ph, 8, 8)
    love.graphics.setColor(ACCENT_PLAYER[1], ACCENT_PLAYER[2], ACCENT_PLAYER[3], state.openProgress)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", px, py, pw, ph, 8, 8)
    love.graphics.setColor(1, 1, 1)

    drawHeader(campaign, px, py, pw)

    local groups = layoutGroups(campaign)
    local gx, gy, gw, gh = gridRect()

    love.graphics.setScissor(gx, gy, gw, gh)
    love.graphics.push()
    love.graphics.translate(0, state.gridOffsetY)

    if #groups == 0 then
        drawEmptyState(gx, gy, gw, gh)
    else
        for _, g in ipairs(groups) do
            if g.key ~= hoveredKey then drawGroupCard(g) end
        end
        if hoveredKey then
            local hg = findGroup(groups, hoveredKey)
            if hg then drawGroupCard(hg) end
        end
    end

    love.graphics.pop()
    love.graphics.setScissor()

    if hoveredKey and not selectedGroupKey then
        local hg = findGroup(groups, hoveredKey)
        if hg then drawInfoPanel(hg, gx, gy, gh) end
    end

    drawScrollHint(gx, gy, gw, gh)

    if selectedGroupKey then
        drawInspectModal(campaign)
    end

    ScreenFX.draw()
end

-- Call from love.mousepressed whenever CollectionUI.isOpen() -- the
-- underlying screen (battle or a campaign_ui screen) never sees the click.
function CollectionUI.handleClick(campaign, mx, my)
    if not isOpenFlag then return end

    if selectedGroupKey then
        local layout = modalLayout(campaign, selectedGroupKey)
        if not layout.g.card then
            selectedGroupKey = nil
            return
        end

        if layout.rects.toReserve and isOver(layout.rects.toReserve, mx, my) then
            performMove(campaign, layout.g, "reserve")
            return
        end
        if layout.rects.toFrontline and isOver(layout.rects.toFrontline, mx, my) then
            performMove(campaign, layout.g, "frontline")
            return
        end
        if isOver(layout.rects.close, mx, my) then
            selectedGroupKey = nil
            return
        end
        if not (mx >= layout.mx and mx <= layout.mx + layout.mw
            and my >= layout.my and my <= layout.my + layout.mh) then
            selectedGroupKey = nil -- click outside the modal closes it
        end
        return
    end

    local px, py, pw = panelRect()

    if isOver(closeButtonRect(px, py, pw), mx, my) then
        CollectionUI.close()
        return
    end

    for _, rect in ipairs(tabRects(px, py, pw)) do
        if isOver(rect, mx, my) then
            if activeTab ~= rect.id then switchTab(rect.id) end
            return
        end
    end

    for _, rect in ipairs(filterRects(px, py, pw)) do
        if isOver(rect, mx, my) then
            if activeTab ~= rect.mode then switchTab(rect.mode) end
            return
        end
    end

    for _, rect in ipairs(sortRects(px, py, pw)) do
        if isOver(rect, mx, my) then
            if sortMode ~= rect.mode then
                sortMode = rect.mode
                triggerSwitchFade()
            end
            return
        end
    end

    local groups = layoutGroups(campaign)
    local gx, gy, gw, gh = gridRect()
    local key = hitTestGroups(groups, mx, my, gx, gy, gw, gh)
    if key then
        selectedGroupKey = key
    end
end

return CollectionUI
