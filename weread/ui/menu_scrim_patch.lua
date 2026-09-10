-- Kindle-style menu scrim applied KOReader-wide without touching core files.
--
-- Runtime-patches the two native menu classes so their drop-down shows a
-- dim backdrop underneath (Kindle behaviour):
--   * FileManagerMenu  -> FileManager / bookshelf menu
--   * ReaderMenu       -> in-book document menu
-- Patching the class table covers existing and future instances, so one
-- ensure() call covers every menu of the session. e-ink display requires a
-- full-screen refresh to surface a new large layer; a non-flashing "full"
-- refresh surfaces it cleanly on this device (no black flash; "flashui" is
-- the black-flash alternative), and a non-flashing full-screen refresh on
-- close clears the veil ghosting.
--
-- Depends on core signatures (KOReader 2024+):
--   FileManagerMenu:onShowMenu(tab_index, do_not_show)
--   FileManagerMenu:onCloseFileManagerMenu()
--   ReaderMenu:onShowMenu(tab_index, do_not_show)
--   ReaderMenu:onCloseReaderMenu()
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Screen = Device.screen

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

return {
    ensure = ensure,
}
