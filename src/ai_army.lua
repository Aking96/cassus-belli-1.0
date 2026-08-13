-- src/ai_army.lua
-- Commander-themed AI deck generation for the campaign: each opponent's
-- army is built from weighted-random cards reflecting a loose profile per
-- commander (Demo Campaign Directive, sections 9-13). Preferences bias
-- probabilities -- they don't dictate the deck -- so two runs against the
-- same commander produce different, but similarly-themed, armies.
--
-- Builds real src/card.lua Card objects using existing constructors
-- (Card.new) -- no second card system.

local Card = require("src.card")
local Commander = require("src.commander")

local AIArmy = {}

local SUITS = { "Hearts", "Diamonds", "Clubs", "Spades" }
local RANKS = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A" }
local HIGH_RANKS = { "10", "J", "Q", "K", "A" }

-- highStrength: chance a given card is drawn from the high-rank pool instead
--   of the full rank spread.
-- bonus: chance a given card gets a strength bonus (split 3/2/1, biggest
--   bonus rarest) -- "upgraded" cards, same concept the shop sells.
local PROFILES = {
    [Commander.JOAN_OF_ARC] = { highStrength = 0.15, bonus = 0.15 }, -- balanced/reinforcement/defensive
    [Commander.PANCHO] = { highStrength = 0.10, bonus = 0.30 },       -- aggressive/high_strength/risk
    [Commander.STONEWALL] = { highStrength = 0.25, bonus = 0.15 },    -- defensive/high_strength/fortification
    [Commander.CALIGULA] = { highStrength = 0.35, bonus = 0.25 },     -- elite/high_strength/unpredictable
    [Commander.VLAD] = { highStrength = 0.30, bonus = 0.25 },         -- aggressive/overwhelming/high_strength
    [Commander.HUNGRY_SEVEN] = { highStrength = 0.10, bonus = 0.15 }, -- trickster/rank-gimmick, not raw strength
    [Commander.JUSTICAR] = { highStrength = 0.20, bonus = 0.20 },        -- balanced/sustain
    [Commander.STANDARD_BEARER] = { highStrength = 0.30, bonus = 0.15 }, -- leans Face-Card-heavy
    [Commander.GAMBLER] = { highStrength = 0.15, bonus = 0.30 },         -- high-variance/risk
    [Commander.ARISTOCRAT] = { highStrength = 0.30, bonus = 0.20 },      -- leans King-heavy
    [Commander.TWINBINDER] = { highStrength = 0.10, bonus = 0.15 },      -- leans Number-Card-heavy
}
local DEFAULT_PROFILE = { highStrength = 0.15, bonus = 0.15 }

local nextId = 1
local function freshId()
    nextId = nextId + 1
    return "E_ai_" .. nextId
end

local function randomRankedCard(profile)
    local pool = (love.math.random() < profile.highStrength) and HIGH_RANKS or RANKS
    local rank = pool[love.math.random(#pool)]
    local suit = SUITS[love.math.random(#SUITS)]
    local card = Card.new(freshId(), suit, rank)

    local roll = love.math.random()
    if roll < profile.bonus * 0.3 then
        card.currentStrength = card.currentStrength + 3
    elseif roll < profile.bonus * 0.6 then
        card.currentStrength = card.currentStrength + 2
    elseif roll < profile.bonus then
        card.currentStrength = card.currentStrength + 1
    end

    return card
end

-- Builds a `size`-card army for `commander` (matching whatever the player's
-- own deck totals, so both sides play a comparably-long battle).
function AIArmy.build(commander, size)
    local profile = PROFILES[commander] or DEFAULT_PROFILE
    local deck = {}

    for _ = 1, size do
        table.insert(deck, randomRankedCard(profile))
    end

    return deck
end

return AIArmy
