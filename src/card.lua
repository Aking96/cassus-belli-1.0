-- src/card.lua
-- Playing card data structure. Pure data + accessors, no rendering, no game logic.
--
-- Fields (per Claude Development Documentation v0.1):
--   id              unique identifier, never changes
--   suit            "Hearts" | "Diamonds" | "Clubs" | "Spades"
--   rank            "2".."10","J","Q","K","A" -- never changes
--   baseStrength    numeric strength derived from rank at creation, never changes
--   currentStrength numeric strength used in comparisons; may be modified by upgrades/effects
--   upgradeLevel    integer, starts at 0
--   tags            table used as a set, e.g. { veteran = true }
--   permanent       true once recruited as a War spoil (Section 3.8) -- not
--                   acted on yet (no cross-battle campaign layer exists),
--                   but set now so that future system has something to read

local Card = {}
Card.__index = Card

-- Standard War-style rank -> strength mapping. 2 is weakest, Ace is strongest.
Card.RANK_STRENGTH = {
    ["2"] = 2,  ["3"] = 3,  ["4"] = 4,  ["5"] = 5,  ["6"] = 6,
    ["7"] = 7,  ["8"] = 8,  ["9"] = 9,  ["10"] = 10,
    ["J"] = 11, ["Q"] = 12, ["K"] = 13, ["A"] = 14,
}

-- Reverse of RANK_STRENGTH -- e.g. for The Twinbinder, which builds a new
-- card from a combined strength value and needs the rank string back.
Card.RANK_FROM_STRENGTH = {}
for rank, strength in pairs(Card.RANK_STRENGTH) do
    Card.RANK_FROM_STRENGTH[strength] = rank
end

-- "Number Cards" (2-10) vs "Face Cards" (J/Q/K) -- standard terminology,
-- Ace counts as neither. Used by The Standard-Bearer, The Aristocrat, and
-- The Twinbinder.
Card.NUMBER_RANKS = {
    ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true, ["6"] = true,
    ["7"] = true, ["8"] = true, ["9"] = true, ["10"] = true,
}
Card.FACE_RANKS = { ["J"] = true, ["Q"] = true, ["K"] = true }

-- Creates a new card. id must be unique within the deck it belongs to.
function Card.new(id, suit, rank)
    assert(Card.RANK_STRENGTH[rank], "Unknown rank: " .. tostring(rank))

    local self = setmetatable({}, Card)
    local strength = Card.RANK_STRENGTH[rank]

    self.id = id
    self.suit = suit
    self.rank = rank
    self.baseStrength = strength
    self.currentStrength = strength
    self.upgradeLevel = 0
    self.tags = {}
    self.permanent = false

    return self
end

-- Returns a short human-readable label, e.g. "K of Spades".
function Card:getLabel()
    return self.rank .. " of " .. self.suit
end

function Card:isNumberCard()
    return Card.NUMBER_RANKS[self.rank] == true
end

function Card:isFaceCard()
    return Card.FACE_RANKS[self.rank] == true
end

-- Returns an independent copy of this card under `newId`. Used when a
-- persistent record (e.g. a campaign's deck) needs to enter a Battle without
-- the Battle's own mutations (capture, permanent-flagging, sideline) ever
-- touching the original -- the campaign's deck only changes via explicit
-- purchases, never as a side effect of how one particular battle went.
function Card:clone(newId)
    local copy = Card.new(newId, self.suit, self.rank)
    copy.currentStrength = self.currentStrength
    copy.upgradeLevel = self.upgradeLevel
    copy.permanent = self.permanent
    for tag in pairs(self.tags) do copy.tags[tag] = true end
    return copy
end

-- Adds a tag (e.g. Card:addTag("veteran")).
function Card:addTag(tag)
    self.tags[tag] = true
end

-- Returns true if the card has the given tag.
function Card:hasTag(tag)
    return self.tags[tag] == true
end

return Card
