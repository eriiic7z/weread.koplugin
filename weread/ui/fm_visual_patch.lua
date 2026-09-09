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
        end)
    else
        pcall(installMosaicMarginHook)
    end
end

return M
