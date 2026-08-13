-- src/commander.lua
-- Commander definitions and the pure strength-comparison hooks their
-- abilities plug into. Battle owns which commander(s), if any, each side
-- holds for the match; this module only implements the abilities themselves
-- so battle.lua's engagement/war comparisons stay readable.

local Commander = {}

Commander.CALIGULA = "Caligula"
Commander.JOAN_OF_ARC = "Joan of Arc"
Commander.STONEWALL = "Stonewall"
Commander.VLAD = "Vlad the Impaler"
Commander.PANCHO = "Pancho Villa"
Commander.HUNGRY_SEVEN = "Hungry 7"
Commander.JUSTICAR = "The Justicar"
Commander.STANDARD_BEARER = "The Standard-Bearer"
Commander.GAMBLER = "The Gambler"
Commander.ARISTOCRAT = "The Aristocrat"
Commander.TWINBINDER = "The Twinbinder"

Commander.ALL = {
    Commander.CALIGULA, Commander.JOAN_OF_ARC, Commander.STONEWALL, Commander.VLAD, Commander.PANCHO,
    Commander.HUNGRY_SEVEN, Commander.JUSTICAR, Commander.STANDARD_BEARER, Commander.GAMBLER,
    Commander.ARISTOCRAT, Commander.TWINBINDER,
}

-- How many Reserve->Deck cycles The Justicar grants (one every N wins).
Commander.JUSTICAR_WINS_PER_CYCLE = 3
-- The Standard-Bearer's Number Card bonus, and how many Face Cards you need
-- in hand to activate it.
Commander.STANDARD_BEARER_BONUS = 4
Commander.STANDARD_BEARER_FACE_COUNT = 3
-- The Aristocrat's 9-of-any-suit bonus while holding any King.
Commander.ARISTOCRAT_BONUS = 2
-- The Gambler's Reserve->Deck cycle fires every round the active deck's
-- card count is at or below half of what it started the battle with.
Commander.GAMBLER_THRESHOLD_FRACTION = 0.5
-- The Twinbinder can combine 2 Number Cards into one at most this many
-- times per battle, for either a normal engagement or a War pick.
Commander.TWINBINDER_USES_PER_BATTLE = 2

-- Short ability text, used by the UI when drawing a commander's card.
Commander.DESCRIPTIONS = {
    [Commander.CALIGULA] = "2s beat Aces",
    [Commander.JOAN_OF_ARC] = "Hearts +1 STR",
    [Commander.STONEWALL] = "War on near-ties",
    [Commander.VLAD] = "Spades +3 vs Hearts",
    [Commander.PANCHO] = "2-6 get +2 STR",
    [Commander.HUNGRY_SEVEN] = "7s beat 9s and 6s",
    [Commander.JUSTICAR] = "Every 3 wins: Reserve card -> Deck",
    [Commander.STANDARD_BEARER] = "3 Face Cards in hand: Numbers +4 STR",
    [Commander.GAMBLER] = "Frontline <=half: Reserve card -> Deck",
    [Commander.ARISTOCRAT] = "Holding a King: 9s +2 STR",
    [Commander.TWINBINDER] = "2x/battle: combine 2 Numbers to play",
}

-- Flavor quote shown under a commander's name on their portrait card.
Commander.QUOTES = {
    [Commander.CALIGULA] = "\"Let them hate me, so long as they fear me.\"",
    [Commander.JOAN_OF_ARC] = "\"I am not afraid. I was born to do this.\"",
    [Commander.STONEWALL] = "\"Stand firm. The wall does not break for anyone.\"",
    [Commander.VLAD] = "\"I do not ask for love. I ask for fear.\"",
    [Commander.PANCHO] = "\"The revolution is not for glory, it is for justice.\"",
    [Commander.HUNGRY_SEVEN] = "\"Six trembles. Nine didn't make it. Seven's still hungry.\"",
    [Commander.JUSTICAR] = "\"Every victory is repaid in kind.\"",
    [Commander.STANDARD_BEARER] = "\"Rally behind the colors, and the line will hold.\"",
    [Commander.GAMBLER] = "\"I've never lost -- I've only run out of luck early.\"",
    [Commander.ARISTOCRAT] = "\"Blood tells. The crown provides.\"",
    [Commander.TWINBINDER] = "\"Two hands, one purpose.\"",
}

-- Public so battle.lua can check for The Justicar/The Gambler/The
-- Twinbinder too -- those abilities mutate deck/reserve/hand state directly
-- rather than plugging into a strength comparison, so they live in
-- battle.lua itself instead of buffSource/hasOverrideWin/etc.
function Commander.hasCommander(commanders, name)
    for _, c in ipairs(commanders) do
        if c == name then return true end
    end
    return false
end

local hasCommander = Commander.hasCommander

-- Returns true if `hand` (an array of Card) contains a card of `rank`.
local function handHasRank(hand, rank)
    if not hand then return false end
    for _, c in ipairs(hand) do
        if c.rank == rank then return true end
    end
    return false
end

-- Returns how many Face Cards (J/Q/K) are in `hand`.
local function countFaceCards(hand)
    if not hand then return 0 end
    local count = 0
    for _, c in ipairs(hand) do
        if c:isFaceCard() then count = count + 1 end
    end
    return count
end

-- Returns the TOTAL strength bonus `card` gets this comparison, plus a list
-- of which held commanders contributed to it. Commanders stack: a side can
-- hold several at once (see Battle:assignCommanders / the multi-select
-- Commander Select screen), so if a card happens to qualify for more than
-- one bonus at the same time (e.g. Joan's Hearts bonus AND the Standard-
-- Bearer's Number Card bonus on the same Hearts-suited Number Card), both
-- apply and add together -- this never picks just one. `ownerHand` is the
-- current hand (array of Card) belonging to whoever owns `card` -- needed
-- for the two "while holding X" abilities; passing nil safely suppresses
-- those (they just never trigger).
function Commander.buffSources(card, commanders, opponentCard, ownerHand)
    local total = 0
    local sources = {}

    if hasCommander(commanders, Commander.JOAN_OF_ARC) and card.suit == "Hearts" then
        total = total + 1
        table.insert(sources, Commander.JOAN_OF_ARC)
    end

    if hasCommander(commanders, Commander.PANCHO) and card.suit and card.baseStrength <= 6 then
        total = total + 2
        table.insert(sources, Commander.PANCHO)
    end

    if hasCommander(commanders, Commander.VLAD) and card.suit == "Spades"
        and opponentCard and opponentCard.suit == "Hearts" then
        total = total + 3
        table.insert(sources, Commander.VLAD)
    end

    if hasCommander(commanders, Commander.ARISTOCRAT) and card.rank == "9"
        and handHasRank(ownerHand, "K") then
        total = total + Commander.ARISTOCRAT_BONUS
        table.insert(sources, Commander.ARISTOCRAT)
    end

    if hasCommander(commanders, Commander.STANDARD_BEARER) and card:isNumberCard()
        and countFaceCards(ownerHand) >= Commander.STANDARD_BEARER_FACE_COUNT then
        total = total + Commander.STANDARD_BEARER_BONUS
        table.insert(sources, Commander.STANDARD_BEARER)
    end

    return total, sources
end

-- Returns the effective strength of `card` for comparison, given the list
-- of commanders its owner currently holds. `opponentCard` is needed for
-- Vlad's matchup-specific bonus; `ownerHand` for the Standard-Bearer/
-- Aristocrat hand-contents bonuses.
function Commander.effectiveStrength(card, commanders, opponentCard, ownerHand)
    local bonus = Commander.buffSources(card, commanders, opponentCard, ownerHand)
    return card.currentStrength + bonus
end

-- Returns true if `card` beats `otherCard` outright due to a commander
-- ability, overriding the normal strength comparison (and any commander
-- strength buff) entirely:
--   Caligula: a 2 beats an Ace for whoever holds her.
--   Hungry 7: a 7 beats a 9 or a 6 for whoever holds him -- "6 is afraid of
--   7, and 7 ate 9."
function Commander.hasOverrideWin(card, otherCard, commanders)
    if hasCommander(commanders, Commander.CALIGULA) and card.rank == "2" and otherCard.rank == "A" then
        return true
    end

    if hasCommander(commanders, Commander.HUNGRY_SEVEN) and card.rank == "7"
        and (otherCard.rank == "9" or otherCard.rank == "6") then
        return true
    end

    return false
end

-- Returns true if this engagement's two cards are close enough to force a
-- War -- equal or exactly 1 rank apart by face value -- because either side
-- holds Stonewall. Checked regardless of which side holds him (his ability
-- isn't described as one-sided, unlike the others), and uses raw
-- baseStrength rather than any commander-buffed value since the ability is
-- specifically about face value.
function Commander.forcesNearTieWar(cardA, cardB, commandersA, commandersB)
    if not hasCommander(commandersA, Commander.STONEWALL)
        and not hasCommander(commandersB, Commander.STONEWALL) then
        return false
    end
    return math.abs(cardA.baseStrength - cardB.baseStrength) <= 1
end

-- Effective Rank rule: a card's printed Rank plus every Strength modifier it
-- currently carries (persistent upgrades baked into currentStrength, plus
-- any commander buff -- exactly what Commander.effectiveStrength computes)
-- is its "effective Rank." If either card's effective Rank matches the
-- OTHER card's plain printed Rank (baseStrength), that card can initiate a
-- War -- a universal rule, independent of which commanders either side
-- holds, distinct from Stonewall's own near-tie check. handA/handB are the
-- current hands of each card's owner, for the Standard-Bearer/Aristocrat
-- buffs that can factor into effective Rank.
function Commander.forcesEffectiveRankWar(cardA, cardB, commandersA, commandersB, handA, handB)
    local effectiveA = Commander.effectiveStrength(cardA, commandersA, cardB, handA)
    local effectiveB = Commander.effectiveStrength(cardB, commandersB, cardA, handB)
    return effectiveA == cardB.baseStrength or effectiveB == cardA.baseStrength
end

return Commander
