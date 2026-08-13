-- src/battle.lua
-- The core battle state machine. Owns both decks/hands and drives the loop
-- described in the v0.1 doc: draw -> select -> reveal -> resolve -> repeat.
-- Contains no rendering or input code (see src/ui.lua for that).

local Card = require("src.card")
local Deck = require("src.deck")
local Hand = require("src.hand")
local AI = require("src.ai")
local Commander = require("src.commander")

local nextCombineId = 1
local function freshCombineId()
    nextCombineId = nextCombineId + 1
    return "combo_" .. nextCombineId
end

local Battle = {}
Battle.__index = Battle

Battle.PHASE = {
    DRAW = "draw",             -- refill both hands to 5
    SELECT = "select",         -- waiting for player + AI to commit a card
    REVEAL = "reveal",         -- both cards committed, shown face up
    RESOLVE = "resolve",       -- compare strength, award or trigger war
    WAR_SELECT = "war_select", -- tied: player is choosing 3 cards + reveal order
    WAR_REVEAL = "war_reveal", -- war cards revealed one pair at a time
    WAR_SPOIL = "war_spoil",   -- war winner (if player) picks their 1 spoil card
    GAME_OVER = "game_over",   -- one army has zero cards left
}

-- How long both cards stay face-up before resolving/each War position reveal,
-- in seconds. Gives those moments actual on-screen presence instead of
-- lasting one frame.
Battle.REVEAL_DURATION = 1.0

-- Each side starts with a 26-card active deck and a 26-card reserve deck held
-- in the wings (one standard 52-card set split in half). Switching to
-- reserves is a one-time trade: whatever's left of the active deck AND hand
-- is sidelined for good (spent, not merged back in later), and the reserve
-- deck becomes the new active deck with a full hand refill so the fight
-- continues immediately instead of skipping a beat.
Battle.STARTING_ACTIVE_SIZE = 26

-- Threshold (active deck + hand) at which the AI decides it's "threatened"
-- and auto-switches to its reserves, if it still has an unused reserve deck.
Battle.AI_RESERVE_THRESHOLD = 4

-- How many cards each side commits per War round.
Battle.WAR_HAND_SIZE = 3

local function addLog(self, line)
    table.insert(self.log, line)
    local maxLines = 50
    while #self.log > maxLines do
        table.remove(self.log, 1)
    end
end

-- Builds one side's starting decks: a full standard 52-card set, shuffled,
-- then split into a 26-card active deck and a 26-card reserve deck.
local function buildSplitDecks(idPrefix)
    local full = Deck.new()
    full:generateStandard(idPrefix)
    full:shuffle()

    local reserve = Deck.new()
    for _ = 1, Battle.STARTING_ACTIVE_SIZE do
        reserve:addToBottom(full:drawCard())
    end

    return full, reserve -- full now holds the other half -- this is the active deck
end

-- opts (all optional, for campaign mode -- see src/campaign.lua):
--   playerDeck/playerReserveDeck, enemyDeck/enemyReserveDeck -- pre-built
--     Deck instances to use instead of a fresh standard 52-card split.
--   playerCommanders -- a fixed LIST of commander names for the player
--     (the Commander Select screen lets the player pick up to 5 to test how
--     they stack together), instead of the default random-1-per-side roll.
--   enemyCommander -- a single fixed commander name for the enemy (the AI
--     always fields exactly one).
-- Called with no opts at all, behavior is identical to before: two fresh
-- standard decks and a random commander per side.
function Battle.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Battle)

    if opts.playerDeck then
        self.playerDeck = opts.playerDeck
        self.playerReserveDeck = opts.playerReserveDeck or Deck.new()
    else
        self.playerDeck, self.playerReserveDeck = buildSplitDecks("P")
    end

    if opts.enemyDeck then
        self.enemyDeck = opts.enemyDeck
        self.enemyReserveDeck = opts.enemyReserveDeck or Deck.new()
    else
        self.enemyDeck, self.enemyReserveDeck = buildSplitDecks("E")
    end

    self.playerReserveUsed = false
    self.enemyReserveUsed = false
    self.playerSidelined = {}
    self.enemySidelined = {}

    -- The Gambler's threshold is relative to whatever the Frontline/active
    -- deck actually started this battle with (campaign decks can grow past
    -- the base 26), captured now before the first DRAW phase touches it.
    self.playerStartingActiveSize = self.playerDeck:count()
    self.enemyStartingActiveSize = self.enemyDeck:count()

    -- The Justicar counts wins (normal engagements and Wars alike); The
    -- Twinbinder counts how many times its combine ability has been used.
    -- Both reset fresh every battle.
    self.playerWinCount = 0
    self.enemyWinCount = 0
    self.playerCombinesUsed = 0
    self.enemyCombinesUsed = 0

    self.playerHand = Hand.new(5)
    self.enemyHand = Hand.new(5)

    self.playerCommanders = {}
    self.enemyCommanders = {}
    self:assignCommanders(opts.playerCommanders, opts.enemyCommander)

    self.phase = Battle.PHASE.DRAW
    self.playerSelection = nil
    self.enemySelection = nil
    self.revealTimer = 0
    self.winner = nil        -- "player" | "enemy" once GAME_OVER
    self.log = {}

    -- War state -- only meaningful while phase is one of the WAR_* phases.
    self.playerWarHand = {}       -- current round's picks, in reveal order
    self.enemyWarHand = {}        -- AI's committed cards for the current round
    self.warAllPlayerCards = {}   -- every card the player has committed across all
                                   -- rounds of this War (including the original tied
                                   -- card) -- the pool AI recruits its spoil from
    self.warAllEnemyCards = {}    -- same for the enemy -- the pool the player picks from
    self.warPlayerWins = 0
    self.warEnemyWins = 0
    self.warRevealIndex = 0       -- how many positions have been revealed/compared
    self.warRevealTimer = 0
    self.warWinner = nil
    self.warSpoilChoices = {}     -- cards currently offered for the spoil pick

    return self
end

-- Rolled once per battle (not per round), unless a campaign fixes one or
-- both sides (see Battle.new's opts). The player can hold several at once
-- (fixedPlayerCommanders is a LIST -- Commander Select lets them pick up to
-- 5 to test how abilities stack); the enemy always fields exactly one,
-- random if not fixed. Whatever's assigned stays fixed for the whole
-- battle, all the way until a winner is decided (GAME_OVER).
function Battle:assignCommanders(fixedPlayerCommanders, fixedEnemyCommander)
    if fixedPlayerCommanders and #fixedPlayerCommanders > 0 then
        self.playerCommanders = fixedPlayerCommanders
    else
        self.playerCommanders = { Commander.ALL[love.math.random(#Commander.ALL)] }
    end
    self.enemyCommanders = { fixedEnemyCommander or Commander.ALL[love.math.random(#Commander.ALL)] }
end

-- Call once per love.update(). Advances the state machine.
function Battle:update(dt)
    if self.phase == Battle.PHASE.DRAW then
        self:checkGamblerCycle("player")
        self:checkGamblerCycle("enemy")
        self.playerHand:refill(self.playerDeck)
        self.enemyHand:refill(self.enemyDeck)
        self.phase = Battle.PHASE.SELECT

    elseif self.phase == Battle.PHASE.SELECT then
        -- AI switches to reserves on its own initiative if its active army is
        -- running thin -- mirrors the player's manual option so neither side
        -- has an exclusive advantage.
        if not self.enemyReserveUsed
            and not self.enemySelection
            and self.enemyDeck:count() + self.enemyHand:count() <= Battle.AI_RESERVE_THRESHOLD
            and not self.enemyReserveDeck:isEmpty()
        then
            self:switchToReserves("enemy")
        end

        -- The AI commits blind, independent of the player's choice -- it never
        -- looks at self.playerSelection. Whichever side commits first is kept
        -- face-down by the UI until both are locked in, so neither side gets
        -- to see the other's card before deciding.
        if not self.enemySelection and self.enemyHand:count() > 0 then
            local idx = AI.chooseCardIndex(self.enemyHand)
            self.enemySelection = self.enemyHand:selectCard(idx)
        end

    elseif self.phase == Battle.PHASE.REVEAL then
        self.revealTimer = self.revealTimer - dt
        if self.revealTimer <= 0 then
            self.phase = Battle.PHASE.RESOLVE
        end

    elseif self.phase == Battle.PHASE.RESOLVE then
        self:resolveEngagement()

    elseif self.phase == Battle.PHASE.WAR_REVEAL then
        self.warRevealTimer = self.warRevealTimer - dt
        if self.warRevealTimer <= 0 then
            self:revealNextWarPosition()
        end
    end
    -- WAR_SELECT and WAR_SPOIL both wait on a player click; nothing to tick.
end

-- Called from UI input when the player clicks a card in their hand.
function Battle:playerChoose(index)
    if self.phase ~= Battle.PHASE.SELECT then return end
    self.playerSelection = self.playerHand:selectCard(index)
    if self.enemySelection then
        self.phase = Battle.PHASE.REVEAL
        self.revealTimer = Battle.REVEAL_DURATION
    end
end

-- Sidelines whatever's left of side's active deck + hand (for good -- this
-- is a one-way trade, not a reshuffle) and swaps in its reserve deck as the
-- new active deck, refilling the hand immediately so play continues without
-- a skipped round. Only usable before that side has committed a card this
-- round, and only once per side. Returns true if the switch happened.
function Battle:switchToReserves(side)
    if self.phase ~= Battle.PHASE.SELECT then return false end

    local isPlayer = side == "player"
    local alreadySelected = isPlayer and self.playerSelection or self.enemySelection
    if alreadySelected then return false end

    local reserveUsed = isPlayer and self.playerReserveUsed or self.enemyReserveUsed
    local reserveDeck = isPlayer and self.playerReserveDeck or self.enemyReserveDeck
    if reserveUsed or reserveDeck:isEmpty() then return false end

    local activeDeck = isPlayer and self.playerDeck or self.enemyDeck
    local hand = isPlayer and self.playerHand or self.enemyHand
    local sidelined = isPlayer and self.playerSidelined or self.enemySidelined

    while not activeDeck:isEmpty() do
        table.insert(sidelined, activeDeck:drawCard())
    end
    while hand:count() > 0 do
        table.insert(sidelined, hand:selectCard(1))
    end

    if isPlayer then
        self.playerDeck = reserveDeck
        self.playerReserveDeck = Deck.new()
        self.playerReserveUsed = true
        self.playerHand:refill(self.playerDeck)
    else
        self.enemyDeck = reserveDeck
        self.enemyReserveDeck = Deck.new()
        self.enemyReserveUsed = true
        self.enemyHand:refill(self.enemyDeck)
    end

    addLog(self, (isPlayer and "You" or "Enemy") ..
        " sideline their remaining cards and fall back to reserves!")
    return true
end

-- Compares the two committed cards and resolves the engagement, or kicks off
-- a War if they tied. Applied in order: Caligula's 2-beats-Ace (and Hungry
-- 7's 7-beats-9-or-6) override first (bypasses strength entirely), then
-- Stonewall's near-tie-forces-War check, then the universal Effective Rank
-- rule (a card whose Strength-boosted effective Rank matches the opponent's
-- plain printed Rank can force a War on its own, independent of
-- commanders), then the normal comparison using each card's commander-
-- adjusted effective strength (Joan/Vlad).
function Battle:resolveEngagement()
    local p, e = self.playerSelection, self.enemySelection

    if Commander.hasOverrideWin(p, e, self.playerCommanders) then
        self:awardEngagement("player", p, e)
        return
    elseif Commander.hasOverrideWin(e, p, self.enemyCommanders) then
        self:awardEngagement("enemy", p, e)
        return
    end

    if Commander.forcesNearTieWar(p, e, self.playerCommanders, self.enemyCommanders) then
        self:beginWar(p, e)
        return
    end

    if Commander.forcesEffectiveRankWar(p, e, self.playerCommanders, self.enemyCommanders,
        self.playerHand.cards, self.enemyHand.cards) then
        self:beginWar(p, e)
        return
    end

    local pStrength = Commander.effectiveStrength(p, self.playerCommanders, e, self.playerHand.cards)
    local eStrength = Commander.effectiveStrength(e, self.enemyCommanders, p, self.enemyHand.cards)

    if pStrength > eStrength then
        self:awardEngagement("player", p, e)
    elseif eStrength > pStrength then
        self:awardEngagement("enemy", p, e)
    else
        self:beginWar(p, e)
    end
end

-- Gives the listed cards to winner's deck and ends the round normally.
function Battle:awardEngagement(winner, ...)
    local targetDeck = (winner == "player") and self.playerDeck or self.enemyDeck
    local cards = { ... }
    for _, card in ipairs(cards) do
        targetDeck:addToBottom(card)
    end
    addLog(self, string.format("%s wins the engagement and claims %d card(s).", winner, #cards))
    self:registerWin(winner)

    self.playerSelection = nil
    self.enemySelection = nil
    self:finishRound()
end

-- Increments `side`'s win counter (normal engagements and Wars both count)
-- and, if it holds The Justicar and just crossed a multiple of
-- JUSTICAR_WINS_PER_CYCLE, shuffles one card from its Reserve back into its
-- Deck.
function Battle:registerWin(side)
    local isPlayer = side == "player"
    if isPlayer then
        self.playerWinCount = self.playerWinCount + 1
    else
        self.enemyWinCount = self.enemyWinCount + 1
    end

    local commanders = isPlayer and self.playerCommanders or self.enemyCommanders
    if not Commander.hasCommander(commanders, Commander.JUSTICAR) then return end

    local winCount = isPlayer and self.playerWinCount or self.enemyWinCount
    if winCount % Commander.JUSTICAR_WINS_PER_CYCLE ~= 0 then return end

    local reserveDeck = isPlayer and self.playerReserveDeck or self.enemyReserveDeck
    local activeDeck = isPlayer and self.playerDeck or self.enemyDeck
    if reserveDeck:isEmpty() then return end

    activeDeck:addRandom(reserveDeck:drawCard())
    addLog(self, (isPlayer and "Your" or "Enemy's") ..
        " Justicar shuffles a Reserve card back into the Deck.")
end

-- Checks The Gambler's recurring comeback trigger for `side`: every round
-- its active deck's card count is at or below half of what it started this
-- battle with, one card shuffles from Reserve into Deck (not a one-time
-- trigger -- it keeps firing every such round as long as Reserve lasts).
-- Called once per DRAW phase, for both sides independently.
function Battle:checkGamblerCycle(side)
    local isPlayer = side == "player"
    local commanders = isPlayer and self.playerCommanders or self.enemyCommanders
    if not Commander.hasCommander(commanders, Commander.GAMBLER) then return end

    local activeDeck = isPlayer and self.playerDeck or self.enemyDeck
    local startingSize = isPlayer and self.playerStartingActiveSize or self.enemyStartingActiveSize
    local threshold = math.floor(startingSize * Commander.GAMBLER_THRESHOLD_FRACTION)
    if activeDeck:count() > threshold then return end

    local reserveDeck = isPlayer and self.playerReserveDeck or self.enemyReserveDeck
    if reserveDeck:isEmpty() then return end

    activeDeck:addRandom(reserveDeck:drawCard())
    addLog(self, (isPlayer and "Your" or "Enemy's") ..
        " Gambler shuffles a Reserve card back into the Deck.")
end

-- Shared end-of-round bookkeeping used by both a normal engagement win and a
-- fully-resolved War (including its spoil pick).
function Battle:finishRound()
    self:checkWinLoss()
    if self.phase ~= Battle.PHASE.GAME_OVER then
        self.phase = Battle.PHASE.DRAW
    end
end

-- Ranks tied: normal engagement pauses and a War begins (Design Bible 3.8).
-- The two tied cards are the first cards "involved in the War" -- everything
-- that gets committed from here on, by both sides, joins the same pool and
-- is only settled once a War winner is finally declared.
function Battle:beginWar(playerTiedCard, enemyTiedCard)
    self.playerSelection = nil
    self.enemySelection = nil
    self.warAllPlayerCards = { playerTiedCard }
    self.warAllEnemyCards = { enemyTiedCard }
    self:startWarRound()
end

-- Starts one round of the War: each side secretly commits WAR_HAND_SIZE
-- fresh cards from their current hand (refilled from their active deck
-- first). The player chooses which cards AND the order they're revealed in;
-- the AI's pick is immediate and random, matching its existing simplicity
-- everywhere else. If a round doesn't produce a majority (2 of 3), a brand
-- new round begins with entirely fresh cards -- see revealNextWarPosition.
function Battle:startWarRound()
    local playerAvailable = self.playerHand:count() + self.playerDeck:count()
    local enemyAvailable = self.enemyHand:count() + self.enemyDeck:count()

    if playerAvailable < Battle.WAR_HAND_SIZE or enemyAvailable < Battle.WAR_HAND_SIZE then
        -- Whoever can't field a full reinforcement line forfeits the War;
        -- checkWinLoss will settle the overall game shortly regardless.
        local winner
        if playerAvailable < Battle.WAR_HAND_SIZE and enemyAvailable < Battle.WAR_HAND_SIZE then
            winner = enemyAvailable >= playerAvailable and "enemy" or "player"
        else
            winner = playerAvailable < Battle.WAR_HAND_SIZE and "enemy" or "player"
        end
        self:finishWar(winner)
        return
    end

    self.playerHand:refill(self.playerDeck)
    self.playerWarHand = {}
    self.enemyWarHand = self:pickEnemyWarHand(Battle.WAR_HAND_SIZE)

    self.warPlayerWins = 0
    self.warEnemyWins = 0
    self.warRevealIndex = 0

    addLog(self, string.format("War! Pick %d cards and their reveal order.", Battle.WAR_HAND_SIZE))
    self.phase = Battle.PHASE.WAR_SELECT
end

function Battle:pickEnemyWarHand(count)
    self.enemyHand:refill(self.enemyDeck)
    local picked = {}
    for _ = 1, count do
        if self.enemyHand:count() == 0 then break end
        local idx = AI.chooseCardIndex(self.enemyHand)
        table.insert(picked, self.enemyHand:selectCard(idx))
    end
    return picked
end

-- Called from UI when the player clicks a hand card during WAR_SELECT. Cards
-- are added to the war hand in click order -- that IS the reveal order.
function Battle:pickWarCard(index)
    if self.phase ~= Battle.PHASE.WAR_SELECT then return end
    if #self.playerWarHand >= Battle.WAR_HAND_SIZE then return end

    table.insert(self.playerWarHand, self.playerHand:selectCard(index))

    if #self.playerWarHand >= Battle.WAR_HAND_SIZE then
        self.phase = Battle.PHASE.WAR_REVEAL
        self.warRevealTimer = Battle.REVEAL_DURATION
    end
end

-- Returns true if the player could combine two cards right now: holds The
-- Twinbinder, hasn't used up TWINBINDER_USES_PER_BATTLE combines this
-- battle, and it's actually their turn to commit a card (a normal
-- engagement pick, or a War pick with room left in this round's hand).
function Battle:canCombine()
    if not Commander.hasCommander(self.playerCommanders, Commander.TWINBINDER) then return false end
    if self.playerCombinesUsed >= Commander.TWINBINDER_USES_PER_BATTLE then return false end
    if self.phase == Battle.PHASE.SELECT then return true end
    if self.phase == Battle.PHASE.WAR_SELECT and #self.playerWarHand < Battle.WAR_HAND_SIZE then return true end
    return false
end

-- The Twinbinder: combines the two Number Cards at hand indices `indexA`
-- and `indexB` into one new card (summed rank, capped at Ace; strength
-- bonuses from both source cards carry over; suit follows whichever source
-- card had the higher printed rank), then plays that combined card exactly
-- as if it had been clicked directly -- as a normal engagement pick during
-- SELECT, or as the next War pick during WAR_SELECT. Both source cards are
-- spent; only the combined card enters play.
function Battle:combinePlayerCards(indexA, indexB)
    if not self:canCombine() then return false end
    if not indexA or not indexB or indexA == indexB then return false end

    local cards = self.playerHand.cards
    local a, b = cards[indexA], cards[indexB]
    if not a or not b then return false end
    if not a:isNumberCard() or not b:isNumberCard() then return false end

    -- Remove the higher index first so the lower index isn't shifted out
    -- from under it.
    local first, second = math.max(indexA, indexB), math.min(indexA, indexB)
    self.playerHand:selectCard(first)
    self.playerHand:selectCard(second)

    local combinedBase = math.min(14, a.baseStrength + b.baseStrength)
    local bonusCarry = (a.currentStrength - a.baseStrength) + (b.currentStrength - b.baseStrength)
    local suit = (b.baseStrength > a.baseStrength) and b.suit or a.suit

    local combined = Card.new(freshCombineId(), suit, Card.RANK_FROM_STRENGTH[combinedBase])
    combined.currentStrength = combined.baseStrength + bonusCarry

    self.playerCombinesUsed = self.playerCombinesUsed + 1
    addLog(self, string.format("You combine %s and %s into %s.", a:getLabel(), b:getLabel(), combined:getLabel()))

    if self.phase == Battle.PHASE.SELECT then
        self.playerSelection = combined
        if self.enemySelection then
            self.phase = Battle.PHASE.REVEAL
            self.revealTimer = Battle.REVEAL_DURATION
        end
    else
        table.insert(self.playerWarHand, combined)
        if #self.playerWarHand >= Battle.WAR_HAND_SIZE then
            self.phase = Battle.PHASE.WAR_REVEAL
            self.warRevealTimer = Battle.REVEAL_DURATION
        end
    end

    return true
end

-- Reveals and compares the next position (slot) in the war hands. Equal
-- strength (same rank, different suit) is a draw for that position and adds
-- to neither side's count. Once all positions in the round are revealed, the
-- side with at least 2 of 3 wins the War outright; otherwise this round's
-- cards join the pool and an entirely new round begins (Recursive Wars).
function Battle:revealNextWarPosition()
    self.warRevealIndex = self.warRevealIndex + 1
    local i = self.warRevealIndex
    local pCard = self.playerWarHand[i]
    local eCard = self.enemyWarHand[i]

    if Commander.hasOverrideWin(pCard, eCard, self.playerCommanders) then
        self.warPlayerWins = self.warPlayerWins + 1
    elseif Commander.hasOverrideWin(eCard, pCard, self.enemyCommanders) then
        self.warEnemyWins = self.warEnemyWins + 1
    else
        local pStrength = Commander.effectiveStrength(pCard, self.playerCommanders, eCard, self.playerHand.cards)
        local eStrength = Commander.effectiveStrength(eCard, self.enemyCommanders, pCard, self.enemyHand.cards)
        if pStrength > eStrength then
            self.warPlayerWins = self.warPlayerWins + 1
        elseif eStrength > pStrength then
            self.warEnemyWins = self.warEnemyWins + 1
        end
    end

    if i < #self.playerWarHand then
        self.warRevealTimer = Battle.REVEAL_DURATION
        return
    end

    for _, card in ipairs(self.playerWarHand) do
        table.insert(self.warAllPlayerCards, card)
    end
    for _, card in ipairs(self.enemyWarHand) do
        table.insert(self.warAllEnemyCards, card)
    end
    self.playerWarHand = {}
    self.enemyWarHand = {}

    if self.warPlayerWins >= 2 then
        self:finishWar("player")
    elseif self.warEnemyWins >= 2 then
        self:finishWar("enemy")
    else
        addLog(self, "No majority -- a new War begins!")
        self:startWarRound()
    end
end

-- A War winner has been declared. The winner recruits exactly one card
-- (permanently -- see Card.permanent) from among everything involved in the
-- War, from any round; every OTHER War-involved card -- from both sides --
-- now goes into the WINNER's deck for the rest of this battle instead of
-- returning to its original owner, i.e. a War is a full capture, and the one
-- chosen card is additionally flagged for a future cross-battle system.
function Battle:finishWar(winner)
    addLog(self, winner == "player" and "You win the War!" or "Enemy wins the War!")
    self.warWinner = winner
    self:registerWin(winner)

    if winner == "player" then
        self.warSpoilChoices = self.warAllEnemyCards
        self.phase = Battle.PHASE.WAR_SPOIL
    else
        self:takeWarSpoilForAI()
    end
end

-- Called from UI when the player clicks their chosen spoil card.
function Battle:chooseWarSpoil(index)
    if self.phase ~= Battle.PHASE.WAR_SPOIL then return end
    local spoil = table.remove(self.warAllEnemyCards, index)
    if not spoil then return end

    spoil.permanent = true
    self.playerDeck:addToBottom(spoil)
    addLog(self, "You permanently recruit " .. spoil:getLabel() .. " from the War.")

    self:settleWarCards("player")
    self:finishRound()
end

-- AI's own spoil pick: simple greedy heuristic (takes the single strongest
-- card the player committed to the War), matching the AI's existing "no real
-- strategy elsewhere either" simplicity.
function Battle:takeWarSpoilForAI()
    local pool = self.warAllPlayerCards
    local bestIndex = 1
    for i = 2, #pool do
        if pool[i].currentStrength > pool[bestIndex].currentStrength then
            bestIndex = i
        end
    end
    local spoil = table.remove(pool, bestIndex)
    if spoil then
        spoil.permanent = true
        self.enemyDeck:addToBottom(spoil)
        addLog(self, "Enemy permanently recruits " .. spoil:getLabel() .. " from the War.")
    end

    self:settleWarCards("enemy")
    self:finishRound()
end

-- Sends every remaining War-involved card (everything except whichever one
-- was taken as the spoil) into winner's deck for the rest of this battle,
-- and clears War state.
function Battle:settleWarCards(winner)
    local winnerDeck = (winner == "player") and self.playerDeck or self.enemyDeck
    for _, card in ipairs(self.warAllPlayerCards) do
        winnerDeck:addToBottom(card)
    end
    for _, card in ipairs(self.warAllEnemyCards) do
        winnerDeck:addToBottom(card)
    end
    self.warAllPlayerCards = {}
    self.warAllEnemyCards = {}
    self.warSpoilChoices = {}
end

-- Returns every card currently on the player's side (active deck, hand,
-- reserve, and sidelined) that was permanently recruited via a War this
-- battle (see Card.permanent). Used by the campaign layer to fold War-won
-- cards into the persistent deck on victory -- battle.lua doesn't know
-- campaigns exist, it just answers "which of my cards are marked permanent."
function Battle:collectPlayerPermanentCards()
    local found = {}
    local pools = { self.playerDeck.cards, self.playerHand.cards, self.playerReserveDeck.cards, self.playerSidelined }
    for _, pool in ipairs(pools) do
        for _, card in ipairs(pool) do
            if card.permanent then table.insert(found, card) end
        end
    end
    return found
end

-- True while any War phase is active (select/reveal/spoil). Exposed so
-- rendering code (ui.lua's zoom/darken trigger, the background's War-
-- intensity hook) doesn't need to duplicate this phase list itself.
function Battle:isInWar()
    return self.phase == Battle.PHASE.WAR_SELECT
        or self.phase == Battle.PHASE.WAR_REVEAL
        or self.phase == Battle.PHASE.WAR_SPOIL
end

-- An army is defeated once its active deck + hand are both empty. A reserve
-- deck only helps if switched to before that point -- see switchToReserves.
function Battle:checkWinLoss()
    local playerTotal = self.playerDeck:count() + self.playerHand:count()
    local enemyTotal = self.enemyDeck:count() + self.enemyHand:count()

    if playerTotal == 0 then
        self.winner = "enemy"
        self.phase = Battle.PHASE.GAME_OVER
    elseif enemyTotal == 0 then
        self.winner = "player"
        self.phase = Battle.PHASE.GAME_OVER
    end
end

return Battle
