-------------------------------------------------------------------------------
--  EllesmereUIBags_FilterEngine.lua
--  Search/filter predicate engine for EllesmereUIBags.
--
--  Evaluates a search query against a normalized bag item record, returning
--  true when the item passes the current filter.
--
--  Architecture (pipeline stage: after classify, before category/sort/render):
--    source items → normalize → [FilterEngine] → CategoryEngine → SortEngine → render
--
--  Current capabilities (MVP):
--    • Plain-text name match (case-insensitive)
--    • Blizzard native isFiltered passthrough
--
--  Extension points (future tokens):
--    • RegisterToken(prefix, handler)  -- e.g. "q:", "type:", "ilvl:", "slot:"
--    • ParseQuery splits raw text into plain text + token list
--    • Each token handler receives the normalized record and returns true/false
--
--  Public API (global: EUI_FilterEngine):
--    EUI_FilterEngine:SetQuery(text)            -- update active query
--    EUI_FilterEngine:GetQuery()                -- current raw query string
--    EUI_FilterEngine:Matches(data, query)      -- test one item (stateless)
--    EUI_FilterEngine:Filter(items)             -- filter a list in-place (modifies _feShow)
--    EUI_FilterEngine:IsActive()                -- true when query is non-empty
--    EUI_FilterEngine:RegisterToken(prefix, fn) -- extend with custom token handler
-------------------------------------------------------------------------------

EUI_FilterEngine = {}

-------------------------------------------------------------------------------
--  Internal state
-------------------------------------------------------------------------------
local _query   = ""   -- current lowercased trimmed query
local _rawQuery = ""  -- unmodified query as set by caller

-- Token handler registry: { prefix -> function(data, value):bool }
-- Handlers receive a normalized item record and the token value (string after
-- the colon). Return true = item matches this token, false = does not match.
local _tokenHandlers = {}

-------------------------------------------------------------------------------
--  Helpers
-------------------------------------------------------------------------------
local function Trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Resolve item name from a normalized data record.
-- Prefers pre-cached _sortName (set by PreCacheSortFields in the main module),
-- then falls back to GetItemInfo. Returns "" when name is not yet in cache.
local function GetItemName(data)
    if data._sortName and data._sortName ~= "" then
        return data._sortName
    end
    if data.itemLink then
        local name = GetItemInfo and (GetItemInfo(data.itemLink))
        if name then return name end
    end
    if data.info and data.info.itemID then
        local name = GetItemInfo and (GetItemInfo(data.info.itemID))
        if name then return name end
    end
    return ""
end

-------------------------------------------------------------------------------
--  Query parsing
--  Returns: plainText (string), tokens (list of {prefix, value})
--
--  Token syntax: prefix:value   (e.g. q:epic  type:consumable  ilvl:>450)
--  Unrecognized tokens are folded back into the plain-text segment so that
--  typing "q:unknown" does not silently hide everything.
-------------------------------------------------------------------------------
local function ParseQuery(rawText)
    local plain = {}
    local tokens = {}
    for part in rawText:gmatch("%S+") do
        local prefix, value = part:match("^([%a_]+):(.+)$")
        if prefix and _tokenHandlers[prefix] then
            tokens[#tokens + 1] = { prefix = prefix, value = value }
        else
            plain[#plain + 1] = part
        end
    end
    return table.concat(plain, " "), tokens
end

-------------------------------------------------------------------------------
--  Public API
-------------------------------------------------------------------------------

-- Update the active query.  Callers (search box OnTextChanged) should pass the
-- raw text; trimming and lowercasing are handled here.
function EUI_FilterEngine:SetQuery(text)
    _rawQuery = text or ""
    _query = Trim(_rawQuery):lower()
end

-- Return the current raw (untransformed) query string.
function EUI_FilterEngine:GetQuery()
    return _rawQuery
end

-- True when any filter is active (query non-empty OR tokens set).
function EUI_FilterEngine:IsActive()
    return _query ~= ""
end

-- Register a custom token handler for advanced filter tokens.
-- prefix  (string): token keyword without the colon, e.g. "q" or "type"
-- handler (function): function(data, value) -> bool
--   data  = normalized item record (has .itemLink, .info, ._sortName, ._giQuality, etc.)
--   value = string after the colon (e.g. "epic", "consumable", ">450")
-- Returns true = item matches, false/nil = item does not match.
function EUI_FilterEngine:RegisterToken(prefix, handler)
    if type(prefix) == "string" and type(handler) == "function" then
        _tokenHandlers[prefix:lower()] = handler
    end
end

-------------------------------------------------------------------------------
--  Bind-type keyword lookup
--  Maps short user-facing terms to their bind classification.
--  Used both by the standalone-keyword path and the "bind:" token handler.
-------------------------------------------------------------------------------
-- Returns true when data matches the requested bind keyword.
-- Returns nil when the required data fields are not yet cached (item deferred).
local function MatchBindKeyword(data, kw)
    if kw == "boe" then
        if data._giBindType == nil then return nil end  -- bind data not yet cached
        return data._giBindType == Enum.ItemBind.OnEquip and not data._isWuE
    elseif kw == "wue" then
        if data._isWuE == nil then return nil end
        return data._isWuE == true
    elseif kw == "bop" then
        if data._giBindType == nil then return nil end
        return data._giBindType == Enum.ItemBind.OnPickup
    elseif kw == "bou" then
        if data._giBindType == nil then return nil end
        return data._giBindType == Enum.ItemBind.OnUse
    elseif kw == "boa" then
        if data._isWarbound == nil then return nil end
        -- Treat account-wide (warbound) items as BoA
        return data._isWarbound == true
    end
    return nil  -- not a recognized bind keyword
end

-- Known standalone binding keywords (pre-built set for O(1) lookup)
local _bindKeywords = { boe = true, bop = true, boa = true, bou = true, wue = true }

-- Test whether a single item passes the given query string (stateless).
-- query defaults to the current active query when omitted.
-- Returns true when the item should be shown, false when it should be hidden.
function EUI_FilterEngine:Matches(data, query)
    local q = query ~= nil and Trim(query):lower() or _query
    if q == "" then return true end

    -- Empty item slots always pass (they render as empty pads, not filtered out)
    if not data or not data.info then return true end

    -- Parse the query into plain text + tokens
    local plainText, tokens = ParseQuery(q)

    -- Evaluate token predicates first; any failing token hides the item
    for _, tok in ipairs(tokens) do
        local handler = _tokenHandlers[tok.prefix]
        if handler and not handler(data, tok.value) then
            return false
        end
    end

    -- Plain-text matching
    if plainText ~= "" then
        -- Check each whitespace-separated word: if ALL words are satisfied the
        -- item passes.  A word can be satisfied by a name substring match OR by
        -- a recognized bind-type keyword (boe/bop/boa/bou/wue).
        local allPass = true
        for word in plainText:gmatch("%S+") do
            local wordPass = false
            -- Bind-type keyword shortcut
            if _bindKeywords[word] then
                local matched = MatchBindKeyword(data, word)
                if matched == true then
                    wordPass = true
                elseif matched == false then
                    -- Recognized keyword but item doesn't match
                    allPass = false
                    break
                else
                    -- nil = bind data not yet cached; let item through so it
                    -- can be re-evaluated when the bag refreshes with full data.
                    wordPass = true
                end
            end
            if not wordPass then
                -- Fall back to name substring match
                local name = GetItemName(data):lower()
                if name == "" then
                    -- Name not yet in cache; defer to Blizzard's isFiltered when available
                    if data.info.isFiltered then allPass = false end
                    -- Let uncached items through; they will be re-evaluated on next refresh
                    break
                end
                if name:find(word, 1, true) then
                    wordPass = true
                end
            end
            if not wordPass then
                allPass = false
                break
            end
        end
        if not allPass then return false end
    end

    return true
end

-- Filter a list of normalized item records using the current active query.
-- Stamps each record with ._feShow = true/false.
-- Returns the number of items that passed the filter.
function EUI_FilterEngine:Filter(items)
    local shown = 0
    for _, data in ipairs(items) do
        local pass = self:Matches(data)
        data._feShow = pass
        if pass then shown = shown + 1 end
    end
    return shown
end

-------------------------------------------------------------------------------
--  Built-in token handlers registered at load time
--
--  These are scaffolds; they can be overwritten or extended after this file
--  loads.  Prefix names follow Baganator / ElvUI conventions where possible.
-------------------------------------------------------------------------------

-- q:<quality>  -- filter by item quality name (epic, rare, uncommon, common, poor, legendary, artifact)
local _qualityNames = {
    poor = 0, gray = 0,
    common = 1, white = 1,
    uncommon = 2, green = 2,
    rare = 3, blue = 3,
    epic = 4, purple = 4,
    legendary = 5, orange = 5,
    artifact = 6, gold = 6,
    heirloom = 7,
}
EUI_FilterEngine:RegisterToken("q", function(data, value)
    local targetQ = _qualityNames[value:lower()]
    if targetQ == nil then return true end  -- unknown quality token: don't hide
    local q = data._giQuality
    if q == nil and data.itemLink then
        local _, _, iq = GetItemInfo(data.itemLink)
        q = iq
    end
    return q == targetQ
end)

-- type:<itemclass>  -- partial match against item type string
EUI_FilterEngine:RegisterToken("type", function(data, value)
    local target = value:lower()
    local typeName = data._sortType or ""
    if typeName == "" and data.itemLink then
        local _, _, _, _, _, itype = GetItemInfo(data.itemLink)
        typeName = itype or ""
    end
    return typeName:lower():find(target, 1, true) ~= nil
end)

-- ilvl:<operator><number>  -- filter by item level (supports >, <, >=, <=, =)
EUI_FilterEngine:RegisterToken("ilvl", function(data, value)
    local op, numStr = value:match("^([><=]*)(%d+)$")
    if not numStr then return true end  -- malformed: don't hide
    local threshold = tonumber(numStr)
    if not threshold then return true end
    local ilvl = data._giIlvl
    if ilvl == nil and data.itemLink then
        local _, _, _, iilvl = GetItemInfo(data.itemLink)
        ilvl = iilvl
    end
    if not ilvl then return false end
    if op == "" or op == "=" then return ilvl == threshold end
    if op == ">"  then return ilvl >  threshold end
    if op == ">=" then return ilvl >= threshold end
    if op == "<"  then return ilvl <  threshold end
    if op == "<=" then return ilvl <= threshold end
    return true
end)

-- bind:<keyword>  -- filter by binding type
--   bind:boe   Bind on Equip (not WuE)
--   bind:bop   Bind on Pickup
--   bind:boa   Bind on Account / warbound
--   bind:bou   Bind on Use
--   bind:wue   Warbound Until Equipped
EUI_FilterEngine:RegisterToken("bind", function(data, value)
    local matched = MatchBindKeyword(data, value:lower())
    if matched == nil then return true end  -- unrecognized value: don't hide
    return matched
end)
