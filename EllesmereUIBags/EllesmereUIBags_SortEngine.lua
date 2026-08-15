-------------------------------------------------------------------------------
--  EllesmereUIBags_SortEngine.lua
--  Sort pipeline stage for EllesmereUIBags.
--
--  Sits at the end of the processing pipeline:
--    source items → normalize → filter → category → [SortEngine] → render
--
--  Current behaviour (MVP):
--    • Provides the same default sort already used by the existing visual
--      sort: quality (desc) > name (asc) > itemID (asc) > bag:slot (asc).
--    • Exposes extension points for composable sort keys without coupling
--      callers to internal field names.
--
--  Default sort keys (applied in listed order):
--    1. Quality descending
--    2. Item name ascending (locale-safe; uses cached _sortName or GetItemInfo)
--    3. Item ID ascending
--    4. Bag ascending, slot ascending (deterministic tiebreaker)
--
--  Extension points (future):
--    • RegisterSortKey(name, fn, priority) -- plug-in comparator fragment
--    • SetActiveSortKeys(keyNames)         -- choose which keys to use
--    • Keys can be enabled / disabled via settings without touching render code
--
--  Public API (global: EUI_SortEngine):
--    EUI_SortEngine:Sort(items)              -- sort items[] with active key set
--    EUI_SortEngine:GetComparator()          -- return the raw comparator function
--    EUI_SortEngine:RegisterSortKey(...)     -- add a custom sort key fragment
--    EUI_SortEngine:SetActiveSortKeys(names) -- choose which keys are active
--    EUI_SortEngine:ResetSortKeys()          -- restore built-in defaults
-------------------------------------------------------------------------------

EUI_SortEngine = {}

-------------------------------------------------------------------------------
--  Helpers
-------------------------------------------------------------------------------
local function GetItemName(data)
    if data._sortName and data._sortName ~= "" then return data._sortName end
    if data.itemLink then
        local n = GetItemInfo and (GetItemInfo(data.itemLink))
        if n then return n end
    end
    return ""
end

-------------------------------------------------------------------------------
--  Built-in sort key registry
--  Each key: { name, weight, fn(a,b)->-1|0|1 }
--  Active keys are sorted by weight ascending, applied left-to-right.
-------------------------------------------------------------------------------
local _builtinKeys = {
    {
        name   = "quality_desc",
        weight = 10,
        fn     = function(a, b)
            local qa = a._sortQuality or a._giQuality or 0
            local qb = b._sortQuality or b._giQuality or 0
            if qa ~= qb then return qa > qb and -1 or 1 end
            return 0
        end,
    },
    {
        name   = "name_asc",
        weight = 20,
        fn     = function(a, b)
            local na = GetItemName(a):lower()
            local nb = GetItemName(b):lower()
            if na ~= nb then return na < nb and -1 or 1 end
            return 0
        end,
    },
    {
        name   = "itemid_asc",
        weight = 30,
        fn     = function(a, b)
            local ia = (a.info and a.info.itemID) or 0
            local ib = (b.info and b.info.itemID) or 0
            if ia ~= ib then return ia < ib and -1 or 1 end
            return 0
        end,
    },
    {
        name   = "bagslot_asc",
        weight = 40,  -- deterministic tiebreaker
        fn     = function(a, b)
            if (a.bag or 0) ~= (b.bag or 0) then
                return (a.bag or 0) < (b.bag or 0) and -1 or 1
            end
            if (a.slot or 0) ~= (b.slot or 0) then
                return (a.slot or 0) < (b.slot or 0) and -1 or 1
            end
            return 0
        end,
    },
}

-- User-registered sort key registry
local _userKeys = {}
local _userKeysDirty = false

-- Active key names; nil = use all built-in defaults in weight order
local _activeKeys = nil

-- Merged, sorted list of active key functions (rebuilt when dirty)
local _compiled = nil

local function CompileKeys()
    local all = {}
    -- Start with built-in keys
    for _, k in ipairs(_builtinKeys) do
        if _activeKeys == nil or _activeKeys[k.name] then
            all[#all + 1] = k
        end
    end
    -- Append user-registered keys
    for _, k in ipairs(_userKeys) do
        if _activeKeys == nil or _activeKeys[k.name] then
            all[#all + 1] = k
        end
    end
    table.sort(all, function(a, b) return (a.weight or 0) < (b.weight or 0) end)
    _compiled = all
    _userKeysDirty = false
end

local function GetCompiledKeys()
    if not _compiled or _userKeysDirty then CompileKeys() end
    return _compiled
end

-------------------------------------------------------------------------------
--  Public API
-------------------------------------------------------------------------------

-- Sort items[] in-place using the active sort key set.
-- Returns items (same reference).
function EUI_SortEngine:Sort(items)
    if #items < 2 then return items end
    local keys = GetCompiledKeys()
    table.sort(items, function(a, b)
        for _, key in ipairs(keys) do
            local cmp = key.fn(a, b)
            if cmp ~= 0 then return cmp < 0 end
        end
        return false
    end)
    return items
end

-- Return the raw Lua comparator (a,b)->bool for use in table.sort directly.
function EUI_SortEngine:GetComparator()
    local keys = GetCompiledKeys()
    return function(a, b)
        for _, key in ipairs(keys) do
            local cmp = key.fn(a, b)
            if cmp ~= 0 then return cmp < 0 end
        end
        return false
    end
end

-- Register a custom sort key fragment.
-- name     (string)   : unique key name (used by SetActiveSortKeys)
-- fn       (function) : function(a, b) -> -1 | 0 | 1 (negative = a sorts first)
-- weight   (number)   : lower weight = applied earlier in the chain; default 50
function EUI_SortEngine:RegisterSortKey(name, fn, weight)
    if type(name) ~= "string" or type(fn) ~= "function" then return end
    _userKeys[#_userKeys + 1] = { name = name, fn = fn, weight = weight or 50 }
    _userKeysDirty = true
end

-- Restrict active keys to the named set.  Pass nil to restore all defaults.
-- names (table or nil): { keyName = true, ... }
function EUI_SortEngine:SetActiveSortKeys(names)
    _activeKeys = names
    _userKeysDirty = true
end

-- Restore built-in defaults (all built-in keys, no user keys active).
function EUI_SortEngine:ResetSortKeys()
    wipe(_userKeys)
    _activeKeys = nil
    _compiled = nil
end
