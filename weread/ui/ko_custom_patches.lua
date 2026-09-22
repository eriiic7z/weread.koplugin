-- weread/ui/ko_custom_patches.lua
--
-- Fork-owned runtime patches for components we do NOT own:
--   1) Kindle-style menu veil (FileManagerMenu / ReaderMenu dim backdrop)
--   2) Local-bookshelf (SimpleUI FileManager / folder-covers mosaic) visuals:
--      FM title face + alignment, mosaic margins, pager size/spacing/format
--
-- No KOReader / SimpleUI / coverbrowser file is modified; both patches are
-- idempotent and installed by the weread plugin at init. (Formerly the two
-- files menu_scrim_patch.lua and fm_visual_patch.lua.)

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Screen = Device.screen
local TitleMetrics = require("weread.ui.header_metrics")

local M = {}

-- ---------------------------------------------------------------------------
-- 1) Kindle-style menu veil
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Kindle-style dim backdrop (formerly weread/ui/dim_scrim.lua).
--
-- Kindle dims everything outside the open menu; KOReader has no such
-- mechanism, so this is a minimal full-screen overlay. e-ink needs an
-- explicit full-screen refresh to actually show a large new layer (the
-- caller shows it with "full"), and the backdrop is drawn with the
-- blitbuffer's true alpha blending (darkenRect) where available, which
-- gives the uniform grey veil Kindle shows. Fallback (no darkenRect):
-- spaced black cells.
-- ---------------------------------------------------------------------------
local DimScrim = Widget:extend{
    name = "wr_dim_scrim",
}

function DimScrim:init()
    self.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
end

-- Kindle backdrop parameters (fixed, matching the Kindle OS dim veil as
-- observed on-device): it is a CHECKERBOARD -- black cell and transparent
-- cell alternating 1:1, so the gap between two black cells equals one cell.
-- Cell size 4px (between the too-large 5px and the too-small 3px trials,
-- per device feedback), black at 80% opacity.
local CELL = 4
local OPACITY = 0.8

function DimScrim:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    if bb.darkenRect then
        local row = 0
        local gy = 0
        while gy <= h - CELL do
            local col = 0
            local gx = 0
            while gx <= w - CELL do
                if (row + col) % 2 == 0 then
                    bb:darkenRect(x + gx, y + gy, CELL, CELL, OPACITY)
                end
                gx = gx + CELL
                col = col + 1
            end
            gy = gy + CELL
            row = row + 1
        end
    else
        -- no alpha support on this buffer type: solid checkerboard fallback
        local row = 0
        local gy = 0
        while gy <= h - CELL do
            local col = 0
            local gx = 0
            while gx <= w - CELL do
                if (row + col) % 2 == 0 then
                    bb:paintRect(x + gx, y + gy, CELL, CELL, Blitbuffer.COLOR_BLACK)
                end
                gx = gx + CELL
                col = col + 1
            end
            gy = gy + CELL
            row = row + 1
        end
    end
end

local applied = false

local function patch_menu_class(cls, show_name, close_name, scrim_key)
    local orig_show = cls[show_name]
    local orig_close = cls[close_name]
    if type(orig_show) ~= "function" or type(orig_close) ~= "function" then
        logger.info("wrScrim: skip (missing methods) " .. show_name)
        return false
    end
    cls[show_name] = function(self, tab_index, do_not_show)
        if not do_not_show then
            -- insert the veil below the menu; a non-flashing full-screen
            -- refresh surfaces the layer (flashui tested as alternative)
            local layer = DimScrim:new{}
            self[scrim_key] = layer
            UIManager:show(layer, "full")
            logger.info("wrScrim: veil shown under " .. show_name)
        end
        return orig_show(self, tab_index, do_not_show)
    end
    cls[close_name] = function(self, ...)
        local ok_l, logger = pcall(require, "logger")
        if ok_l then logger.info("wrScrim: close-hook enter scrim=" .. tostring(self[scrim_key] ~= nil)) end
        if self[scrim_key] then
            UIManager:close(self[scrim_key])
            self[scrim_key] = nil
            -- non-flashing full refresh: clears the veil everywhere on the
            -- e-ink display (closing widgets only refresh their own region)
            UIManager:setDirty(nil, "partial")
            if ok_l then logger.info("wrScrim: close-hook scrim dropped") end
        end
        if ok_l then logger.info("wrScrim: close-hook calling orig") end
        local r = orig_close(self, ...)
        if ok_l then logger.info("wrScrim: close-hook orig returned") end
        return r
    end
    logger.info("wrScrim: patched " .. show_name)
    return true
end

local function ensure()
    if applied then
        return true
    end
    local ok1, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok1 then
        patch_menu_class(FileManagerMenu, "onShowMenu", "onCloseFileManagerMenu", "_wr_scrim")
    else
        logger.info("wrScrim: fm require failed")
    end
    local ok2, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok2 then
        patch_menu_class(ReaderMenu, "onShowMenu", "onCloseReaderMenu", "_wr_scrim")
    else
        logger.info("wrScrim: reader menu require failed")
    end
    applied = true
    logger.info("wrScrim: ensure done")
    return true
end


local title_hook_installed = false

local function installTitleFaceHook()
    local ok, TitleBar = pcall(require, "ui/widget/titlebar")
    if not ok or not TitleBar or type(TitleBar.init) ~= "function" then return end
    if title_hook_installed then return end
    title_hook_installed = true
    local orig_init = TitleBar.init
    TitleBar.init = function(self, ...)
        local is_fm = self.left_icon == "home" and not self._wr_fm_title_done
        if is_fm then
            -- FileManager title: weread shelf title face
            self.title_face = Font:getFace(TitleMetrics.FACE, TitleMetrics.FACE_SIZE)
            -- Measured (paintY logs): FM text top 73 vs weread 66 → 7px low.
            -- title_group overlap offsets are ignored by the layout, so the
            -- real fix is a content-level lift (liftFMContent, scheduled after
            -- boot); pad stays 0 so the title sits at the bar top.
            if self.title_top_padding then
                self.title_top_padding = Screen:scaleBySize(TitleMetrics.FM_TOP_PADDING)
            end
        end
        local res = orig_init(self, ...)
        if is_fm then
            -- Pin the title's x ourselves: KOReader centres it inside a parent
            -- whose width can be odd on some relayouts, making
            -- (parent_w - text_w)/2 land on .5 and alternating between 488/489
            -- when returning to the root folder (measured: see git log).
            -- Only the x we pass is replaced — the title is still drawn by
            -- KOReader's own TextWidget (same mechanism as the toolbar icons).
            if self.title_widget and self.title_widget.paintTo
                    and not self._wr_titlex_hooked then
                self._wr_titlex_hooked = true
                local tw = self.title_widget
                local orig_tw_paint = tw.paintTo
                tw.paintTo = function(tw_self, bb, x, y)
                    local sz = tw_self:getSize()
                    local bar_w = self.dimen and self.dimen.w
                    if sz and bar_w and sz.w then
                        x = math.floor((bar_w - sz.w) / 2)
                    end
                    return orig_tw_paint(tw_self, bb, x, y)
                end
            end
            -- separator directly under the 书库 title row (weread position),
            -- not at the whole header bottom (which includes the path subtitle)
            if not self._wr_fm_sep then
                local w = Screen:getWidth()
                local inset = Screen:scaleBySize(TitleMetrics.LINE_INSET)
                local title_h = 0
                if self.title_widget and self.title_widget.getSize then
                    local ok_s, sz = pcall(function()
                        return self.title_widget:getSize()
                    end)
                    if ok_s and sz then title_h = sz.h or 0 end
                end
                local y = math.max(1, math.floor(title_h)
                    + Screen:scaleBySize(TitleMetrics.LINE_GAP))
                local sep = LineWidget:new{
                    dimen = Geom:new{
                        w = math.max(1, w - 2 * inset),
                        h = Screen:scaleBySize(TitleMetrics.LINE_H),
                    },
                    background = Blitbuffer.gray(TitleMetrics.LINE_GRAY),
                }
                sep.overlap_offset = { inset, y }
                table.insert(self, sep)
                self._wr_fm_sep = true
            end
            self._wr_fm_title_done = true
        end
        return res
    end
end

--- Lift the whole SimpleUI-wrapped FM content up so the FM title aligns with
--- the weread shelf title (measured: 7px). The wrap offset lives on
--- fm._navbar_inner.overlap_offset; adjusting it moves the title bar too.
-- A/B switch: the weread pages are natively hosted now, so this lift (tuned
-- against the old self-drawn pages) may no longer be needed. true = old
-- behaviour (lift 7px up), false = no lift.
local FM_CONTENT_LIFT = false

local function liftFMContent()
    pcall(function()
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_f and FM.instance
        if not fm or fm._wr_fm_lifted then return end
        local inner = fm._navbar_inner
        if inner and inner.overlap_offset then
            local oy = inner.overlap_offset[2]
            if oy and oy >= 7 then
                inner.overlap_offset[2] = oy - 7
                fm._wr_fm_lifted = true
                logger.info("wrFmPatch: FM content lifted by 7px (title align)")
            end
        end
    end)
end

local mosaic_hook_installed = false

--- Pager (页码导航器) sizing: mirror SimpleUI's own resize hook, but force the
--- compact values (icon 18 / text 14) when the user is on the DEFAULT
--- pagination size ("s"). Implemented as a runtime patch so no SimpleUI
--- source file is modified and upgrades can't lose it.
local PAGER_ICON_SZ = 18
local PAGER_FONT_SZ = 14

--- Grow a button's tap (and hold) range to `touch` px, centred on the button,
-- without touching its layout footprint or how it paints: GestureRange accepts
-- a function, so the range is recomputed from the button's live dimen.
--- Long-press on a pager control opens SimpleUI's pagination-bar settings window
--- on RELEASE, like every other hold menu (SimpleUI's own bar zones fire on
--- hold_release). KOReader's Button has no release callback, so the press only
--- marks the button and its release handler acts (button.lua:548-575). Setting
--- hold_callback also suppresses the Button's hold_input on a hold, while a plain
--- TAP still opens the native page-number dialog (call_hold_input_on_tap,
--- button.lua:88-89).
local function hookPagerHoldToSettings(btn)
    if not (btn and type(btn.onHoldReleaseSelectButton) == "function") then return end
    if btn._wr_hold_release_hooked then return end
    btn._wr_hold_release_hooked = true
    -- KOReader calls this bare (`self.hold_callback()`, button.lua:555), so it must
    -- not take a self parameter — capture the button instead.
    btn.hold_callback = function() btn._wr_hold_pending = true end
    local orig_release = btn.onHoldReleaseSelectButton
    btn.onHoldReleaseSelectButton = function(self, ...)
        local pending = self._wr_hold_pending
        self._wr_hold_pending = nil
        local res
        if orig_release then res = orig_release(self, ...) end
        if pending then M.openPaginationBarSettingsWindow() end
        return res
    end
end

local function widenTouchRange(btn, touch)
    if not (btn and btn.ges_events and touch) then return end
    for _, seq in pairs(btn.ges_events) do
        for _, gs in ipairs(seq) do
            if gs.ges == "tap" or gs.ges == "hold" then
                gs.range = function()
                    local d = btn.dimen
                    if not d then return nil end
                    local pad = math.floor((touch - d.w) / 2)
                    return Geom:new{
                        x = d.x - pad, y = d.y - pad, w = touch, h = touch,
                    }
                end
            end
        end
    end
end

local function installPagerSizePatch()
    local ok_b, B = pcall(require, "screens/sui_bottombar")
    if not ok_b or not B or type(B.resizePaginationButtons) ~= "function" then
        logger.info("wrFmPatch: sui_bottombar unavailable, pager size patch skipped")
        return
    end
    if B._wr_pager_size_patched then return end
    B._wr_pager_size_patched = true
    local orig_resize = B.resizePaginationButtons
    B.resizePaginationButtons = function(widget, icon_size)
        local res = orig_resize(widget, icon_size)
        pcall(function()
            if not widget then return end
            -- SimpleUI's pagination preset scales OUR baselines (s = 1.0 keeps the
            -- values this pager has always had); the in-page pagers use the same
            -- factor, so the two stay equal in every preset.
            local pscale = TitleMetrics.pagerScale()
            local icon_px = math.floor(Screen:scaleBySize(PAGER_ICON_SZ) * pscale)
            local font_px = math.floor(PAGER_FONT_SZ * pscale)
            local names = {
                "page_info_left_chev", "page_info_right_chev",
                "page_info_first_chev", "page_info_last_chev",
            }
            for _, n in ipairs(names) do
                local btn = widget[n]
                if btn and btn.init then
                    btn.icon_width = icon_px
                    btn.icon_height = icon_px
                    btn:init()
                end
            end
            -- btn:init() rebuilds ges_events, so widen after it
            local touch = Screen:scaleBySize(TitleMetrics.TOUCH)
            for _, n in ipairs(names) do
                widenTouchRange(widget[n], touch)
            end
            local txt = widget.page_info_text
            if txt and txt.init then
                txt.text_font_size = font_px
                txt:init()
            end
        end)
        return res
    end
    logger.info("wrFmPatch: pager size patch installed (baseline icon " .. PAGER_ICON_SZ
        .. " / font " .. PAGER_FONT_SZ .. " scaled by the SimpleUI pagination preset)")

    -- apply to the currently live FM pager as well
    pcall(function()
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_f and FM.instance
        local fc = fm and (fm.file_chooser or (fm.ui and fm.ui.file_chooser))
        if fc then B.resizePaginationButtons(fc, B.getPaginationIconSize and B.getPaginationIconSize() or 0) end
    end)
end

local function installPagerTextPatch()
    local ok_fc, FC = pcall(require, "ui/widget/filechooser")
    if not ok_fc or not FC or type(FC.updatePageInfo) ~= "function" or FC._wr_xy_patched then
        return
    end
    FC._wr_xy_patched = true
    -- Single page: there is nothing to paginate, so hide KOReader's footer
    -- pager row and reclaim its height, exactly like the weread shelf does.
    -- (Menu:updatePageInfo re-shows the chevrons on every build, so this runs
    -- after each build; the height comes from _recalculateDimen, which is
    -- wrapped below to temporarily zero the widgets it measures.)
    local PAGER_BTNS = { "page_info_left_chev", "page_info_right_chev",
                         "page_info_first_chev", "page_info_last_chev" }
    local function hidePagerRow(fc)
        for _, n in ipairs(PAGER_BTNS) do
            local b = fc[n]
            if b and b.hide then b:hide() end
        end
        if fc.page_info_text then fc.page_info_text:setText("") end
        -- Without these the row keeps painting the previously drawn (grey)
        -- "x/y" until some other repaint happens.
        if fc.page_info and fc.page_info.resetLayout then fc.page_info:resetLayout() end
        local ok_ui, UIMgr = pcall(require, "ui/uimanager")
        if ok_ui and UIMgr then
            UIMgr:setDirty(fc.show_parent or fc, "ui")
        end
    end
    local orig_update_items = FC.updateItems
    if type(orig_update_items) == "function" and not FC._wr_single_page_patched then
        FC._wr_single_page_patched = true
        FC.updateItems = function(self, ...)
            local res = orig_update_items(self, ...)
            local single = (self.page_num or 1) <= 1
            if single ~= self._wr_single_page then
                self._wr_single_page = single
                -- relayout once so the list takes (or gives back) the freed
                -- footer height
                res = orig_update_items(self, ...)
            end
            -- Always last: the rebuild above ends with updatePageInfo, which
            -- re-shows the chevrons and rewrites "x/y".
            if single then hidePagerRow(self) end
            return res
        end
        local orig_recalc = FC._recalculateDimen
        if type(orig_recalc) == "function" then
            FC._recalculateDimen = function(self, ...)
                if not self._wr_single_page then return orig_recalc(self, ...) end
                -- shrink the two widgets its bottom_height measures, call the
                -- original, then restore (so a later show() still works)
                local saved = {}
                local function shrink(w)
                    if w and w.dimen then
                        saved[w] = { w.dimen.w, w.dimen.h }
                        w.dimen.w, w.dimen.h = 0, 0
                    end
                end
                shrink(self.page_info_text)
                shrink(self.page_return_arrow)
                local ok, res = pcall(orig_recalc, self, ...)
                for w, wh in pairs(saved) do
                    w.dimen.w, w.dimen.h = wh[1], wh[2]
                end
                if not ok then error(res) end
                return res
            end
        end
    end
    local orig = FC.updatePageInfo
    FC.updatePageInfo = function(self, ...)
        -- local-bookshelf pager: match the weread pager's icon spacing (27px
        -- spacer) and show the page number as "x/y" instead of "第 x 页，共 y 页"
        if self.page_info_spacer then
            self.page_info_spacer.width = Screen:scaleBySize(21)
        end
        local res = orig(self, ...)
        pcall(function()
            if self.page_info_text and self.page_num and self.page_num >= 1 then
                self.page_info_text:setText(
                    tostring(self.page or 1) .. "/" .. tostring(self.page_num))
            end
            -- Long-press (on release) on the page number or on any of the four
            -- arrows opens SimpleUI's own pagination-bar settings window. The tap
            -- keeps KOReader's own page-number dialog: call_hold_input_on_tap makes
            -- the Button use hold_input for taps (button.lua:88-89), while
            -- hold_callback outranks it for a hold (button.lua:554-559).
            if not self._wr_pager_hold_hooked then
                self._wr_pager_hold_hooked = true
                M.hookPagerHoldToSettings(self.page_info_text)
                M.hookPagerHoldToSettings(self.page_info_left_chev)
                M.hookPagerHoldToSettings(self.page_info_right_chev)
                M.hookPagerHoldToSettings(self.page_info_first_chev)
                M.hookPagerHoldToSettings(self.page_info_last_chev)
            end
            -- HorizontalGroup caches its offsets; without this the new spacer
            -- width / shorter text never reflow
            if self.page_info and self.page_info.resetLayout then
                self.page_info:resetLayout()
            end
            local ok_ui2, UIMgr2 = pcall(require, "ui/uimanager")
            if ok_ui2 and UIMgr2 then
                UIMgr2:setDirty(self.show_parent or "all", "ui")
            end
        end)
        return res
    end
    logger.info("wrFmPatch: pager spacing/format patch installed (21px, x/y)")
    -- apply to the live FM pager as well
    pcall(function()
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_f and FM.instance
        local fc = fm and (fm.file_chooser or (fm.ui and fm.ui.file_chooser))
        if fc and type(fc.updatePageInfo) == "function" then fc:updatePageInfo() end
    end)
end

--- Tell the live weread pages that the shared rows/cols changed so they rebuild in
--- place. Two callers, because the two menu paths differ:
---   * SimpleUI's settings window writes the setting on APPLY -> the store hook fires;
---   * coverbrowser's own "items per page" widget only mutates the FileChooser fields
---     on apply and writes the setting on CLOSE (main.lua:222-242) -> there the
---     relayout is what happens at apply, so the mosaic recalc watches for it.
local function notifyCoverGridChange()
    pcall(function()
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        local stack = ok_ui and UIManager
            and (UIManager._window_stack or UIManager.window_stack)
        for _, entry in ipairs(stack or {}) do
            local w = entry and entry.widget
            if w and type(w.refreshCoverGrid) == "function" then
                w:refreshCoverGrid()
            end
        end
    end)
end

local function installMosaicMarginHook()
    local ok_m, MM = pcall(require, "mosaicmenu")
    if not ok_m or not MM or type(MM._recalculateDimen) ~= "function" then
        logger.info("wrFmPatch: mosaicmenu unavailable (coverbrowser absent?)")
        return
    end
    if mosaic_hook_installed then return end
    mosaic_hook_installed = true
    local orig_recalc = MM._recalculateDimen
    local mosaic_top_extra = Screen:scaleBySize(TitleMetrics.GRID_TOP_EXTRA)
    -- Gap between covers, shared with the weread shelf (TitleMetrics.coverGap):
    -- one number for both pages instead of a second hand-tuned margin.
    local m = TitleMetrics.coverGap()
    -- ONE place for the mosaic sizing, used by the recalc wrapper and again right
    -- before the item build: some startup paths build the grid before our recalc
    -- runs, which left the widened outer spacers and the old item width in the same
    -- row — the row then overflowed and the right margin vanished until a settings
    -- change re-synced them.
    local function sizeMosaicItems(w)
        local rows, cols = w.nb_rows, w.nb_cols
        local id = w.inner_dimen
        if not (rows and cols and rows > 0 and cols > 0 and id and id.w and id.h) then
            return false
        end
        -- keep the same bottom edge while the grid is shifted down by
        -- mosaic_top_extra (see the item_group top spacer below)
        local h_avail = math.max(1, id.h - mosaic_top_extra)
        -- Outer margins match the title separator's inset (43px, like the bookshelf's
        -- grid) while the gap BETWEEN covers stays the small shared value.
        local outer = Screen:scaleBySize(TitleMetrics.LINE_INSET)
        w.item_margin = m
        w.item_height = math.max(1, math.floor(
            (h_avail - (w.others_height or 0) - (1 + rows) * m) / rows))
        w.item_width = math.max(1, math.floor(
            (id.w - 2 * outer - (cols - 1) * m) / cols))
        w.item_dimen = Geom:new{ x = 0, y = 0, w = w.item_width, h = w.item_height }
        return true
    end

    MM._recalculateDimen = function(self, ...)
        orig_recalc(self, ...)
        -- Publish our margin unconditionally: when the geometry is not measurable
        -- yet the code below bails out, and leaving upstream's value (18px) in place
        -- let the bookshelf mirror a margin FM itself would never use.
        self.item_margin = m
        if not sizeMosaicItems(self) then
            return
        end
        -- The local library's rows/cols changed without a settings write (coverbrowser
        -- mutates the fields on APPLY and saves them on close): follow the relayout.
        -- Needed a first-run case: on the FIRST apply after KOReader starts there is no
        -- baseline yet, and requiring one kept the watcher silent — the shelf then only
        -- followed the close-time setting write ("first apply does nothing, every later
        -- one is instant"). With no baseline, compare against the stored setting
        -- instead: a difference means an apply already happened, so notify.
        local n_cols, n_rows = self.nb_cols, self.nb_rows
        if n_cols and n_rows then
            local seen = MM._wr_grid_seen
            if not seen then
                local stored_cols, stored_rows
                pcall(function()
                    local ok_b, B = pcall(require, "bookinfomanager")
                    if ok_b and B and type(B.getSetting) == "function" then
                        stored_cols = tonumber(B:getSetting("nb_cols_portrait"))
                        stored_rows = tonumber(B:getSetting("nb_rows_portrait"))
                    end
                end)
                if stored_cols ~= n_cols or stored_rows ~= n_rows then
                    notifyCoverGridChange()
                end
            elseif seen[1] ~= n_cols or seen[2] ~= n_rows then
                notifyCoverGridChange()
            end
            MM._wr_grid_seen = { n_cols, n_rows }
        end
    end

    -- shift the whole grid down: enlarge the item_group's leading spacer
    local orig_build = MM._updateItemsBuildUI
    if type(orig_build) == "function" then
        -- Kept so the bookshelf can still read SimpleUI's strip height: it lives as
        -- an upvalue of the ORIGINAL builder, not of this wrapper.
        MM._wr_orig_updateItemsBuildUI = orig_build
        MM._updateItemsBuildUI = function(self, ...)
            -- Size first: the items are built from self.item_dimen below.
            sizeMosaicItems(self)
            local r = orig_build(self, ...)
            pcall(function()
                local g = self.item_group
                -- Shift exactly once per spacer object. coverbrowser rebuilds the
                -- group's children on every update, but some paths reuse them, and
                -- an unconditional "+= mosaic_top_extra" would push the grid lower
                -- on every folder visit until the layout blew up.
                if g and g[1] and type(g[1].width) == "number"
                        and not g[1]._wr_grid_padded then
                    g[1]._wr_grid_padded = true
                    g[1].width = g[1].width + mosaic_top_extra
                end
                -- Horizontal outer margins: DERIVED from the sizing just applied, so
                -- every row always adds up to the available width (a constant span
                -- could not correct a row built with a different item width).
                local id_w = self.inner_dimen and self.inner_dimen.w
                local cols = self.nb_cols
                if id_w and cols and self.item_width then
                    local span = math.max(m, math.floor(
                        (id_w - cols * self.item_width - (cols - 1) * m) / 2))
                    for _, container in ipairs(g or {}) do
                        local row = container and container[1]
                        if type(row) == "table" and row[1] and row[#row]
                                and type(row[1].width) == "number"
                                and type(row[#row].width) == "number" then
                            row[1].width = span
                            row[#row].width = span
                        end
                    end
                end
            end)
            return r
        end
    end
    -- coverbrowser copies these methods onto the widget class when mosaic is
    -- enabled, and that copy is taken before this hook runs — so patching
    -- MosaicMenu alone never reached the live grid. (The previous guard also
    -- required FileChooser.nb_cols_portrait, which is only set when the user
    -- changes that setting, so the fix-up was skipped at startup as well.) Patch
    -- the class AND the live widget, with no such guard.
    local ok_fc, FC = pcall(require, "ui/widget/filechooser")
    if ok_fc and FC then
        if FC._recalculateDimen == orig_recalc then
            FC._recalculateDimen = MM._recalculateDimen
        end
        if type(orig_build) == "function"
                and FC._updateItemsBuildUI == orig_build
                and MM._updateItemsBuildUI then
            FC._updateItemsBuildUI = MM._updateItemsBuildUI
        end
    end
    -- coverbrowser assigns FileChooser._recalculateDimen from MosaicMenu while the
    -- display mode is set up (main.lua:687) — at startup, i.e. *before* this hook
    -- runs, which is why patching the module table alone never reached the grid.
    -- The class assignment above plus this live-widget assignment is what makes the
    -- margin land. A forced rebuild is deliberately NOT done here: calling
    -- updateItems(1) at this point re-entered coverbrowser's own update path while
    -- the FileManager was still drawing, and a class-level updateItems wrapper was
    -- dropped for the same reason.
    pcall(function()
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_f and FM.instance
        local fc = fm and (fm.file_chooser or (fm.ui and fm.ui.file_chooser))
        if not fc then return end
        if fc._recalculateDimen == orig_recalc then
            fc._recalculateDimen = MM._recalculateDimen
        end
        if type(orig_build) == "function" and fc._updateItemsBuildUI == orig_build then
            fc._updateItemsBuildUI = MM._updateItemsBuildUI
        end
    end)
    logger.info("wrFmPatch: mosaic margin hook installed (m=" .. m .. ")")
end

--- Call synchronously from WeReadPlugin:init(): light FM title hook only, so
--- it catches the FM TitleBar construction (heavy coverbrowser work is
--- deferred to keep first paint snappy / crash-free).
-- forward declarations (defined further below, referenced inside apply_fm)
local layoutFMToolbar
local installFMToolbarPatch

--- SimpleUI's navpager arrows only jump to first/last on hold_RELEASE (see its
--- navbar_hold_settings zone), while our mirrored dock arrows act as soon as
--- the hold fires. Patch the zones registered on the FileManager so both feel
--- the same: the jump happens while the finger is still down, and the later
--- hold_release does not fire a second time. Arrow boundaries are read from
--- SimpleUI's own navbar_pos_prev/next zones, so its geometry stays the source
--- of truth.
--- Make the navpager arrows jump on HOLD (not on release) for every widget
--- SimpleUI registers its bar zones on — the FileManager and any page it hosts
--- through the Bar Injection API. SimpleUI's own zones are hold_release, while
--- our pages used to fire on hold; this keeps the two identical.
-- Arrow boundaries are read from SimpleUI's own navbar_pos_prev/next zones, so
-- its geometry stays the source of truth.
--- Armed by our own arrow-state report (below) and consumed by
--- installRedundantRefreshSuppress(). Keyed by widget; stores a wall-clock second
--- so a stale arm can never suppress a repaint much later.
local wr_arrow_suppress_at = {}

local function rewriteNavpagerHold(zones)
    local ok_cfg, Config = pcall(require, "infra/sui_config")
    if not (ok_cfg and Config and Config.isNavpagerEnabled
            and Config.isNavpagerEnabled()) then return end
    local sw = Screen:getWidth()
    local prev_end_x, next_x, hold_start, hold_settings
    for _, z in ipairs(zones or {}) do
        local sz = z.screen_zone
        if z.id == "navbar_pos_prev" and sz then
            prev_end_x = (sz.ratio_x + sz.ratio_w) * sw
        elseif z.id == "navbar_pos_next" and sz then
            next_x = sz.ratio_x * sw
        elseif z.id == "navbar_hold_start" then
            hold_start = z
        elseif z.id == "navbar_hold_settings" then
            hold_settings = z
        end
    end
    if not (hold_start and hold_settings and prev_end_x and next_x) then
        return
    end
    local handled = false
    -- Direction state comes from the topmost pageable widget we can see, and only
    -- falls back to SimpleUI's resolver. Keeping the primary source here means
    -- the hold path cannot silently depend on a foreign helper's semantics.
    local function stateFromTop()
        local ok_ui, UIMgr = pcall(require, "ui/uimanager")
        if ok_ui and UIMgr then
            local stack = UIMgr._window_stack or UIMgr.window_stack
            for i = #(stack or {}), 1, -1 do
                local w = stack[i] and stack[i].widget
                if w and type(w.page) == "number"
                        and type(w.page_num) == "number" then
                    return w.page > 1, w.page < w.page_num
                end
            end
        end
        local prev, nxt = false, false
        if Config.getNavpagerState then
            local ok_s, p, n = pcall(Config.getNavpagerState)
            if ok_s then prev, nxt = p, n end
        end
        return prev == true, nxt == true
    end
    local function hasDir(dir)
        local prev, nxt = stateFromTop()
        if dir == "prev" then return prev end
        return nxt
    end
    -- Same resolution SimpleUI uses: topmost pageable widget on the stack,
    -- otherwise the FileManager's file chooser. Returns true when the jump was
    -- actually handed to a target (so the caller knows whether to swallow the
    -- release or let SimpleUI have it).
    local function gotoPage(page)
        local ok_ui, UIMgr = pcall(require, "ui/uimanager")
        if ok_ui and UIMgr then
            local stack = UIMgr._window_stack or UIMgr.window_stack
            for i = #(stack or {}), 1, -1 do
                local w = stack[i] and stack[i].widget
                if w then
                    local target, fn
                    if type(w.onGotoPage) == "function"
                            and type(w.page_num) == "number" then
                        target, fn = w, w.onGotoPage
                    elseif w.file_chooser
                            and type(w.file_chooser.onGotoPage) == "function"
                            and type(w.file_chooser.page_num) == "number" then
                        target, fn = w.file_chooser, w.file_chooser.onGotoPage
                    end
                    if target then
                        local ok = pcall(function()
                            fn(target, page or target.page_num)
                        end)
                        if ok then return true end
                    end
                end
            end
        end
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local fc = ok_f and FM.instance and FM.instance.file_chooser
        if fc and type(fc.onGotoPage) == "function"
                and type(fc.page_num) == "number" then
            local ok = pcall(function() fc:onGotoPage(page or fc.page_num) end)
            if ok then return true end
        end
        return false
    end
    local orig_start = hold_start.handler
    hold_start.handler = function(ges)
        local x = ges and ges.pos and ges.pos.x or -1
        local dir
        if x >= 0 and x < prev_end_x then
            dir = "prev"
        elseif next_x and x >= next_x then
            dir = "next"
        end
        if dir then
            local allowed = hasDir(dir)
            local target = (dir == "prev") and 1 or nil
            local jumped = false
            if allowed then jumped = gotoPage(target) end
            logger.info("wrHold: dir=" .. dir .. " x=" .. tostring(x)
                .. " allowed=" .. tostring(allowed)
                .. " jumped=" .. tostring(jumped))
            if jumped then
                handled = true
                return true
            end
            -- Nothing moved: do NOT swallow the release — SimpleUI's own
            -- hold_release handler keeps its chance (this is what makes the
            -- feature degrade to "jump on release" instead of "dead").
            handled = false
            if orig_start then return orig_start(ges) end
            return true
        end
        handled = false
        if orig_start then return orig_start(ges) end
        return true
    end
    local orig_settings = hold_settings.handler
    hold_settings.handler = function(ges)
        if handled then
            handled = false -- already jumped on hold; swallow the release
            return true
        end
        if orig_settings then return orig_settings(ges) end
        return true
    end
end

--- SimpleUI's navpager arrows are internally inconsistent for the built-in
--- homescreen: the arrow is lit from `_current_page/_total_pages`, while its tap
--- path needs `onNextPage/onPrevPage` + a numeric `page_num`. The homescreen has
--- the methods but no `page_num`, so the tap does nothing (it falls through to
--- the invisible FileManager underneath). Wrap the two arrow taps: when the
--- normal gate reports no direction, use the topmost fullscreen widget's own
--- onNextPage/onPrevPage instead.
local function rewriteNavpagerArrows(zones)
    for _, z in ipairs(zones or {}) do
        if z and (z.id == "navbar_pos_prev" or z.id == "navbar_pos_next") then
            local is_prev = (z.id == "navbar_pos_prev")
            local orig_h = z.handler
            z.handler = function(ev)
                local forward = false
                local ok = pcall(function()
                    local ok_cfg, Config = pcall(require, "infra/sui_config")
                    local prev, nxt = false, false
                    if ok_cfg and Config and Config.getNavpagerState then
                        local ok_s, p, n = pcall(Config.getNavpagerState)
                        if ok_s then prev, nxt = p, n end
                    end
                    -- Normal case: a direction exists -> keep SimpleUI's own
                    -- handler (it pages the FM / our pages / custom screens).
                    if (is_prev and prev) or ((not is_prev) and nxt) then
                        forward = true
                        return
                    end
                    local ok_ui, UIMgr = pcall(require, "ui/uimanager")
                    if not (ok_ui and UIMgr) then return end
                    local stack = UIMgr._window_stack or UIMgr.window_stack
                    for i = #(stack or {}), 1, -1 do
                        local w = stack[i] and stack[i].widget
                        if w and w.covers_fullscreen then
                            local fn = is_prev and "onPrevPage" or "onNextPage"
                            local is_hs = (w.name == "homescreen")
                                or w._current_page ~= nil
                                or w._total_pages ~= nil
                            if is_hs and type(w[fn]) == "function" then
                                pcall(function() w[fn](w) end)
                            end
                            return
                        end
                    end
                end)
                if forward or not ok then
                    if orig_h then return orig_h(ev) end
                    return true
                end
                return true
            end
        end
    end
end

local function installNavpagerHoldPatch()
    local ok_b, B = pcall(require, "screens/sui_bottombar")
    if not ok_b or not B or type(B.registerTouchZones) ~= "function" then
        return
    end
    if B._wr_navpager_hold_patched then return end
    B._wr_navpager_hold_patched = true
    local orig_register = B.registerTouchZones
    B.registerTouchZones = function(plugin, w)
        if not (w and type(w.registerTouchZones) == "function") then
            return orig_register(plugin, w)
        end
        -- Temporarily intercept the widget's own registration so the zone
        -- handlers can be rewritten before they are installed.
        local orig_wreg = w.registerTouchZones
        w.registerTouchZones = function(self, zones)
            pcall(rewriteNavpagerHold, zones)
            pcall(rewriteNavpagerArrows, zones)
            local res = orig_wreg(self, zones)
            -- Zones now exist on the widget: let the page take over individual
            -- tabs (its family switch) or react to the registration.
            if type(self.on_zones_registered) == "function" then
                pcall(self.on_zones_registered, self, zones)
            end
            -- NOTE: nothing is stamped here. A previous iteration stamped a
            -- global transition timestamp on every dock zone to feed a repaint
            -- coalescer; that coalescer swallowed the repaint of the view being
            -- switched to (the new view shares the old one's name/region), which
            -- is what made tab switches look stuck. Both are gone.
            -- Native navpager arrows: SimpleUI builds this page's bar while the
            -- page is still being shown (not yet on the window stack), so its own
            -- getNavpagerState() reads the PREVIOUS page and the arrows would
            -- keep that page's state. Report this page's real state explicitly
            -- after every zone registration — that also re-runs on every SimpleUI
            -- bar rebuild, so the state can never go stale.
            pcall(function()
                if not (self.name == "weread_shelf" or self.name == "weread_stats") then return end
                local ok_cfg, Config = pcall(require, "infra/sui_config")
                if not (ok_cfg and Config and Config.isNavpagerEnabled
                        and Config.isNavpagerEnabled()) then return end
                local ok_b, B = pcall(require, "screens/sui_bottombar")
                if not (ok_b and B and B.updateNavpagerArrows) then return end
                local p, pn = self.page, self.page_num
                local numeric = type(p) == "number" and type(pn) == "number"
                local prev = numeric and p > 1 or false
                local nxt = numeric and p < pn or false
                B.updateNavpagerArrows(self, prev, nxt)
                -- Record what the arrows now show and arm the one-shot suppression
                -- of SimpleUI's deferred whole-page refresh (see
                -- installRedundantRefreshSuppress): that refresh re-draws exactly
                -- this state and is the navpager-only switch flash.
                self._wr_reported_arrows = { prev, nxt }
                wr_arrow_suppress_at[self] = os.time()
                -- NO setDirty here: this runs inside UIManager:show (before the
                -- first paint), so the widget's own pending repaint already draws
                -- the corrected arrows. That extra whole-widget setDirty was a
                -- second large e-ink refresh right after every switch — the flash
                -- only navpager mode showed.
                logger.info("wrNav: " .. tostring(self.name)
                    .. " page=" .. tostring(p) .. "/" .. tostring(pn)
                    .. " prev=" .. tostring(prev) .. " next=" .. tostring(nxt))
            end)
            -- Diagnostic (kept on purpose, see AGENTS.md 日志自查线索): dump the
            -- real zone list of our pages once per registration, so the navpager
            -- layout (ids + rectangles) can be compared with what we assume
            -- instead of being guessed.
            pcall(function()
                if not (self.name == "weread_shelf" or self.name == "weread_stats") then return end
                local parts = {}
                for id, tz in pairs(self._zones or {}) do
                    local r = tz and tz.gs_range and tz.gs_range.range
                    if r then
                        parts[#parts + 1] = string.format("%s@%d,%d %dx%d", id,
                            r.x or -1, r.y or -1, r.w or -1, r.h or -1)
                    end
                end
                table.sort(parts)
                logger.info("wrZoneTab: " .. tostring(self.name) .. " | "
                    .. table.concat(parts, " | "))
            end)
            return res
        end
        local res = orig_register(plugin, w)
        w.registerTouchZones = orig_wreg
        return res
    end
end

--- SimpleUI's deferred navpager refresh passes a snapshot taken BEFORE our page
--- entered the window stack — i.e. the PREVIOUS screen's paging state — and writes
--- it over the arrows we already reported at registration. Correct the arguments
--- for our two pages (same rule we apply in the registration report) so the
--- native refresh becomes a no-op in content: the arrows stay right, and the
--- one-shot suppression below can prove that its repaint paints nothing new.
--- Wrapped defensively: any error leaves the original call untouched.
local function installNavpagerStateCorrection()
    local ok_b, B = pcall(require, "screens/sui_bottombar")
    if not ok_b or not B or type(B.updateNavpagerArrows) ~= "function" then return end
    if B._wr_state_corrected then return end
    B._wr_state_corrected = true
    local orig = B.updateNavpagerArrows
    B.updateNavpagerArrows = function(widget, has_prev, has_next)
        pcall(function()
            if type(widget) ~= "table" then return end
            local name = widget.name
            if not (name == "weread_shelf" or name == "weread_stats") then return end
            local p, pn = widget.page, widget.page_num
            if type(p) ~= "number" or type(pn) ~= "number" then return end
            has_prev, has_next = p > 1, p < pn
        end)
        return orig(widget, has_prev, has_next)
    end
    logger.info("wrNavState: corrected updateNavpagerArrows for our pages")
end

--- Suppress ONE provably redundant repaint: SimpleUI's injected-page show patch
--- schedules, one tick after the show, `UIManager:setDirty(target2, "ui")` with
--- no region (infra/sui_patches.lua, navpager block) — unconditionally, even when
--- the arrow state it drew is the one we already reported before the first paint.
--- Our two pages report their arrows at registration (before the paint), so that
--- refresh re-draws identical content; on e-ink it is a second full-page refresh,
--- i.e. the flash only navpager mode shows. SimpleUI 2.7.1 offers no descriptor
--- flag to skip it and the guard (_navpager_rebuild_pending) is file-local, so the
--- only precise interception point is this call.
---
--- Constraints (deliberately narrow, fail-open):
---   * only our two pages (they are the only widgets that self-report arrows),
---   * only ONE repaint per report (disarmed on use; also expires by wall clock),
---   * only the whole-widget "ui" refresh with NO region (the shape SimpleUI uses),
---   * only while the arrows still show exactly the state we recorded (i.e. the
---     repaint would paint nothing new);
---   * every check runs inside pcall — any error means "do not suppress";
---   * it never suppresses anything else, and it never swallows a repaint it
---     cannot prove redundant.
--- Remove this if SimpleUI ever exposes a descriptor flag for the same thing.
local function installRedundantRefreshSuppress()
    local UIMgr = require("ui/uimanager")
    if UIMgr._wr_suppress_installed then return end
    UIMgr._wr_suppress_installed = true
    local WINDOW_S = 2   -- the deferred refresh lands within the same second
    local orig_set = UIMgr.setDirty
    UIMgr.setDirty = function(self, widget, refreshtype, refreshregion, ...)
        local skip = false
        if type(widget) == "table" then
            pcall(function()
                local t = wr_arrow_suppress_at[widget]
                if not t then return end
                if os.time() - t > WINDOW_S then
                    wr_arrow_suppress_at[widget] = nil   -- stale: drop it
                    return
                end
                -- Other refreshes in the same burst (title band with a region,
                -- type=nil, type=fn) must NOT consume the arm: the one we care
                -- about is the LAST one, the plain whole-widget "ui" refresh.
                if refreshtype ~= "ui" or refreshregion ~= nil then return end
                wr_arrow_suppress_at[widget] = nil       -- consume on the candidate
                local bar = widget._navbar_bar
                local hg = bar and (bar._navpager_hg or bar[1])
                local flags = widget._wr_reported_arrows
                if not (hg and flags and hg[1] and hg[#hg]) then
                    logger.info("wrNavSuppress: candidate rejected (no arrow cells)")
                    return
                end
                if hg[1]._arrow_enabled ~= flags[1]
                        or hg[#hg]._arrow_enabled ~= flags[2] then
                    logger.info("wrNavSuppress: candidate rejected, arrows="
                        .. tostring(hg[1]._arrow_enabled) .. ","
                        .. tostring(hg[#hg]._arrow_enabled)
                        .. " reported=" .. tostring(flags[1]) .. "," .. tostring(flags[2]))
                    return
                end
                skip = true
            end)
        end
        if skip then
            logger.info("wrNavSuppress: skipped 1 redundant whole-page ui repaint"
                .. " (arrows already correct)")
            return
        end
        return orig_set(self, widget, refreshtype, refreshregion, ...)
    end
    logger.info("wrNavSuppress: installed (one-shot, our pages only, fail-open)")
end

local function installUiScaleRefreshHook()
    local ok_tb, TB = pcall(require, "screens/sui_titlebar")
    if not (ok_tb and TB and type(TB.reapplyAll) == "function") then return end
    if TB._wr_ui_scale_hooked then return end
    TB._wr_ui_scale_hooked = true
    -- SimpleUI re-applies the title-bar size preset to every live widget through
    -- this one call (Button Size -> _reapplyAllTitlebars -> reapplyAll,
    -- sui_menu.lua:1770-1773). The local library updates live because that pass
    -- re-runs its layout; our pages own their header rows, so they need the same
    -- moment. The pages themselves no-op unless the preset really changed.
    local orig = TB.reapplyAll
    TB.reapplyAll = function(fm_self, window_stack, ...)
        local res = orig(fm_self, window_stack, ...)
        pcall(function()
            for _, entry in ipairs(window_stack or {}) do
                local w = entry and entry.widget
                if w and type(w.refreshUiScale) == "function" then
                    w:refreshUiScale()
                end
            end
        end)
        return res
    end
    logger.info("wrFmPatch: titlebar.reapplyAll wrapped (hosted pages refresh live)")
end

--- Opens SimpleUI's own "Title Bar" settings window — the same one its menu
--- entry opens. Mirrors how SimpleUI opens the top-bar window
--- (screens/sui_topbar.lua: _showTopbarSettingsWindow), but with
--- plugin._makeTitleBarMenu instead of _makeTopbarMenu.
local function openTitleBarSettingsWindow()
    pcall(function()
        local ok_st, ST = pcall(require, "engines/sui_window")
        local ok_ui, UI = pcall(require, "infra/sui_core")
        local plugin = ok_ui and UI and UI.getLivePlugin and UI.getLivePlugin()
        if not (ok_st and ST and plugin) then return end
        if not plugin._makeTitleBarMenu and plugin.addToMainMenu then
            plugin:addToMainMenu({})
        end
        if not plugin._makeTitleBarMenu then return end
        local navpager = false
        pcall(function()
            local Config = require("infra/sui_config")
            navpager = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false
        end)
        local win_title = "Title Bar"
        local function buildRoot(ctx)
            local ctx_menu = ST.makeCtxMenu(ctx)
            -- The window title reuses SimpleUI's own localised label for this bar:
            -- its menu item already carries the translation, so the title follows
            -- the UI language without us duplicating any string.
            pcall(function()
                local bars = plugin.makeBarsMenuItems and plugin.makeBarsMenuItems(ctx_menu)
                local entry = bars and bars[3]   -- Status / Navigation / Title Bar (sui_menu.lua:2770-2774)
                if entry and entry.text and entry.text ~= "" then win_title = entry.text end
            end)
            return ST.MenuTable{
                items          = plugin._makeTitleBarMenu(ctx_menu),
                inner_w        = ctx.inner_w,
                repaint        = function() ctx.repaint() end,
                lock_overlay   = ctx.lockOverlay,
                unlock_overlay = ctx.unlockOverlay,
                push_stack     = function(id, params)
                    if type(id) == "string" then ctx.push(id, params)
                    else ctx.push("nested_menu", params) end
                end,
                on_close       = function() end,
            }
        end
        local win = ST:new{
            name             = "wr_title_settings",
            title            = function() return win_title end,
            screens          = ST.makeSettingsScreens(buildRoot),
            navpager_mode    = navpager,
            position         = "bottom",
            has_settings_btn = true,
        }
        win:show()
    end)
end

--- Long-press on the FM title bar (the title row and its empty areas) opens that
--- window, matching SimpleUI's "hold a bar to open its settings" habit. Buttons are
--- deliberately NOT touched: KOReader delivers a hold to the child widget first
--- (widgetcontainer.lua:100-107) and SimpleUI's own button holds are no-ops (its
--- back button's hold = "go to page 1"), so overriding them would remove native
--- behaviour. Gated by the same key SimpleUI uses for its own top-bar hold.
--- Opens SimpleUI's own "Pagination Bar" settings menu in its settings window —
--- the same items its main menu shows under Bars ▸ Pagination Bar. The bar menu
--- builder is exposed on the plugin (plugin.makeBarsMenuItems, sui_menu.lua:2786)
--- and returns the bars in a fixed order (sui_menu.lua:2770-2784), so we take its
--- Pagination Bar entry and hand that entry's own sub-items to the window: the
--- menu content stays SimpleUI's, we only open the window.
local function openPaginationBarSettingsWindow()
    pcall(function()
        local ok_win, Win = pcall(require, "engines/sui_window")
        local ok_ui, UI = pcall(require, "infra/sui_core")
        local plugin = ok_ui and UI and UI.getLivePlugin and UI.getLivePlugin()
        if not (ok_win and Win and plugin) then return end
        if not plugin.makeBarsMenuItems and plugin.addToMainMenu then
            plugin:addToMainMenu({})
        end
        if not plugin.makeBarsMenuItems then return end
        local navpager = false
        pcall(function()
            local Config = require("infra/sui_config")
            navpager = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false
        end)
        local win_title = "Pagination Bar"
        local function buildRoot(ctx)
            local ctx_menu = Win.makeCtxMenu(ctx)
            local bars = plugin.makeBarsMenuItems(ctx_menu) or {}
            local tx = rawget(_G, "_")   -- KOReader installs _; absent in bare tests
            local want = tx and tx("Pagination Bar") or nil
            local entry
            if want then
                for _, it in ipairs(bars) do
                    if it.text == want then entry = it break end
                end
            end
            if not entry then entry = bars[4] end -- …, Title Bar, Pagination Bar, …
            -- Title from SimpleUI's own localised label for this bar
            if entry and entry.text and entry.text ~= "" then win_title = entry.text end
            local items = {}
            if entry and type(entry.sub_item_table_func) == "function" then
                local ok_sub, sub = pcall(entry.sub_item_table_func)
                if ok_sub and type(sub) == "table" then items = sub end
            end
            return Win.MenuTable{
                items          = items,
                inner_w        = ctx.inner_w,
                repaint        = function() ctx.repaint() end,
                lock_overlay   = ctx.lockOverlay,
                unlock_overlay = ctx.unlockOverlay,
                push_stack     = function(id, params)
                    if type(id) == "string" then ctx.push(id, params)
                    else ctx.push("nested_menu", params) end
                end,
                on_close       = function() end,
            }
        end
        local win = Win:new{
            name             = "wr_pager_settings",
            title            = function() return win_title end,
            screens          = Win.makeSettingsScreens(buildRoot),
            navpager_mode    = navpager,
            position         = "bottom",
            has_settings_btn = true,
        }
        win:show()
    end)
end

local function registerTitleHoldZones(fm_self, band_y, band_h)
    if not (fm_self and fm_self.registerTouchZones and band_h and band_h > 0) then return end
    local sh = Screen:getHeight()
    local zone = {
        ratio_x = 0,
        ratio_y = math.max(0, band_y) / sh,
        ratio_w = 1,
        ratio_h = band_h / sh,
    }
    pcall(function()
        fm_self:registerTouchZones({
            {
                id          = "wr_title_hold_start",
                ges         = "hold",
                screen_zone = zone,
                handler     = function() return true end,
            },
            {
                id          = "wr_title_hold_settings",
                ges         = "hold_release",
                screen_zone = zone,
                handler     = function()
                    local enabled = true
                    pcall(function()
                        local Store = require("infra/sui_store")
                        enabled = Store:nilOrTrue("simpleui_topbar_settings_on_hold")
                    end)
                    if enabled then openTitleBarSettingsWindow() end
                    return true
                end,
            },
        })
    end)
end

--- The rows/cols setting (coverbrowser's, which SimpleUI's menu path writes) is the
--- ONE source both pages follow. The local library reacts on its own, but our pages
--- only read it while laying out — so nudge them here, like the Button Size preset.
local function installCoverGridChangeHook()
    local ok_b, B = pcall(require, "bookinfomanager")
    if not (ok_b and B and type(B.saveSetting) == "function") then return end
    if B._wr_grid_hooked then return end
    B._wr_grid_hooked = true
    local orig = B.saveSetting
    B.saveSetting = function(self, key, value, ...)
        local res = orig(self, key, value, ...)
        if key == "nb_cols_portrait" or key == "nb_rows_portrait" then
            notifyCoverGridChange()
        end
        return res
    end
    logger.info("wrFmPatch: cover-grid setting hook installed")
end

local function apply_fm()
    installTitleFaceHook()
    installFMToolbarPatch()
    pcall(installCoverGridChangeHook)
    -- no timer: the preset hook must be in place before the user can change it
    pcall(installUiScaleRefreshHook)
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(1.5, function()
            -- A/B switch: the 7px FM content lift was tuned against the OLD
            -- self-drawn weread pages; both pages are natively hosted now, so it
            -- may no longer be needed (see FM_CONTENT_LIFT).
            if FM_CONTENT_LIFT then pcall(liftFMContent) end
            pcall(installMosaicMarginHook)
            pcall(installPagerSizePatch)
            pcall(installPagerTextPatch)
            pcall(installNavpagerHoldPatch)
            pcall(installNavpagerStateCorrection)
            pcall(installRedundantRefreshSuppress)
            -- (installDirtyCoalesce and installRepaintTrace are intentionally NOT
            -- installed: the coalescer intercepted UIManager.setDirty globally and
            -- dropped the repaint that a just-shown view needed, which is exactly the
            -- "tab switch does nothing / UI looks stuck" symptom. Repaints must never
            -- be swallowed; the switch flash is handled by the show-then-close ordering
            -- and closeForNavigation instead.)
            pcall(function()
                local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
                local fm = ok_f and FM.instance
                if fm then layoutFMToolbar(fm) end
            end)
        end)
    else
        pcall(installMosaicMarginHook)
    end
end


-- ---------------------------------------------------------------------------
-- FM (本地书库) header toolbar: move SimpleUI's titlebar buttons (返回 / 搜索 |
-- 浏览 / 菜单) out of the title row into a compact row below the title
-- separator — 18px glyphs, 16px spacing, 24px side insets — and reserve that
-- row's height in the TitleBar so the content stays uncovered.
-- ---------------------------------------------------------------------------
local fm_toolbar_installed = false

-- ---------------------------------------------------------------------------
-- FM header geometry — single source of truth. Coordinate frame is the
-- TitleBar's top edge, which is exactly where the SimpleUI status bar's bottom
-- edge sits (the FM content is laid out below it), so all values below are
-- effectively measured from the status-bar bottom line:
--   title     : drawn by TitleBar itself (anchor + TitleBar's own padding)
--   separator : title text box bottom + LINE_GAP      (hugs the title by design)
--   icons row : separator bottom (1px) + ICON_GAP, or ICONS_Y when set
--   subtitle  : icon box vertical centre + SUB_SHIFT, or SUB_Y when set
-- ICONS_Y / SUB_Y are optional overrides: leave them nil and each element is
-- derived from the row above it (so changing the title font / icon box keeps
-- the whole block aligned automatically); set one to a bar-relative number to
-- pin just that element.
local FM_HDR = {
    -- Geometry shared with the weread pages (weread/ui/header_metrics.lua): the
    -- shelf's tab/action band reads the same numbers, so both pages' grid boxes
    -- keep the same height in every size preset.
    LINE_GAP   = TitleMetrics.LINE_GAP, -- separator offset below the title row
    ICON_GAP   = TitleMetrics.ICON_GAP, -- toolbar row offset below the separator
    SUB_SHIFT  = -4,   -- subtitle fine-tune around its row centring
    SIDE       = TitleMetrics.LINE_INSET, -- left/right inset (== separator ends)
    ICON_PX    = TitleMetrics.ICON_PX,  -- icon glyph size
    ICON_PAD   = TitleMetrics.ICON_PAD, -- invisible tap padding added to the glyph box
    ICON_GAP_X = TitleMetrics.ICON_GAP_X, -- spacing between icons
    ICONS_Y    = nil,  -- optional override: pin the toolbar row (nil = derive)
    SUB_Y      = nil,  -- optional override: pin the subtitle    (nil = derive)
}

local function shrinkFMButton(btn, box, glyph)
    pcall(function()
        btn.width  = box
        btn.height = box
        btn.padding_left, btn.padding_right = 0, 0
        btn.padding_top, btn.padding_bottom = 0, 0
        local Font = require("ui/font")
        local ok_s, S = pcall(require, "features/sui_style")
        local face = (ok_s and S and S.FACE_ICONS) or "cfont"
        local img = btn.image
        if img then
            img.width, img.height = glyph, glyph
            if img.is_sui_wrapper then
                img.face = Font:getFace(face, math.floor(glyph * 0.65))
            else
                pcall(img.free, img)
                pcall(img.init, img)
            end
        end
        local lbl = btn.label_widget
        if lbl then
            lbl.width, lbl.height = glyph, glyph
            if lbl.is_sui_wrapper then
                lbl.face = Font:getFace(face, math.floor(glyph * 0.65))
            end
        end
        if type(btn.update) == "function" then pcall(btn.update, btn) end
    end)
end

--- Enforce our own x/y at paint time. SimpleUI re-positions the left-side
--- buttons (back/search) whenever page/folder state changes, so storing an
--- overlap_offset is not enough — the paint override wins regardless.
local function forcePaintAt(btn, bar)
    if not (btn and btn.paintTo) or btn._wr_paint_at then return end
    btn._wr_paint_at = true
    local orig = btn.paintTo
    btn.paintTo = function(self, bb, x, y)
        local off = self.overlap_offset or { 0, 0 }
        -- prefer the TitleBar's recorded absolute origin (works for widgets
        -- inside groups too, e.g. the subtitle, which has no offset)
        local base_x = (bar and bar._wr_abs_x) or (x - (off[1] or 0))
        local base_y = (bar and bar._wr_abs_y) or (y - (off[2] or 0))
        local wx, wy = self._wr_x, self._wr_y
        if self._wr_center then
            -- live-measure at paint time (layout may not be ready earlier)
            local w = 0
            pcall(function() w = self:getSize().w or 0 end)
            wx = math.max(0, math.floor((Screen:getWidth() - w) / 2))
        end
        return orig(self, bb, base_x + (wx or 0), base_y + (wy or 0))
    end
end

--- Record the TitleBar's absolute paint origin once (used by forcePaintAt).
local function ensureBarOrigin(tb)
    if not (tb and tb.paintTo) or tb._wr_origin_hooked then return end
    tb._wr_origin_hooked = true
    local orig = tb.paintTo
    tb.paintTo = function(self, bb, x, y)
        self._wr_abs_x, self._wr_abs_y = x, y
        return orig(self, bb, x, y)
    end
end

local fm_toolbar_laying_out = false

layoutFMToolbar = function(fm_self)
    local tb = fm_self and fm_self.title_bar
    if not tb or fm_toolbar_laying_out then return end
    fm_toolbar_laying_out = true
    local sw    = Screen:getWidth()
    -- Follow SimpleUI's own title-bar size preset (Compact / Default / Large =
    -- 0.75 / 1.0 / 1.3) instead of pinning one size: the glyph, its invisible pad
    -- and the inter-icon gap scale together, so the Default preset reproduces the
    -- previous values exactly (47 / 14 / 29 px on a KPW4) while the other two
    -- presets become effective. SIDE stays fixed on purpose — it is what keeps
    -- this row aligned with the title separator above it.
    local size_scale = TitleMetrics.uiScale()
    local glyph = math.floor(Screen:scaleBySize(FM_HDR.ICON_PX) * size_scale)
    local box   = TitleMetrics.controlBoxH()   -- glyph + its invisible tap padding
    local gap   = math.floor(Screen:scaleBySize(FM_HDR.ICON_GAP_X) * size_scale)
    local side  = Screen:scaleBySize(FM_HDR.SIDE)

    local ok = pcall(function()
        ensureBarOrigin(tb)
        -- title row height -> separator y (same formula as the separator patch)
        local title_h = 0
        pcall(function()
            if tb.title_widget and tb.title_widget.getSize then
                title_h = tb.title_widget:getSize().h or 0
            end
        end)
        local sep_y = math.floor(title_h) + Screen:scaleBySize(FM_HDR.LINE_GAP)
        local y     = FM_HDR.ICONS_Y
            or (sep_y + 1 + Screen:scaleBySize(FM_HDR.ICON_GAP))

        -- the four widgets (SimpleUI's injected three + the native right button)
        local widgets = {}
        for _, w in ipairs({
            fm_self._titlebar_up_btn,
            fm_self._titlebar_search_btn,
            fm_self._titlebar_browse_btn,
            tb.right_button,
        }) do
            if w and w.overlap_offset then
                local ox = w.overlap_offset[1] or 0
                if ox < sw then -- skip ones SimpleUI hid by pushing off-screen
                    widgets[#widgets + 1] = w
                end
            end
        end
        if #widgets == 0 then return end

        local lefts, rights = {}, {}
        for _, w in ipairs(widgets) do
            if (w.overlap_offset[1] or 0) < sw / 2 then
                lefts[#lefts + 1] = w
            else
                rights[#rights + 1] = w
            end
        end
        local function by_x(a, b)
            return (a.overlap_offset[1] or 0) < (b.overlap_offset[1] or 0)
        end
        table.sort(lefts, by_x)
        table.sort(rights, by_x)

        local toolbar_touch = Screen:scaleBySize(TitleMetrics.TOUCH)
        --- Long-press on a toolbar button opens the same Title Bar settings window
        --- as the band long-press (SimpleUI's own button holds are no-ops, and the
        --- back button's "hold → page 1" is intentionally replaced by this).
        local function hookButtonHold(w)
            if not (w and w.hold_callback ~= nil) then return end
            w.hold_callback = function() openTitleBarSettingsWindow() end
        end
        for i, w in ipairs(lefts) do
            shrinkFMButton(w, box, glyph)
            w.overlap_align = nil
            w._wr_x = side + (i - 1) * (box + gap)
            w._wr_y = y
            forcePaintAt(w, tb)
            widenTouchRange(w, toolbar_touch)
            hookButtonHold(w)
        end
        local total = #rights * box + math.max(0, #rights - 1) * gap
        local rx0   = math.max(side, sw - side - total)
        for i, w in ipairs(rights) do
            shrinkFMButton(w, box, glyph)
            w.overlap_align = nil
            w._wr_x = rx0 + (i - 1) * (box + gap)
            w._wr_y = y
            forcePaintAt(w, tb)
            widenTouchRange(w, toolbar_touch)
            hookButtonHold(w)
        end

        -- subtitle (folder path) shares the toolbar row, vertically centred
        local sub = tb.subtitle_widget
        if sub then
            -- SimpleUI writes its verbose localised page template into the
            -- subtitle ("Page X of Y"). Rebuild the page part as 第p/pn页 next
            -- to the folder path — no locale text is parsed, the numbers come
            -- from the file chooser; a single page shows no page info at all
            -- (SimpleUI already omits it there).
            if not sub._wr_subtitle_hooked and type(sub.setText) == "function" then
                sub._wr_subtitle_hooked = true
                local orig_set_text = sub.setText
                sub.setText = function(w, text, ...)
                    local fc = fm_self.file_chooser
                    local p  = fc and fc.page
                    local pn = fc and fc.page_num
                    -- Only rewrite calls that really carry the page template
                    -- ("第 1 页，共 2 页" / "Page 1 of 2"): SimpleUI also sets
                    -- the plain path on its own, and rewriting that would drop
                    -- the path and make the next call compose a duplicate.
                    if type(text) == "string" and p and pn and pn > 1 then
                        -- Robust rule: no assumption about the spaces in the
                        -- localised template. A page fragment is identified by
                        -- "页" + "共" (zh) or "Page N of M" (en) plus two
                        -- number groups; SimpleUI also sets the bare path, and
                        -- rewriting that would drop the path.
                        local nums = {}
                        for n in text:gmatch("(%d+)") do nums[#nums + 1] = n end
                        local is_page = (#nums >= 2)
                            and ((text:find("页") and text:find("共"))
                                or text:match("Page%s*%d+%s*of%s*%d+"))
                        if is_page then
                            local head = text:match("^(.*)  ·  ")
                            text = (head and head ~= "")
                                and (head .. "  ·  第" .. p .. "/" .. pn .. "页")
                                or ("第" .. p .. "/" .. pn .. "页")
                        end
                    end
                    return orig_set_text(w, text, ...)
                end
            end
            local sub_h = 0
            pcall(function() sub_h = sub:getSize().h or 0 end)
            local left_w  = #lefts * box + math.max(0, #lefts - 1) * gap
            local right_w = #rights * box + math.max(0, #rights - 1) * gap
            local mid_w = math.max(1, sw - side * 2 - left_w - right_w
                - Screen:scaleBySize(16))
            pcall(function()
                if sub.max_width then sub.max_width = mid_w
                elseif sub.width then sub.width = mid_w end
            end)
            local sub_w = mid_w
            pcall(function()
                if sub.alignment then sub.alignment = "center" end
                sub_w = sub:getSize().w or mid_w
            end)
            sub._wr_x = math.max(side, math.floor((sw - sub_w) / 2))
            sub._wr_center = true
            local sub_y = FM_HDR.SUB_Y
                or (y + math.max(0, math.floor((box - sub_h) / 2))
                    + Screen:scaleBySize(FM_HDR.SUB_SHIFT))
            sub._wr_y = sub_y
            forcePaintAt(sub, tb)
        end

        -- Reserve the toolbar row / recalc / repaint only when the geometry
        -- actually changed: SimpleUI's apply() runs several times per
        -- navigation and each run used to dirty this same title-bar strip
        -- again, which shows up as a flash on e-ink.
        local sig = table.concat({
            tostring(title_h), tostring(sep_y), tostring(y),
            tostring(box), tostring(side), tostring(gap), tostring(#widgets),
        }, ":")
        local unchanged = (fm_self._wr_tb_sig == sig)
        fm_self._wr_tb_sig = sig
        if unchanged then return end

        -- reserve the toolbar row inside the TitleBar so content moves down
        local target_h = y + box + Screen:scaleBySize(TitleMetrics.ROW_TAIL)
        local cur_h    = tb.titlebar_height or (tb.dimen and tb.dimen.h) or 0
        -- Follow the band in BOTH directions: SimpleUI's Button Size preset can
        -- shrink the row too, and pinning only the growth left the grid behind.
        local band_changed = (target_h ~= cur_h)
        -- Publish the band we just computed: the bookshelf derives its own top pad
        -- from it (FM title band + this row + the grid's own top spacing), so grid
        -- tops stay aligned across SimpleUI's Button Size presets. Our own number,
        -- not a KOReader field, so it can never silently read as nil.
        M._fm_band = {
            titlebar_h = target_h,
            top_extra  = Screen:scaleBySize(TitleMetrics.GRID_TOP_EXTRA),
            row_y      = y,
            box        = box,
        }
        if band_changed then
            tb.titlebar_height = target_h
            if tb.dimen then
                tb.dimen = Geom:new{ x = 0, y = 0, w = tb.dimen.w, h = target_h }
            end
        end
        pcall(function()
            if fm_self._recalculateDimen then fm_self:_recalculateDimen() end
        end)
        -- Grid top follows the title band. KOReader's outer layout caches the item
        -- group's offset (measured: the painted y stayed at 212 while the band went
        -- 168 → 186), so we correct the paint coordinate ourselves. The target is an
        -- ABSOLUTE value measured on device: the item group is painted at
        -- (status-bar height + title band), because the grid's own top spacing is the
        -- item group's internal leading spacer. Using an absolute target needs no
        -- "reference band", and if KOReader's cache ever refreshes by itself the
        -- correction simply becomes zero. Installed on every layout so the first
        -- paint is already covered.
        pcall(function()
            local fc = fm_self.file_chooser or (fm_self.ui and fm_self.ui.file_chooser)
            local ig = fc and fc.item_group
            if not (ig and type(ig.paintTo) == "function") or ig._wr_grid_shift_hooked then
                return
            end
            ig._wr_grid_shift_hooked = true
            local topbar_h = 0
            pcall(function()
                local ok_t, T = pcall(require, "screens/sui_topbar")
                if ok_t and T and T.TOTAL_TOP_H then
                    local ok_h, h = pcall(T.TOTAL_TOP_H)
                    if ok_h and tonumber(h) then topbar_h = tonumber(h) end
                end
            end)
            local orig_paint = ig.paintTo
            ig.paintTo = function(g, bb, x, y, ...)
                local dy = 0
                pcall(function()
                    local band = M._fm_band
                    local tb_h = band and band.titlebar_h or nil
                    if tb_h then
                        dy = (topbar_h + tb_h) - y
                    end
                end)
                return orig_paint(g, bb, x, y + dy, ...)
            end
        end)
        -- Re-measuring alone does not move the covers: coverbrowser only re-lays the
        -- grid out on a list refresh, so when the band height changed do what its own
        -- CoverBrowser:refreshFileManagerInstance does (main.lua:621-627). The
        -- signature guard above keeps this from recursing.
        if band_changed then
            pcall(function()
                local fc = fm_self.file_chooser or (fm_self.ui and fm_self.ui.file_chooser)
                if not fc then return end
                if fc._recalculateDimen then fc:_recalculateDimen() end
                if fc.switchItemTable then
                    fc:switchItemTable(nil, nil, fc.prev_itemnumber, { dummy = "" })
                end
            end)
        end
        -- Long-press on the title band opens SimpleUI's Title Bar settings window;
        -- re-registered on every layout because our toolbar reservation changes the
        -- band's height.
        local band_y = 0
        pcall(function()
            local ok_t, T = pcall(require, "screens/sui_topbar")
            if ok_t and T and T.TOTAL_TOP_H then
                local ok_h, h = pcall(T.TOTAL_TOP_H)
                if ok_h and tonumber(h) then band_y = tonumber(h) end
            end
        end)
        registerTitleHoldZones(fm_self, band_y, target_h)
        pcall(function()
            local ok_ui, UIManager = pcall(require, "ui/uimanager")
            if ok_ui and UIManager then UIManager:setDirty(fm_self, "ui") end
        end)
        logger.info("wrFmToolbar: laid out (" .. #lefts .. " left / " .. #rights
            .. " right), glyph=" .. glyph .. " y=" .. y)
    end)
    if not ok then logger.info("wrFmToolbar: layout failed") end
    fm_toolbar_laying_out = false
end

installFMToolbarPatch = function()
    if fm_toolbar_installed then return end
    local ok_t, ST = pcall(require, "screens/sui_titlebar")
    if not ok_t or not ST or type(ST.apply) ~= "function" then
        logger.info("wrFmToolbar: sui_titlebar unavailable, toolbar patch skipped")
        return
    end
    fm_toolbar_installed = true
    local orig_apply = ST.apply
    ST.apply = function(fm_self, ...)
        local res = orig_apply(fm_self, ...)
        pcall(layoutFMToolbar, fm_self)
        return res
    end
    logger.info("wrFmToolbar: hook installed")
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------
--- FM band numbers from the last toolbar layout (see M._fm_band above): the
--- bookshelf uses them to keep its grid top aligned with the local library's.
--- nil until the FM has laid its toolbar out once (caller then falls back).
function M.fmBand()
    return M._fm_band
end

M.ensure = ensure          -- veil only (safe to call repeatedly)
M.apply = apply_fm         -- FM visuals only
--- Opened by long-pressing a bar: the FM title bar (see registerTitleHoldZones)
--- and the bookshelf page's title band (weread/ui/library_view.lua). Moves to
--- fullscreen_host.lua when the shell plugin is split out of this plugin.
M.openTitleBarSettingsWindow = openTitleBarSettingsWindow
--- Opened by long-pressing a pager row's page number (non-navpager mode), on the
--- local library's pager and on the bookshelf's own pager.
M.openPaginationBarSettingsWindow = openPaginationBarSettingsWindow
--- Wires long-press (on release) of a pager control to that window; used by both
--- the local library's pager and the bookshelf's own pager.
M.hookPagerHoldToSettings = hookPagerHoldToSettings
function M.install()       -- both, used by WeReadPlugin:init()
    ensure()
    apply_fm()
end

return M
