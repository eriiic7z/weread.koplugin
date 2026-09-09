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
local FullscreenHost = require("weread.ui.fullscreen_host")
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local T = require("ffi/util").template

local function tr(text) return I18n.tr(text) end

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
            text = self.cover_loading and tr("Cover loading") or tr("No cover"),
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
    local title = self.book.title or self.book.bookId or self.book.book_id or tr("Untitled")
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
    local gap = HorizontalSpan:new{ width = Screen:scaleBySize(14) }
    for _, tab in ipairs(tabs) do
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
            text_font_size = 18,
            text_font_bold = true,
            enabled = enabled,
            padding_h = Screen:scaleBySize(6),
            padding_v = Screen:scaleBySize(1),
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
            VerticalSpan:new{ width = Screen:scaleBySize(3) }, -- keep tap highlight clear of the title separator
            button,
            -- active underline: same 1px thickness as the bottom dock
            -- separator (active state kept via colour only); spaced below
            -- the button so the tap highlight never touches it
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
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
    local th = math.max(1, tab_group:getSize().h)
    local ah = math.max(1, actions:getSize().h)
    local tw = math.max(1, tab_group:getSize().w)
    local aw = math.max(1, actions:getSize().w)
    local h = math.max(th, ah)
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
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        width = self.screen_w,
        height = h,
        padding_left = side_m,
        row,
    }
end

function LibraryView:actionBar()
    -- actions as one compact group aligned right (books adds 筛选)
    -- (personal fork: localized literals; active state shown via bold)
    local search_active = self.keyword and self.keyword ~= ""
    local filter_active = self.filter_label and self.filter_label ~= tr("All")
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
            padding_v = Screen:scaleBySize(1),
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
        status = tr("Done")
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
            text = self.keyword and self.keyword ~= "" and tr("No shelf matches.") or tr("No items."),
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
                text = book.title or book.bookId or book.book_id or tr("Untitled"),
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

function LibraryView:pageBar()
    if not self.paged or (self.page_count or 1) <= 1 then return nil end
    if self.mode == "public_account" then
        return self:pubPageBar()
    end
    local cell_w = math.floor(self.screen_w / 3)
    local button_height = Screen:scaleBySize(54)
    local previous = Button:new{
        text = tr("Previous"), width = cell_w, height = button_height,
        text_font_size = 22, text_font_bold = true, radius = 0, margin = 0,
        bordersize = 0, enabled = self.page > 1, show_parent = self,
        callback = function()
            if self.page > 1 and self.on_page_changed then
                self.on_page_changed(self.page - 1)
            end
        end,
    }
    local page_text = Button:new{
        text = T(tr("%1/%2 pages"), tostring(self.page), tostring(self.page_count)),
        width = cell_w, height = button_height, text_font_size = 18,
        radius = 0, margin = 0, bordersize = 0,
        enabled = false, show_parent = self,
    }
    local next_page = Button:new{
        text = tr("Next"), width = self.screen_w - 2 * cell_w,
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

--- Public-account (公众号) pager: one slim centred row above the dock.
--- Backgrounds are proportional to their text: every control button is
--- sized as text-line + same small vertical padding (like the tab and the
--- action buttons), so small 14px text gets a proportionally smaller bar.
function LibraryView:pubPageBar()
    local pad = Screen:scaleBySize(1)
    local function mk(text, fs, bold, enabled, cb)
        return Button:new{
            text = text, text_font_size = fs,
            text_font_bold = bold, enabled = enabled,
            padding_v = pad, radius = 0, margin = 0, bordersize = 0,
            show_parent = self, callback = cb,
        }
    end
    local previous = mk(tr("Previous"), 14, true, self.page > 1, function()
        if self.page > 1 and self.on_page_changed then
            self.on_page_changed(self.page - 1)
        end
    end)
    local next_page = mk(tr("Next"), 14, true, self.page < self.page_count, function()
        if self.page < self.page_count and self.on_page_changed then
            self.on_page_changed(self.page + 1)
        end
    end)
    local page_text = Button:new{
        text = T(tr("%1/%2 pages"), tostring(self.page), tostring(self.page_count)),
        text_font_size = 14, text_font_bold = false,
        enabled = false, padding_v = pad,
        radius = 0, margin = 0, bordersize = 0,
        show_parent = self,
    }
    self._page_buttons = { previous, page_text, next_page }
    local group = HorizontalGroup:new{
        previous,
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        page_text,
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        next_page,
    }
    local gh = math.max(1, group:getSize().h)
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = gh },
        group,
    }
end

function LibraryView:init()
    -- Reusable full-screen host: SimpleUI reserved bands + dock (tabs/icons
    -- from SimpleUI's own registry) + frontlight edge gestures + top-edge
    -- native menu gestures. The dock entry that points at this plugin gets
    -- the active indicator and its label.
    FullscreenHost.install(self, {
        -- this dock's "bookshelf" item = the SimpleUI QA pointing at the
        -- weread plugin (launch); it gets the active indicator
        dock_highlight = function(_, _, cfg)
            return cfg ~= nil and cfg.plugin_key == "weread"
                and cfg.plugin_method == "launch"
        end,
        -- family-internal navigation: WeRead-launch item = current page
        -- (no-op); the reading-statistics dispatcher item switches to the
        -- stats page without leaving the host or going through SimpleUI
        dock_nav = function(view, _, cfg)
            if cfg and cfg.plugin_key == "weread" then
                return true
            end
            if cfg and cfg.dispatcher_action == "weread_reading_statistics" then
                -- family switch: open the stats page hosted; the shelf view
                -- is passed along and closed by the stats loader only once
                -- its data is ready (no FM/home flash in between)
                if view.on_stats then view.on_stats(view) end
                return true
            end
            return false
        end,
    })
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    local top_gap, bottom_gap = self:reservedBands()
    -- pull the whole header block up: reserve 10px less of the top band
    -- (scroll area grows by the same amount, so the dock/bottom band stay flush)
    top_gap = math.max(0, top_gap - Screen:scaleBySize(10))
    -- Full-screen viewport; the top/bottom bands below are left transparent
    -- (spacers), so the SimpleUI top status bar and bottom nav bar of the
    -- FileManager underneath stay visible. The white panel only wraps the
    -- actual content, which is inset by the reserved bands.
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = false
    self.outer_margin = 0
    self.content_width = self.screen_w
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    -- cover-grid side margin, aligned with the dock separator line's own
    -- left/right inset (bottomDock side_m = scaleBySize(24))
    self.cover_side_margin = Screen:scaleBySize(24)
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or tr("WeRead"),
        title_face = Font:getFace("smalltfont", 26), -- shelf title: smalltfont, bumped +2 over FM's 24
        title_top_padding = Screen:scaleBySize(6), -- same vertical padding as FM TitleBar → same title height
        align = "center",
        with_bottom_line = false, -- the bottom line below is drawn by title_sep
        right_icon_size_ratio = 0.75,
        -- personal fork: the X close button is hidden (cleaner top bar).
        -- Closing still works via the physical Back key (key_events.Close)
        -- and the dock navigation; pass close_callback back here to restore X.
        show_parent = self,
    }
    local tool = self:toolRow()
    -- title separator: mirrors the bottom dock divider (same thin light-grey
    -- line inset by cover_side_margin on both sides), replacing the built-in
    -- TitleBar bottom line
    local title_sep = HorizontalGroup:new{
        HorizontalSpan:new{ width = self.cover_side_margin },
        LineWidget:new{
            dimen = Geom:new{
                w = math.max(1, self.screen_w - 2 * self.cover_side_margin),
                h = Screen:scaleBySize(1),
            },
            background = Blitbuffer.gray(0.72),
        },
        HorizontalSpan:new{ width = self.cover_side_margin },
    }
    self:preparePagination()
    local page_bar = self:pageBar()
    self.top_gap = top_gap
    self.bottom_gap = bottom_gap
    local dock = self:bottomDock(bottom_gap)
    local dock_h = dock and bottom_gap or 0
    local scroll_h = math.max(1, self.screen_h - top_gap - dock_h
        - self.title_bar:getHeight() - title_sep:getSize().h
        - tool:getSize().h - (page_bar and page_bar:getSize().h or 0))
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
            page_bar = self:pageBar()
            scroll_h = math.max(1, self.screen_h - top_gap - dock_h
                - self.title_bar:getHeight() - title_sep:getSize().h
                - tool:getSize().h - (page_bar and page_bar:getSize().h or 0))
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
                    align = "left", self.title_bar, title_sep, tool, scroll,
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

-- Frontlight edge gestures mirroring KOReader: one-finger vertical swipe
-- on the left edge, and two-finger north/south anywhere, adjust the
-- frontlight with the same delta curve and on/off boundary as
-- DeviceListener (calculateGestureDelta).
function LibraryView:onShow()
    -- Host gestures: top-edge native menu + frontlight swipes
    self:registerHostGestures()
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
        on_stats = callbacks.on_stats,
        on_select = callbacks.on_select,
        on_page_changed = callbacks.on_page_changed,
    }
    UIManager:show(view)
    return view
end

-- Kindle-style menu veil: apply as soon as this module loads (plugin init
-- may not run on every launch). Idempotent.
local wr_scrim = require("weread.ui.menu_scrim_patch")
if wr_scrim and wr_scrim.ensure then
    wr_scrim.ensure()
end

return M
