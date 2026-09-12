-- FullscreenHost — SimpleUI integration for the WeRead full-screen pages.
--
-- The bookshelf and the reading-statistics page are hosted by SimpleUI itself
-- through its Bar Injection API (infra/sui_core.lua → M.BarInjection):
--   * SimpleUI draws the real top status bar and bottom navigation bar, so every
--     bar setting (icon size / label size / icons-text-both / colours / style /
--     transparency / navpager) applies to these pages automatically;
--   * it registers the bottom-bar touch zones, the top-edge tap/swipe zones that
--     open the native FileManager TouchMenu, gesture priority, the active-tab
--     highlight and the close handling.
--
-- What is left here is only what SimpleUI does not provide:
--   1. The descriptor helpers used to register our pages with its API.
--   2. Frontlight swipe gestures (left edge / two fingers). KOReader implements
--      these as widget-level zones on the FileManager, and SimpleUI does not
--      register them for injected pages — but our page covers the FileManager.
--
-- Usage: FullscreenHost.install(view, opts) from the view's init, then
--   view:ensureBarDescriptors() and (in onShow) view:registerHostGestures().

local Device = require("device")
local Screen = Device.screen
local logger = require("weread.lib.logger")

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

--- Raw per-item SimpleUI config for a dock tab (custom QAs), nil for built-in
--- ids.
function Host:dockConfig(id)
    if not (id and id:match("^custom_qa_")) then return nil end
    local store = sui_store()
    if not store then return nil end
    return store:readSetting("simpleui_qa_" .. id)
end

--- The list of SimpleUI dock tab ids in the order its bar renders them.
--- MUST come from SimpleUI's own resolver (infra/sui_config.loadTabConfig): it
--- drops ids it does not recognise, and its touch zones (`navbar_pos_1..n`) are
--- numbered by that filtered list. Reading the raw `simpleui_bar_tabs` setting
--- instead shifts every index past a dropped id, so an override lands on the
--- wrong cell (taps that "do nothing" or hijack another tab).
function Host:dockTabs()
    local ok_cfg, Config = pcall(require, "infra/sui_config")
    if ok_cfg and Config and type(Config.loadTabConfig) == "function" then
        local ok, tabs = pcall(Config.loadTabConfig)
        if ok and type(tabs) == "table" and #tabs > 0 then return tabs end
    end
    local store = sui_store()
    if not store then return nil end
    if store:readSetting("simpleui_bar_enabled", true) == false then return nil end
    local tabs = store:readSetting("simpleui_bar_tabs")
    if type(tabs) ~= "table" or #tabs == 0 then return nil end
    return tabs
end

--- The dock tab id whose config matches `match(view, tab_id, cfg)`, or nil.
function Host:findDockTab(match)
    local tabs = self:dockTabs()
    if not tabs or type(match) ~= "function" then return nil end
    for _, id in ipairs(tabs) do
        local ok, cfg = pcall(function() return self:dockConfig(id) end)
        if ok and match(self, id, cfg) then return id end
    end
    return nil
end

--- True when SimpleUI's Bar Injection API is available.
function Host.nativeBarAvailable()
    local ok, UI = pcall(require, "infra/sui_core")
    return ok and UI and UI.BarInjection ~= nil
end

--- Register a Bar Injection descriptor (SimpleUI's official extension point for
--- third-party widgets). Idempotent per id.
local bi_registered = {}
function Host.registerBarInjection(desc)
    if type(desc) ~= "table" or not desc.id or bi_registered[desc.id] then return end
    local ok, UI = pcall(require, "infra/sui_core")
    if not ok or not UI or not UI.BarInjection then return end
    local ok_reg = pcall(UI.BarInjection.register, desc)
    if ok_reg then bi_registered[desc.id] = true end
end

--- Height of the FileManager's own pager row, measured live. Our in-page
--- pager/period rows copy this so the three rows are identical by
--- construction (and follow SimpleUI's font/icon settings automatically).
--- Returns nil when the FM pager is not available (falls back to the shared
--- metric at the call site).
function Host:fmPagerRowHeight()
    local h
    pcall(function()
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_f and FM.instance
        local fc = fm and (fm.file_chooser or (fm.ui and fm.ui.file_chooser))
        local grp = fc and fc.page_info
        if grp and grp.getSize then
            local sz = grp:getSize()
            if sz and type(sz.h) == "number" and sz.h > 0 then h = sz.h end
        end
    end)
    return h
end

--- Index of `tab_id` in the rendered bar. SimpleUI names the centre-tab touch
--- zones "navbar_pos_1..n" in BOTH modes (navpager's prev/next arrows are
--- separate zone ids), so there is no slot offset to apply.
function Host:renderedTabIndex(ctx, tab_id)
    if not tab_id then return nil end
    local tabs = (ctx and ctx.tabs) or self:dockTabs() or {}
    for i, id in ipairs(tabs) do
        if id == tab_id then return i end
    end
    return nil
end

--- Replace the tap handler of one rendered dock slot. Used to keep a page's
--- own semantics for a single tab (the family switch) while SimpleUI still
--- draws the bar and handles every other zone.
function Host:overrideDockTab(index, handler)
    local zones = self._zones
    if not (index and type(handler) == "function" and type(zones) == "table") then
        return false
    end
    local z = zones["navbar_pos_" .. index]
    if type(z) ~= "table" then
        logger.info("wrZoneTab: override MISSING navbar_pos_" .. tostring(index))
        return false
    end
    z.handler = handler
    logger.info("wrZoneTab: override OK navbar_pos_" .. tostring(index))
    return true
end

--- A/B switch for the 10px top lift our header had before this page was hosted
--- natively. It was tuned together with the FM content lift (see
--- ko_custom_patches.FM_CONTENT_LIFT); with both pages natively hosted it may no
--- longer be needed. true = old behaviour (lift 10px up), false = no lift.
local NATIVE_TOP_LIFT = false

--- Post-injection fixups: SimpleUI builds the wrapped bar with the *previous*
--- tab as active (a BI widget is not one of its named screens), so we rebuild it
--- with the tab that represents this page; and (when enabled) we re-apply the
--- 10px top lift.
local function afterInject(w, ctx, match)
    pcall(function()
        local tabs = (ctx and ctx.tabs) or nil
        local active = w:findDockTab(match)
        local ok_b, B = pcall(require, "screens/sui_bottombar")
        if active and ok_b and B and B.buildBarWidget and B.replaceBar then
            local bar = B.buildBarWidget(active, tabs)
            if bar then
                B.replaceBar(w, bar, tabs)
                -- No setDirty here: this runs inside UIManager:show, whose own
                -- first paint already includes the bar we just swapped in. A
                -- second full repaint at that instant is an extra e-ink refresh
                -- the user perceives as a flash.
            end
        end
        local inner = w._navbar_inner
        local topbar_h = w._navbar_topbar_h or 0
        if NATIVE_TOP_LIFT and inner and inner.overlap_offset and topbar_h > 0 then
            inner.overlap_offset[2] = topbar_h - Screen:scaleBySize(10)
        end
        -- SimpleUI applies its sub-page titlebar to every injected widget, and
        -- that unconditionally adds a back button on the left. Our pages never
        -- had one, so push it off-screen (its own hidden-button technique; we
        -- do NOT touch the global "sub_back" setting, which other pages use).
        local back = w._titlebar_sub_back_btn
        if back then
            back.overlap_align = nil
            back.overlap_offset = { Screen:getWidth() * 2, 0 }
            back.callback = function() end
            back.hold_callback = function() end
        end
        -- SimpleUI builds the wrapped bar while the widget is still being
        -- shown (not yet on the window stack), so its own getNavpagerState()
        -- reads the PREVIOUS page. The registration wrapper in
        -- ko_custom_patches reports this page's real state instead — inside
        -- UIManager:show, i.e. BEFORE the first paint, so the corrected arrows
        -- are already part of that first frame.
        --
        -- (A second, post-show report used to run here from scheduleIn(0.05)
        -- together with a whole-content-region setDirty. It was redundant, and
        -- that extra large e-ink refresh immediately after the switch is
        -- exactly the flash only navpager mode showed. Removed.)
    end)
end

local STATS_MATCH = function(_, _, cfg)
    return cfg ~= nil and cfg.dispatcher_action == "weread_reading_statistics"
end

local SHELF_MATCH = function(_, _, cfg)
    return cfg ~= nil and cfg.plugin_key == "weread"
        and (cfg.plugin_method == nil or cfg.plugin_method == "launch")
end

--- Descriptors for the two weread pages (registered lazily, simpleui-only).
function Host.ensureBarDescriptors()
    Host.registerBarInjection{
        id          = "weread_stats",
        widget_name = "weread_stats",
        get_active_action = function(w)
            return w:findDockTab(STATS_MATCH)
        end,
        is_pageable = true,
        on_inject = function(w, ctx) afterInject(w, ctx, STATS_MATCH) end,
    }
    Host.registerBarInjection{
        id          = "weread_shelf",
        widget_name = "weread_shelf",
        get_active_action = function(w)
            return w:findDockTab(SHELF_MATCH)
        end,
        -- pageable: SimpleUI then draws navpager arrows and routes their taps
        -- to our onPrevPage/onNextPage/onGotoPage.
        is_pageable = true,
        on_inject = function(w, ctx) afterInject(w, ctx, SHELF_MATCH) end,
    }
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
        local L = self._host and self._host.labels or {}
        local text
        if new_intensity <= 0 then
            text = L.frontlight_off or "前光已关闭"
        else
            local v = tostring(powerd:frontlightIntensity())
            local t = L.frontlight_set
            if type(t) == "function" then
                text = t(v)
            elseif type(t) == "string" then
                text = (t:gsub("%%1", v))
            else
                text = "前光亮度已设为 " .. v .. "。"
            end
        end
        Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
    end
    return true
end

--- Top-edge menu opening (mirrors native FileManager zones). Only used when
--- SimpleUI's Bar Injection is unavailable: when it hosts the page it registers
--- equivalent zones itself.
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

--- Register this view's touch zones. Call from your view's onShow.
--- `skip_top_menu` is true when SimpleUI hosts the page (it registers the
--- top-edge menu zones itself); the frontlight zones are always ours.
function Host:registerHostGestures(skip_top_menu)
    -- left-edge strip matching KOReader's native DSWIPE_ZONE_LEFT_EDGE (1/8)
    local fl_edge_w = 1 / 8
    local zones = {}
    if not skip_top_menu then
        zones[#zones + 1] = {
            id = "host_top_tap_menu",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            handler = function(ges) return self:onTopTapMenu(ges) end,
        }
        zones[#zones + 1] = {
            id = "host_top_swipe_menu",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            handler = function(ges) return self:onTopSwipeMenu(ges) end,
        }
        zones[#zones + 1] = {
            id = "host_top_swipe_menu_ext",
            ges = "swipe",
            screen_zone = { ratio_x = 1 / 4, ratio_y = 0, ratio_w = 2 / 4, ratio_h = 1 / 5 },
            handler = function(ges) return self:onTopSwipeMenu(ges) end,
        }
    end
    zones[#zones + 1] = {
        id = "host_fl_left_edge",
        ges = "swipe",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = fl_edge_w, ratio_h = 1 },
        handler = function(ges) return self:onFrontlightSwipe(ges) end,
    }
    zones[#zones + 1] = {
        id = "host_fl_two_finger",
        ges = "two_finger_swipe",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        handler = function(ges) return self:onFrontlightSwipe(ges) end,
    }
    self:registerTouchZones(zones)
end

--- KOReader's Exit / Restart / Suspend events reach every stacked widget. When
--- a third-party menu (e.g. SimpleUI's power menu, which works purely by
--- broadcastEvent) fires one while this hosted view still covers the
--- FileManager, we must close ourselves so the teardown / suspend can proceed —
--- otherwise nothing appears to happen. (Sleep calls UIManager:suspend()
--- directly; the same rule keeps the stack clean for it.)
function Host:onExit()
    pcall(function()
        if self.onClose then self:onClose() end
    end)
    return true
end

--- Close this page as part of an in-app navigation (the bookshelf <-> stats
--- family switch). SimpleUI's UIManager.close wrapper skips its "restore the FM
--- tab" rebuild + setDirty when the closing widget carries this flag — that
--- rebuild repaints the (now covered) FileManager and is the remaining source of
--- the switch flash. SimpleUI's own navigate sets exactly this flag.
function Host:closeForNavigation()
    pcall(function()
        self._navbar_closing_intentionally = true
        if self.onClose then self:onClose() end
        self._navbar_closing_intentionally = nil
    end)
    return true
end

function Host:onRestart()
    return Host.onExit(self)
end

function Host:onSuspend()
    return Host.onExit(self)
end

--- Localisable strings (optional). opts.labels = {
---   frontlight_off,                              -- frontlight-off notice
---   frontlight_set,                              -- string with %1, or a function(value)
--- }
function Host.install(view, opts)
    if view._host then return end
    view._host = opts or {}
    if not view.screen_w then
        view.screen_w = Screen:getWidth()
        view.screen_h = Screen:getHeight()
    end
    -- inject the host methods onto this instance
    for _, name in ipairs({
        "dockConfig", "dockTabs", "findDockTab", "ensureBarDescriptors",
        "registerHostGestures", "onFrontlightSwipe",
        "onTopTapMenu", "onTopSwipeMenu",
        "onExit", "onRestart", "onSuspend", "closeForNavigation",
        "renderedTabIndex", "overrideDockTab", "fmPagerRowHeight",
    }) do
        if not view[name] then
            view[name] = Host[name]
        end
    end
    return view
end

return Host
