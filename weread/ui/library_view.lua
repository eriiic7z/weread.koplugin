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
local TitleMetrics = require("weread.ui.header_metrics")
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local logger = require("weread.lib.logger")
local T = require("ffi/util").template

local function _(text) return I18n.tr(text) end

--- Navpager mode: true when SimpleUI's bottom bar is in navpager mode.
local function navpagerOn()
    local ok, cfg = pcall(require, "infra/sui_config")
    return ok and cfg and cfg.isNavpagerEnabled and cfg.isNavpagerEnabled() or false
end

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

-- Transparent tap pad: layout footprint stays button-sized (like the local
-- bookshelf chevron buttons) while the touch range extends beyond it, so both
-- pagers share identical geometry and only the hit area differs.
local TapPad = InputContainer:extend{
    width = nil,
    height = nil,
    touch_size = nil,
    inner = nil,
    enabled = true,
    callback = nil,
}

function TapPad:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = CenterContainer:new{
        dimen = self.dimen:copy(),
        self.inner,
    }
    local touch = self.touch_size or self.width
    self.ges_events = {
        TapPad = {
            range = function()
                return Geom:new{
                    x = self.dimen.x - math.floor((touch - self.dimen.w) / 2),
                    y = self.dimen.y - math.floor((touch - self.dimen.h) / 2),
                    w = touch, h = touch,
                }
            end,
        },
    }
end

function TapPad:onTapPad()
    -- forward the tap to the inner Button so its highlight/feedback plays
    -- exactly as if the button itself had been pressed
    if self.enabled and self.inner and self.inner.onTapSelectButton then
        return self.inner:onTapSelectButton()
    end
    return true
end

function TapPad:onFocus()
    return self.inner and self.inner:onFocus()
end

function TapPad:onUnfocus()
    return self.inner and self.inner:onUnfocus()
end

local ShelfRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    font_size = 22,
    pad_h = nil,
    status_font_size = nil,
    status_color = nil,
    callback = nil,
    show_parent = nil,
}

function ShelfRow:init()
    local pad_h = self.pad_h or Size.padding.large
    local inner_width = self.width - 2 * pad_h
    local face = Font:getFace("cfont", self.font_size)
    local status_face = Font:getFace("cfont", self.status_font_size or self.font_size)
    local status_opts = { text = self.status or "", face = status_face }
    if self.status_color then status_opts.fgcolor = self.status_color end
    local status_widget = TextWidget:new(status_opts)
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
        padding_left = pad_h,
        padding_right = pad_h,
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
    -- book title below the cover: 15px bold (local-bookshelf mosaic title
    -- spec, FS_DETAIL); single line, long names truncate with ellipsis
    local title_widget = TextWidget:new{
        text = title,
        face = Font:getFace("smallinfofont", 15),
        bold = true,
        max_width = cover_width,
    }
    -- author line under the title: 12px, regular weight (two sizes smaller)
    local author_widget
    local author_name = self.book.author or ""
    if author_name ~= "" then
        author_widget = TextWidget:new{
            text = author_name,
            face = Font:getFace("smallinfofont", 12),
            max_width = cover_width,
        }
    end
    -- Absolute layout: KOReader line boxes are taller than their glyphs, so
    -- stacking title/author TextWidgets leaves extra visible white. Lay them
    -- out by hand: cover→title keeps a small gap; the author line is pulled
    -- up into the title's empty descender space to tighten the line spacing.
    local gap_c = Screen:scaleBySize(2)
    local author_pull = Screen:scaleBySize(3)
    local have_author = author_widget ~= nil
    local title_sz = title_widget:getSize()
    local author_sz = have_author and author_widget:getSize() or nil
    local total_h = cover_height + gap_c + title_sz.h
        + (have_author and (author_sz.h - author_pull) or 0)
    local y_cover = math.max(0, math.floor((self.height - total_h) / 2))
    local y_title = y_cover + cover_height + gap_c
    local y_author = y_title + title_sz.h - author_pull
    local function cx(w) return math.max(0, math.floor((self.width - w) / 2)) end
    cover.overlap_offset = { cx(cover_width), y_cover }
    title_widget.overlap_offset = { cx(title_sz.w), y_title }
    local layers = {
        dimen = Geom:new{ w = self.width, h = self.height },
        allow_mirroring = false,
        cover,
        title_widget,
    }
    if have_author then
        author_widget.overlap_offset = { cx(author_sz.w), y_author }
        layers[#layers + 1] = author_widget
    end
    local cell = OverlapGroup:new(layers)
    self.frame = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        cell,
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
    -- Sizes follow SimpleUI's title-bar size preset (Default = the previous
    -- values); insets that must keep matching the separator are NOT scaled.
    local us = TitleMetrics.uiScale()
    local gap = HorizontalSpan:new{ width = math.floor(Screen:scaleBySize(14) * us) }
    for _i, tab in ipairs(tabs) do
        local active = tab.mode == self.mode
        local enabled = tab.mode ~= "public_account" or self.wp_enable
        local button = Button:new{
            text = tab.text,
            radius = 0,
            margin = 0,
            bordersize = 0,
            -- no background: KOReader forces ROUNDED corners on the tap
            -- highlight whenever a Button has a background, so leave it nil
            -- to get the square highlight (直角矩形)
            text_font_size = math.floor(18 * us),
            text_font_bold = true,
            enabled = enabled,
            padding_h = math.floor(Screen:scaleBySize(6) * us),
            padding_v = math.floor(Screen:scaleBySize(1) * us),
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
            VerticalSpan:new{ width = math.floor(Screen:scaleBySize(3) * us) }, -- keep tap highlight clear of the title separator
            button,
            -- active underline: same 1px thickness as the bottom dock
            -- separator (active state kept via colour only); spaced below
            -- the button so the tap highlight never touches it
            VerticalSpan:new{ width = math.floor(Screen:scaleBySize(4) * us) },
            LineWidget:new{
                dimen = Geom:new{
                    w = b_w,
                    h = Screen:scaleBySize(1),
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
    local tw = math.max(1, tab_group:getSize().w)
    local aw = math.max(1, actions:getSize().w)
    -- Kept as the natural content height (plan C: only the header TOP is
    -- unified across the three pages, rows keep their own height).
    local h = math.max(tab_group:getSize().h, actions:getSize().h)
    -- tab group inset by the dock separator's own side margin, so the tabs
    -- align with the cover grid and the bottom dock divider
    local side_m = Screen:scaleBySize(24)
    local gap_w = math.max(0, self.screen_w - side_m - tw - aw)
    local row = HorizontalGroup:new{
        align = "center",
        tab_group,
        HorizontalSpan:new{ width = gap_w },
        actions,
    }
    -- Navpager indicator, centred over the row: same visual slot as FM's
    -- path/page subtitle (the line under the separator). Empty until we know
    -- the page count (see refreshToolPageInfo). The indicator is centred on
    -- the SCREEN, so it lives in a screen-wide layer on top of the row (the
    -- row itself keeps its own side padding).
    local info = TextWidget:new{ text = "", face = Font:getFace("cfont", 16) }
    self._tool_page_info = info
    local row_fc = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        width = self.screen_w,
        height = h,
        padding_left = side_m,
        row,
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        row_fc,
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = h },
            info,
        },
    }
end

--- Text of the centred navpager indicator: "第p/pn页" only while SimpleUI's
--- navpager owns paging and there is more than one page.
function LibraryView:refreshToolPageInfo()
    local w = self._tool_page_info
    if not w then return end
    local text = ""
    if navpagerOn() and self.paged then
        local total = math.max(1, self.page_count or 1)
        if total > 1 then
            local cur = math.max(1, math.min(self.page or 1, total))
            text = T(_("第%1/%2页"), cur, total)
        end
    end
    pcall(function() w:setText(text) end)
end

function LibraryView:actionBar()
    local us = TitleMetrics.uiScale()
    -- actions as one compact group aligned right (books adds 筛选)
    -- (personal fork: localized literals; active state shown via bold)
    local search_active = self.keyword and self.keyword ~= ""
    local filter_active = self.filter_label and self.filter_label ~= _("All")
    local sort_active = self.sort_label and self.sort_label ~= ""
    local actions = {}
    table.insert(actions, {
        text = "刷新", bold = false,
        cb = function() if self.on_refresh then self.on_refresh() end end,
    })
    table.insert(actions, {
        text = "搜索", bold = search_active,
        cb = function() if self.on_search then self.on_search() end end,
    })
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
    local gap = HorizontalSpan:new{ width = math.floor(Screen:scaleBySize(8) * us) }
    local row = HorizontalGroup:new{}
    self._action_secondary = {}
    self._action_primary = {}
    for _i, action in ipairs(actions) do
        if #row > 0 then row[#row + 1] = gap end
        local button = Button:new{
            text = action.text,
            radius = 0, margin = 0, bordersize = 0,
            text_font_size = math.floor(16 * us),
            text_font_bold = action.bold == true,
            padding_v = math.floor(Screen:scaleBySize(1) * us),
            show_parent = self,
            callback = action.cb,
        }
        row[#row + 1] = button
        self._action_primary[#self._action_primary + 1] = button
    end
    -- right margin mirrors the bottom dock separator's own inset (side_m),
    -- so the action module's right edge aligns with the separator's end
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        padding_right = Screen:scaleBySize(28),
        row,
    }
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
        -- SimpleUI's pageable contract: the native navpager arrows resolve their
        -- target through page/page_num on the topmost pageable widget.
        self.page_num = self.page_count
        self.page = math.max(
            1,
            math.min(math.floor(tonumber(self.page) or 1), self.page_count)
        )
    end
    self:refreshToolPageInfo()
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
        -- the added author line pushed the grid up against the tab underline;
        -- restore the previous headroom with a leading spacer
        table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(12) })
        local columns = math.max(1, math.floor(tonumber(self.cover_columns) or 3))
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        -- the grid as a whole is inset on both sides by the dock separator's
        -- own margin; per-book spacing/size logic below is unchanged
        local side_m = self.cover_side_margin or Screen:scaleBySize(24)
        local usable_w = math.max(1, self.content_width - 2 * side_m)
        local cell_width = math.floor(usable_w / columns)
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
                table.insert(content, HorizontalGroup:new{
                    HorizontalSpan:new{ width = side_m },
                    HorizontalGroup:new(grid_row),
                    HorizontalSpan:new{ width = side_m },
                })
            end
            local width = column == columns
                and usable_w - cell_width * (columns - 1)
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
        local pub = self.mode == "public_account"
        local inset = pub and Screen:scaleBySize(24) or Size.padding.large
        local row_w = pub and self.screen_w or self.list_width
        for index = first, last do
            local book = source[index]
            local row_opts = {
                text = book.title or book.bookId or book.book_id or _("Untitled"),
                status = self:itemStatus(book),
                width = row_w,
                font_size = pub and 19 or 20,
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(book, self.mode) end
                end,
            }
            if pub then
                row_opts.pad_h = Screen:scaleBySize(24)
                row_opts.status_font_size = 16
                row_opts.status_color = Blitbuffer.gray(0.55)
            end
            local shelf_row = ShelfRow:new(row_opts)
            self._item_rows[#self._item_rows + 1] = shelf_row
            self._focus_item_rows[#self._focus_item_rows + 1] = { shelf_row }
            table.insert(content, shelf_row)
            table.insert(content, HorizontalGroup:new{
                HorizontalSpan:new{ width = inset },
                LineWidget:new{
                    dimen = Geom:new{ w = row_w - 2 * inset, h = 1 },
                    background = Blitbuffer.COLOR_GRAY,
                },
            })
        end
    end
    return content
end

--- Unified narrow pager above the dock (bookshelf + public-account list):
---   « 首页|上一页 | x/y | 下一页|末页 »
--- « / » = jump to first / last page; 上一页/下一页 are text; every control
--- keeps the bookshelf ratio (text line + 1px vertical padding).
function LibraryView:pageBar()
    if not self.paged or (self.page_count or 1) <= 1 then return nil end
    return self:koPager()
end

function LibraryView:koPager()
    -- Baselines stay the values these pagers have always used; SimpleUI's pagination
    -- preset scales them (s = 1.0, so the default preset is pixel-identical).
    local pscale = TitleMetrics.pagerScale()
    local icon_sz = math.floor(Screen:scaleBySize(18) * pscale)
    local gap = Screen:scaleBySize(21) -- same as the FM pager spacer
    local total = math.max(1, self.page_count or 1)
    local cur = math.max(1, math.min(self.page or 1, total))
    local function jump(p)
        p = math.max(1, math.min(total, p))
        if p ~= cur and self.on_page_changed then
            self.on_page_changed(p)
        end
    end
    local function chev(icon, enabled, cb)
        local btn = Button:new{
            icon = icon,
            icon_width = icon_sz,
            icon_height = icon_sz,
            bordersize = 0,
            enabled = enabled,
            -- a hold must work even on a disabled arrow (first/prev at page 1): the
            -- long press opens the pagination-bar settings window
            allow_hold_when_disabled = true,
            show_parent = self,
            callback = cb,
        }
        -- long-press (on release), on any of the four arrows, opens the native
        -- pagination-bar settings window — same as the page number below
        require("weread.ui.ko_custom_patches").hookPagerHoldToSettings(btn)
        -- layout footprint = the FM chevron button's (icon + its 2px padding),
        -- touch area grows beyond it
        local footprint = icon_sz + 2 * Screen:scaleBySize(2)
        local touch = footprint + 2 * Screen:scaleBySize(13)
        return TapPad:new{
            width = footprint,
            height = footprint,
            touch_size = touch,
            inner = btn,
            enabled = enabled,
        }
    end
    local first = chev("chevron.first", cur > 1, function() jump(1) end)
    local left = chev("chevron.left", cur > 1, function() jump(cur - 1) end)
    local right = chev("chevron.right", cur < total, function() jump(cur + 1) end)
    local last = chev("chevron.last", cur < total, function() jump(total) end)
    -- Tap opens KOReader's own page-number dialog: the FileManager pager uses this
    -- same hold_input mechanism (menu.lua:832-848), with call_hold_input_on_tap so
    -- a plain tap opens it (button.lua:88-89).
    local page_text
    page_text = Button:new{
        text = T("%1/%2", tostring(cur), tostring(total)),
        text_font_size = math.floor(14 * pscale),
        text_font_bold = false,
        bordersize = 0,
        enabled = true,
        show_parent = self,
        call_hold_input_on_tap = true,
        hold_input = {
            title = _("Go to page"),
            hint_func = function() return T(_("1 - %1"), total) end,
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function() page_text:closeInputDialog() end,
                    },
                    {
                        text = _("Go to page"),
                        callback = function()
                            local p = tonumber(page_text.input_dialog:getInputText())
                            if p and p >= 1 and p <= total then
                                jump(p)
                                page_text:closeInputDialog()
                            end
                        end,
                    },
                },
            },
        },
    }
    -- Long-press (on release) opens SimpleUI's own pagination-bar settings window;
    -- the tap keeps the native page-number dialog configured above.
    require("weread.ui.ko_custom_patches").hookPagerHoldToSettings(page_text)
    self._page_buttons = { first, left, right, last, page_text }
    local function sp() return HorizontalSpan:new{ width = gap } end
    -- Copy the FileManager pager row's height (measured live) so the three rows
    -- are identical by construction; shared metric only as a fallback.
    local row_h = self:fmPagerRowHeight()
        or Screen:scaleBySize(TitleMetrics.PAGER_ROW_H)
    local row = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = row_h },
        HorizontalGroup:new{
            first, sp(), left, sp(), page_text, sp(), right, sp(), last,
        },
    }
    return row
end

--- Navpager is provided by SimpleUI's Bar Injection (is_pageable = true); it
--- drives onPrevPage/onNextPage/onGotoPage, defined in init.

--- Family-internal switch (kept from before the native migration): the dock
--- tap for the stats tab opens the stats page over this one and closes this one
--- once its data is ready — instead of going through SimpleUI's navigate, which
--- left the stats page under this one and looked like a dead tap.
function LibraryView:openStats()
    if self.on_stats then
        self.on_stats(self)
        return true
    end
    return false
end

--- Called by the touch-zone wrapper right after SimpleUI installed this page's
--- bar zones (they do not exist at on_inject time). Take over just the stats
--- tab's tap semantics so the family switch is the same as before the
--- migration instead of SimpleUI's navigate (which left the stats page under
--- this one and looked like a dead tap).
function LibraryView:on_zones_registered()
    if self.native_bar ~= true then return end
    local stats_id = self:findDockTab(function(_, _, cfg)
        return cfg ~= nil and cfg.dispatcher_action == "weread_reading_statistics"
    end)
    if not stats_id then
        logger.info("wrZoneTab: shelf found NO stats tab in the dock list")
        return
    end
    local index = self:renderedTabIndex(nil, stats_id)
    logger.info("wrZoneTab: shelf stats tab=" .. tostring(stats_id)
        .. " index=" .. tostring(index))
    if not index then return end
    self:overrideDockTab(index, function()
        logger.info("wrFlow: tap stats tab -> openStats")
        -- Never let an error inside the tap path escape: an unhandled Lua error
        -- in a touch-zone handler breaks KOReader's input chain (the UI then
        -- looks frozen).
        local ok, err = pcall(function() return self:openStats() end)
        if not ok then
            logger.err("wrFlow: openStats failed:", tostring(err))
            return true -- consume the tap anyway
        end
        return true
    end)
end
--- Legacy alias kept for the method-inventory check; the shelf pager above
--- now serves both bookshelf and public-account pages.
function LibraryView:pubPageBar()
    return self:pageBar()
end

function LibraryView:init()
    -- SimpleUI hosts this page through its Bar Injection API: real top/bottom
    -- bars with every setting applied, its own top-edge menu gestures, bar
    -- taps, highlight and close handling. We only keep the frontlight gestures.
    -- Looked up here rather than at file top: this file's load no longer depends
    -- on the host module, and relocating the host later becomes a path change only
    -- (no load-order coupling).
    local FullscreenHost = require("weread.ui.fullscreen_host")
    FullscreenHost.install(self)
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.native_bar = FullscreenHost.nativeBarAvailable()
    if self.native_bar then
        self:ensureBarDescriptors()
        -- BarInjection matches shown widgets by name.
        self.name = "weread_shelf"
    end
    self.covers_fullscreen = true
    self.outer_margin = 0
    self.content_width = self.screen_w
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    -- cover-grid side margin, aligned with the dock separator line's own
    -- left/right inset (== LINE_INSET in ui/header_metrics.lua)
    self.cover_side_margin = Screen:scaleBySize(TitleMetrics.LINE_INSET)
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or _("WeRead"),
        title_face = Font:getFace(TitleMetrics.FACE, TitleMetrics.FACE_SIZE),
        title_top_padding = Screen:scaleBySize(TitleMetrics.TOP_PADDING),
        align = "center",
        with_bottom_line = false, -- the bottom line below is drawn by title_sep
        bottom_v_padding = Screen:scaleBySize(TitleMetrics.LINE_GAP),
        right_icon_size_ratio = 0.75,
        -- personal fork: the X close button is hidden (cleaner top bar).
        -- Closing still works via the physical Back key (key_events.Close)
        -- and the dock navigation; pass close_callback back here to restore X.
        show_parent = self,
    }
    -- Layout is built by buildLayout() so it can be re-run in place when
    -- SimpleUI's title-bar size preset changes: the rows read their metrics at
    -- build time and every height derived from them (scroll area, cover cells,
    -- rows per page) has to be recomputed together.
    self:buildLayout()
end

--- Builds this page's layout tree: the header rows take TitleMetrics.uiScale()
--- here, and the scroll area / cover cell height / rows per page follow from the
--- row heights. Called by init, and again by refreshUiScale() on a preset change.
function LibraryView:buildLayout()
    local tool = self:toolRow()
    -- title separator: mirrors the bottom dock divider (same thin light-grey
    -- line inset by cover_side_margin on both sides), replacing the built-in
    -- TitleBar bottom line
    local title_sep = HorizontalGroup:new{
        HorizontalSpan:new{ width = self.cover_side_margin },
        LineWidget:new{
            dimen = Geom:new{
                w = math.max(1, self.screen_w - 2 * self.cover_side_margin),
                h = Screen:scaleBySize(TitleMetrics.LINE_H),
            },
            background = Blitbuffer.gray(TitleMetrics.LINE_GRAY),
        },
        HorizontalSpan:new{ width = self.cover_side_margin },
    }
    -- Header band metrics (title row + separator + tool row). The title long-press
    -- zone covers exactly this band, so its height is remembered here.
    self._title_sep_h = title_sep:getSize().h
    self._tool_row_h  = tool:getSize().h
    self:preparePagination()
    -- Navpager mode hands page turning to the native dock arrows (pre-migration
    -- behaviour), so the in-page pager row is hidden while it is on.
    local page_bar
    if not navpagerOn() then
        page_bar = self:pageBar()
    end
    -- Native bar: SimpleUI's wrapper already holds the top/bottom bars, so we
    -- lay our content out on the content height it provides.
    local layout_h = self.screen_h
    if self.native_bar then
        local ok_core, UI = pcall(require, "infra/sui_core")
        if ok_core and UI and UI.getContentHeight then
            local ok_h, h = pcall(UI.getContentHeight)
            if ok_h and type(h) == "number" and h > 0 then layout_h = h end
        end
    end
    self.layout_h = layout_h
    -- always 0: the native bar already sits outside our content box
    self.top_gap, self.bottom_gap = 0, 0
    -- The 8px gap below the pager existed only to clear the self-drawn dock;
    -- with the native bar there is nothing to clear, so drop it (the FM footer
    -- has no such gap either).
    local pager_gap = self.native_bar and 0 or Screen:scaleBySize(8)
    local scroll_h = math.max(1, layout_h
        - self.title_bar:getHeight() - title_sep:getSize().h
        - tool:getSize().h - (page_bar and page_bar:getSize().h or 0) - pager_gap)
    -- Public-account list: auto-fit the rows per page to the viewport, so no
    -- dead line is left between the list and the pager (page rows are NOT
    -- hard-coded here; they follow the available scroll height).
    if self.paged and self.mode == "public_account" and not self.cover_mode then
        local probe = ShelfRow:new{
            text = "\u{4e66}",
            status = "00",
            width = self.screen_w,
            font_size = 19,
            pad_h = Screen:scaleBySize(24),
            status_font_size = 16,
            show_parent = self,
        }
        local row_h = math.max(1, probe:getSize().h)
        -- every rendered row is followed by a 1px separator line
        local fit = math.max(1, math.floor(scroll_h / (row_h + 1)))
        if fit ~= self.page_size then
            self.page_size = fit
            self:preparePagination()
            -- same navpager rule: the native dock arrows own paging there
            if not navpagerOn() then
                page_bar = self:pageBar()
            end
            scroll_h = math.max(1, layout_h
                - self.title_bar:getHeight() - title_sep:getSize().h
                - tool:getSize().h - (page_bar and page_bar:getSize().h or 0) - pager_gap)
        end
    end
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
    -- ScrollableContainer registers full-SCREEN gesture ranges, and it sits
    -- before the pager in the tree (propagation is children-first, ascending).
    -- The pager taps are handled by the pager's own widgets (native zones), so no
    -- clamp is needed here.
    -- One row holds the tabs plus the right-aligned actions (tool row).
    local tool_buttons = {}
    for _i, button in ipairs(self._tab_buttons) do
        tool_buttons[#tool_buttons + 1] = button
    end
    for _i, button in ipairs(self._action_primary) do
        tool_buttons[#tool_buttons + 1] = button
    end
    local rows = { tool_buttons }
    for _i, item_row in ipairs(self._focus_item_rows) do
        rows[#rows + 1] = item_row
    end
    local outside_scroll = {}
    for _i, button in ipairs(tool_buttons) do outside_scroll[button] = true end
    if self._page_buttons then
        rows[#rows + 1] = self._page_buttons
        for _i, button in ipairs(self._page_buttons) do outside_scroll[button] = true end
    end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    FocusNav.initialFocus(self, 1, 1)
    local panel = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        width = self.screen_w,
        VerticalGroup:new{
            align = "left", self.title_bar, title_sep, tool, scroll,
            page_bar or VerticalSpan:new{ width = 0 },
            VerticalSpan:new{ width = pager_gap },
        },
    }
    -- Keep the top-level widget's identity. When SimpleUI hosts this page it wraps
    -- our first child and stores the top-bar offset ON that object
    -- (`widget._navbar_inner = widget[1]`, sui_patches.lua:2086, and
    -- wrapWithNavbar sets inner.overlap_offset) — replacing either one drops the
    -- offset and yanks the page up under the status bar.
    local outer = self._navbar_inner or self[1]
    if outer then
        outer[1] = panel
        outer.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.layout_h }
        pcall(function() if outer.resetLayout then outer:resetLayout() end end)
    else
        self[1] = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.layout_h },
            panel,
        }
    end
    self._ui_scale = TitleMetrics.uiScale()
    -- Paging interface: the in-page pager and SimpleUI's navpager arrows both
    -- drive this (SimpleUI looks for page_num + onPrevPage/onNextPage/
    -- onGotoPage on the pageable widget).
    local function jumpToPage(p)
        local total = math.max(1, self.page_count or 1)
        p = math.max(1, math.min(total, math.floor(tonumber(p) or 1)))
        if p ~= self.page and self.on_page_changed then
            self.on_page_changed(p)
        end
        return true
    end
    if not self.onPrevPage then
        self.onPrevPage = function() return jumpToPage((self.page or 1) - 1) end
    end
    if not self.onNextPage then
        self.onNextPage = function() return jumpToPage((self.page or 1) + 1) end
    end
    self.onGotoPage = function(_, p) return jumpToPage(p) end
end

-- Frontlight edge gestures mirroring KOReader: one-finger vertical swipe
-- on the left edge, and two-finger north/south anywhere, adjust the
-- frontlight with the same delta curve and on/off boundary as
-- DeviceListener (calculateGestureDelta).
--- Re-runs the layout in place when SimpleUI's title-bar size preset changes.
--- Fired by the patch layer from inside SimpleUI's own reapplyAll (the same wheel
--- that makes the local library update live). Only a really different scale is
--- worth a rebuild, so ordinary reapplies cost nothing.
function LibraryView:refreshUiScale()
    if self._ui_scale == TitleMetrics.uiScale() then return end
    self:buildLayout()
    self:registerTitleHoldZones()   -- the band height may have changed with the row
    UIManager:setDirty(self, "ui")
end

--- Long-press on the title band (title row, separator, tab/action row) opens
--- SimpleUI's own "Title Bar" settings window — the same window the local library
--- opens the same way, and meaningful here too because its Button Size drives our
--- tab/action sizes (see TitleMetrics.uiScale). The row's buttons get the hold as
--- well: a hold lands on the child widget first (widgetcontainer.lua:100-107), and
--- their own native long-press is a no-op, so nothing is taken away. Called from
--- onShow, because the band's top edge is SimpleUI's status-bar height, which only
--- exists once this page has been injected.
function LibraryView:registerTitleHoldZones()
    if self.native_bar ~= true then return end
    local ok = pcall(function()
        local band_h = (self.title_bar and self.title_bar:getHeight() or 0)
            + (self._title_sep_h or 0) + (self._tool_row_h or 0)
        if band_h <= 0 then return end
        local sh = Screen:getHeight()
        local zone = {
            ratio_x = 0,
            ratio_y = (self._navbar_topbar_h or 0) / sh,
            ratio_w = 1,
            ratio_h = band_h / sh,
        }
        local function open_settings()
            local enabled = true
            pcall(function()
                local Store = require("infra/sui_store")
                enabled = Store:nilOrTrue("simpleui_topbar_settings_on_hold")
            end)
            if not enabled then return end
            local P = require("weread.ui.ko_custom_patches")
            if P.openTitleBarSettingsWindow then P.openTitleBarSettingsWindow() end
        end
        self:registerTouchZones({
            {
                id          = "wr_shelf_title_hold_start",
                ges         = "hold",
                screen_zone = zone,
                handler     = function() return true end,
            },
            {
                id          = "wr_shelf_title_hold_settings",
                ges         = "hold_release",
                screen_zone = zone,
                handler     = function()
                    open_settings()
                    return true
                end,
            },
        })
        local function hook(btn)
            if not (btn and btn.hold_callback ~= nil) then return end
            btn.hold_callback = function() open_settings() end
        end
        for _, b in ipairs(self._tab_buttons or {}) do hook(b) end
        for _, b in ipairs(self._action_primary or {}) do hook(b) end
    end)
    if not ok then logger.info("wrHold: shelf title hold zones failed") end
end

function LibraryView:onShow()
    logger.info("wrFlow: shelf onShow mode=" .. tostring(self.mode)
        .. " page=" .. tostring(self.page) .. "/" .. tostring(self.page_num))
    -- Host gestures: frontlight edge swipes; the top-edge native menu is
    -- registered by SimpleUI itself for injected widgets, so only the fallback
    -- (non-native) path needs our own top zones.
    self:registerHostGestures(self.native_bar == true)
    self:registerTitleHoldZones()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function LibraryView:onClose()
    logger.info("wrFlow: shelf onClose")
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
        on_stats = callbacks.on_stats,
        on_select = callbacks.on_select,
        on_page_changed = callbacks.on_page_changed,
    }
    UIManager:show(view)
    return view
end

-- Kindle-style menu veil: apply as soon as this module loads (plugin init
-- may not run on every launch). Idempotent.
local wr_scrim = require("weread.ui.ko_custom_patches")
if wr_scrim and wr_scrim.ensure then
    wr_scrim.ensure()
end

return M
