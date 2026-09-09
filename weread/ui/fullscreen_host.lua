-- FullscreenHost — reusable infrastructure for full-screen overlay views.
--
-- Any view that covers the FileManager full-screen (like the WeRead
-- bookshelf) gets the same four facilities SimpleUI's own screens have,
-- without re-implementing them per view:
--   1. Reserved bands: the SimpleUI top status bar / bottom nav bar stay
--      visible above and below the overlay (transparent spacers).
--   2. Bottom dock: mirrors the user's SimpleUI bar (simpleui_bar_tabs) with
--      SimpleUI's own icons/labels (QA.getEntry), forwards taps back to
--      SimpleUI (navigation / custom-QA actions), and highlights the entry
--      that represents this view.
--   3. Frontlight edge gestures: left-edge swipe + two-finger swipe adjust
--      the frontlight (KOReader-consistent delta), with native feedback.
--   4. Top-edge menu gestures: tapping/swiping down from the top opens the
--      native FileManager TouchMenu (zone geometry mirrors KOReader).
--
-- Usage (from any plugin):
--   local Host = require("<path>.fullscreen_host")
--   -- build your view, then in its init (or before show):
--   Host.install(self, {
--       dock_self_plugin = "yourplugin",  -- dock entry that is "this page"
--       dock_self_label = "我的界面",      -- label for that entry
--   })
--   -- install() provides: self:dockTabs(), self:dockIconFor(id),
--   -- self:dockLabel(id), self:bottomDock(height), self:onDockTap(id),
--   -- self:showPowerDialog(), self:registerHostGestures(), plus
--   -- self:reservedBands() (top, bottom). Your init then lays out
--   -- content between the bands and adds the dock, exactly like the
--   -- WeRead bookshelf does.
--
-- NOTE: depends on SimpleUI's settings layout and its QA registry being
-- loaded (QA icons resolve via require cache / SimpleUI active on FM).

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = Device.screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Host = {}

local function sui_store()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil end
    local path = DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls then return nil end
    return LuaSettings:open(path)
end

--- Raw per-item SimpleUI config for a dock tab (custom QAs), nil for
--- built-in ids.
function Host:dockConfig(id)
    if not (id and id:match("^custom_qa_")) then return nil end
    local store = sui_store()
    if not store then return nil end
    return store:readSetting("simpleui_qa_" .. id)
end

--- Reserved top (status bar) / bottom (nav bar) heights from SimpleUI's
--- settings, in pixels. 0 when SimpleUI bands are off or unreachable.
function Host.reservedBands()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return 0, 0 end
    local path = DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or lfs.attributes(path, "mode") ~= "file" then return 0, 0 end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls then return 0, 0 end
    local store = LuaSettings:open(path)
    local function sui_pct(key, def, lo, hi)
        local v = store and tonumber(store:readSetting(key))
        if not v then return def end
        return math.max(lo, math.min(hi, v))
    end
    local top = 0
    if store and store:readSetting("simpleui_topbar_enabled", true) ~= false then
        local s = sui_pct("simpleui_topbar_size_pct", 100, 50, 150) / 100
        top = math.floor(22 * s)
            + math.floor(Screen:scaleBySize(20) * s)
            + math.floor(Screen:scaleBySize(8) * s)
    end
    local bar = 0
    if store and store:readSetting("simpleui_bar_enabled", true) ~= false then
        local s = sui_pct("simpleui_bar_size_pct", 100, 50, 150) / 100
        local b = sui_pct("simpleui_bar_bottom_margin_pct", 100, 0, 300) / 100
        bar = math.floor(Screen:scaleBySize(96) * s)
            + Screen:scaleBySize(2)
            + math.floor(Screen:scaleBySize(12) * b)
    end
    return top, bar
end

--- The list of SimpleUI dock tab ids (raw order), nil when bar disabled.
function Host:dockTabs()
    local store = sui_store()
    if not store then return nil end
    if store:readSetting("simpleui_bar_enabled", true) == false then return nil end
    local tabs = store:readSetting("simpleui_bar_tabs")
    if type(tabs) ~= "table" or #tabs == 0 then return nil end
    return tabs
end

--- Resolve the icon FILE for a dock tab id via SimpleUI's own action registry
--- (user icon changes apply automatically). nil => text-only dock cell.
function Host:dockIconFor(id)
    local entry = Host:qaEntry(id)
    local icon = entry and entry.icon
    if type(icon) ~= "string" or icon == "" then return nil end
    local ok_s, S = pcall(require, "features/sui_style")
    if ok_s and S and type(S.safeIconPath) == "function" then
        return S.safeIconPath(icon, nil)
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs.attributes(icon, "mode") == "file" then return icon end
    return nil
end

--- SimpleUI's QA.getEntry (its own icon/label/state resolution).
function Host:qaEntry(id)
    local ok, QA = pcall(require, "features/sui_quickactions")
    if ok and QA and type(QA.getEntry) == "function" then
        return QA.getEntry(id)
    end
    return nil
end

--- Label shown for a dock tab. Prefers SimpleUI's own label.
function Host:dockLabel(id)
    local entry = Host:qaEntry(id)
    if entry and type(entry.label) == "string" and entry.label ~= "" then
        return entry.label
    end
    return tostring(id)
end

-- Dock cell: CenterContainer + ImageWidget (file, is_icon, alpha) or text,
-- active indicator overlaid on top — same look as SimpleUI.
local DockCell = InputContainer:extend{
    icon = nil,
    icon_sz = 0,
    label = nil,
    active = false,
    indic_h = 0,
    dock_cb = nil,
}

function DockCell:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local content
    if self.icon then
        content = ImageWidget:new{
            file = self.icon,
            width = self.icon_sz,
            height = self.icon_sz,
            is_icon = true,
            alpha = true,
        }
    else
        content = TextWidget:new{
            text = self.label or "",
            face = Font:getFace("cfont", 14),
            bold = self.active,
        }
    end
    local centered = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        content,
    }
    if self.active and self.indic_h and self.indic_h > 0 then
        self[1] = OverlapGroup:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            allow_mirroring = false,
            centered,
            LineWidget:new{
                dimen = Geom:new{ w = self.width, h = self.indic_h },
                background = Blitbuffer.COLOR_BLACK,
                overlap_offset = { 0, 0 },
            },
        }
    else
        self[1] = centered
    end
    self.ges_events = {
        TapSelectButton = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function DockCell:onTapSelectButton()
    if self.dock_cb then self.dock_cb() end
    return true
end


--- Build the bottom dock row for height px (the reserved bottom band).
--- Returns a FrameContainer to place at the bottom of the view, or nil.
function Host:bottomDock(height)
    if not height or height <= 0 then return nil end
    local store = sui_store()
    local tabs = self:dockTabs()
    if not tabs then return nil end
    local function clamp_pct(key, def, lo, hi)
        local v = store and tonumber(store:readSetting(key))
        if not v then return def end
        return math.max(lo, math.min(hi, v))
    end
    local bar_s = clamp_pct("simpleui_bar_size_pct", 100, 50, 150) / 100
    local icon_s = clamp_pct("simpleui_bar_icon_scale_pct", 100, 50, 200) / 100
    local bot_pct = clamp_pct("simpleui_bar_bottom_margin_pct", 100, 0, 300)
    local side_m = Screen:scaleBySize(24)
    local indicator_h = math.max(1, math.floor(Screen:scaleBySize(3) * bar_s))
    local icon_sz = math.max(10, math.floor(Screen:scaleBySize(44) * bar_s * icon_s))
    local top_sp = Screen:scaleBySize(2)
    local bot_sp = math.floor(Screen:scaleBySize(12) * bot_pct / 100)
    local sep_h = Screen:scaleBySize(1)
    local pad_above = math.max(0, top_sp - sep_h)
    local bar_h = math.max(1, height - top_sp - bot_sp)
    local usable_w = math.max(1, self.screen_w - 2 * side_m)

    local cell_w = math.floor(usable_w / #tabs)
    local row = HorizontalGroup:new{}
    local highlight = self._host and self._host.dock_highlight
    for index, id in ipairs(tabs) do
        local width = index == #tabs and usable_w - cell_w * (#tabs - 1) or cell_w
        local cfg = self:dockConfig(id)
        local active = highlight and highlight(self, id, cfg) or false
        local icon = self:dockIconFor(id)
        local label = self:dockLabel(id)
        row[#row + 1] = DockCell:new{
            width = width,
            height = bar_h,
            icon = icon,
            icon_sz = icon_sz,
            label = label,
            active = active,
            indic_h = active and indicator_h or 0,
            dock_cb = function() self:onDockTap(id) end,
            show_parent = self,
        }
    end
    local sep_bg = Blitbuffer.COLOR_GRAY
    pcall(function() sep_bg = Blitbuffer.gray(0.72) end)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        width = self.screen_w,
        height = height,
        padding_left = side_m,
        padding_right = side_m,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad_above },
            LineWidget:new{
                dimen = Geom:new{ w = usable_w, h = sep_h },
                background = sep_bg,
            },
            row,
            VerticalSpan:new{ width = bot_sp },
        },
    }
end

--- Tap on a dock tab. The hosting view gets first say via opts.dock_nav
--- (family-internal pages: switch in place, no FM replay). Anything it does
--- not handle follows the default: power = in-place dialog; navigation /
--- actions owned by SimpleUI drop this view and replay the tap on FM.
function Host:onDockTap(tab_id)
    local nav = self._host and self._host.dock_nav
    if nav then
        local cfg = self:dockConfig(tab_id)
        if nav(self, tab_id, cfg) then
            return true
        end
    end
    -- Power: in-place dialog over this view (like SimpleUI's own), so the
    -- full-screen page does not need to close first.
    if tab_id == "power" then
        self:showPowerDialog()
        return true
    end
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FM.instance
    local plugin = fm and fm._simpleui_plugin
    local function replay()
        if plugin and type(plugin._onTabTap) == "function" then
            pcall(plugin._onTabTap, plugin, tab_id, fm)
        end
    end
    local function close_self()
        pcall(function()
            if self.onClose then self:onClose() end
        end)
    end
    if tab_id == "home" or tab_id == "sui_settings"
        or tab_id == "settings" or tab_id == "history" then
        close_self()
        UIManager:scheduleIn(0, replay)
        return true
    end
    if tab_id == "homescreen" then
        replay()
        close_self()
        return true
    end
    close_self()
    UIManager:scheduleIn(0, replay)
    return true
end

--- In-place power dialog (mirrors SimpleUI's), shown over this view.
function Host:showPowerDialog()
    if self._host_power_dialog then return end -- ignore double taps
    local ButtonDialog = require("ui/widget/buttondialog")
    local Event = require("ui/event")
    local dialog_w = math.floor(Screen:getWidth() * 0.42)
    local function _clear()
        self._host_power_dialog = nil
    end
    local buttons = {}
    if Device:canRestart() then
        buttons[#buttons + 1] = {{ text = "重启", callback = function()
            local d = self._host_power_dialog
            self._host_power_dialog = nil
            UIManager:close(d)
            UIManager:broadcastEvent(Event:new("Restart"))
        end }}
    end
    if Device:canReboot() then
        buttons[#buttons + 1] = {{ text = "重新引导", callback = function()
            local d = self._host_power_dialog
            self._host_power_dialog = nil
            UIManager:close(d)
            UIManager:askForReboot()
        end }}
    end
    if Device:canSuspend() then
        buttons[#buttons + 1] = {{ text = "休眠", callback = function()
            local d = self._host_power_dialog
            self._host_power_dialog = nil
            UIManager:close(d)
            UIManager:flushSettings()
            UIManager:suspend()
        end }}
    end
    buttons[#buttons + 1] = {{ text = "退出", callback = function()
        local d = self._host_power_dialog
        self._host_power_dialog = nil
        UIManager:close(d)
        local ok_l, logger = pcall(require, "logger")
        if ok_l then logger.info("wrHost: power-exit: dialog closed, broadcasting Exit") end
        UIManager:broadcastEvent(Event:new("Exit"))
        if ok_l then logger.info("wrHost: power-exit: Exit broadcast returned") end
        pcall(function()
            if self.onClose then self:onClose() end
        end)
        if ok_l then logger.info("wrHost: power-exit: view closed, callback done") end
    end }}
    self._host_power_dialog = ButtonDialog:new{
        width = dialog_w,
        tap_close_callback = _clear,
        buttons = buttons,
    }
    UIManager:show(self._host_power_dialog)
end

--- Frontlight swipe (left edge / two fingers), KOReader-consistent.
function Host:onFrontlightSwipe(ges)
    if not Device:hasFrontlight() then return false end
    local dir = type(ges) == "table" and ges.direction or nil
    local direction
    if dir == "north" then direction = 1
    elseif dir == "south" then direction = -1 end
    if not direction then return false end
    local powerd = Device:getPowerDevice()
    local fl_max = tonumber(powerd.fl_max) or 1
    local gestureScale = Screen:getHeight() * 0.8
    local x = math.min(1, (tonumber(ges.distance) or 1) / gestureScale)
    local delta_int = math.ceil(0.5 * fl_max * x * x)
    local new_intensity = powerd:frontlightIntensity() + direction * delta_int
    if new_intensity <= 0 then
        powerd:turnOffFrontlight()
    else
        powerd:setIntensity(new_intensity)
    end
    if powerd.updateResumeFrontlightState then
        pcall(powerd.updateResumeFrontlightState, powerd)
    end
    local ok_n, Notification = pcall(require, "ui/widget/notification")
    if ok_n and Notification then
        local text = new_intensity <= 0
            and "前光已关闭"
            or ("前光亮度已设为 " .. tostring(powerd:frontlightIntensity()) .. "。")
        Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
    end
    return true
end

--- Top-edge menu opening (mirrors native FileManager zones).
local function fm_menu_open(ges, method)
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    local menu = ok and FM.instance and FM.instance.menu
    if menu and type(menu[method]) == "function" then
        return pcall(menu[method], menu, ges)
    end
    return false
end

function Host:onTopTapMenu(ges)
    return fm_menu_open(ges, "onTapShowMenu")
end

function Host:onTopSwipeMenu(ges)
    return fm_menu_open(ges, "onSwipeShowMenu")
end

--- Register this view's touch zones. Call from your view's onShow (or once
--- after show). Zone geometry: top 1/8 full-width tap + swipe and middle EXT
--- band open the native menu; a NARROW left-edge strip (24px, not 1/8)
--- adjusts the frontlight so content scrolling is not eaten by a wide light
--- strip; two-finger swipe adjusts it anywhere.
function Host:registerHostGestures()
    -- left-edge strip matching KOReader's native DSWIPE_ZONE_LEFT_EDGE (1/8)
    local fl_edge_w = 1 / 8
    self:registerTouchZones({
        {
            id = "host_top_tap_menu",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            handler = function(ges) return self:onTopTapMenu(ges) end,
        },
        {
            id = "host_top_swipe_menu",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            handler = function(ges) return self:onTopSwipeMenu(ges) end,
        },
        {
            id = "host_top_swipe_menu_ext",
            ges = "swipe",
            screen_zone = { ratio_x = 1 / 4, ratio_y = 0, ratio_w = 2 / 4, ratio_h = 1 / 5 },
            handler = function(ges) return self:onTopSwipeMenu(ges) end,
        },
        {
            id = "host_fl_left_edge",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = fl_edge_w, ratio_h = 1 },
            handler = function(ges) return self:onFrontlightSwipe(ges) end,
        },
        {
            id = "host_fl_two_finger",
            ges = "two_finger_swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onFrontlightSwipe(ges) end,
        },
    })
end

-- Install the host facilities onto a view instance. Idempotent-ish: call
-- once from the view's init with its options table.
--- KOReader's Exit broadcast reaches every stacked widget. When a third
--- party menu (e.g. SimpleUI's power menu Quit) broadcasts Exit while this
--- hosted view still covers the FM, we close ourselves so the FM teardown
--- finds a clean stack (mirrors the dock power path which closes first).
function Host:onExit()
    pcall(function()
        if self.onClose then self:onClose() end
    end)
    return true
end

function Host.install(view, opts)
    if view._host then return end
    view._host = opts or {}
    -- screen geometry helpers the dock needs
    if not view.screen_w then
        view.screen_w = Screen:getWidth()
        view.screen_h = Screen:getHeight()
    end
    -- inject the host methods onto this instance
    for _, name in ipairs({
        "reservedBands", "dockTabs", "dockConfig", "dockIconFor", "dockLabel",
        "bottomDock", "onDockTap", "showPowerDialog", "onExit",
        "onFrontlightSwipe", "onTopTapMenu", "onTopSwipeMenu",
        "registerHostGestures",
    }) do
        if not view[name] then
            view[name] = Host[name]
        end
    end
    return view
end

return Host
