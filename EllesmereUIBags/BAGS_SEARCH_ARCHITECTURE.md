# EllesmereUIBags – Search, Filter & Pipeline Architecture

> **Status**: MVP / Phase 1 implementation

This document describes the Baganator-inspired search/filter and pipeline architecture
added in this PR, and outlines the follow-up steps for full feature parity.

---

## Architecture overview

Items flow through a linear pipeline from raw bag slots to rendered UI:

```
BAG_UPDATE / search change
        │
        ▼
1. Source items
   C_Container.GetContainerItemInfo  →  raw slot records
        │
        ▼
2. Normalize
   AcquireSlotTable, pre-cache GetItemInfo fields
   (_giQuality, _giIlvl, _isGear, _ksLevel, …)
        │
        ▼
3. Classify  [EUI_CategoryManager:ClassifyAll]
   Assigns .categoryIndex to every item
        │
        ▼
4. Filter  [EUI_FilterEngine]
   • Query is set by the debounced search box (default 100 ms)
   • Plain-text name substring match (case-insensitive)
   • Falls back to Blizzard's .isFiltered when no query is set
   • Token hooks registered for future: q:, type:, ilvl:, slot:
        │
        ▼
5. Category pipeline  [EUI_CategoryEngine]
   • No-op by default (items keep their .categoryIndex from step 3)
   • RegisterRule() extension point for user-defined category overrides
        │
        ▼
6. Sort pipeline  [EUI_SortEngine]
   • Default key chain: quality↓ → name↑ → itemID↑ → bag:slot↑
   • RegisterSortKey() extension point for custom sort fragments
   • SetActiveSortKeys() restricts or reorders the active key set
        │
        ▼
7. Render  [RefreshInventory]
   • Builds grid from displayItems (already filtered + sorted)
   • Shows "No items found" empty-state label when filter is active
     and nothing passes (category/All Items views only; OneBag/MultiBag
     dim non-matching items rather than hiding them)
```

## Module public APIs

### `EUI_FilterEngine`

| Method | Description |
|--------|-------------|
| `SetQuery(text)` | Set the current search query (typically called by the debounced search box handler) |
| `GetQuery()` | Return the raw query string |
| `IsActive()` | `true` when the query is non-empty |
| `Matches(data[, query])` | Test one item record; returns `true` = show |
| `Filter(items)` | Stamp `._feShow` on every record in a list |
| `RegisterToken(prefix, fn)` | Register a custom filter token (e.g. `"q"`, `"type"`, `"ilvl"`) |

Built-in token handlers (scaffolded, ready to extend):

| Token | Example | Behaviour |
|-------|---------|-----------|
| `q:` | `q:epic` | Filter by item quality name |
| `type:` | `type:consumable` | Partial match against item type string |
| `ilvl:` | `ilvl:>450` | Item level comparison (supports `>`, `<`, `>=`, `<=`, `=`) |

### `EUI_CategoryEngine`

| Method | Description |
|--------|-------------|
| `Process(items)` | Apply registered rules; stamps `._ceCategoryOverride` when matched |
| `RegisterRule(name, testFn, priority)` | Add a category override rule |
| `ClearRules()` | Remove all rules |
| `GetRuleCount()` | Number of active rules |

### `EUI_SortEngine`

| Method | Description |
|--------|-------------|
| `Sort(items)` | Sort items[] in-place with the active key chain |
| `GetComparator()` | Return the raw `(a,b)->bool` comparator for use in `table.sort` |
| `RegisterSortKey(name, fn, weight)` | Register a custom sort key fragment |
| `SetActiveSortKeys(names)` | Restrict which keys are active; `nil` = all defaults |
| `ResetSortKeys()` | Restore built-in defaults |

## Settings added

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bagSearchDebounce` | number (ms) | `100` | Delay before applying a typed search query |

The setting is persisted in `EllesmereUIBagsDB` (profile scope) and exposed in the
**Bags → Search** options panel as a slider (0–500 ms, step 25 ms).

## Search UX behaviour

- **Typing**: query is committed after `bagSearchDebounce` ms of inactivity
- **Clear button (×)**: commits empty query immediately (no debounce)
- **ESC key**: commits empty query immediately
- **Empty state**: "No items found" label appears in the grid area when the filter
  is active and returns no results (category / All Items views only)
- **OneBag / MultiBag**: non-matching items are dimmed (existing Blizzard
  `isFiltered` behaviour), no empty-state label

---

## Next steps / follow-up work

### Tokenized filters
- `q:rare` / `q:epic` — quality filter (token scaffolded, needs UX testing)
- `type:weapon` / `type:consumable` — item-class filter
- `ilvl:>450` — item-level range filter
- `slot:trinket` — equipment slot filter
- `bind:boe` / `bind:bop` — binding type filter
- `set:` — item-set membership filter
- **UI hint**: show accepted token prefixes in search box tooltip or below the box

### User-defined categories
- `EUI_CategoryEngine.RegisterRule()` is the extension point
- UI: "Add Category" panel should write rules via `RegisterRule` and persist them
  in `bp.bagUserCategoryRules`
- Rule evaluation order (priority) should be configurable

### Sort enhancements
- Expose `EUI_SortEngine.RegisterSortKey` and `SetActiveSortKeys` in the options panel
- Pre-built sort presets: by ilvl, by quality, by item type, by recent acquisition
- Per-category sort override (different sort order for Reagents vs Gear)

### Offline / guild / currency parity (Baganator scope)
- **Offline inventory**: cache bag contents per character in `EllesmereUIDB`; surface
  in a separate "All Characters" view tab
- **Guild bank**: `EUI_BankFrame` already handles personal bank; extend with guild-bank
  tab using the same pipeline
- **Currency**: already tracked in footer; add a dedicated currency view tab

### Performance
- Pre-warm `GetItemName` into `_sortName` at classify time (avoids a second
  `GetItemInfo` call in FilterEngine for items not yet run through PreCacheSortFields)
- Consider an `ItemIndex` module to centralise all per-item metadata caching

### Testing
- WoW addon Lua has no off-client test runner; validation is done in-client
- Consider exporting the FilterEngine / SortEngine as standalone pure-Lua modules
  so they can be unit-tested with a lightweight Lua interpreter
