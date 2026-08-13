-- src/hand.lua
-- Fixed-size hand of cards drawn from a Deck. Handles refill and selection only;
-- knows nothing about battle rules or rendering.

local Hand = {}
Hand.__index = Hand

-- maxSize defaults to 5 per the v0.1 core loop.
function Hand.new(maxSize)
    local self = setmetatable({}, Hand)
    self.cards = {}
    self.maxSize = maxSize or 5
    return self
end

-- Draws from deck until the hand is full or the deck runs out.
function Hand:refill(deck)
    while #self.cards < self.maxSize and not deck:isEmpty() do
        table.insert(self.cards, deck:drawCard())
    end
end

-- Removes and returns the card at 1-based index (e.g. the card the player clicked).
function Hand:selectCard(index)
    return table.remove(self.cards, index)
end

function Hand:isFull()
    return #self.cards >= self.maxSize
end

function Hand:count()
    return #self.cards
end

return Hand
