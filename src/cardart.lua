-- src/cardart.lua
-- Loads and caches the card face images (assets/cards/*.png -- the
-- "PNG-cards-1.3" pack), keyed by rank+suit so ui.lua never touches the
-- filesystem or LOVE's image API directly.

local CardArt = {}

local RANK_NAMES = {
    ["2"] = "2", ["3"] = "3", ["4"] = "4", ["5"] = "5", ["6"] = "6",
    ["7"] = "7", ["8"] = "8", ["9"] = "9", ["10"] = "10",
    ["J"] = "jack", ["Q"] = "queen", ["K"] = "king", ["A"] = "ace",
}

local cache = {}
local backImage

-- Returns the cached Image for `card`, loading it from disk on first use.
function CardArt.get(card)
    local key = card.rank .. card.suit
    local image = cache[key]
    if image then return image end

    local path = string.format("assets/cards/%s_of_%s.png", RANK_NAMES[card.rank], card.suit:lower())
    image = love.graphics.newImage(path)
    cache[key] = image
    return image
end

-- Returns the cached card-back Image (assets/ui/card_back.jpg), shared by
-- every face-down card regardless of suit/rank.
function CardArt.getBack()
    if not backImage then
        backImage = love.graphics.newImage("assets/ui/card_back.jpg")
    end
    return backImage
end

return CardArt
