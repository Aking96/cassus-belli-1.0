-- src/ai.lua
-- Basic enemy AI for v0.1. Deliberately simple (random selection) so the
-- battle loop can be validated first. Replace chooseCardIndex's body later
-- for smarter behavior -- callers only depend on this one function.

local AI = {}

-- Returns a 1-based index into hand.cards for the AI to play.
function AI.chooseCardIndex(hand)
    return love.math.random(#hand.cards)
end

return AI
