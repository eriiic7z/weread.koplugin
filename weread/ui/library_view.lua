-- Full-screen, e-ink-friendly bookshelf with direct Books/Public Accounts tabs.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local T = require("ffi/util").template

local function _(text) return I18n.tr(text) end

local CachedCorner = Widget:extend{
    size = 0,
}

function CachedCorner:init()
    self.size = math.max(1, math.floor(tonumber(self.size) or 1))
    self.dimen = Geom:new{ w = self.size, h = self.size }
end

function CachedCorner:paintTo(bb, x, y)
    -- A compact, solid dog-ear in the upper-right corner. Drawing it one
    -- scanline at a time keeps the marker dependency-free and crisp on e-ink.
    for row = 0, self.size - 1 do
        local width = self.size - row
        bb:paintRect(x + row, y + row, width, 1, Blitbuffer.COLOR_BLACK)
    end
end

local ShelfRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    font_size = 22,
    callback = nil,
    show_parent = nil,
}

function ShelfRow:init()
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", self.font_size)
    local status_widget = TextWidget:new{ text = self.status or "", face = face }
    local status_width = status_widget:getSize().w
    local gap = Size.padding.large
    local title_widget = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - status_width - gap),
    }
    gap = math.max(gap, inner_width - title_widget:getSize().w - status_width)
    self.frame = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding_left = padding,
        padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            title_widget,
            HorizontalSpan:new{ width = gap },
            status_widget,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapShelfRow = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function ShelfRow:onTapShelfRow()
    if not self.callback then return true end
    self.frame.invert = true
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:forceRePaint()
    self.frame.invert = false
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:setDirty(nil, "fast", self.frame.dimen)
    self.callback()
    return true
end

function ShelfRow:onFocus()
    self.frame.invert = true
    return true
end

function ShelfRow:onUnfocus()
    self.frame.invert = false
    return true
end

local CoverCell = InputContainer:extend{
    book = nil,
    width = nil,
    height = nil,
    cover_path = nil,
    cover_loading = false,
    cached = false,
    callback = nil,
    show_parent = nil,
}

function CoverCell:init()
    local padding = Size.padding.small
    local border = Size.border.thin
    local cover_width = math.max(1, self.width - 2 * padding)
    local label_height = math.min(
        math.max(1, math.floor(self.height * 0.35)),
        Screen:scaleBySize(52)
    )
    local cover_height = math.max(1, self.height - label_height)
    -- image box = max area inside the cell (frame border reserved)
    local image_width = math.max(1, cover_width - 2 * border)
    local image_height = math.max(1, cover_height - 2 * border)
    local fit_w, fit_h = image_width, image_height
    local cover_content
    if self.cover_path then
        -- Pass 1: render to discover the best-fit displayed size, so the
        -- frame can hug the actual cover art (no stretching, no crop).
        local probe
        local ok = pcall(function()
            probe = ImageWidget:new{
                file = self.cover_path,
                width = image_width,
                height = image_height,
                scale_factor = 0,
                file_do_cache = false,
            }
            probe:getSize()
        end)
        if ok and probe then
            local cw, ch = probe:getCurrentWidth(), probe:getCurrentHeight()
            if cw and ch and cw > 0 and ch > 0 then
                fit_w, fit_h = cw, ch
            end
            pcall(probe.free, probe)
            -- Pass 2: rebuild at exactly the fitted size (same aspect ratio,
            -- so width/height == best-fit, no distortion), then frame it.
            local image
            local ok2 = pcall(function()
                image = ImageWidget:new{
                    file = self.cover_path,
                    width = fit_w,
                    height = fit_h,
                    scale_factor = nil,
                    file_do_cache = false,
                }
                image:getSize()
            end)
            if ok2 and image then
                cover_content = image
                self._has_cover = true
            elseif image and type(image.free) == "function" then
                pcall(image.free, image)
            end
        end
    end
    if not cover_content then
        cover_content = TextWidget:new{
            text = self.cover_loading and _("Cover loading") or _("No cover"),
            face = Font:getFace("cfont", 18),
            max_width = image_width,
        }
        self._has_cover = false
    end
    -- Frame hugs the cover art: width/height = fitted art + border, padding 0
    local framed_w = math.max(1, fit_w + 2 * border)
    local framed_h = math.max(1, fit_h + 2 * border)
    local cover_frame = CenterContainer:new{
        dimen = Geom:new{ w = cover_width, h = cover_height },
        FrameContainer:new{
            width = framed_w,
            height = framed_h,
            margin = 0,
            padding = 0,
            bordersize = border,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = fit_w, h = fit_h },
                cover_content,
            },
        },
    }
    local cover_layers = {
        dimen = Geom:new{ w = cover_width, h = cover_height },
        cover_frame,
    }
    self._has_cached_corner = self.cached == true
    if self._has_cached_corner then
        local corner_size = math.max(1, math.min(
            cover_width,
            cover_height,
            Screen:scaleBySize(16)
        ))
        local corner = CachedCorner:new{ size = corner_size }
        -- hug the (possibly shrunken) cover frame's top-right corner
        local frame_x = math.floor((cover_width - framed_w) / 2)
        local frame_y = math.floor((cover_height - framed_h) / 2)
        corner.overlap_offset = { frame_x + framed_w - corner_size, frame_y }
        cover_layers[#cover_layers + 1] = corner
        self._cached_corner_size = corner_size
    end
    local cover = OverlapGroup:new(cover_layers)
    local title = self.book.title or self.book.bookId or self.book.book_id or _("Untitled")
    local title_widget = TextWidget:new{
        text = title,
        face = Font:getFace("cfont", 18),
        max_width = cover_width,
    }
    self.frame = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            VerticalGroup:new{
                align = "center",
                cover,
                title_widget,
            },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapCoverCell = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function CoverCell:onTapCoverCell()
    if self.callback then self.callback() end
    return true
end

function CoverCell:onFocus()
    self.frame.invert = true
    return true
end

function CoverCell:onUnfocus()
    self.frame.invert = false
    return true
end

local LibraryView = FocusManager:extend{
    mode = "books",
    title = nil,
    wp_enable = true,
    books = nil,
    accounts = nil,
    keyword = nil,
    sort_label = nil,
    filter_label = nil,
    on_switch = nil,
    on_search = nil,
    on_refresh = nil,
    on_sort = nil,
    on_filter = nil,
    on_select = nil,
    paged = false,
    page = 1,
    page_size = 10,
    cover_mode = false,
    cover_columns = 3,
    cover_rows = 2,
    cover_cell_height = nil,
    cover_paths = nil,
    cover_loading = nil,
    on_page_changed = nil,
}

function LibraryView:tabBar()
    -- Compact left-hand tab group (shares the tool row with the actions)
    -- (personal fork: localized literals; active = bold + underline bar)
    local tabs = {
        { mode = "books", text = "书籍" },
        { mode = "public_account", text = "公众号" },
    }
    local row = HorizontalGroup:new{}
    self._tab_buttons = {}
    local gap = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
    for _, tab in ipairs(tabs) do
        local active = tab.mode == self.mode
        local enabled = tab.mode ~= "public_account" or self.wp_enable
        local button = Button:new{
            text = tab.text,
            radius = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            text_font_size = 18,
            text_font_bold = true,
            enabled = enabled,
            padding_h = Screen:scaleBySize(8),
            padding_v = Screen:scaleBySize(2),
            show_parent = self,
            callback = function()
                if enabled and not active and self.on_switch then
                    self.on_switch(tab.mode)
                end
            end,
        }
        if enabled then self._tab_buttons[#self._tab_buttons + 1] = button end
        if #row > 0 then row[#row + 1] = gap end
        local b_w = math.max(1, button:getSize().w)
        table.insert(row, VerticalGroup:new{
            align = "left",
            button,
            LineWidget:new{
                dimen = Geom:new{
                    w = b_w,
                    h = active and Screen:scaleBySize(3) or 1,
                },
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
        })
    end
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, row }
end

-- Tool row: tabs on the left, right-aligned actions sharing the same line.
-- (No OffsetContainer: not shipped on all KOReader builds, so tabs and the
-- actions row are joined with an elastic gap instead.)
function LibraryView:toolRow()
    local tab_group = self:tabBar()
    local actions = self:actionBar()
    local th = math.max(1, tab_group:getSize().h)
    local ah = math.max(1, actions:getSize().h)
    local tw = math.max(1, tab_group:getSize().w)
    local aw = math.max(1, actions:getSize().w)
    local h = math.max(th, ah)
    local gap_w = math.max(0, self.screen_w - tw - aw)
    local row = HorizontalGroup:new{
        align = "center",
        tab_group,
        HorizontalSpan:new{ width = gap_w },
        actions,
    }
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        width = self.screen_w,
        height = h,
        row,
    }
end

function LibraryView:actionBar()
    -- actions as one compact group aligned right (books adds 筛选)
    -- (personal fork: localized literals; active state shown via bold)
    local search_active = self.keyword and self.keyword ~= ""
    local filter_active = self.filter_label and self.filter_label ~= _("All")
    local sort_active = self.sort_label and self.sort_label ~= ""
    local actions = {}
    table.insert(actions, {
        text = "排序", bold = sort_active,
        cb = function() if self.on_sort then self.on_sort() end end,
    })
    if self.mode == "books" then
        table.insert(actions, {
            text = "筛选", bold = filter_active,
            cb = function() if self.on_filter then self.on_filter() end end,
        })
    end
    table.insert(actions, {
        text = "搜索", bold = search_active,
        cb = function() if self.on_search then self.on_search() end end,
    })
    table.insert(actions, {
        text = "刷新", bold = false,
        cb = function() if self.on_refresh then self.on_refresh() end end,
    })
    local gap = HorizontalSpan:new{ width = Screen:scaleBySize(8) }
    local row = HorizontalGroup:new{}
    self._action_secondary = {}
    self._action_primary = {}
    for _, action in ipairs(actions) do
        if #row > 0 then row[#row + 1] = gap end
        local button = Button:new{
            text = action.text,
            radius = 0, margin = 0, bordersize = 0,
            text_font_size = 16,
            text_font_bold = action.bold == true,
            show_parent = self,
            callback = action.cb,
        }
        row[#row + 1] = button
        self._action_primary[#self._action_primary + 1] = button
    end
    -- right padding matches the TitleBar close button's Screen:scaleBySize(11)
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        padding_right = Screen:scaleBySize(11),
        row,
    }
end

-- Bottom dock mirroring the user's SimpleUI bar. Reads simpleui_bar_tabs
-- from the SimpleUI settings file; tapping a non-WeRead tab closes this view
-- and replays the tap on SimpleUI itself (fm._simpleui_plugin:_onTabTap), so
-- navigation + the active indicator stay SimpleUI's own.
local WEREAD_DOCK_ID = "weread"

local function _sui_store()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil end
    local path = DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls then return nil end
    return LuaSettings:open(path)
end

function LibraryView:dockTabs()
    local store = _sui_store()
    if not store then return nil end
    if store:readSetting("simpleui_bar_enabled", true) == false then return nil end
    local tabs = store:readSetting("simpleui_bar_tabs")
    if type(tabs) ~= "table" or #tabs == 0 then return nil end
    return tabs
end

-- Resolve the icon NAME (no ext) for a dock tab id, mirroring SimpleUI's
-- own icon sources; ensures a copy exists in the KOReader user-icons dir
-- (getDataDir/icons) so Button's name-based IconWidget lookup resolves it.
-- Returns nil (text label fallback) when no icon is available.
function LibraryView:dockIconFor(id)
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil end
    local base = DataStorage:getDataDir()
    if not base then return nil end
    local user_icons = base .. "/icons"
    local plugins_dir = base .. "/plugins"
    local sui_icons = plugins_dir .. "/simpleui.koplugin/icons"
    -- source file for each dock id (same file SimpleUI shows)
    local source
    local icon_name
    if id:match("^custom_qa_") then
        -- read the QA's stored icon path (e.g. plugins/simpleui.../plugin.svg)
        local store = _sui_store()
        local cfg = store and store:readSetting("simpleui_qa_" .. id)
        local ic = type(cfg) == "table" and cfg.icon or nil
        if type(ic) == "string" and ic ~= "" then
            local cand
            if ic:match("^plugins/") then
                cand = base .. "/" .. ic
            elseif ic:match("^/mnt/") or ic:match("^%.%.?/") or ic:match("%.svg$") then
                cand = plugins_dir .. "/simpleui.koplugin/icons/plugin.svg"
            end
            if cand and lfs.attributes(cand, "mode") == "file" then
                source = cand
                icon_name = cand:match("([^/]+)%.svg$")
            end
        end
        if not source then
            source = sui_icons .. "/plugin.svg"
            icon_name = "plugin"
        end
    elseif id == "home" or id == "library" then
        source = sui_icons .. "/library.svg"
        icon_name = "library"
    elseif id == "homescreen" then
        -- SimpleUI homescreen icon = KOReader mdlight home.svg (not koreader/icons)
        -- copied under a private name so we never overwrite the shared home.svg
        source = base .. "/resources/icons/mdlight/home.svg"
        icon_name = "wr_home"
    elseif id == "power" then
        source = sui_icons .. "/power.svg"
        icon_name = "power"
    elseif id == "settings" or id == "sui_settings" then
        source = sui_icons .. "/settings.svg"
        icon_name = "settings"
    elseif id == "history" then
        source = sui_icons .. "/history.svg"
        icon_name = "history"
    elseif id == "collections" then
        source = sui_icons .. "/library.svg"
        icon_name = "library"
    end
    if not source or not icon_name then return nil end
    if lfs.attributes(source, "mode") ~= "file" then return nil end
    -- ensure a copy under the user icons dir (kept private for homescreen)
    local target = user_icons .. "/" .. icon_name .. ".svg"
    if lfs.attributes(target, "mode") ~= "file" then
        local ok_cp, ffiutil = pcall(require, "ffi/util")
        if ok_cp and ffiutil.copyFile then
            pcall(ffiutil.copyFile, source, target)
        end
    end
    if lfs.attributes(target, "mode") == "file" then return target end
    return nil
end

local function _dockLabel(tab_id)
    if tab_id == WEREAD_DOCK_ID then return "微信读书" end
    if tab_id == "home" then return "书库" end
    if tab_id == "homescreen" then return "主页" end
    if tab_id == "history" then return "历史" end
    if tab_id == "settings" or tab_id == "sui_settings" then return "设置" end
    if tab_id == "power" then return "电源" end
    if tab_id == "collections" then return "收藏" end
    return tab_id
end

-- Dock cell rendered exactly like SimpleUI: CenterContainer + ImageWidget
-- (file, is_icon, alpha) with the active indicator overlaid on top.
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

function LibraryView:bottomDock(height)
    if not height or height <= 0 then return nil end
    local store = _sui_store()
    local tabs = self:dockTabs()
    if not tabs then return nil end
    -- Mirror SimpleUI dock geometry from its settings.
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
    -- Same three-band sandwich as SimpleUI: TOP_SP/sep, BAR_H content,
    -- BOT_SP padding. height (from ui_reserved_bands) = BAR_H + TOP_SP + BOT_SP.
    local top_sp = Screen:scaleBySize(2)
    local bot_sp = math.floor(Screen:scaleBySize(12) * bot_pct / 100)
    local sep_h = Screen:scaleBySize(1)
    local pad_above = math.max(0, top_sp - sep_h)
    local bar_h = math.max(1, height - top_sp - bot_sp)
    local usable_w = math.max(1, self.screen_w - 2 * side_m)
    -- Resolve the display order, remembering each raw SimpleUI id.
    local resolved = {}
    local raw = {}
    for _, id in ipairs(tabs) do
        if id and id:match("^custom_qa_") then
            resolved[#resolved + 1] = WEREAD_DOCK_ID
        else
            resolved[#resolved + 1] = id
        end
        raw[#raw + 1] = id
    end
    if #resolved == 0 then return nil end
    local cell_w = math.floor(usable_w / #resolved)
    self._dock_tabs = {}
    local row = HorizontalGroup:new{}
    for index, id in ipairs(resolved) do
        local is_weread = id == WEREAD_DOCK_ID
        local width = index == #resolved and usable_w - cell_w * (#resolved - 1) or cell_w
        local icon = self:dockIconFor(raw[index])
        -- SimpleUI-identical cell: CenterContainer + ImageWidget(file) with
        -- the active indicator overlaid on top; DockCell handles the tap.
        local cell = DockCell:new{
            width = width,
            height = bar_h,
            icon = icon,
            icon_sz = icon_sz,
            label = _dockLabel(id),
            active = is_weread,
            indic_h = is_weread and indicator_h or 0,
            dock_cb = function() self:onDockTap(id) end,
            show_parent = self,
        }
        if not is_weread then self._dock_tabs[#self._dock_tabs + 1] = { id = id } end
        row[#row + 1] = cell
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

function LibraryView:onDockTap(tab_id)
    -- WeRead's own dock entry: already here, nothing to do.
    if tab_id == WEREAD_DOCK_ID then return true end

    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FM.instance
    local plugin = fm and fm._simpleui_plugin
    local function replay()
        if plugin and type(plugin._onTabTap) == "function" then
            pcall(plugin._onTabTap, plugin, tab_id, fm)
        end
    end
    local function close_self()
        pcall(function() self:onClose() end)
    end

    if tab_id == "home" or tab_id == "power" or tab_id == "sui_settings"
        or tab_id == "settings" or tab_id == "history" then
        -- Navigation targets owned by SimpleUI: close this view first (back
        -- to the SimpleUI screen WeRead was opened from), then replay the tap
        -- on the real FM so SimpleUI navigates with its own transition.
        close_self()
        UIManager:scheduleIn(0, replay)
        return true
    end
    if tab_id == "homescreen" then
        -- SimpleUI pushes its Home Screen above this view, then we drop
        -- ourselves underneath it: direct transition, no library flash.
        replay()
        close_self()
        return true
    end
    -- power and anything else: in-place actions need the SimpleUI FM
    -- environment, so close first, then replay on the real FM immediately.
    close_self()
    UIManager:scheduleIn(0, replay)
    return true
end

function LibraryView:itemStatus(book)
    if self.mode == "public_account" then return book.author or "" end
    local status = ""
    if book.readUpdateTime and book.readUpdateTime > 0 then
        status = os.date("%Y-%m-%d", book.readUpdateTime)
    elseif book.finishReading == 1 then
        status = _("Done")
    end
    if book._cached then
        status = status ~= "" and ("✓  " .. status) or "✓"
    end
    return status
end

function LibraryView:preparePagination()
    local source = self.mode == "public_account"
        and (self.accounts or {}) or (self.books or {})
    self.page_size = math.max(1, math.floor(tonumber(self.page_size) or 10))
    if self.cover_mode and self.mode == "books" then
        local columns = math.max(1, math.floor(tonumber(self.cover_columns) or 3))
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        self.page_size = columns * rows
    end
    if self.paged then
        self.page_count = math.max(1, math.ceil(#source / self.page_size))
        self.page = math.max(
            1,
            math.min(math.floor(tonumber(self.page) or 1), self.page_count)
        )
    end
end

function LibraryView:content()
    local source = self.mode == "public_account"
        and (self.accounts or {}) or (self.books or {})
    local content = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.list_width },
    }
    self._item_rows = {}
    self._focus_item_rows = {}
    if #source == 0 then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = self.keyword and self.keyword ~= "" and _("No shelf matches.") or _("No items."),
            face = Font:getFace("cfont", 20),
            max_width = self.content_width,
        })
        return content
    end
    local first = 1
    local last = #source
    if self.paged then
        first = (self.page - 1) * self.page_size + 1
        last = math.min(#source, first + self.page_size - 1)
    end
    if self.cover_mode and self.mode == "books" then
        local columns = math.max(1, math.floor(tonumber(self.cover_columns) or 3))
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        local cell_width = math.floor(self.content_width / columns)
        local cell_height = math.floor(math.max(
            1,
            tonumber(self.cover_cell_height) or math.floor(self.screen_h * 0.28)
        ))
        local grid_height = math.max(cell_height, tonumber(self.cover_content_height)
            or cell_height * rows)
        local grid_row
        for index = first, last do
            local book = source[index]
            local column = ((index - first) % columns) + 1
            local row = math.floor((index - first) / columns) + 1
            if column == 1 then
                grid_row = {}
                self._focus_item_rows[#self._focus_item_rows + 1] = grid_row
                table.insert(content, HorizontalGroup:new(grid_row))
            end
            local width = column == columns
                and self.content_width - cell_width * (columns - 1)
                or cell_width
            local height = row == rows and grid_height - cell_height * (rows - 1)
                or cell_height
            local cover_cell = CoverCell:new{
                book = book,
                cached = book._cached == true,
                cover_path = self.cover_paths and self.cover_paths[book] or nil,
                cover_loading = self.cover_loading and self.cover_loading[book] == true,
                width = width,
                height = math.max(1, height),
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(book, self.mode) end
                end,
            }
            self._item_rows[#self._item_rows + 1] = cover_cell
            grid_row[#grid_row + 1] = cover_cell
        end
    else
        for index = first, last do
            local book = source[index]
            local shelf_row = ShelfRow:new{
                text = book.title or book.bookId or book.book_id or _("Untitled"),
                status = self:itemStatus(book),
                width = self.list_width,
                font_size = self.mode == "books" and 20 or 22,
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(book, self.mode) end
                end,
            }
            self._item_rows[#self._item_rows + 1] = shelf_row
            self._focus_item_rows[#self._focus_item_rows + 1] = { shelf_row }
            table.insert(content, shelf_row)
            table.insert(content, HorizontalGroup:new{
                HorizontalSpan:new{ width = Size.padding.large },
                LineWidget:new{
                    dimen = Geom:new{ w = self.list_width - 2 * Size.padding.large, h = 1 },
                    background = Blitbuffer.COLOR_GRAY,
                },
            })
        end
    end
    return content
end

function LibraryView:pageBar()
    if not self.paged or (self.page_count or 1) <= 1 then return nil end
    local cell_w = math.floor(self.screen_w / 3)
    local button_height = Screen:scaleBySize(54)
    local previous = Button:new{
        text = _("Previous"), width = cell_w, height = button_height,
        text_font_size = 22, text_font_bold = true, radius = 0, margin = 0,
        bordersize = 0, enabled = self.page > 1, show_parent = self,
        callback = function()
            if self.page > 1 and self.on_page_changed then
                self.on_page_changed(self.page - 1)
            end
        end,
    }
    local page_text = Button:new{
        text = T(_("%1/%2 pages"), tostring(self.page), tostring(self.page_count)),
        width = cell_w, height = button_height, text_font_size = 18,
        radius = 0, margin = 0, bordersize = 0,
        enabled = false, show_parent = self,
    }
    local next_page = Button:new{
        text = _("Next"), width = self.screen_w - 2 * cell_w,
        height = button_height, text_font_size = 22, text_font_bold = true,
        radius = 0, margin = 0, bordersize = 0,
        enabled = self.page < self.page_count, show_parent = self,
        callback = function()
            if self.page < self.page_count and self.on_page_changed then
                self.on_page_changed(self.page + 1)
            end
        end,
    }
    self._page_buttons = { previous, page_text, next_page }
    return HorizontalGroup:new{ previous, page_text, next_page }
end

-- Reserve the exact SimpleUI top status bar / bottom nav bar heights by
-- mirroring sui_topbar.lua & sui_bottombar.lua formulas and reading the
-- SimpleUI settings file (no cross-plugin require). Returns top, bottom.
local function read_sui_pct(store, key, def, lo, hi)
    if not store then return def end
    local v = tonumber(store:readSetting(key))
    if not v then return def end
    return math.max(lo, math.min(hi, math.floor(v)))
end

local function ui_reserved_bands()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return 0, 0 end
    local path = DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or lfs.attributes(path, "mode") ~= "file" then return 0, 0 end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls then return 0, 0 end
    local store = LuaSettings:open(path)
    -- top status bar: TOTAL_TOP_H = floor(FS_TITLE(22)*s) + pads
    local top = 0
    if store and store:readSetting("simpleui_topbar_enabled", true) ~= false then
        local s = read_sui_pct(store, "simpleui_topbar_size_pct", 100, 50, 150) / 100
        top = math.floor(22 * s)
            + math.floor(Screen:scaleBySize(20) * s)
            + math.floor(Screen:scaleBySize(8) * s)
    end
    -- bottom nav bar: BAR_H(scaleBySize(96)*s) + TOP_SP(2) + BOT_SP(12*b)
    local bar = 0
    if store and store:readSetting("simpleui_bar_enabled", true) ~= false then
        local s = read_sui_pct(store, "simpleui_bar_size_pct", 100, 50, 150) / 100
        local b = read_sui_pct(store, "simpleui_bar_bottom_margin_pct", 100, 0, 300) / 100
        bar = math.floor(Screen:scaleBySize(96) * s)
            + Screen:scaleBySize(2)
            + math.floor(Screen:scaleBySize(12) * b)
    end
    return top, bar
end

function LibraryView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    -- Full-screen viewport; the top/bottom bands below are left transparent
    -- (spacers), so the SimpleUI top status bar and bottom nav bar of the
    -- FileManager underneath stay visible. The white panel only wraps the
    -- actual content, which is inset by the reserved bands.
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true
    self.outer_margin = 0
    self.content_width = self.screen_w
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or _("WeRead Bookshelf"),
        title_face = Font:getFace("tfont", 28),
        align = "center",
        with_bottom_line = true,
        right_icon_size_ratio = 0.75,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local tool = self:toolRow()
    self:preparePagination()
    local page_bar = self:pageBar()
    local top_gap, bottom_gap = ui_reserved_bands()
    local dock = self:bottomDock(bottom_gap)
    local dock_h = dock and bottom_gap or 0
    local scroll_h = math.max(1, self.screen_h - top_gap - dock_h
        - self.title_bar:getHeight() - tool:getSize().h
        - (page_bar and page_bar:getSize().h or 0))
    if self.cover_mode and self.mode == "books" then
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        self.cover_content_height = scroll_h
        self.cover_cell_height = math.max(1, math.floor(scroll_h / rows))
    end
    local content = self:content()
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_h },
        show_parent = self,
        VerticalGroup:new{ align = "left", content },
    }
    -- One row holds the tabs plus the right-aligned actions (tool row).
    local tool_buttons = {}
    for _, button in ipairs(self._tab_buttons) do
        tool_buttons[#tool_buttons + 1] = button
    end
    for _, button in ipairs(self._action_primary) do
        tool_buttons[#tool_buttons + 1] = button
    end
    local rows = { tool_buttons }
    for _, item_row in ipairs(self._focus_item_rows) do
        rows[#rows + 1] = item_row
    end
    local outside_scroll = {}
    for _, button in ipairs(tool_buttons) do outside_scroll[button] = true end
    if self._page_buttons then
        rows[#rows + 1] = self._page_buttons
        for _, button in ipairs(self._page_buttons) do outside_scroll[button] = true end
    end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    FocusNav.initialFocus(self, 1, 1)
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = top_gap },
            FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0, padding = 0, margin = 0,
                width = self.screen_w,
                VerticalGroup:new{
                    align = "left", self.title_bar, tool, scroll,
                    page_bar or VerticalSpan:new{ width = 0 },
                },
            },
            VerticalSpan:new{ width = bottom_gap - dock_h },
            dock or VerticalSpan:new{ width = 0 },
        },
    }
    if self.paged and Device:hasKeys() then
        self.onNextPage = function(view)
            if view.page < view.page_count and view.on_page_changed then
                view.on_page_changed(view.page + 1)
            end
            return true
        end
        self.onPrevPage = function(view)
            if view.page > 1 and view.on_page_changed then
                view.on_page_changed(view.page - 1)
            end
            return true
        end
    end
end

function LibraryView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function LibraryView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function LibraryView:onClose()
    UIManager:close(self)
    return true
end

local M = {}
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = LibraryView:new{
        mode = data.mode,
        title = data.title,
        wp_enable = data.wp_enable ~= false,
        books = data.books,
        accounts = data.accounts,
        keyword = data.keyword,
        sort_label = data.sort_label,
        filter_label = data.filter_label,
        paged = data.paged == true,
        page = data.page,
        page_size = data.page_size,
        cover_mode = data.cover_mode == true,
        cover_columns = data.cover_columns,
        cover_rows = data.cover_rows,
        cover_cell_height = data.cover_cell_height,
        cover_paths = data.cover_paths,
        cover_loading = data.cover_loading,
        on_switch = callbacks.on_switch,
        on_search = callbacks.on_search,
        on_refresh = callbacks.on_refresh,
        on_sort = callbacks.on_sort,
        on_filter = callbacks.on_filter,
        on_select = callbacks.on_select,
        on_page_changed = callbacks.on_page_changed,
    }
    UIManager:show(view)
    return view
end

return M
