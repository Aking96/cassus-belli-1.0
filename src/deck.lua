-- src/deck.lua
-- Deck generation, shuffling, and draw/return operations.
-- A Deck is the ordered pool an army draws from during a battle.

local Card = require("src.card")

local Deck = {}
Deck.__index = Deck

local SUITS = { "Hearts", "Diamonds", "Clubs", "Spades" }
local RANKS = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A" }

-- Creates an empty deck.
function Deck.new()
    local self = setmetatable({}, Deck)
    self.cards = {}
    return self
end

-- Fills this deck with a standard 52-card set. idPrefix (e.g. "P" or "E")
-- keeps player/enemy card ids from colliding.
function Deck:generateStandard(idPrefix)
    local n = 1
    for _, suit in ipairs(SUITS) do
        for _, rank in ipairs(RANKS) do
            table.insert(self.cards, Card.new(idPrefix .. "_" .. n, suit, rank))
            n = n + 1
        end
    end
end

-- Fisher-Yates shuffle in place. Requires love.math (LOVE's seeded RNG).
function Deck:shuffle()
    for i = #self.cards, 2, -1 do
        local j = love.math.random(i)
        self.cards[i], self.cards[j] = self.cards[j], self.cards[i]
    end
end

-- Removes and returns the top card, or nil if the deck is empty.
function Deck:drawCard()
    return table.remove(self.cards, 1)
end

-- Adds a card to the bottom of the deck (used when a card is won).
function Deck:addToBottom(card)
    table.insert(self.cards, card)
end

-- Inserts a card at a random position -- "shuffles it in" rather than
-- stacking it predictably on top or bottom. Used by The Justicar and The
-- Gambler, both of which move a card from Reserve back into the Deck.
function Deck:addRandom(card)
    local index = love.math.random(#self.cards + 1)
    table.insert(self.cards, index, card)
end

function Deck:isEmpty()
    return #self.cards == 0
end

function Deck:count()
    return #self.cards
end

return Deck
