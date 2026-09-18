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

local Device = require("device")
local Screen = Device.screen

local M = {
    FACE      = "smalltfont",
    FACE_SIZE = 28,   -- title font size, shared by all three page titles

    TOP_PADDING    = 0, -- title bar top padding, identical on all three pages
                       -- (the FileManager title sits at the content top; the
                       -- weread pages match it so the headers line up)
    FM_TOP_PADDING = 0, -- kept for call sites that name the FM case explicitly

    -- Control row under the separator (the local library's toolbar row is the
    -- reference for both pages): glyph size, its invisible tap padding, the gap
    -- below the separator, the inter-icon spacing and the trailing pad below the
    -- row. The shelf uses the same numbers for its tab/action row, so the two
    -- pages' "separator -> grid top" heights match (only the content inside the
    -- row differs: icons there, text here).
    ICON_PX    = 26,
    ICON_PAD   = 8,
    ICON_GAP   = 9,
    ICON_GAP_X = 16,
    ROW_TAIL   = 3,

    -- Top spacing of the cover grid under the control row. Two numbers, because the
    -- two control rows hide different amounts of empty band below their visible
    -- content (FM's icons sit centred in a 61px box plus a 5px tail; the shelf's
    -- tab/action row is text and hides almost none). The goal is ALIGNED GRID TOPS:
    -- measured on device, FM's first cover row started 7px lower than the shelf's
    -- (256 vs 249) at 14, so it is reduced by those 7px.
    GRID_TOP_EXTRA = 10,  -- FM's grid shift (design units; ≈18px on a KPW4)

    -- Kept for reference: the glyph + padding pair above, in design units.
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

--- Icon box height (glyph + its invisible tap padding), both terms scaled by
--- SimpleUI's title-bar size preset — the reference height of the control row.
--- Mirrors the local library's own expression, term by term.
function M.controlBoxH()
    local s = M.uiScale()
    return math.floor(Screen:scaleBySize(M.ICON_PX) * s)
         + math.floor(Screen:scaleBySize(M.ICON_PAD) * s)
end

--- Full control-row height: the icon box plus the trailing pad the local library
--- reserves below it.
function M.controlRowH()
    return M.controlBoxH() + Screen:scaleBySize(M.ROW_TAIL)
end

--- The ONE control source for both pages' cover grid: the rows/cols setting that
--- coverbrowser owns and SimpleUI's own menu path writes (`nb_cols_portrait` /
--- `nb_rows_portrait`, stored in settings/bookinfo_cache.sqlite3 and read here
--- through BookInfoManager). The shelf must read the SETTING, not the FileManager's
--- runtime fields: those only update when FM itself relayouts, so reading them made
--- a setting change move FM's grid while leaving the shelf's alone.
--- Returns nil when the setting can not be read (caller falls back to its own
--- adaptive layout).
function M.coverGridSpec()
    local spec
    pcall(function()
        local ok_b, B = pcall(require, "bookinfomanager")
        if not (ok_b and B and type(B.getSetting) == "function") then return end
        local cols = tonumber(B:getSetting("nb_cols_portrait"))
        local rows = tonumber(B:getSetting("nb_rows_portrait"))
        if not (cols and rows and cols >= 1 and rows >= 1) then return end
        spec = {
            cols    = math.floor(cols),
            rows    = math.floor(rows),
            gap     = M.coverGap(),
            label_h = M.coverLabelH(),
        }
    end)
    return spec
end

--- Height the local library reserves under each cover for SimpleUI's title/author
--- strips (nil when unavailable). Both pages use it so their covers come out the
--- same size. Our own patch wraps MosaicMenu._updateItemsBuildUI and SimpleUI keeps
--- the value as an upvalue of the ORIGINAL builder — hence the lookup there.
function M.coverLabelH()
    local h
    pcall(function()
        local ok_m, MM = pcall(require, "mosaicmenu")
        local ok_u, userpatch = pcall(require, "userpatch")
        if not (ok_m and ok_u and MM and userpatch) then return end
        local fn = MM._wr_orig_updateItemsBuildUI or MM._updateItemsBuildUI
        local item = fn and userpatch.getUpValue(fn, "MosaicMenuItem")
        if item and tonumber(item._simpleui_strip_h) then
            h = math.floor(tonumber(item._simpleui_strip_h))
        end
    end)
    return h
end

--- Gap between two adjacent covers — the single knob for cover spacing and,
--- through it, cover size: the local library's grid margin and the gap the
--- bookshelf keeps around its cells both come from here (a smaller value = bigger
--- covers, tighter grid). Derived from the shelf's cell decoration (padding +
--- border on both sides, ui/size) so the pages share one number.
function M.coverGap()
    local gap = 6
    pcall(function()
        local Size = require("ui/size")
        if Size and Size.padding and Size.border then
            gap = 2 * ((Size.padding.tiny or 0) + (Size.border.thin or 0))
        end
    end)
    return gap
end

--- Total space the control band takes under the separator: the gap the local
--- library leaves between separator and row, plus the row itself. Pages that do
--- not draw icons use it as a fixed band so their grid box matches FM's.
function M.controlBandH()
    return Screen:scaleBySize(M.ICON_GAP) + M.controlRowH()
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
