const std = @import("std");
const url_input = @import("../browser/url_input.zig");
const start_page = @import("start_page.zig");
const webview_events = @import("../webview/webview_events.zig");

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

pub const Id = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Class = ?*anyopaque;

pub const CGFloat = f64;

pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub const tab_strip_height: CGFloat = 36;
pub const toolbar_height: CGFloat = 48;
pub const chrome_height: CGFloat = toolbar_height;

const address_field_height: CGFloat = 28;
const address_field_margin: CGFloat = 12;
const nav_button_size: CGFloat = 28;
const nav_button_gap: CGFloat = 8;
const tab_width: CGFloat = 220;
const min_tab_width: CGFloat = 76;
const tab_height: CGFloat = 28;
const tab_icon_size: CGFloat = 16;
const tab_close_button_size: CGFloat = 20;
const tab_close_button_margin: CGFloat = 4;
const tab_margin: CGFloat = 12;
const tab_label_x: CGFloat = 28;
const inactive_tab_width: CGFloat = 160;
const min_titlebar_tab_strip_width: CGFloat = 320;
const titlebar_window_margin: CGFloat = 118;
const titlebar_new_tab_button_size: CGFloat = 28;
const titlebar_new_tab_button_gap: CGFloat = 4;

const NSButtonTypeMomentaryChange: usize = 5;
const NSImageLeft: isize = 2;
const NSImageScaleProportionallyDown: isize = 1;
const NSImageSymbolScaleMedium: isize = 2;
const NSLayoutAttributeLeft: isize = 1;
const NSTextAlignmentCenter: isize = 1;
const NSUTF8StringEncoding: usize = 4;
const NSLineBreakByTruncatingTail: isize = 4;

const NSViewMinYMargin: usize = 1 << 3;
const NSViewWidthSizable: usize = 1 << 1;
const NSViewTopPinned = NSViewMinYMargin;
const NSViewTopPinnedWidth = NSViewMinYMargin | NSViewWidthSizable;
const objc_pointer_alignment_log2: u8 = 3;

extern "c" fn objc_msgSend() void;
extern "c" fn arc4random_buf(buffer: *anyopaque, size: usize) void;

const WebViewChromeState = struct {
    webview: Id,
    is_internal: bool = false,
    is_loading: bool = false,
};

var current_address_field: Id = null;
var current_reload_button: Id = null;
var current_tab_icon: Id = null;
var current_tab_label: Id = null;
var current_tab_container: Id = null;
var current_tab_document_view: Id = null;
var current_tab_new_button: Id = null;
var current_tab_scroll_view: Id = null;
var current_tab_target: Id = null;
var current_webview_target: Id = null;
var current_window: Id = null;
var current_tab_snapshots: std.ArrayList(webview_events.TabSnapshot) = .empty;
var webview_chrome_states: std.ArrayList(WebViewChromeState) = .empty;
var webcrypto_master_key: [32]u8 = undefined;
var webcrypto_master_key_initialized = false;

pub fn install(window_handle: Id, content_view: Id, bounds: CGRect, webview: Id) !Id {
    current_window = window_handle;
    installAddressBarTargetClass();
    const address_field = try addToolbar(content_view, bounds, webview);
    msg1(void, window_handle, sel("makeFirstResponder:"), address_field);
    return address_field;
}

pub fn noteExternalLoad(webview: Id) void {
    const state = ensureWebViewChromeState(webview) catch return;
    state.is_internal = false;

    if (isActiveWebView(webview)) {
        setCurrentTabIcon(defaultFavicon());
    }
}

pub fn noteInternalLoad(webview: Id) void {
    const state = ensureWebViewChromeState(webview) catch return;
    state.is_internal = true;
    state.is_loading = false;

    if (isActiveWebView(webview)) {
        setCurrentAddress("nimlo://start");
        setCurrentTabIcon(systemSymbol("sparkles", "Nimlo"));
        setCurrentTabTitle("Nimlo");
        setWindowTitle("Nimlo");
        setLoadingState(false);
    }
    webview_events.emitNavigation(.{
        .source_handle = webview,
        .url = "nimlo://start",
        .title = "Nimlo",
        .loading_state = .idle,
    });
}

fn addToolbar(content_view: Id, bounds: CGRect, webview: Id) !Id {
    const target = msg0(Id, msg0(Id, cls("NimloAddressBarTarget"), sel("alloc")), sel("init"));
    if (target == null) return error.MacOSAddressTargetUnavailable;

    _ = msg0(Id, target, sel("retain"));
    _ = c.object_setInstanceVariable(@ptrCast(@alignCast(target.?)), "webView", webview);
    current_webview_target = target;

    try addTitlebarTabStrip(current_window orelse return error.MacOSWindowUnavailable, target);

    const button_y = toolbarControlY(bounds, nav_button_size);
    var button_x = address_field_margin;

    _ = try addToolbarButton(content_view, target, "chevron.left", "Back", "goBack:", button_x, button_y);
    button_x += nav_button_size + nav_button_gap;
    _ = try addToolbarButton(content_view, target, "chevron.right", "Forward", "goForward:", button_x, button_y);
    button_x += nav_button_size + nav_button_gap;
    current_reload_button = try addToolbarButton(content_view, target, "arrow.clockwise", "Reload", "reload:", button_x, button_y);

    const address_x = button_x + nav_button_size + nav_button_gap;
    const address_frame = CGRect{
        .origin = .{
            .x = address_x,
            .y = toolbarControlY(bounds, address_field_height),
        },
        .size = .{
            .width = @max(1, bounds.size.width - address_x - address_field_margin),
            .height = address_field_height,
        },
    };

    const text_field = msg1(
        Id,
        msg0(Id, cls("NSTextField"), sel("alloc")),
        sel("initWithFrame:"),
        address_frame,
    );
    if (text_field == null) return error.MacOSAddressFieldUnavailable;

    _ = c.object_setInstanceVariable(@ptrCast(@alignCast(target.?)), "addressField", text_field);
    current_address_field = text_field;

    msg1(void, text_field, sel("setAutoresizingMask:"), NSViewTopPinnedWidth);
    msg1(void, text_field, sel("setPlaceholderString:"), nsString("Search or enter URL"));
    msg1(void, text_field, sel("setFont:"), msg1(Id, cls("NSFont"), sel("systemFontOfSize:"), @as(CGFloat, 13)));
    msg1(void, text_field, sel("setTarget:"), target);
    msg1(void, text_field, sel("setAction:"), sel("addressSubmitted:"));
    msg1(void, content_view, sel("addSubview:"), text_field);
    configureWebView(webview);

    return text_field;
}

pub fn configureWebView(webview: Id) void {
    _ = ensureWebViewChromeState(webview) catch null;

    if (current_webview_target) |target| {
        msg1(void, webview, sel("setNavigationDelegate:"), target);
    }
}

pub fn forgetWebView(webview: Id) void {
    for (webview_chrome_states.items, 0..) |state, index| {
        if (state.webview == webview) {
            _ = webview_chrome_states.orderedRemove(index);
            return;
        }
    }
}

pub fn setActiveWebView(webview: Id) void {
    _ = ensureWebViewChromeState(webview) catch null;

    if (current_webview_target) |target| {
        _ = c.object_setInstanceVariable(@ptrCast(@alignCast(target)), "webView", webview);
    }
    updateAddressFromWebView(webview);
    updateWindowTitleFromWebView(webview);
    _ = updateFaviconFromWebView(webview);
    setLoadingState(webViewIsLoading(webview));
}

fn addTitlebarTabStrip(window_handle: Id, target: Id) !void {
    const container_frame = CGRect{
        .origin = .{
            .x = 0,
            .y = 0,
        },
        .size = .{
            .width = titlebarContainerWidth(),
            .height = tab_strip_height,
        },
    };
    const container = msg1(
        Id,
        msg0(Id, cls("NSView"), sel("alloc")),
        sel("initWithFrame:"),
        container_frame,
    );
    if (container == null) return error.MacOSTabStripUnavailable;

    current_tab_container = container;
    current_tab_target = target;
    try installTitlebarTabScrollView(container);
    try renderTitlebarTabs(&.{});
    webview_events.setChromeSink(.{
        .context = target.?,
        .on_tabs_changed = handleTabsChanged,
    });
    installWindowResizeObserver(window_handle, target);

    const controller = msg0(Id, msg0(Id, cls("NSTitlebarAccessoryViewController"), sel("alloc")), sel("init"));
    if (controller == null) return error.MacOSTitlebarAccessoryUnavailable;

    msg1(void, controller, sel("setView:"), container);
    msg1(void, controller, sel("setLayoutAttribute:"), NSLayoutAttributeLeft);
    msg1(void, window_handle, sel("addTitlebarAccessoryViewController:"), controller);
}

fn installWindowResizeObserver(window_handle: Id, target: Id) void {
    const notification_center = msg0(Id, cls("NSNotificationCenter"), sel("defaultCenter"));
    if (notification_center == null) return;

    msg4(
        void,
        notification_center,
        sel("addObserver:selector:name:object:"),
        target,
        sel("windowDidResize:"),
        nsString("NSWindowDidResizeNotification"),
        window_handle,
    );
}

fn installTitlebarTabScrollView(container: Id) !void {
    const scroll_frame = CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = titlebarTabAreaWidth(container),
            .height = tab_strip_height,
        },
    };
    const scroll_view = msg1(
        Id,
        msg0(Id, cls("NSScrollView"), sel("alloc")),
        sel("initWithFrame:"),
        scroll_frame,
    );
    if (scroll_view == null) return error.MacOSTabScrollViewUnavailable;

    const document_view = msg1(
        Id,
        msg0(Id, cls("NSView"), sel("alloc")),
        sel("initWithFrame:"),
        scroll_frame,
    );
    if (document_view == null) return error.MacOSTabDocumentViewUnavailable;

    msg1(void, scroll_view, sel("setAutoresizingMask:"), NSViewTopPinnedWidth);
    msg1(void, scroll_view, sel("setBorderType:"), @as(isize, 0));
    msg1(void, scroll_view, sel("setDrawsBackground:"), false);
    msg1(void, scroll_view, sel("setHasHorizontalScroller:"), false);
    msg1(void, scroll_view, sel("setHasVerticalScroller:"), false);
    msg1(void, scroll_view, sel("setDocumentView:"), document_view);
    msg1(void, container, sel("addSubview:"), scroll_view);

    current_tab_scroll_view = scroll_view;
    current_tab_document_view = document_view;
}

fn renderTitlebarTabs(tabs: []const webview_events.TabSnapshot) !void {
    const container = current_tab_container orelse return;
    const document_view = current_tab_document_view orelse return;
    const target = current_tab_target orelse return;

    updateTitlebarContainerLayout();
    removeAllSubviews(document_view);
    removePinnedNewTabButton(container);

    var x: CGFloat = 0;
    var active_button: Id = null;
    const tab_count = tabs.len;
    const tab_slot_width = tabWidthForCount(tab_count, titlebarTabAreaWidth(container));

    for (tabs) |tab| {
        const width = tab_slot_width;
        const button = try addTitlebarTabButton(document_view, target, tab, x, width);
        _ = try addTitlebarTabCloseButton(document_view, target, tab, x, width);
        if (tab.is_active) {
            active_button = button;
        }
        x += width + titlebar_new_tab_button_gap;
    }

    if (tab_count == 0) {
        const fallback: webview_events.TabSnapshot = .{
            .id = 1,
            .title = "Nimlo",
            .url = "nimlo://start",
            .is_active = true,
        };
        active_button = try addTitlebarTabButton(document_view, target, fallback, x, tab_width);
        x += tab_width + titlebar_new_tab_button_gap;
    }

    resizeTabDocument(document_view, titlebarTabAreaWidth(container));
    current_tab_label = active_button;
    current_tab_icon = active_button;
    _ = try addTitlebarNewTabButton(container, target);
}

fn addTitlebarTabButton(container: Id, target: Id, tab: webview_events.TabSnapshot, x: CGFloat, width: CGFloat) !Id {
    const frame = CGRect{
        .origin = .{
            .x = x,
            .y = (tab_strip_height - tab_height) / 2,
        },
        .size = .{ .width = width, .height = tab_height },
    };
    const button = msg1(
        Id,
        msg0(Id, cls("NSButton"), sel("alloc")),
        sel("initWithFrame:"),
        frame,
    );
    if (button == null) return error.MacOSTabButtonUnavailable;

    const title = tabDisplayTitle(tab.title, width) catch "Nimlo";
    msg1(void, button, sel("setTitle:"), nsString(title));
    msg1(void, button, sel("setToolTip:"), nsString(std.heap.page_allocator.dupeZ(u8, tab.title) catch "Nimlo"));
    msg1(void, button, sel("setImage:"), tabImage(tab));
    msg1(void, button, sel("setImagePosition:"), NSImageLeft);
    msg1(void, button, sel("setAutoresizingMask:"), NSViewTopPinned);
    msg1(void, button, sel("setBordered:"), tab.is_active);
    msg1(void, button, sel("setButtonType:"), NSButtonTypeMomentaryChange);
    msg1(void, button, sel("setFont:"), msg1(Id, cls("NSFont"), sel("systemFontOfSize:"), @as(CGFloat, 13)));
    msg1(void, button, sel("setLineBreakMode:"), NSLineBreakByTruncatingTail);
    if (msg0(Id, button, sel("cell"))) |cell| {
        msg1(void, cell, sel("setWraps:"), false);
        msg1(void, cell, sel("setUsesSingleLineMode:"), true);
        msg1(void, cell, sel("setLineBreakMode:"), NSLineBreakByTruncatingTail);
    }
    msg1(void, button, sel("setTag:"), @as(isize, @intCast(tab.id)));
    msg1(void, button, sel("setTarget:"), target);
    msg1(void, button, sel("setAction:"), sel("activateTab:"));
    msg1(void, container, sel("addSubview:"), button);
    return button;
}

fn addTitlebarTabCloseButton(
    container: Id,
    target: Id,
    tab: webview_events.TabSnapshot,
    x: CGFloat,
    width: CGFloat,
) !Id {
    const frame = CGRect{
        .origin = .{
            .x = x + width - tab_close_button_size - tab_close_button_margin,
            .y = (tab_strip_height - tab_close_button_size) / 2,
        },
        .size = .{ .width = tab_close_button_size, .height = tab_close_button_size },
    };
    const button = msg1(
        Id,
        msg0(Id, cls("NSButton"), sel("alloc")),
        sel("initWithFrame:"),
        frame,
    );
    if (button == null) return error.MacOSTabCloseButtonUnavailable;

    const symbol = systemSymbol("xmark", "Close Tab");
    if (symbol != null) {
        msg1(void, button, sel("setImage:"), symbol);
        msg1(void, button, sel("setTitle:"), nsString(""));
    } else {
        msg1(void, button, sel("setTitle:"), nsString("x"));
    }

    msg1(void, button, sel("setAutoresizingMask:"), NSViewTopPinned);
    msg1(void, button, sel("setBordered:"), false);
    msg1(void, button, sel("setButtonType:"), NSButtonTypeMomentaryChange);
    msg1(void, button, sel("setToolTip:"), nsString("Close Tab"));
    msg1(void, button, sel("setTag:"), @as(isize, @intCast(tab.id)));
    msg1(void, button, sel("setTarget:"), target);
    msg1(void, button, sel("setAction:"), sel("closeTab:"));
    msg1(void, container, sel("addSubview:"), button);
    return button;
}

fn tabDisplayTitle(title: []const u8, width: CGFloat) ![:0]const u8 {
    const max_chars: usize = if (width <= inactive_tab_width) 18 else 24;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(std.heap.page_allocator);

    var visible_chars: usize = 0;
    var last_was_space = false;
    for (title) |byte| {
        const normalized: u8 = if (std.ascii.isWhitespace(byte)) ' ' else byte;
        if (normalized == ' ' and (visible_chars == 0 or last_was_space)) continue;
        if (visible_chars >= max_chars) break;

        try output.append(std.heap.page_allocator, normalized);
        visible_chars += 1;
        last_was_space = normalized == ' ';
    }

    while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        _ = output.pop();
    }

    if (title.len > output.items.len and output.items.len >= 3) {
        output.items[output.items.len - 3] = '.';
        output.items[output.items.len - 2] = '.';
        output.items[output.items.len - 1] = '.';
    }

    return try output.toOwnedSliceSentinel(std.heap.page_allocator, 0);
}

fn addTitlebarNewTabButton(container: Id, target: Id) !Id {
    const frame = CGRect{
        .origin = .{
            .x = titlebarTabAreaWidth(container) + titlebar_new_tab_button_gap,
            .y = (tab_strip_height - titlebar_new_tab_button_size) / 2,
        },
        .size = .{ .width = titlebar_new_tab_button_size, .height = titlebar_new_tab_button_size },
    };
    const button = msg1(
        Id,
        msg0(Id, cls("NSButton"), sel("alloc")),
        sel("initWithFrame:"),
        frame,
    );
    if (button == null) return error.MacOSTitlebarButtonUnavailable;

    const symbol = systemSymbol("plus", "New Tab");
    if (symbol != null) {
        msg1(void, button, sel("setImage:"), symbol);
        msg1(void, button, sel("setTitle:"), nsString(""));
    } else {
        msg1(void, button, sel("setTitle:"), nsString("+"));
    }

    msg1(void, button, sel("setAutoresizingMask:"), NSViewTopPinned);
    msg1(void, button, sel("setBordered:"), false);
    msg1(void, button, sel("setButtonType:"), NSButtonTypeMomentaryChange);
    msg1(void, button, sel("setToolTip:"), nsString("New Tab"));
    msg1(void, button, sel("setTag:"), @as(isize, -1));
    msg1(void, button, sel("setTarget:"), target);
    msg1(void, button, sel("setAction:"), sel("newTab:"));
    msg1(void, container, sel("addSubview:"), button);
    current_tab_new_button = button;
    return button;
}

fn titlebarTabAreaWidth(container: Id) CGFloat {
    const bounds = msg0(CGRect, container, sel("bounds"));
    const reserved = titlebar_new_tab_button_size + titlebar_new_tab_button_gap + tab_margin;
    return @max(min_tab_width, bounds.size.width - reserved);
}

fn tabWidthForCount(tab_count: usize, tab_area_width: CGFloat) CGFloat {
    if (tab_count == 0) return tab_width;

    const count: CGFloat = @floatFromInt(tab_count);
    const total_gaps = if (tab_count > 1) titlebar_new_tab_button_gap * @as(CGFloat, @floatFromInt(tab_count - 1)) else 0;
    const available = @max(min_tab_width, tab_area_width - total_gaps);
    return std.math.clamp(available / count, min_tab_width, tab_width);
}

fn resizeTabDocument(document_view: Id, content_width: CGFloat) void {
    msg1(void, document_view, sel("setFrame:"), CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = content_width, .height = tab_strip_height },
    });
}

fn titlebarContainerWidth() CGFloat {
    if (current_window) |window| {
        const frame = msg0(CGRect, window, sel("frame"));
        return @max(min_titlebar_tab_strip_width, frame.size.width - titlebar_window_margin);
    }

    return min_titlebar_tab_strip_width;
}

fn updateTitlebarContainerLayout() void {
    const container = current_tab_container orelse return;
    const width = titlebarContainerWidth();
    msg1(void, container, sel("setFrame:"), CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = width, .height = tab_strip_height },
    });

    if (current_tab_scroll_view) |scroll_view| {
        msg1(void, scroll_view, sel("setFrame:"), CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = titlebarTabAreaWidth(container), .height = tab_strip_height },
        });
    }
}

fn removePinnedNewTabButton(container: Id) void {
    _ = container;
    if (current_tab_new_button) |button| {
        msg0(void, button, sel("removeFromSuperview"));
        current_tab_new_button = null;
    }
}

fn handleTabsChanged(_: *anyopaque, tabs: []const webview_events.TabSnapshot) void {
    current_tab_snapshots.clearRetainingCapacity();
    current_tab_snapshots.appendSlice(std.heap.page_allocator, tabs) catch return;
    renderTitlebarTabs(tabs) catch return;
}

fn removeAllSubviews(view: Id) void {
    const subviews = msg0(Id, view, sel("subviews"));
    if (subviews != null) {
        msg1(void, subviews, sel("makeObjectsPerformSelector:"), sel("removeFromSuperview"));
    }
}

fn tabImage(tab: webview_events.TabSnapshot) Id {
    if (tab.favicon_url.len > 0) {
        const url_z = std.heap.page_allocator.dupeZ(u8, tab.favicon_url) catch return defaultFaviconForTab(tab);
        const ns_url = msg1(Id, cls("NSURL"), sel("URLWithString:"), nsString(url_z));
        if (ns_url != null) {
            const image = msg1(Id, msg0(Id, cls("NSImage"), sel("alloc")), sel("initWithContentsOfURL:"), ns_url);
            if (image != null) return sizedTabImage(image);
        }
    }

    return sizedTabImage(defaultFaviconForTab(tab));
}

fn defaultFaviconForTab(tab: webview_events.TabSnapshot) Id {
    if (std.mem.eql(u8, tab.url, "nimlo://start")) return systemSymbol("sparkles", "Nimlo");
    return defaultFavicon();
}

fn sizedTabImage(image: Id) Id {
    if (image != null) {
        msg1(void, image, sel("setSize:"), CGSize{ .width = tab_icon_size, .height = tab_icon_size });
    }

    return image;
}

fn addToolbarButton(
    content_view: Id,
    target: Id,
    symbol_name: [:0]const u8,
    tooltip: [:0]const u8,
    action: [:0]const u8,
    x: CGFloat,
    y: CGFloat,
) !Id {
    const frame = CGRect{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = nav_button_size, .height = nav_button_size },
    };
    const button = msg1(
        Id,
        msg0(Id, cls("NSButton"), sel("alloc")),
        sel("initWithFrame:"),
        frame,
    );
    if (button == null) return error.MacOSToolbarButtonUnavailable;

    const symbol = systemSymbol(symbol_name, tooltip);
    const image = if (symbol) |value| value else fallbackSymbolImage(symbol_name);
    if (image != null) {
        msg1(void, button, sel("setImage:"), image);
    } else {
        msg1(void, button, sel("setTitle:"), nsString(fallbackButtonTitle(symbol_name)));
    }

    msg1(void, button, sel("setAutoresizingMask:"), NSViewTopPinned);
    msg1(void, button, sel("setTitle:"), nsString(""));
    msg1(void, button, sel("setBordered:"), false);
    msg1(void, button, sel("setButtonType:"), NSButtonTypeMomentaryChange);
    msg1(void, button, sel("setToolTip:"), nsString(tooltip));
    msg1(void, button, sel("setTarget:"), target);
    msg1(void, button, sel("setAction:"), sel(action));
    msg1(void, content_view, sel("addSubview:"), button);
    return button;
}

fn systemSymbol(symbol_name: [:0]const u8, accessibility_description: [:0]const u8) Id {
    const image = msg2(
        Id,
        cls("NSImage"),
        sel("imageWithSystemSymbolName:accessibilityDescription:"),
        nsString(symbol_name),
        nsString(accessibility_description),
    );
    if (image == null) return null;

    const config = msg1(
        Id,
        cls("NSImageSymbolConfiguration"),
        sel("configurationWithScale:"),
        NSImageSymbolScaleMedium,
    );
    if (config == null) return image;

    return msg1(Id, image, sel("imageWithSymbolConfiguration:"), config);
}

fn fallbackSymbolImage(symbol_name: [:0]const u8) Id {
    if (std.mem.eql(u8, symbol_name, "chevron.left")) return msg1(Id, cls("NSImage"), sel("imageNamed:"), nsString("NSGoLeftTemplate"));
    if (std.mem.eql(u8, symbol_name, "chevron.right")) return msg1(Id, cls("NSImage"), sel("imageNamed:"), nsString("NSGoRightTemplate"));
    if (std.mem.eql(u8, symbol_name, "arrow.clockwise")) return msg1(Id, cls("NSImage"), sel("imageNamed:"), nsString("NSRefreshTemplate"));
    if (std.mem.eql(u8, symbol_name, "xmark")) return msg1(Id, cls("NSImage"), sel("imageNamed:"), nsString("NSStopProgressTemplate"));

    return null;
}

fn fallbackButtonTitle(symbol_name: [:0]const u8) [:0]const u8 {
    if (std.mem.eql(u8, symbol_name, "chevron.left")) return "<";
    if (std.mem.eql(u8, symbol_name, "chevron.right")) return ">";
    if (std.mem.eql(u8, symbol_name, "arrow.clockwise")) return "R";
    if (std.mem.eql(u8, symbol_name, "xmark")) return "X";

    return "?";
}

fn toolbarControlY(bounds: CGRect, height: CGFloat) CGFloat {
    return bounds.size.height - chrome_height + ((toolbar_height - height) / 2);
}

fn installAddressBarTargetClass() void {
    if (c.objc_getClass("NimloAddressBarTarget") != null) return;

    const superclass = c.objc_getClass("NSObject");
    const target_class = c.objc_allocateClassPair(superclass, "NimloAddressBarTarget", 0);
    if (target_class == null) return;

    _ = c.class_addIvar(target_class, "addressField", @sizeOf(Id), objc_pointer_alignment_log2, "@");
    _ = c.class_addIvar(target_class, "webView", @sizeOf(Id), objc_pointer_alignment_log2, "@");
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("addressSubmitted:"),
        @ptrCast(&addressSubmitted),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("goBack:"),
        @ptrCast(&goBack),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("goForward:"),
        @ptrCast(&goForward),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("reload:"),
        @ptrCast(&reload),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("newTab:"),
        @ptrCast(&newTab),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("activateTab:"),
        @ptrCast(&activateTab),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("closeTab:"),
        @ptrCast(&closeTab),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("windowDidResize:"),
        @ptrCast(&windowDidResize),
        "v@:@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("webView:didStartProvisionalNavigation:"),
        @ptrCast(&navigationStarted),
        "v@:@@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("webView:didReceiveServerRedirectForProvisionalNavigation:"),
        @ptrCast(&navigationChanged),
        "v@:@@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("webView:didCommitNavigation:"),
        @ptrCast(&navigationChanged),
        "v@:@@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("webView:didFinishNavigation:"),
        @ptrCast(&navigationFinished),
        "v@:@@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("webView:didFailNavigation:withError:"),
        @ptrCast(&navigationFailed),
        "v@:@@@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("webView:didFailProvisionalNavigation:withError:"),
        @ptrCast(&navigationFailed),
        "v@:@@@",
    );
    _ = c.class_addMethod(
        target_class,
        c.sel_registerName("_webCryptoMasterKeyForWebView:"),
        @ptrCast(&webCryptoMasterKey),
        "@@:@",
    );

    c.objc_registerClassPair(target_class);
}

fn webCryptoMasterKey(_: Id, _: Sel, _: Id) callconv(.c) Id {
    if (!webcrypto_master_key_initialized) {
        arc4random_buf(&webcrypto_master_key, webcrypto_master_key.len);
        webcrypto_master_key_initialized = true;
    }

    return msg2(
        Id,
        cls("NSData"),
        sel("dataWithBytes:length:"),
        &webcrypto_master_key,
        webcrypto_master_key.len,
    );
}

fn addressSubmitted(target: Id, _: Sel, _: Id) callconv(.c) void {
    const address_field = getIvar(target, "addressField") orelse return;
    const webview = getIvar(target, "webView") orelse return;
    const value = msg0(Id, address_field, sel("stringValue"));
    const raw = msg0(?[*:0]const u8, value, sel("UTF8String")) orelse return;
    const input = std.mem.span(raw);

    const normalized = url_input.normalize(std.heap.page_allocator, input) catch |err| {
        std.debug.print("address input ignored: {s}\n", .{@errorName(err)});
        return;
    };

    if (std.mem.eql(u8, normalized, "nimlo://start")) {
        msg1(void, address_field, sel("setStringValue:"), nsString("nimlo://start"));
        loadInternalStartPage(webview) catch return;
        std.debug.print("address bar loading internal page: {s}\n", .{normalized});
        return;
    }

    const url_z = std.heap.page_allocator.dupeZ(u8, normalized) catch return;
    const ns_url = msg1(Id, cls("NSURL"), sel("URLWithString:"), nsString(url_z));
    if (ns_url == null) return;

    const request = msg1(Id, cls("NSURLRequest"), sel("requestWithURL:"), ns_url);
    if (request == null) return;

    msg1(void, address_field, sel("setStringValue:"), nsString(url_z));
    noteExternalLoad(webview);
    _ = msg1(Id, webview, sel("loadRequest:"), request);
    std.debug.print("address bar loading: {s}\n", .{normalized});
}

fn goBack(target: Id, _: Sel, _: Id) callconv(.c) void {
    const webview = getIvar(target, "webView") orelse return;
    if (msg0(bool, webview, sel("canGoBack"))) {
        _ = msg0(Id, webview, sel("goBack"));
    }
}

fn goForward(target: Id, _: Sel, _: Id) callconv(.c) void {
    const webview = getIvar(target, "webView") orelse return;
    if (msg0(bool, webview, sel("canGoForward"))) {
        _ = msg0(Id, webview, sel("goForward"));
    }
}

fn newTab(target: Id, _: Sel, _: Id) callconv(.c) void {
    _ = target;
    webview_events.emitNewTabRequested();
    std.debug.print("new tab requested.\n", .{});
}

fn activateTab(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const tab_id = msg0(isize, sender, sel("tag"));
    if (tab_id <= 0) return;

    webview_events.emitTabActivatedRequested(@intCast(tab_id));
}

fn closeTab(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const tab_id = msg0(isize, sender, sel("tag"));
    if (tab_id <= 0) return;

    webview_events.emitTabClosedRequested(@intCast(tab_id));
}

fn windowDidResize(_: Id, _: Sel, _: Id) callconv(.c) void {
    renderTitlebarTabs(current_tab_snapshots.items) catch return;
}

fn reload(target: Id, _: Sel, _: Id) callconv(.c) void {
    const webview = getIvar(target, "webView") orelse return;

    if (webViewIsLoading(webview)) {
        _ = msg0(Id, webview, sel("stopLoading"));
        setWebViewLoading(webview, false);
        return;
    }

    if (webViewIsInternal(webview)) {
        loadInternalStartPage(webview) catch return;
        std.debug.print("reloaded internal start page.\n", .{});
        return;
    }

    _ = msg0(Id, webview, sel("reload"));
}

fn loadInternalStartPage(webview: Id) !void {
    const html_z = try std.heap.page_allocator.dupeZ(u8, start_page.html);
    _ = msg2(
        Id,
        webview,
        sel("loadHTMLString:baseURL:"),
        nsString(html_z),
        @as(Id, null),
    );
    noteInternalLoad(webview);
}

fn navigationStarted(target: Id, _: Sel, webview: Id, _: Id) callconv(.c) void {
    _ = target;
    setWebViewLoading(webview, true);
    updateAddressFromWebView(webview);
    updateWindowTitleFromWebView(webview);
    emitNavigationFromWebView(webview, .loading, null);
}

fn navigationChanged(target: Id, _: Sel, webview: Id, _: Id) callconv(.c) void {
    _ = target;
    updateAddressFromWebView(webview);
    emitNavigationFromWebView(webview, if (webViewIsLoading(webview)) .loading else .idle, null);
}

fn navigationFinished(target: Id, _: Sel, webview: Id, _: Id) callconv(.c) void {
    _ = target;
    setWebViewLoading(webview, false);
    updateAddressFromWebView(webview);
    updateWindowTitleFromWebView(webview);
    const favicon_url = updateFaviconFromWebView(webview);
    emitNavigationFromWebView(webview, .idle, favicon_url);
}

fn navigationFailed(target: Id, _: Sel, webview: Id, _: Id, _: Id) callconv(.c) void {
    _ = target;
    setWebViewLoading(webview, false);
    updateAddressFromWebView(webview);
    emitNavigationFromWebView(webview, .failed, null);
}

fn updateAddressFromWebView(webview: Id) void {
    const url = msg0(Id, webview, sel("URL"));
    if (url == null) {
        if (isActiveWebView(webview) and webViewIsInternal(webview)) setCurrentAddress("nimlo://start");
        return;
    }

    const absolute = msg0(Id, url, sel("absoluteString"));
    const raw = msg0(?[*:0]const u8, absolute, sel("UTF8String")) orelse return;
    const address = std.mem.span(raw);
    if (address.len == 0) return;

    if (webViewIsInternal(webview) and std.mem.startsWith(u8, address, "about:")) {
        if (!isActiveWebView(webview)) return;
        setCurrentAddress("nimlo://start");
        return;
    }

    setWebViewInternal(webview, false);
    if (!isActiveWebView(webview)) return;
    setCurrentAddress(address);
}

fn updateWindowTitleFromWebView(webview: Id) void {
    if (!isActiveWebView(webview)) return;

    if (webViewIsInternal(webview)) {
        setCurrentTabTitle("Nimlo");
        setWindowTitle("Nimlo");
        return;
    }

    const title = msg0(Id, webview, sel("title"));
    if (title == null) {
        setFallbackWindowTitleFromUrl(webview);
        return;
    }

    const raw = msg0(?[*:0]const u8, title, sel("UTF8String")) orelse {
        setFallbackWindowTitleFromUrl(webview);
        return;
    };
    const page_title = std.mem.span(raw);
    if (page_title.len == 0) {
        setFallbackWindowTitleFromUrl(webview);
        return;
    }

    const tab_title = std.heap.page_allocator.dupeZ(u8, page_title) catch return;
    setCurrentTabTitle(tab_title);

    const title_text = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s} - Nimlo",
        .{page_title},
    ) catch return;
    const full_title = std.heap.page_allocator.dupeZ(u8, title_text) catch return;
    setWindowTitle(full_title);
}

fn setFallbackWindowTitleFromUrl(webview: Id) void {
    if (!isActiveWebView(webview)) return;

    const fallback = titleFromWebViewUrl(webview) orelse "Nimlo";
    const tab_title = std.heap.page_allocator.dupeZ(u8, fallback) catch return;
    setCurrentTabTitle(tab_title);

    const title_text = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s} - Nimlo",
        .{fallback},
    ) catch return;
    const full_title = std.heap.page_allocator.dupeZ(u8, title_text) catch return;
    setWindowTitle(full_title);
}

fn setCurrentAddress(address: [:0]const u8) void {
    if (current_address_field) |address_field| {
        msg1(void, address_field, sel("setStringValue:"), nsString(address));
    }
}

fn setCurrentTabTitle(title: [:0]const u8) void {
    if (current_tab_label) |label| {
        msg1(void, label, sel("setTitle:"), nsString(title));
    }
}

fn setCurrentTabIcon(image: Id) void {
    if (current_tab_icon) |icon| {
        msg1(void, icon, sel("setImage:"), image);
    }
}

fn setWindowTitle(title: [:0]const u8) void {
    if (current_window) |window| {
        msg1(void, window, sel("setTitle:"), nsString(title));
    }
}

fn updateFaviconFromWebView(webview: Id) ?[:0]const u8 {
    if (webViewIsInternal(webview)) {
        if (isActiveWebView(webview)) setCurrentTabIcon(systemSymbol("sparkles", "Nimlo"));
        return "";
    }

    const favicon_url = declaredFaviconUrl(webview) orelse rootFaviconUrl(webview) orelse {
        if (isActiveWebView(webview)) setCurrentTabIcon(defaultFavicon());
        return null;
    };
    const ns_url = msg1(Id, cls("NSURL"), sel("URLWithString:"), nsString(favicon_url));
    if (ns_url == null) {
        if (isActiveWebView(webview)) setCurrentTabIcon(defaultFavicon());
        return null;
    }

    const image = msg1(Id, msg0(Id, cls("NSImage"), sel("alloc")), sel("initWithContentsOfURL:"), ns_url);
    if (isActiveWebView(webview)) setCurrentTabIcon(if (image) |value| value else defaultFavicon());
    return favicon_url;
}

fn declaredFaviconUrl(webview: Id) ?[:0]const u8 {
    const page_url = webViewUrl(webview) orelse return null;
    const page_url_z = std.heap.page_allocator.dupeZ(u8, page_url) catch return null;
    const ns_url = msg1(Id, cls("NSURL"), sel("URLWithString:"), nsString(page_url_z));
    if (ns_url == null) return null;

    const data = msg1(Id, cls("NSData"), sel("dataWithContentsOfURL:"), ns_url);
    if (data == null) return null;

    const html_value = msg2(
        Id,
        msg0(Id, cls("NSString"), sel("alloc")),
        sel("initWithData:encoding:"),
        data,
        NSUTF8StringEncoding,
    );
    if (html_value == null) return null;

    const raw_html = msg0(?[*:0]const u8, html_value, sel("UTF8String")) orelse return null;
    const href = findDeclaredIconHref(std.mem.span(raw_html)) orelse return null;
    return resolveFaviconUrl(page_url, href);
}

fn rootFaviconUrl(webview: Id) ?[:0]const u8 {
    const url = msg0(Id, webview, sel("URL"));
    if (url == null) return null;

    const scheme_value = msg0(Id, url, sel("scheme"));
    const host_value = msg0(Id, url, sel("host"));
    const raw_scheme = msg0(?[*:0]const u8, scheme_value, sel("UTF8String")) orelse return null;
    const raw_host = msg0(?[*:0]const u8, host_value, sel("UTF8String")) orelse return null;
    const scheme = std.mem.span(raw_scheme);
    const host = std.mem.span(raw_host);

    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return null;
    const favicon_url = std.fmt.allocPrint(std.heap.page_allocator, "{s}://{s}/favicon.ico", .{ scheme, host }) catch return null;
    return std.heap.page_allocator.dupeZ(u8, favicon_url) catch null;
}

fn defaultFavicon() Id {
    return systemSymbol("globe", "Website");
}

fn findDeclaredIconHref(html: []const u8) ?[]const u8 {
    var offset: usize = 0;
    while (indexOfIgnoreCase(html[offset..], "<link")) |relative_start| {
        const tag_start = offset + relative_start;
        const tag_end = std.mem.indexOfScalarPos(u8, html, tag_start, '>') orelse return null;
        const tag = html[tag_start .. tag_end + 1];

        const rel = attributeValue(tag, "rel");
        const href = attributeValue(tag, "href");
        if (rel != null and href != null and isIconRel(rel.?)) return href.?;

        offset = tag_end + 1;
    }

    return null;
}

fn attributeValue(tag: []const u8, wanted_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        while (i < tag.len and !isAttributeNameByte(tag[i])) : (i += 1) {}
        const name_start = i;
        while (i < tag.len and isAttributeNameByte(tag[i])) : (i += 1) {}
        if (name_start == i) break;

        const name = tag[name_start..i];
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len) return null;

        const quote = tag[i];
        if (quote == '"' or quote == '\'') {
            i += 1;
            const value_start = i;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            const value = tag[value_start..i];
            if (asciiEqlIgnoreCase(name, wanted_name)) return value;
        } else {
            const value_start = i;
            while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {}
            const value = tag[value_start..i];
            if (asciiEqlIgnoreCase(name, wanted_name)) return value;
        }
    }

    return null;
}

fn resolveFaviconUrl(page_url: []const u8, href: []const u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) {
        return std.heap.page_allocator.dupeZ(u8, href) catch null;
    }

    const scheme_end = std.mem.indexOf(u8, page_url, "://") orelse return null;
    const scheme = page_url[0..scheme_end];
    const authority_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, page_url, authority_start, '/') orelse page_url.len;
    const origin = page_url[0..path_start];

    if (std.mem.startsWith(u8, href, "//")) {
        const text = std.fmt.allocPrint(std.heap.page_allocator, "{s}:{s}", .{ scheme, href }) catch return null;
        return std.heap.page_allocator.dupeZ(u8, text) catch null;
    }

    if (std.mem.startsWith(u8, href, "/")) {
        const text = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ origin, href }) catch return null;
        return std.heap.page_allocator.dupeZ(u8, text) catch null;
    }

    const directory_end = std.mem.lastIndexOfScalar(u8, page_url[0..path_start], '/') orelse path_start;
    const text = if (directory_end > authority_start)
        std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ page_url[0 .. directory_end + 1], href }) catch return null
    else
        std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ origin, href }) catch return null;
    return std.heap.page_allocator.dupeZ(u8, text) catch null;
}

fn isIconRel(rel: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, rel, " \t\r\n");
    while (parts.next()) |part| {
        if (asciiEqlIgnoreCase(part, "icon") or asciiEqlIgnoreCase(part, "shortcut icon") or asciiEqlIgnoreCase(part, "apple-touch-icon")) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn asciiEqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (std.ascii.toLower(left_byte) != std.ascii.toLower(right_byte)) return false;
    }
    return true;
}

fn isAttributeNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':';
}

test "findDeclaredIconHref finds icon link href" {
    const html =
        \\<html><head>
        \\<link rel="stylesheet" href="/site.css">
        \\<link href="/icons/favicon.svg" rel="shortcut icon">
        \\</head></html>
    ;

    try std.testing.expectEqualStrings("/icons/favicon.svg", findDeclaredIconHref(html).?);
}

test "resolveFaviconUrl handles absolute and root-relative hrefs" {
    try std.testing.expectEqualStrings(
        "https://static.example.test/icon.svg",
        (resolveFaviconUrl("https://www.example.test/path/page.html", "//static.example.test/icon.svg") orelse return error.MissingResolvedUrl),
    );
    try std.testing.expectEqualStrings(
        "https://www.example.test/favicon.ico",
        (resolveFaviconUrl("https://www.example.test/path/page.html", "/favicon.ico") orelse return error.MissingResolvedUrl),
    );
}

fn emitNavigationFromWebView(webview: Id, loading_state: webview_events.LoadingState, favicon_url: ?[]const u8) void {
    var url_text: []const u8 = "";
    var title_text: []const u8 = "";

    if (webViewIsInternal(webview)) {
        url_text = "nimlo://start";
        title_text = "Nimlo";
    } else {
        if (webViewUrl(webview)) |url| {
            url_text = url;
        }

        title_text = webViewTitle(webview) orelse titleFromWebViewUrl(webview) orelse "";
    }

    if (url_text.len == 0) return;

    webview_events.emitNavigation(.{
        .source_handle = webview,
        .url = url_text,
        .title = title_text,
        .favicon_url = favicon_url orelse "",
        .loading_state = loading_state,
        .can_go_back = msg0(bool, webview, sel("canGoBack")),
        .can_go_forward = msg0(bool, webview, sel("canGoForward")),
    });
}

fn webViewUrl(webview: Id) ?[]const u8 {
    const url = msg0(Id, webview, sel("URL"));
    if (url == null) return null;

    const absolute = msg0(Id, url, sel("absoluteString"));
    const raw = msg0(?[*:0]const u8, absolute, sel("UTF8String")) orelse return null;
    return std.mem.span(raw);
}

fn webViewTitle(webview: Id) ?[]const u8 {
    const title = msg0(Id, webview, sel("title"));
    if (title == null) return null;

    const raw = msg0(?[*:0]const u8, title, sel("UTF8String")) orelse return null;
    const text = std.mem.span(raw);
    return if (text.len == 0) null else text;
}

fn titleFromWebViewUrl(webview: Id) ?[]const u8 {
    const url = webViewUrl(webview) orelse return null;
    if (std.mem.eql(u8, url, "nimlo://start")) return "Nimlo";

    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const host_start = scheme_end + 3;
    const host_end = std.mem.indexOfAnyPos(u8, url, host_start, "/?#") orelse url.len;
    if (host_start >= host_end) return url;

    return url[host_start..host_end];
}

fn activeWebView() Id {
    return getIvar(current_webview_target, "webView");
}

fn isActiveWebView(webview: Id) bool {
    return webview != null and webview == activeWebView();
}

fn ensureWebViewChromeState(webview: Id) !*WebViewChromeState {
    if (webview == null) return error.MacOSWebViewUnavailable;

    for (webview_chrome_states.items) |*state| {
        if (state.webview == webview) return state;
    }

    try webview_chrome_states.append(std.heap.page_allocator, .{ .webview = webview });
    return &webview_chrome_states.items[webview_chrome_states.items.len - 1];
}

fn webViewChromeState(webview: Id) ?*WebViewChromeState {
    if (webview == null) return null;

    for (webview_chrome_states.items) |*state| {
        if (state.webview == webview) return state;
    }

    return null;
}

fn setWebViewInternal(webview: Id, is_internal: bool) void {
    const state = ensureWebViewChromeState(webview) catch return;
    state.is_internal = is_internal;
}

fn webViewIsInternal(webview: Id) bool {
    return if (webViewChromeState(webview)) |state| state.is_internal else false;
}

fn setWebViewLoading(webview: Id, is_loading: bool) void {
    const state = ensureWebViewChromeState(webview) catch return;
    state.is_loading = is_loading;

    if (isActiveWebView(webview)) setLoadingState(is_loading);
}

fn webViewIsLoading(webview: Id) bool {
    return if (webViewChromeState(webview)) |state| state.is_loading else false;
}

fn setLoadingState(is_loading: bool) void {
    if (current_reload_button) |button| {
        if (is_loading) {
            setToolbarButtonSymbol(button, "xmark", "Stop");
        } else {
            setToolbarButtonSymbol(button, "arrow.clockwise", "Reload");
        }
    }
}

fn setToolbarButtonSymbol(button: Id, symbol_name: [:0]const u8, tooltip: [:0]const u8) void {
    const symbol = systemSymbol(symbol_name, tooltip);
    const image = if (symbol) |value| value else fallbackSymbolImage(symbol_name);
    if (image != null) {
        msg1(void, button, sel("setImage:"), image);
        msg1(void, button, sel("setTitle:"), nsString(""));
    } else {
        msg1(void, button, sel("setTitle:"), nsString(fallbackButtonTitle(symbol_name)));
    }
    msg1(void, button, sel("setToolTip:"), nsString(tooltip));
}

fn getIvar(object: Id, name: [:0]const u8) Id {
    if (object == null) return null;

    var value: ?*anyopaque = null;
    _ = c.object_getInstanceVariable(@ptrCast(@alignCast(object.?)), name, &value);
    return value;
}

fn cls(name: [:0]const u8) Class {
    return @ptrCast(c.objc_getClass(name));
}

fn sel(name: [:0]const u8) Sel {
    return @ptrCast(c.sel_registerName(name));
}

fn nsString(value: [:0]const u8) Id {
    return msg1(Id, cls("NSString"), sel("stringWithUTF8String:"), value.ptr);
}

fn msg0(comptime ReturnType: type, receiver: Id, selector: Sel) ReturnType {
    const Fn = *const fn (Id, Sel) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector);
}

fn msg1(comptime ReturnType: type, receiver: Id, selector: Sel, arg1: anytype) ReturnType {
    const Arg1 = @TypeOf(arg1);
    const Fn = *const fn (Id, Sel, Arg1) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, arg1);
}

fn msg2(comptime ReturnType: type, receiver: Id, selector: Sel, arg1: anytype, arg2: anytype) ReturnType {
    const Arg1 = @TypeOf(arg1);
    const Arg2 = @TypeOf(arg2);
    const Fn = *const fn (Id, Sel, Arg1, Arg2) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, arg1, arg2);
}

fn msg4(comptime ReturnType: type, receiver: Id, selector: Sel, arg1: anytype, arg2: anytype, arg3: anytype, arg4: anytype) ReturnType {
    const Arg1 = @TypeOf(arg1);
    const Arg2 = @TypeOf(arg2);
    const Arg3 = @TypeOf(arg3);
    const Arg4 = @TypeOf(arg4);
    const Fn = *const fn (Id, Sel, Arg1, Arg2, Arg3, Arg4) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, arg1, arg2, arg3, arg4);
}
