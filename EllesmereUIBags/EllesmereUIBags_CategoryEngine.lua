-------------------------------------------------------------------------------
--  EllesmereUIBags_CategoryEngine.lua
--  Category pipeline stage for EllesmereUIBags.
--
--  Sits between FilterEngine and SortEngine in the processing pipeline:
--    source items → normalize → filter → [CategoryEngine] → sort → render
--
--  Current behaviour (MVP):
--    • Default: all items are assigned to the category already set by
--      EUI_CategoryManager:ClassifyAll (the existing category system).
--    • Exposes a clean API for future rule-based / user-defined category
--      overrides without touching EUI_CategoryManager.
--
--  Extension points (future):
--    • RegisterRule(name, testFn, priority) -- user-defined category rules
--    • ApplyRules(items)                    -- run rules over item list
--    • Rules are evaluated highest-priority-first; first match wins.
--    • Rules can override or supplement EUI_CategoryManager output.
--
--  Public API (global: EUI_CategoryEngine):
--    EUI_CategoryEngine:Process(items)    -- apply category rules to item list
--    EUI_CategoryEngine:RegisterRule(...)  -- add a user-defined category rule
--    EUI_CategoryEngine:ClearRules()       -- remove all user-defined rules
--    EUI_CategoryEngine:GetRuleCount()     -- number of registered rules
-------------------------------------------------------------------------------

EUI_CategoryEngine = {}

-------------------------------------------------------------------------------
--  Internal rule registry
--  Each rule: { name, test, priority }
--  test(data) -> categoryKey (string|number) or nil (= no override)
-------------------------------------------------------------------------------
local _rules = {}
local _rulesSorted = false  -- dirty flag: sort before next Process

local function SortRules()
    table.sort(_rules, function(a, b)
        return (a.priority or 0) > (b.priority or 0)
    end)
    _rulesSorted = true
end

-------------------------------------------------------------------------------
--  Public API
-------------------------------------------------------------------------------

-- Process an item list: evaluate registered rules in priority order.
-- Sets data._ceCategoryOverride = categoryKey when a rule matches.
-- Items that no rule matches keep their existing categoryIndex from ClassifyAll.
-- Returns items (same list, possibly with _ceCategoryOverride stamps).
function EUI_CategoryEngine:Process(items)
    if #_rules == 0 then return items end  -- fast path: no user rules

    if not _rulesSorted then SortRules() end

    for _, data in ipairs(items) do
        if data.info then
            for _, rule in ipairs(_rules) do
                local override = rule.test(data)
                if override ~= nil then
                    data._ceCategoryOverride = override
                    break
                end
            end
        end
    end

    return items
end

-- Register a category override rule.
-- name     (string)   : human-readable label for the rule
-- testFn   (function) : function(data) -> categoryKey or nil
-- priority (number)   : higher runs first; default 0
function EUI_CategoryEngine:RegisterRule(name, testFn, priority)
    if type(name) ~= "string" or type(testFn) ~= "function" then return end
    _rules[#_rules + 1] = { name = name, test = testFn, priority = priority or 0 }
    _rulesSorted = false
end

-- Remove all registered rules (useful for testing / profile reset).
function EUI_CategoryEngine:ClearRules()
    wipe(_rules)
    _rulesSorted = true
end

-- Return the number of registered rules.
function EUI_CategoryEngine:GetRuleCount()
    return #_rules
end
