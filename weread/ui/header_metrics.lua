-- weread/ui/header_metrics.lua
--
-- Single source of truth for the title bars of this fork's three pages:
--   * FM 本地书库    (SimpleUI-patched native TitleBar, ui/ko_custom_patches.lua)
--   * 微信读书书架页 (ui/library_view.lua)
--   * 阅读统计页     (ui/read_stats_view.lua)
--
-- Values are design constants; pass them through Screen:scaleBySize() at the
-- use site (koplugin modules must not scale at load time). Keeping them in one
-- place is the only thing stopping the three headers from drifting apart:
-- before this module each page hard-coded its own copy of the same numbers.
--
-- Exceptions, deliberately kept here so they are visible instead of folklore:
--   * FM_TOP_PADDING = 0 — the FM title row is followed by our icon toolbar
--     row, so it must start flush with the bar top (the other two pages use
--     TOP_PADDING = 6).
--   * FM's title face / top padding are set by our TitleBar init hook
--     (ui/ko_custom_patches.lua): FACE / FACE_SIZE are shared, but FM keeps
--     FM_TOP_PADDING = 0 instead of TOP_PADDING.

local M = {
    FACE      = "smalltfont",
    FACE_SIZE = 28,   -- title font size, shared by all three page titles

    TOP_PADDING    = 0, -- title bar top padding, identical on all three pages
                       -- (the FileManager title sits at the content top; the
                       -- weread pages match it so the headers line up)
    FM_TOP_PADDING = 0, -- kept for call sites that name the FM case explicitly

    -- Height of the control row under the separator (FileManager toolbar row:
    -- icon glyph 26 + 8 tap padding). The shelf tool row and the stats tab row
    -- use the same height so all three headers are structurally identical.
    ROW_H = 34,

    LINE_GAP   = 6.5,  -- separator: below the title text box
    LINE_INSET = 24,   -- separator: inset on both sides (== cover grid / dock)
    LINE_H     = 1,    -- separator: thickness
    LINE_GRAY  = 0.72, -- separator: Blitbuffer.gray() level

    -- Tap range for the FM icon buttons (toolbar row + pager chevrons):
    -- the weread pager's own touch size — its footprint (18 + 2*2) grown by
    -- 2*13 on each side. Layout footprint, icon size and spacing stay as they
    -- are; only "what counts as a tap" grows.
    TOUCH = 48,

    -- Height of an in-page pager row. The FileManager's own pager row is the
    -- reference every pager/period row must match (it measures 52px on the
    -- reference device = 29 design units, incl. KOReader's Size.padding.button).
    PAGER_ROW_H = 29,

    -- Pager size presets. SimpleUI's own setting (simpleui_bar_pagination_size)
    -- is mapped to a factor applied to THIS fork's baselines, so:
    --   * "s" (the preset most devices sit on) = 1.0 = exactly the values these
    --     pagers have always used (no visual change);
    --   * the FM pager (which we patch) and the in-page pagers use the same
    --     factor, so they stay equal in every preset;
    --   * each element keeps its own baseline (pager icon 18 / pager text 14 /
    --     period-row text 16 / spacer 21) and just scales by the factor.
    PAGER_SCALE = { xs = 0.75, s = 1.0, m = 1.3 },
}

--- Factor for the current SimpleUI pagination preset. Lazily read (never at load
--- time) and pcall-guarded: unavailable → 1.0, i.e. the previous hard-coded values.
function M.pagerScale()
    local factor = 1
    pcall(function()
        local Store = require("infra/sui_store")
        local key = Store:readSetting("simpleui_bar_pagination_size") or "s"
        factor = M.PAGER_SCALE[key] or 1
    end)
    return factor
end

--- Factor for SimpleUI's title-bar size preset (Compact / Default / Large =
--- 0.75 / 1.0 / 1.3), used by everything that lives in a page header: the FM
--- toolbar row, the shelf's tab/action rows and the stats tab row. Read lazily and
--- pcall-guarded: unavailable → 1.0 (the values these controls always had).
--- Alignment constants (side insets, separator/underline thickness) deliberately
--- do NOT go through this factor — they must keep matching the separator.
function M.uiScale()
    local factor = 1
    pcall(function()
        local ST = require("screens/sui_titlebar")
        if ST and type(ST.getSizeScale) == "function" then
            local ok, v = pcall(ST.getSizeScale)
            if ok and tonumber(v) then factor = tonumber(v) end
        end
    end)
    return factor
end

return M
