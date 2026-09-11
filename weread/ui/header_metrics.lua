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
    FACE_SIZE = 26,

    TOP_PADDING    = 6, -- title bar top padding (书架页 / 统计页)
    FM_TOP_PADDING = 0, -- FM exception, see header note

    LINE_GAP   = 6.5,  -- separator: below the title text box
    LINE_INSET = 24,   -- separator: inset on both sides (== cover grid / dock)
    LINE_H     = 1,    -- separator: thickness
    LINE_GRAY  = 0.72, -- separator: Blitbuffer.gray() level

    -- Tap range for the FM icon buttons (toolbar row + pager chevrons):
    -- the weread pager's own touch size — its footprint (18 + 2*2) grown by
    -- 2*13 on each side. Layout footprint, icon size and spacing stay as they
    -- are; only "what counts as a tap" grows.
    TOUCH = 48,
}

return M
