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
            self.title_face = Font:getFace("smalltfont", 26)
            -- Measured (paintY logs): FM text top 73 vs weread 66 → 7px low.
            -- title_group overlap offsets are ignored by the layout, so the
            -- real fix is a content-level lift (liftFMContent, scheduled after
            -- boot); pad stays 0 so the title sits at the bar top.
            if self.title_top_padding then
                self.title_top_padding = Screen:scaleBySize(0)
            end
        end
        local res = orig_init(self, ...)
        if is_fm then
            -- separator directly under the 书库 title row (weread position),
            -- not at the whole header bottom (which includes the path subtitle)
            if not self._wr_fm_sep then
                local w = Screen:getWidth()
                local inset = Screen:scaleBySize(24)
                local title_h = 0
                if self.title_widget and self.title_widget.getSize then
                    local ok_s, sz = pcall(function()
                        return self.title_widget:getSize()
                    end)
                    if ok_s and sz then title_h = sz.h or 0 end
                end
                local y = math.max(1, math.floor(title_h)
                    + Screen:scaleBySize(6.5))
                local sep = LineWidget:new{
                    dimen = Geom:new{
                        w = math.max(1, w - 2 * inset),
                        h = Screen:scaleBySize(1),
                    },
                    background = Blitbuffer.gray(0.72),
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
            local names = {
                "page_info_left_chev", "page_info_right_chev",
                "page_info_first_chev", "page_info_last_chev",
            }
            for _, n in ipairs(names) do
                local btn = widget[n]
                if btn and btn.init then
                    btn.icon_width = Screen:scaleBySize(PAGER_ICON_SZ)
                    btn.icon_height = Screen:scaleBySize(PAGER_ICON_SZ)
                    btn:init()
                end
            end
            local txt = widget.page_info_text
            if txt and txt.init then
                txt.text_font_size = PAGER_FONT_SZ
                txt:init()
            end
        end)
        return res
    end
    logger.info("wrFmPatch: pager size patch installed (icon " .. PAGER_ICON_SZ
        .. " / font " .. PAGER_FONT_SZ .. ", unconditional)")

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
            -- HorizontalGroup caches its offsets; without this the new spacer
            -- width / shorter text never reflow
            if self.page_info and self.page_info.resetLayout then
                self.page_info:resetLayout()
            end
            local ok_ui, UIManager = pcall(require, "ui/uimanager")
            if ok_ui and UIManager then
                UIManager:setDirty(self.show_parent or "all", "ui")
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

local function installMosaicMarginHook()
    local ok_m, MM = pcall(require, "mosaicmenu")
    if not ok_m or not MM or type(MM._recalculateDimen) ~= "function" then
        logger.info("wrFmPatch: mosaicmenu unavailable (coverbrowser absent?)")
        return
    end
    if mosaic_hook_installed then return end
    mosaic_hook_installed = true
    local orig_recalc = MM._recalculateDimen
    local mosaic_top_extra = Screen:scaleBySize(14)
    MM._recalculateDimen = function(self, ...)
        orig_recalc(self, ...)
        local m = Screen:scaleBySize(24)
        local rows, cols = self.nb_rows, self.nb_cols
        local id = self.inner_dimen
        if not (rows and cols and rows > 0 and cols > 0 and id and id.w and id.h) then
            return
        end
        -- keep the same bottom edge while the grid is shifted down by
        -- mosaic_top_extra (see the item_group top spacer below)
        local h_avail = math.max(1, id.h - mosaic_top_extra)
        self.item_margin = m
        self.item_height = math.max(1, math.floor(
            (h_avail - (self.others_height or 0) - (1 + rows) * m) / rows))
        self.item_width = math.max(1, math.floor(
            (id.w - (1 + cols) * m) / cols))
        self.item_dimen = Geom:new{
            x = 0, y = 0,
            w = self.item_width,
            h = self.item_height,
        }
    end

    -- shift the whole grid down: enlarge the item_group's leading spacer
    local orig_build = MM._updateItemsBuildUI
    if type(orig_build) == "function" then
        MM._updateItemsBuildUI = function(self, ...)
            local r = orig_build(self, ...)
            pcall(function()
                local g = self.item_group
                if g and g[1] and type(g[1].width) == "number" then
                    g[1].width = g[1].width + mosaic_top_extra
                end
            end)
            return r
        end
    end
    local ok_fc, FC = pcall(require, "ui/widget/filechooser")
    if ok_fc and FC then
        if FC.nb_cols_portrait and FC._recalculateDimen == orig_recalc then
            FC._recalculateDimen = MM._recalculateDimen
        end
        -- coverbrowser copies the builder onto FileChooser when mosaic is
        -- enabled; make sure that copy is our wrapped version too
        if type(orig_build) == "function"
                and FC._updateItemsBuildUI == orig_build
                and MM._updateItemsBuildUI then
            FC._updateItemsBuildUI = MM._updateItemsBuildUI
        end
    end
    logger.info("wrFmPatch: mosaic margin hook installed")
end

--- Call synchronously from WeReadPlugin:init(): light FM title hook only, so
--- it catches the FM TitleBar construction (heavy coverbrowser work is
--- deferred to keep first paint snappy / crash-free).
-- forward declarations (defined further below, referenced inside apply_fm)
local layoutFMToolbar
local installFMToolbarPatch

local function apply_fm()
    installTitleFaceHook()
    installFMToolbarPatch()
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(1.5, function()
            pcall(liftFMContent)
            pcall(installMosaicMarginHook)
            pcall(installPagerSizePatch)
            pcall(installPagerTextPatch)
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
    LINE_GAP   = 6.5,  -- separator offset below the title row
    ICON_GAP   = 9,    -- toolbar row offset below the separator
    SUB_SHIFT  = -4,   -- subtitle fine-tune around its row centring
    SIDE       = 24,   -- left/right inset (aligned with the separator ends)
    ICON_PX    = 26,   -- icon glyph size
    ICON_PAD   = 8,    -- invisible tap padding added to the glyph box
    ICON_GAP_X = 16,   -- spacing between icons
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
    local glyph = Screen:scaleBySize(FM_HDR.ICON_PX)
    local box   = glyph + Screen:scaleBySize(FM_HDR.ICON_PAD)
    local gap   = Screen:scaleBySize(FM_HDR.ICON_GAP_X)
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

        for i, w in ipairs(lefts) do
            shrinkFMButton(w, box, glyph)
            w.overlap_align = nil
            w._wr_x = side + (i - 1) * (box + gap)
            w._wr_y = y
            forcePaintAt(w, tb)
        end
        local total = #rights * box + math.max(0, #rights - 1) * gap
        local rx0   = math.max(side, sw - side - total)
        for i, w in ipairs(rights) do
            shrinkFMButton(w, box, glyph)
            w.overlap_align = nil
            w._wr_x = rx0 + (i - 1) * (box + gap)
            w._wr_y = y
            forcePaintAt(w, tb)
        end

        -- subtitle (folder path) shares the toolbar row, vertically centred
        local sub = tb.subtitle_widget
        if sub then
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

        -- reserve the toolbar row inside the TitleBar so content moves down
        local target_h = y + box + Screen:scaleBySize(3)
        local cur_h    = tb.titlebar_height or (tb.dimen and tb.dimen.h) or 0
        if target_h > cur_h then
            tb.titlebar_height = target_h
            if tb.dimen then
                tb.dimen = Geom:new{ x = 0, y = 0, w = tb.dimen.w, h = target_h }
            end
        end
        pcall(function()
            if fm_self._recalculateDimen then fm_self:_recalculateDimen() end
        end)
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
M.ensure = ensure          -- veil only (safe to call repeatedly)
M.apply = apply_fm         -- FM visuals only
function M.install()       -- both, used by WeReadPlugin:init()
    ensure()
    apply_fm()
end

return M
