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
local UIManager = require("ui/uimanager")
local logger = require("logger")
local DimScrim = require("weread.ui.dim_scrim")

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
        if self[scrim_key] then
            UIManager:close(self[scrim_key])
            self[scrim_key] = nil
            -- non-flashing full refresh: clears the veil everywhere on the
            -- e-ink display (closing widgets only refresh their own region)
            UIManager:setDirty(nil, "partial")
        end
        return orig_close(self, ...)
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
