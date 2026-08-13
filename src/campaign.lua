-- src/campaign.lua
-- Campaign meta-state and orchestration: commander selection, gold, the
-- persistent player deck, the opponent roster, the shop, and starting/
-- ending each Battle. Owns no rendering -- src/campaign_ui.lua reads this
-- module's state and calls its action methods (toggleCommander, buyCard,
-- selectOpponent, ...) in response to input. src/main.lua drives
-- Campaign:update(dt) and reads Campaign.state to decide whether to render
-- the battle screen (src/ui.lua) or a campaign menu screen (campaign_ui.lua).
--
-- The campaign never duplicates battle rules: it only builds decks (via
-- Card/Deck) and commander choices, then hands them to Battle.new() and
-- lets the existing battle system run untouched.

local Card = require("src.card")
local Deck = require("src.deck")
local Battle = require("src.battle")
local Commander = require("src.commander")
local AIArmy = require("src.ai_army")

local Campaign = {}
Campaign.__index = Campaign

Campaign.STATE = {
    COMMANDER_SELECT = "commander_select",
    BATTLE = "battle",
    VICTORY = "victory",
    SHOP = "shop",
    BATTLE_SELECT = "battle_select",
    CAMPAIGN_COMPLETE = "campaign_complete",
    DEFEAT = "defeat",
}

Campaign.VICTORY_GOLD = 100
Campaign.SHOP_SIZE = 3
-- How many commanders the player can pick at once on the Commander Select
-- screen, to test how their abilities stack together.
Campaign.MAX_PLAYER_COMMANDERS = 5

local SUITS = { "Hearts", "Diamonds", "Clubs", "Spades" }
local RANKS = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A" }

local nextId = 1
local function freshId(prefix)
    nextId = nextId + 1
    return prefix .. "_" .. nextId
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- Demo pricing: a card's price scales with whatever strength bonus it
-- carries (a plain rank/suit card is cheapest). Cassus Belli has no
-- existing card-price data to reuse, so these are the "simple demo prices"
-- the directive allows for when none exist yet.
local function priceForCard(card)
    local bonus = card.currentStrength - card.baseStrength
    if bonus >= 3 then return 150
    elseif bonus >= 2 then return 100
    elseif bonus >= 1 then return 75
    else return 50 end
end

local function generateShopCard()
    local rank = RANKS[love.math.random(#RANKS)]
    local suit = SUITS[love.math.random(#SUITS)]
    local card = Card.new(freshId("shop"), suit, rank)

    local roll = love.math.random()
    if roll < 0.15 then
        card.currentStrength = card.currentStrength + 3
    elseif roll < 0.35 then
        card.currentStrength = card.currentStrength + 2
    elseif roll < 0.65 then
        card.currentStrength = card.currentStrength + 1
    end

    return card
end

local function generateShop()
    local shop = {}
    for i = 1, Campaign.SHOP_SIZE do
        local card = generateShopCard()
        shop[i] = { card = card, price = priceForCard(card), purchased = false }
    end
    return shop
end

-- Splits a flat list of Card objects into a shuffled active deck plus a
-- reserve deck half its size -- the same 50/50 split rule Battle's own
-- standard-deck builder uses, just generalized to an arbitrary card list.
local function splitDeck(cards)
    local full = Deck.new()
    for _, card in ipairs(cards) do full:addToBottom(card) end
    full:shuffle()

    local reserve = Deck.new()
    local half = math.floor(#cards / 2)
    for _ = 1, half do
        reserve:addToBottom(full:drawCard())
    end
    return full, reserve
end

function Campaign.new()
    local self = setmetatable({}, Campaign)

    self.state = Campaign.STATE.COMMANDER_SELECT
    self.playerCommanders = {} -- up to MAX_PLAYER_COMMANDERS names, chosen on COMMANDER_SELECT
    self.currentOpponent = nil
    self.gold = 0
    self.wins = 0
    self.defeatedOpponents = {}
    self.availableOpponents = {}
    self.deck = {}          -- persistent player deck: array of Card -- shop purchases
                            -- plus any card permanently recruited via a War (see
                            -- checkBattleOutcome)
    self.reserveIds = {}    -- set of card id -> true: which of self.deck is currently
                            -- assigned to Reserve (see the Collection menu,
                            -- src/collection_ui.lua). Anything in self.deck NOT in
                            -- this set is Frontline. This is the persistent split
                            -- startBattleAgainst reads from -- distinct from
                            -- Battle's own in-battle playerReserveDeck, which is
                            -- just this split cloned into that one fight.
    self.shop = {}
    self.battle = nil       -- active Battle instance, or nil outside STATE.BATTLE
    self.lastWinner = nil   -- "player" | "enemy", set when the most recent Battle ended
    self.cardsWonThisBattle = {} -- War-recruited cards from the battle that just ended,
                                  -- for the VICTORY screen to display

    return self
end

-- Called from the COMMANDER_SELECT screen whenever the player clicks a
-- commander button -- toggles it in/out of the set they'll fight with (up
-- to MAX_PLAYER_COMMANDERS at once, to test how abilities stack). Doesn't
-- start anything; the player confirms separately once ready.
function Campaign:toggleCommander(commander)
    if self.state ~= Campaign.STATE.COMMANDER_SELECT then return end

    for i, name in ipairs(self.playerCommanders) do
        if name == commander then
            table.remove(self.playerCommanders, i)
            return
        end
    end
    if #self.playerCommanders >= Campaign.MAX_PLAYER_COMMANDERS then return end
    table.insert(self.playerCommanders, commander)
end

-- Called from the COMMANDER_SELECT screen's [START BATTLE], once at least
-- one commander is selected. Builds the starting 52-card persistent deck
-- and picks a random first opponent from everyone the player isn't using.
function Campaign:confirmCommanders()
    if self.state ~= Campaign.STATE.COMMANDER_SELECT then return end
    if #self.playerCommanders == 0 then return end

    self.availableOpponents = {}
    for _, name in ipairs(Commander.ALL) do
        if not contains(self.playerCommanders, name) then
            table.insert(self.availableOpponents, name)
        end
    end

    self.deck = {}
    for _, suit in ipairs(SUITS) do
        for _, rank in ipairs(RANKS) do
            table.insert(self.deck, Card.new(freshId("P"), suit, rank))
        end
    end

    -- Even 26/26 Frontline/Reserve starting split -- shuffled via a temp Deck
    -- (reusing Deck:shuffle rather than duplicating Fisher-Yates here) so it
    -- isn't just "the second half of suit/rank order."
    self.reserveIds = {}
    local shuffled = Deck.new()
    for _, card in ipairs(self.deck) do shuffled:addToBottom(card) end
    shuffled:shuffle()
    for i = 1, math.floor(#shuffled.cards / 2) do
        self.reserveIds[shuffled.cards[i].id] = true
    end

    self:startBattleAgainst(self.availableOpponents[love.math.random(#self.availableOpponents)])
end

-- True if `cardId` is currently assigned to Reserve. Everything in self.deck
-- not flagged here is Frontline -- there is no separate "frontline set."
function Campaign:isInReserve(cardId)
    return self.reserveIds[cardId] == true
end

-- Returns the actual Card objects (not clones) currently assigned to each
-- pool, in self.deck order. Read-only views for the Collection menu and
-- startBattleAgainst -- callers that need to hand cards to a Battle must
-- clone them first (see cloneAll), same as the rest of this module already
-- does, so nothing a Battle does ever touches the persistent record directly.
function Campaign:frontlineCards()
    local list = {}
    for _, card in ipairs(self.deck) do
        if not self.reserveIds[card.id] then table.insert(list, card) end
    end
    return list
end

function Campaign:reserveCards()
    local list = {}
    for _, card in ipairs(self.deck) do
        if self.reserveIds[card.id] then table.insert(list, card) end
    end
    return list
end

-- Moves one card from Frontline to Reserve. Refuses (returns false, no
-- state change) if the card isn't found, is already in Reserve, or the move
-- would leave Frontline with zero cards -- the Collection menu must never be
-- able to walk the player into an unfightable army.
function Campaign:moveToReserve(cardId)
    if self.reserveIds[cardId] then return false end

    local found = false
    for _, card in ipairs(self.deck) do
        if card.id == cardId then
            found = true
            break
        end
    end
    if not found then return false end

    if #self:frontlineCards() <= 1 then return false end

    self.reserveIds[cardId] = true
    return true
end

-- Moves one card from Reserve to Frontline. Refuses if the card isn't found
-- or isn't currently in Reserve.
function Campaign:moveToFrontline(cardId)
    if not self.reserveIds[cardId] then return false end
    self.reserveIds[cardId] = nil
    return true
end

-- Groups self.deck by rank+suit+currentStrength+upgradeLevel+tags so two
-- printed-identical cards stack together, but a strength-boosted shop copy
-- (or a future upgraded one) counts as its own distinct "unique" entry
-- rather than being silently folded into the plain version. Used by the
-- Collection menu (grouping) and by collectionCounts below (uniques).
local function cardGroupKey(card)
    local tagList = {}
    for tag in pairs(card.tags) do table.insert(tagList, tag) end
    table.sort(tagList)
    return table.concat({
        card.rank, card.suit, card.currentStrength, card.upgradeLevel,
        table.concat(tagList, ","),
    }, "|")
end
Campaign.cardGroupKey = cardGroupKey

-- Dynamically computed stats panel data -- never stored, always derived
-- fresh from self.deck/self.reserveIds so it can't drift out of sync.
-- Returns { frontline = {cards=N, unique=N}, reserve = {...}, total = {...} }.
function Campaign:collectionCounts()
    local function summarize(cards)
        local seen = {}
        local unique = 0
        for _, card in ipairs(cards) do
            local key = cardGroupKey(card)
            if not seen[key] then
                seen[key] = true
                unique = unique + 1
            end
        end
        return { cards = #cards, unique = unique }
    end

    return {
        frontline = summarize(self:frontlineCards()),
        reserve = summarize(self:reserveCards()),
        total = summarize(self.deck),
    }
end

-- Clones every card in a persistent list under fresh ids, so nothing a
-- Battle does to them (capture, permanent-flagging, sideline) touches the
-- original record.
local function cloneAll(cards, idPrefix)
    local clones = {}
    for _, card in ipairs(cards) do
        table.insert(clones, card:clone(freshId(idPrefix)))
    end
    return clones
end

-- Builds a shuffled Deck from a flat list of Card objects, with no split --
-- used for the player side, which is already split by the persistent
-- Frontline/Reserve assignment (see frontlineCards/reserveCards) rather than
-- needing splitDeck's random 50/50 cut.
local function toShuffledDeck(cards)
    local deck = Deck.new()
    for _, card in ipairs(cards) do deck:addToBottom(card) end
    deck:shuffle()
    return deck
end

function Campaign:startBattleAgainst(opponentCommander)
    self.currentOpponent = opponentCommander

    -- The player's battle decks come from whatever Frontline/Reserve split
    -- the Collection menu currently holds, not a fresh random cut -- this is
    -- what makes moving a card between Frontline and Reserve there actually
    -- matter for the next fight.
    local playerActive = toShuffledDeck(cloneAll(self:frontlineCards(), "P"))
    local playerReserve = toShuffledDeck(cloneAll(self:reserveCards(), "P"))
    local aiCards = AIArmy.build(opponentCommander, #self.deck)
    local enemyActive, enemyReserve = splitDeck(aiCards)

    self.battle = Battle.new({
        playerDeck = playerActive, playerReserveDeck = playerReserve,
        enemyDeck = enemyActive, enemyReserveDeck = enemyReserve,
        playerCommanders = self.playerCommanders,
        enemyCommander = opponentCommander,
    })
    self.state = Campaign.STATE.BATTLE
end

-- Call once per love.update(dt) whenever state == BATTLE, after
-- self.battle:update(dt). Detects the Battle's own GAME_OVER and advances
-- the campaign; leaves self.battle in place through this call so the battle
-- screen can render its final state for one more frame before it clears.
function Campaign:checkBattleOutcome()
    if not self.battle or self.battle.phase ~= self.battle.PHASE.GAME_OVER then return end

    self.lastWinner = self.battle.winner
    if self.battle.winner == "player" then
        self.wins = self.wins + 1
        self.gold = self.gold + Campaign.VICTORY_GOLD

        -- Any card permanently recruited via a War this battle joins the
        -- persistent deck for good, and is shown on the VICTORY screen.
        self.cardsWonThisBattle = self.battle:collectPlayerPermanentCards()
        for _, card in ipairs(self.cardsWonThisBattle) do
            table.insert(self.deck, card)
            self.reserveIds[card.id] = true -- new cards start in Reserve until promoted
        end

        table.insert(self.defeatedOpponents, self.currentOpponent)
        for i, name in ipairs(self.availableOpponents) do
            if name == self.currentOpponent then
                table.remove(self.availableOpponents, i)
                break
            end
        end
        self.currentOpponent = nil
        self.shop = generateShop()
        self.state = Campaign.STATE.VICTORY
    else
        self.cardsWonThisBattle = {}
        self.state = Campaign.STATE.DEFEAT
    end

    self.battle = nil
end

-- Called from the VICTORY screen's [CONTINUE].
function Campaign:enterShop()
    if self.state ~= Campaign.STATE.VICTORY then return end
    self.state = Campaign.STATE.SHOP
end

function Campaign:buyCard(index)
    if self.state ~= Campaign.STATE.SHOP then return end
    local entry = self.shop[index]
    if not entry or entry.purchased or self.gold < entry.price then return end

    self.gold = self.gold - entry.price
    entry.purchased = true
    table.insert(self.deck, entry.card)
    self.reserveIds[entry.card.id] = true -- new cards start in Reserve until promoted
end

-- Called from the shop's [CONTINUE].
function Campaign:leaveShop()
    if self.state ~= Campaign.STATE.SHOP then return end
    if #self.availableOpponents == 0 then
        self.state = Campaign.STATE.CAMPAIGN_COMPLETE
    else
        self.state = Campaign.STATE.BATTLE_SELECT
    end
end

-- Called from the BATTLE_SELECT screen.
function Campaign:selectOpponent(commander)
    if self.state ~= Campaign.STATE.BATTLE_SELECT then return end
    self:startBattleAgainst(commander)
end

return Campaign
