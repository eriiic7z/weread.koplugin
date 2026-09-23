-- weread/ui/read_stats_view.lua — WeRead reading statistics visualization page.
--
-- Pure presentation layer: given a normalized stats table (see weread/lib/read_stats.lua)
-- and callbacks, it builds a full-screen, card-based, e-ink-friendly page that
-- adapts to any screen width. It performs no network I/O.
--
-- Sizing model (the key to avoiding overflow): `content_width` is the single
-- authoritative inner width. FrameContainer:getSize() ignores its `width` field
-- (that only affects the painted border), so we never rely on it to clamp
-- content; instead every child is constrained to <= content_width, and each card
-- is pinned to exactly content_width with a zero-height spacer.
--
-- Layout:
--   [TitleBar: mode · period (no close button)]
--   [title separator]
--   [Tab bar: 周 / 月 / 年 / 总]
--   [ScrollableContainer]
--     ├─ Overview card (total time / days / average / compare / rank / summary)
--     ├─ Trend card (bar chart with a value axis)
--     ├─ Ranking card (most-read books)
--     └─ Preference card (categories / time / authors / publishers)
--   [Nav row: previous | next]   (hidden for "overall")

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local logger = require("weread.lib.logger")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local TitleMetrics = require("weread.ui.header_metrics")
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local T = require("ffi/util").template

local function _(text)
    return I18n.tr(text)
end

-- Long titles shown in the title bar.
local MODE_TITLE = {
    weekly = "This week",
    monthly = "This month",
    annually = "This year",
    overall = "Overall",
}

-- Short labels + order for the tab bar.
local TABS = {
    { mode = "weekly", text = "Week" },
    { mode = "monthly", text = "Month" },
    { mode = "annually", text = "Year" },
    { mode = "overall", text = "Total" },
}

-- ---------------------------------------------------------------------------
-- Formatting helpers (localized, view-only)
-- ---------------------------------------------------------------------------

local function format_duration(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 60 then
        return _("< 1 min")
    end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 and m > 0 then
        return T(_("%1 h %2 min"), h, m)
    elseif h > 0 then
        return T(_("%1 h"), h)
    end
    return T(_("%1 min"), m)
end

-- Compact form for the chart value axis ("3.2h" / "45m" / "0").
local function format_duration_axis(seconds)
    seconds = tonumber(seconds) or 0
    if seconds >= 3600 then
        return string.format("%gh", math.floor(seconds / 360 + 0.5) / 10)
    elseif seconds >= 60 then
        return string.format("%dm", math.floor(seconds / 60 + 0.5))
    elseif seconds > 0 then
        return "<1m"
    end
    return "0"
end

local function format_compare(compare)
    if type(compare) ~= "number" or compare == 0 then
        return nil
    end
    local pct = math.floor(math.abs(compare) * 100 + 0.5)
    if pct == 0 then
        return nil
    end
    if compare > 0 then
        return T(_("↑ %1% vs previous"), pct)
    end
    return T(_("↓ %1% vs previous"), pct)
end

-- ---------------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------------

local ReadStatsView = FocusManager:extend{
    host = false, -- hosted overlay (dock/bands/gestures) when opened from the shelf
    data = nil,
    on_prev = nil,
    on_next = nil,
    on_switch = nil,
    on_latest = nil,   -- long-press on the dock's next arrow -> newest period
}

function ReadStatsView:faces()
    return {
        number = Font:getFace("tfont", 28),
        label = Font:getFace("cfont", 15),
        card_title = Font:getFace("tfont", 18),
        body = Font:getFace("cfont", 16),
        small = Font:getFace("cfont", 13),
    }
end

-- Zero-height spacer that pins a VerticalGroup to the full content width.
function ReadStatsView:widthPin()
    return HorizontalSpan:new{ width = self.content_width }
end

function ReadStatsView:makeCard(inner)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = self.card_border,
        radius = Size.radius.window,
        padding = self.card_padding,
        margin = 0,
        inner,
    }
end

function ReadStatsView:cardTitle(text)
    local f = self.fonts
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = text, face = f.card_title, max_width = self.content_width },
        VerticalSpan:new{ width = Size.padding.small },
        LineWidget:new{
            dimen = Geom:new{ w = self.content_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        },
        VerticalSpan:new{ width = Size.padding.default },
    }
end

-- A left label + right value line spanning the full content width.
function ReadStatsView:kvLine(left, right, face)
    face = face or self.fonts.body
    local right_w = TextWidget:new{ text = right, face = face }
    local rw = right_w:getSize().w
    local left_w = TextWidget:new{
        text = left, face = face,
        max_width = math.max(1, self.content_width - rw - Size.padding.default),
    }
    local gap = math.max(Size.padding.default, self.content_width - rw - left_w:getSize().w)
    return HorizontalGroup:new{
        left_w,
        HorizontalSpan:new{ width = gap },
        right_w,
    }
end

-- Horizontal proportional bar: "name ....... value" then a scaled bar below.
function ReadStatsView:proportionBar(name, value_text, ratio)
    local bar_w = math.max(1, math.floor(math.min(1, ratio) * self.content_width + 0.5))
    return VerticalGroup:new{
        align = "left",
        self:kvLine(name, value_text, self.fonts.body),
        VerticalSpan:new{ width = Size.padding.tiny },
        LineWidget:new{
            dimen = Geom:new{ w = bar_w, h = Screen:scaleBySize(6) },
            background = Blitbuffer.COLOR_BLACK,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------------

function ReadStatsView:buildOverviewCard()
    local d, f = self.data, self.fonts
    local content = VerticalGroup:new{ align = "left", self:widthPin() }

    -- Headline: total reading time, with a small caption to its right.
    local caption = TextWidget:new{ text = _("Total reading time"), face = f.label }
    local number = TextWidget:new{
        text = format_duration(d.total_read_time),
        face = f.number,
        max_width = math.max(1, self.content_width - caption:getSize().w - Size.padding.default),
    }
    table.insert(content, HorizontalGroup:new{
        align = "bottom",
        number,
        HorizontalSpan:new{ width = Size.padding.default },
        caption,
    })

    -- Sub-metrics on one wrapping line.
    local parts = { T(_("%1 days read"), d.read_days or 0) }
    if (d.day_average or 0) > 0 then
        parts[#parts + 1] = T(_("Daily average %1"), format_duration(d.day_average))
    end
    local cmp = format_compare(d.compare)
    if cmp then parts[#parts + 1] = cmp end
    if type(d.read_rate) == "number" and d.read_rate > 0 then
        parts[#parts + 1] = T(_("Text reading %1%"), math.floor(d.read_rate + 0.5))
    end
    if d.rank_text and d.rank_text ~= "" then
        parts[#parts + 1] = d.rank_text
    end
    table.insert(content, VerticalSpan:new{ width = Size.padding.default })
    table.insert(content, TextBoxWidget:new{
        text = table.concat(parts, "  ·  "),
        face = f.label,
        width = self.content_width,
    })

    -- Merged summary (读过/读完/阅读/笔记).
    local summary = d.summary or {}
    if #summary > 0 then
        local chips = {}
        for _i, s in ipairs(summary) do
            chips[#chips + 1] = T("%1 %2", s.name, s.counts)
        end
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        table.insert(content, LineWidget:new{
            dimen = Geom:new{ w = self.content_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        table.insert(content, TextBoxWidget:new{
            text = table.concat(chips, "    "),
            face = f.body,
            width = self.content_width,
        })
    end

    return self:makeCard(content)
end

-- Vertical bar chart with a value axis on the left.
function ReadStatsView:buildChartCard()
    local d, f = self.data, self.fonts
    local buckets = d.buckets or {}
    if #buckets == 0 then
        return nil
    end

    local n = #buckets
    local max_value = 1
    for _i, b in ipairs(buckets) do
        if b.value > max_value then max_value = b.value end
    end

    local chart_h = Screen:scaleBySize(104)
    -- Left value axis: peak at top, 0 at bottom.
    local top_lbl = format_duration_axis(max_value)
    local axis_top = TextWidget:new{ text = top_lbl, face = f.small }
    local axis_bot = TextWidget:new{ text = "0", face = f.small }
    local lh = axis_top:getSize().h
    local axis_w = math.max(axis_top:getSize().w, axis_bot:getSize().w)
    local axis_col = VerticalGroup:new{
        align = "right",
        RightContainer:new{ dimen = Geom:new{ w = axis_w, h = lh }, axis_top },
        VerticalSpan:new{ width = math.max(0, chart_h - 2 * lh) },
        RightContainer:new{ dimen = Geom:new{ w = axis_w, h = lh }, axis_bot },
    }

    local axis_gap = Size.padding.small
    local chart_w = self.content_width - axis_w - axis_gap
    local gap = Screen:scaleBySize(n > 16 and 2 or 4)
    local bar_w = math.floor((chart_w - (n - 1) * gap) / n)
    if bar_w < 1 then bar_w = 1 end
    local label_step = math.ceil(n / 8)

    local bars_row = HorizontalGroup:new{ align = "bottom" }
    local labels_row = HorizontalGroup:new{ align = "top" }
    for i, b in ipairs(buckets) do
        local bar_h = math.floor((b.value / max_value) * chart_h + 0.5)
        if bar_h == 0 and b.value > 0 then bar_h = 1 end
        local col = bar_h > 0
            and LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bar_h }, background = Blitbuffer.COLOR_BLACK }
            or VerticalSpan:new{ width = 0 }
        table.insert(bars_row, BottomContainer:new{ dimen = Geom:new{ w = bar_w, h = chart_h }, col })

        local label_text = ((i - 1) % label_step == 0) and b.label or ""
        table.insert(labels_row, CenterContainer:new{
            dimen = Geom:new{ w = bar_w, h = lh + Screen:scaleBySize(2) },
            TextWidget:new{ text = label_text, face = f.small },
        })
        if i < n then
            table.insert(bars_row, HorizontalSpan:new{ width = gap })
            table.insert(labels_row, HorizontalSpan:new{ width = gap })
        end
    end

    local chart_col = VerticalGroup:new{
        align = "left",
        bars_row,
        LineWidget:new{ dimen = Geom:new{ w = chart_w, h = Size.line.medium }, background = Blitbuffer.COLOR_BLACK },
        VerticalSpan:new{ width = Size.padding.tiny },
        labels_row,
    }

    local content = VerticalGroup:new{
        align = "left",
        self:widthPin(),
        self:cardTitle(_("Reading time trend")),
        HorizontalGroup:new{
            align = "top",
            axis_col,
            HorizontalSpan:new{ width = axis_gap },
            chart_col,
        },
    }
    return self:makeCard(content)
end

function ReadStatsView:buildRankCard()
    local list = self.data.top_books or {}
    if #list == 0 then
        return nil
    end
    local max_seconds = 1
    for _i, item in ipairs(list) do
        if item.seconds > max_seconds then max_seconds = item.seconds end
    end
    local content = VerticalGroup:new{ align = "left", self:widthPin(), self:cardTitle(_("Most-read books")) }
    for i, item in ipairs(list) do
        if i > 1 then
            table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        end
        table.insert(content, self:proportionBar(T("%1. %2", i, item.title),
            format_duration(item.seconds), item.seconds / max_seconds))
    end
    return self:makeCard(content)
end

function ReadStatsView:buildPreferenceCard()
    local d, f = self.data, self.fonts
    local categories = d.prefer_category or {}
    local authors = d.prefer_author or {}
    local publishers = d.prefer_publisher or {}
    if #categories == 0 and #authors == 0 and #publishers == 0
        and not d.prefer_time_word and not d.prefer_category_word then
        return nil
    end

    local content = VerticalGroup:new{ align = "left", self:widthPin(), self:cardTitle(_("Reading preferences")) }
    local first = true
    local function section(widget)
        if not first then
            table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        end
        first = false
        table.insert(content, widget)
    end

    if #categories > 0 then
        local max_seconds = 1
        for _i, c in ipairs(categories) do
            if c.seconds > max_seconds then max_seconds = c.seconds end
        end
        local group = VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = d.prefer_category_word or _("Categories"), face = f.label, max_width = self.content_width },
        }
        for i = 1, math.min(#categories, 5) do
            local c = categories[i]
            table.insert(group, VerticalSpan:new{ width = Size.padding.small })
            table.insert(group, self:proportionBar(c.title, format_duration(c.seconds), c.seconds / max_seconds))
        end
        section(group)
    end

    if d.prefer_time_word and d.prefer_time_word ~= "" then
        section(self:kvLine(_("Preferred time"), d.prefer_time_word, f.body))
    end

    local function name_count_line(label, items)
        local parts = {}
        for i = 1, math.min(#items, 6) do
            local it = items[i]
            parts[#parts + 1] = it.count > 0 and T("%1·%2", it.name, it.count) or it.name
        end
        section(VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = label, face = f.label, max_width = self.content_width },
            VerticalSpan:new{ width = Size.padding.tiny },
            TextBoxWidget:new{ text = table.concat(parts, "   "), face = f.body, width = self.content_width },
        })
    end
    if #authors > 0 then name_count_line(_("Favorite authors"), authors) end
    if #publishers > 0 then name_count_line(_("Favorite publishers"), publishers) end

    return self:makeCard(content)
end

function ReadStatsView:buildEmptyCard()
    return self:makeCard(VerticalGroup:new{
        align = "left",
        self:widthPin(),
        TextWidget:new{ text = _("No reading records for this period."), face = self.fonts.body, max_width = self.content_width },
    })
end

-- ---------------------------------------------------------------------------
-- Assembly
-- ---------------------------------------------------------------------------

function ReadStatsView:buildContent()
    local page = VerticalGroup:new{ align = "left" }
    local function add(card)
        if not card then return end
        if #page > 0 then
            table.insert(page, VerticalSpan:new{ width = Size.padding.large })
        end
        table.insert(page, card)
    end
    add(self:buildOverviewCard())
    add(self:buildChartCard())
    add(self:buildRankCard())
    add(self:buildPreferenceCard())
    if #page == 0 then
        add(self:buildEmptyCard())
    end
    return page
end

function ReadStatsView:buildTabBar()
    local n = #TABS
    -- tabs span the same width as the cards (24px inset each side)
    local side = Screen:scaleBySize(24)
    local cell_w = math.floor((self.screen_w - 2 * side) / n)
    local row = HorizontalGroup:new{}
    self._tab_buttons = {}
    -- Sizes follow SimpleUI's title-bar size preset (Default = previous values);
    -- the card-matching side inset above is deliberately not scaled.
    local us = TitleMetrics.uiScale()
    for _i, tab in ipairs(TABS) do
        local active = (tab.mode == self.data.mode)
        local button = Button:new{
            text = _(tab.text),
            width = cell_w,
            radius = 0,
            margin = 0,
            bordersize = Size.border.thin,
            -- no background: KOReader forces ROUNDED corners on the tap
            -- highlight whenever a Button has a background → keeps the
            -- fixed & tap highlights both square (bookshelf style)
            preselect = active,
            text_font_bold = active,
            text_font_size = math.floor(18 * us), -- tab labels two sizes smaller
            padding_v = math.floor(Screen:scaleBySize(1) * us), -- bookshelf control-height ratio
            show_parent = self,
            callback = function() self:onSwitchMode(tab.mode) end,
        }
        self._tab_buttons[#self._tab_buttons + 1] = button
        if active then
            -- Preselect is painted as an inverted frame; without this the
            -- focus cursor leaving the tab would erase its highlight.
            button.onUnfocus = function(_self)
                _self.frame.invert = true
                return true
            end
        end
        table.insert(row, button)
    end
    local tab_frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        padding_left = side,
        padding_right = side,
        row,
    }
    return tab_frame
end

--- Navpager hooks (SimpleUI's bottom-bar mode): the dock-end arrows take over
--- period navigation, so the in-page 上一周期/下一周期 row is hidden while
--- navpager is on (and comes back when it is off).
local function navpagerOn()
    local ok, cfg = pcall(require, "infra/sui_config")
    return ok and cfg and cfg.isNavpagerEnabled and cfg.isNavpagerEnabled() or false
end

--- Period navigation: with navpager the bottom-bar arrows drive it (SimpleUI
--- reads page/page_num), taps call onPrevPage/onNextPage, holds call
--- onGotoPage(1) for the prev arrow (earliest period) and onGotoPage(page_num)
--- for the next arrow (newest period). The virtual pager below maps exactly that
--- state onto allow_prev/allow_next, so the arrows show/dim correctly.
function ReadStatsView:onPrevPage()
    self:onPrevPeriod()
    return true
end

function ReadStatsView:onNextPage()
    self:onNextPeriod()
    return true
end

function ReadStatsView:onGotoPage(page)
    if page and page <= 1 then
        -- earliest period: allow_prev is unbounded, so there is nothing to jump
        -- to (same as before the native migration)
        return true
    end
    if self.on_latest then self.on_latest() end
    return true
end

--- Period navigation stays on the in-page row when navpager is off; with
--- navpager on the row is hidden and the bottom-bar arrows take over.

function ReadStatsView:buildNavRow()
    local d = self.data
    if not d.allow_prev and not d.allow_next then
        self._nav_buttons = {}
        return nil
    end
    -- Copy the FileManager pager row's height (measured live) so this row and
    -- the shelf's pager row match it exactly; shared metric as a fallback.
    local row_h = self:fmPagerRowHeight()
        or Screen:scaleBySize(TitleMetrics.PAGER_ROW_H)
    -- bookshelf rule: button height = text line + small vertical padding
    local pad_v = Screen:scaleBySize(1)
    -- Same pagination preset factor as the pager rows (s = 1.0 = previous value).
    local pscale = TitleMetrics.pagerScale()
    local function mk(text, enabled, cb)
        return Button:new{
            text = text, text_font_size = math.floor(16 * pscale), text_font_bold = false,
            padding_v = pad_v, radius = 0, margin = 0, bordersize = 0,
            show_parent = self, enabled = enabled, callback = cb,
        }
    end
    local prev_button = mk("上一周期", d.allow_prev == true,
        function() self:onPrevPeriod() end)
    local next_button = mk("下一周期", d.allow_next == true,
        function() self:onNextPeriod() end)
    self._nav_buttons = { prev_button, next_button }
    local group = HorizontalGroup:new{
        prev_button,
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        next_button,
    }
    local row = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = row_h },
            group,
        },
    }
    return row
end

function ReadStatsView:init()
    self.fonts = self:faces()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    if self.host then
        -- SimpleUI hosts this page through its Bar Injection API: real top/bottom
        -- bars with every setting applied, its own top-edge menu gestures, bar
        -- taps, highlight and close handling. We only keep the frontlight gestures.
        -- Looked up here rather than at file top: this file's load no longer
        -- depends on the host module, and relocating the host later becomes a path
        -- change only (no load-order coupling).
        local FullscreenHost = require("weread.ui.fullscreen_host")
        FullscreenHost.install(self)
        self.native_bar = FullscreenHost.nativeBarAvailable()
        if self.native_bar then
            self:ensureBarDescriptors()
            -- BarInjection matches shown widgets by name.
            self.name = "weread_stats"
        end
        self.covers_fullscreen = true
        self.top_gap, self.bottom_gap = 0, 0
    else
        self.covers_fullscreen = true
    end

    -- KOReader's own screenshot module, registered as an active widget exactly like
    -- FileManager does (filemanager.lua:400): our fullscreen page sits above the
    -- FileManager, so without this its long-diagonal-swipe / two-finger-tap
    -- gestures never reach it.
    pcall(function()
        local Screenshoter = require("ui/widget/screenshoter")
        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_fm and FM.instance
        self._wr_screenshot = Screenshoter:new{ prefix = "FileManager", ui = fm or self }
        self.active_widgets = { self._wr_screenshot }
    end)
    -- KOReader's gesture → action mappings (the Gestures plugin) and SimpleUI's own
    -- gestures are registered as touch zones on the *FileManager*, which this
    -- fullscreen page covers — so those mappings silently stop working here. Hand a
    -- gesture our page did not consume to the FileManager's own handler.
    -- Only the two-finger / pinch family is forwarded: one-finger gestures belong to
    -- this page (scroll, frontlight, pager).
    local FORWARD_GESTURES = {
        pinch = true, spread = true, inward_pan = true, outward_pan = true,
        two_finger_tap = true, two_finger_swipe = true,
    }
    pcall(function()
        local orig_gesture = self.onGesture
        self.onGesture = function(s, ev)
            local r = orig_gesture and orig_gesture(s, ev)
            local ges = ev and ev.ges
            if not r and ges and FORWARD_GESTURES[ges] then
                local fwd = false
                pcall(function()
                    local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
                    local fm = ok_f and FM.instance
                    if fm and type(fm.onGesture) == "function" then
                        fwd = fm:onGesture(ev) and true or false
                    end
                end)
                if fwd then return true end
            end
            return r
        end
    end)

    -- Authoritative widths. Reserve space for the scrollbar so cards never get
    -- cropped, and derive the inner content width from card border + padding.
    self.outer_margin = Size.padding.large
    self.card_border = Size.border.window
    self.card_padding = Size.padding.large
    -- Cards share the bookshelf cover grid's side geometry: 24px in from the
    -- screen edges on both sides (scrollbar sits clear of that inset).
    local side_inset = Screen:scaleBySize(24)
    self.card_width = math.max(1, self.screen_w - 2 * side_inset)
    self.content_width = math.max(1, self.card_width
        - 2 * self.card_border - 2 * self.card_padding)

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Layout is built by buildLayout() so it can be re-run in place when
    -- SimpleUI's title-bar size preset changes: the tab row reads its metrics
    -- there and the scroll area follows from the row heights.
    self:buildLayout()
end

--- Builds this page's layout tree. Called by init, and again by refreshUiScale()
--- when SimpleUI's title-bar size preset changes.
function ReadStatsView:buildLayout()
    local d = self.data
    -- Virtual pager state for SimpleUI's native navpager arrows: "page > 1"
    -- means a previous period exists, "page < page_num" a next one. The arrow
    -- handlers below turn that back into period navigation — the behaviour this
    -- page had before the native migration. (Only meaningful while navpager is
    -- on; harmless otherwise.)
    self.page = (d.allow_prev == true) and 2 or 1
    self.page_num = self.page + ((d.allow_next == true) and 1 or 0)
    local mode_title = _(MODE_TITLE[d.mode] or "Reading statistics")
    local title = (d.period_label and d.period_label ~= "")
        and T("%1 · %2", mode_title, d.period_label) or mode_title
    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = title,
        title_multilines = true,
        title_face = Font:getFace(TitleMetrics.FACE, TitleMetrics.FACE_SIZE),
        title_top_padding = Screen:scaleBySize(TitleMetrics.TOP_PADDING),
        align = "center",
        with_bottom_line = false, -- no bottom line / separator below the title
        bottom_v_padding = Screen:scaleBySize(TitleMetrics.LINE_GAP),
        -- X close button removed (bookshelf style): Back key / dock nav close
        show_parent = self,
    }

    local tab_bar = self:buildTabBar()
    -- Navpager mode hands period navigation to the native dock arrows, so the
    -- in-page row is hidden while it is on (pre-migration behaviour).
    local nav_row
    if not navpagerOn() then
        nav_row = self:buildNavRow()
    end

    local rows = { self._tab_buttons }
    if nav_row then rows[#rows + 1] = self._nav_buttons end
    FocusNav.apply(self, rows)
    FocusNav.initialFocus(self, 1, 1)

    -- no title separator line: tab row sits directly under the title
    local top_h = self.title_bar:getHeight() + tab_bar:getSize().h
    local nav_h = nav_row and nav_row:getSize().h or 0
    -- Available height for our own content: with the native bar, SimpleUI's
    -- wrapper already holds the top/bottom bars, so we lay out on the content
    -- height it provides (same value as the bands we used to reserve).
    local layout_h = self.screen_h
    if self.host and self.native_bar then
        local ok_core, UI = pcall(require, "infra/sui_core")
        if ok_core and UI and UI.getContentHeight then
            local ok_h, h = pcall(UI.getContentHeight)
            if ok_h and type(h) == "number" and h > 0 then layout_h = h end
        end
    end
    local vreserve = 0
    local scroll_h = layout_h - top_h - nav_h - vreserve
    self.layout_h = layout_h

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_h },
        show_parent = self,
        HorizontalGroup:new{
            HorizontalSpan:new{ width = Screen:scaleBySize(24) },
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = self.outer_margin },
                self:buildContent(),
                VerticalSpan:new{ width = self.outer_margin },
            },
        },
    }
    -- Let KOReader's built-in screenshot gesture (a long diagonal swipe) through:
    -- its own fullscreen widgets do the same on purpose (bookstatuswidget.lua:535-
    -- 540), while a ScrollableContainer consumes every swipe and would otherwise
    -- swallow the gesture before FileManager's screenshot module sees it.
    local orig_scroll_swipe = scroll.onScrollableSwipe
    scroll.onScrollableSwipe = function(s, arg, ges_ev)
        local d = ges_ev and ges_ev.direction
        if d == "northeast" or d == "northwest"
                or d == "southeast" or d == "southwest" then
            return false
        end
        return orig_scroll_swipe and orig_scroll_swipe(s, arg, ges_ev)
    end
    self.scroll = scroll
    -- halve the scrollbar width vs the stock default (6 → 3 scale units)
    scroll.scroll_bar_width = math.max(1, math.floor(Screen:scaleBySize(6) / 2))
    -- scrollbar is created lazily at first paint (paintTo → initState), so hook
    -- initState to colour the bar the moment it exists
    local orig_init_state = scroll.initState
    scroll.initState = function(s)
        orig_init_state(s)
        local bar = s._v_scroll_bar
        if bar then
            local g = Blitbuffer.gray(0.25) -- gray 0.25
            bar.bordercolor = g
            bar.rectcolor = g
            -- the half-width bar sits flush against the device bezel; nudge it
            -- left so it reads as a margin, not a screen edge
            local shift = Screen:scaleBySize(8)
            local orig_paint = bar.paintTo
            bar.paintTo = function(bs, bb, bx, by)
                orig_paint(bs, bb, bx - shift, by)
            end
        end
    end
    self:applyScrollbarColor()

    local body = VerticalGroup:new{
        align = "left", self.title_bar, tab_bar, scroll,
    }
    if nav_row then
        table.insert(body, nav_row)
    end
    self._ui_scale = TitleMetrics.uiScale()

    -- Keep the top-level widget's identity: when SimpleUI hosts this page it wraps
    -- our first child and stores the top-bar offset on that object
    -- (sui_patches.lua:2086 + wrapWithNavbar), so it must not be replaced.
    local outer = self._navbar_inner or self[1]
    if outer then
        outer[1] = body
        outer.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.layout_h }
        pcall(function() if outer.resetLayout then outer:resetLayout() end end)
    else
        self[1] = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, padding = 0, margin = 0,
            dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.layout_h },
            body,
        }
    end
end

--- Re-runs the layout in place when SimpleUI's title-bar size preset changes.
--- Fired by the patch layer from inside SimpleUI's own reapplyAll; a rebuild only
--- happens when the preset really changed.
function ReadStatsView:refreshUiScale()
    if self._ui_scale == TitleMetrics.uiScale() then return end
    self:buildLayout()
    UIManager:setDirty(self, "ui")
end

--- Scrollbar appears/updates only after layout, so re-apply the light colour
--- on show too, not just at construction.
function ReadStatsView:applyScrollbarColor()
    local bar = self.scroll and self.scroll._v_scroll_bar
    if bar then
        local g = Blitbuffer.gray(0.25) -- gray 0.25
        bar.bordercolor = g
        bar.rectcolor = g
    end
end

function ReadStatsView:onShow()
    logger.info("wrFlow: stats onShow")
    if self.host then
        -- With the native bar SimpleUI already registers the top-edge menu
        -- tap/swipe zones for injected widgets, so only our frontlight zones
        -- are still needed.
        self:registerHostGestures(self.native_bar == true)
    end
    self:applyScrollbarColor()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function ReadStatsView:onClose()
    logger.info("wrFlow: stats onClose")
    UIManager:close(self)
    return true
end

function ReadStatsView:onSwitchMode(mode)
    if mode ~= self.data.mode and self.on_switch then
        self.on_switch(mode)
    end
    return true
end

--- Called by the touch-zone wrapper right after SimpleUI installed this page's
--- bar zones (they do not exist at on_inject time). Take over just the
--- bookshelf tab's tap semantics, mirroring the shelf's switch.
function ReadStatsView:on_zones_registered()
    if self.native_bar ~= true then return end
    local shelf_id = self:findDockTab(function(_, _, cfg)
        return cfg ~= nil and cfg.plugin_key == "weread"
            and (cfg.plugin_method == nil or cfg.plugin_method == "launch")
    end)
    if not shelf_id then return end
    local index = self:renderedTabIndex(nil, shelf_id)
    if not index then return end
    self:overrideDockTab(index, function()
        logger.info("wrFlow: tap shelf tab -> back to bookshelf")
        -- Defensive: an unhandled error here breaks KOReader's input chain.
        pcall(function()
            if self.on_bookshelf then self.on_bookshelf() end
        end)
        return true
    end)
end

function ReadStatsView:onPrevPeriod()
    if self.data.allow_prev and self.on_prev then
        self.on_prev()
    end
    return true
end

function ReadStatsView:onNextPeriod()
    if self.data.allow_next and self.on_next then
        self.on_next()
    end
    return true
end

local M = {}

-- Show the statistics page.
--   data      : normalized stats table from weread/lib/read_stats.lua
--   callbacks : { on_prev = fn, on_next = fn, on_switch = fn(mode),
--                 on_latest = fn, on_bookshelf = fn }
-- Returns the widget instance.
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = ReadStatsView:new{
        host = callbacks.host_mode == true,
        data = data,
        on_prev = callbacks.on_prev,
        on_next = callbacks.on_next,
        on_switch = callbacks.on_switch,
        on_bookshelf = callbacks.on_bookshelf,
        on_latest = callbacks.on_latest,
    }
    UIManager:show(view)
    return view
end

return M
