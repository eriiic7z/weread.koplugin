-- weread/ui/fm_visual_patch.lua
--
-- Local-bookshelf (SimpleUI FileManager / folder-covers mosaic) runtime
-- patches, applied by the weread plugin:
--   1) FM title bar face → smalltfont 26 + vertical alignment (matches the
--      weread shelf title). Installed EARLY at plugin init because KOReader
--      builds the FM TitleBar before plugins finish loading.
--   2) folder-covers mosaic wall margins → 24px (heavier coverbrowser
--      module, deferred until a moment after boot).
--
-- No KOReader / coverbrowser files are touched; idempotent.

local Font = require("ui/font")
local Geom = require("ui/geometry")
local LineWidget = require("ui/widget/linewidget")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local logger = require("logger")

local M = {}

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
    MM._recalculateDimen = function(self, ...)
        orig_recalc(self, ...)
        local m = Screen:scaleBySize(24)
        local rows, cols = self.nb_rows, self.nb_cols
        local id = self.inner_dimen
        if not (rows and cols and rows > 0 and cols > 0 and id and id.w and id.h) then
            return
        end
        self.item_margin = m
        self.item_height = math.max(1, math.floor(
            (id.h - (self.others_height or 0) - (1 + rows) * m) / rows))
        self.item_width = math.max(1, math.floor(
            (id.w - (1 + cols) * m) / cols))
        self.item_dimen = Geom:new{
            x = 0, y = 0,
            w = self.item_width,
            h = self.item_height,
        }
    end
    local ok_fc, FC = pcall(require, "ui/widget/filechooser")
    if ok_fc and FC and FC.nb_cols_portrait
            and FC._recalculateDimen == orig_recalc then
        FC._recalculateDimen = MM._recalculateDimen
    end
    logger.info("wrFmPatch: mosaic margin hook installed")
end

--- Call synchronously from WeReadPlugin:init(): light FM title hook only, so
--- it catches the FM TitleBar construction (heavy coverbrowser work is
--- deferred to keep first paint snappy / crash-free).
function M.apply()
    installTitleFaceHook()
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(1.5, function()
            pcall(liftFMContent)
            pcall(installMosaicMarginHook)
            pcall(installPagerSizePatch)
            pcall(installPagerTextPatch)
        end)
    else
        pcall(installMosaicMarginHook)
    end
end

return M
