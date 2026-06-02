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
const tab_height: CGFloat = 28;
const tab_icon_size: CGFloat = 16;
const tab_margin: CGFloat = 12;
const tab_label_x: CGFloat = 28;

const NSButtonTypeMomentaryChange: usize = 5;
const NSImageScaleProportionallyDown: isize = 1;
const NSImageSymbolScaleMedium: isize = 2;
const NSLayoutAttributeLeft: isize = 1;
const NSTextAlignmentCenter: isize = 1;
const NSUTF8StringEncoding: usize = 4;

const NSViewMinYMargin: usize = 1 << 3;
const NSViewWidthSizable: usize = 1 << 1;
const NSViewTopPinned = NSViewMinYMargin;
const NSViewTopPinnedWidth = NSViewMinYMargin | NSViewWidthSizable;
const objc_pointer_alignment_log2: u8 = 3;

extern "c" fn objc_msgSend() void;

// TODO(browser core): replace this single-window flag with real navigation state.
var current_page_is_internal = false;
var current_address_field: Id = null;
var current_reload_button: Id = null;
var current_tab_icon: Id = null;
var current_tab_label: Id = null;
var current_window: Id = null;
var current_page_is_loading = false;

pub fn install(window_handle: Id, content_view: Id, bounds: CGRect, webview: Id) !Id {
    current_window = window_handle;
    installAddressBarTargetClass();
    const address_field = try addToolbar(content_view, bounds, webview);
    msg1(void, window_handle, sel("makeFirstResponder:"), address_field);
    return address_field;
}

pub fn noteExternalLoad() void {
    current_page_is_internal = false;
    setCurrentTabIcon(defaultFavicon());
}

pub fn noteInternalLoad() void {
    current_page_is_internal = true;
    setCurrentAddress("nimlo://start");
    setCurrentTabIcon(systemSymbol("sparkles", "Nimlo"));
    setCurrentTabTitle("Nimlo");
    setWindowTitle("Nimlo");
    webview_events.emitNavigation(.{
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

    try addTitlebarTabStrip(current_window orelse return error.MacOSWindowUnavailable);

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
    msg1(void, webview, sel("setNavigationDelegate:"), target);

    return text_field;
}

fn addTitlebarTabStrip(window_handle: Id) !void {
    const container_frame = CGRect{
        .origin = .{
            .x = 0,
            .y = 0,
        },
        .size = .{ .width = tab_width + tab_margin, .height = tab_strip_height },
    };
    const container = msg1(
        Id,
        msg0(Id, cls("NSView"), sel("alloc")),
        sel("initWithFrame:"),
        container_frame,
    );
    if (container == null) return error.MacOSTabStripUnavailable;

    const icon_frame = CGRect{
        .origin = .{
            .x = 7,
            .y = (tab_strip_height - tab_icon_size) / 2,
        },
        .size = .{ .width = tab_icon_size, .height = tab_icon_size },
    };
    const icon = msg1(
        Id,
        msg0(Id, cls("NSImageView"), sel("alloc")),
        sel("initWithFrame:"),
        icon_frame,
    );
    if (icon == null) return error.MacOSTabIconUnavailable;

    const tab_frame = CGRect{
        .origin = .{
            .x = tab_label_x,
            .y = (tab_strip_height - tab_height) / 2,
        },
        .size = .{ .width = tab_width - tab_label_x, .height = tab_height },
    };
    const label = msg1(
        Id,
        msg0(Id, cls("NSTextField"), sel("alloc")),
        sel("initWithFrame:"),
        tab_frame,
    );
    if (label == null) return error.MacOSTabLabelUnavailable;

    current_tab_icon = icon;
    current_tab_label = label;

    msg1(void, icon, sel("setImageScaling:"), NSImageScaleProportionallyDown);
    msg1(void, icon, sel("setImage:"), systemSymbol("sparkles", "Nimlo"));
    msg1(void, container, sel("addSubview:"), icon);

    msg1(void, label, sel("setAutoresizingMask:"), NSViewTopPinned);
    msg1(void, label, sel("setStringValue:"), nsString("Nimlo"));
    msg1(void, label, sel("setEditable:"), false);
    msg1(void, label, sel("setSelectable:"), false);
    msg1(void, label, sel("setBezeled:"), true);
    msg1(void, label, sel("setAlignment:"), NSTextAlignmentCenter);
    msg1(void, label, sel("setFont:"), msg1(Id, cls("NSFont"), sel("systemFontOfSize:"), @as(CGFloat, 13)));
    msg1(void, container, sel("addSubview:"), label);

    const controller = msg0(Id, msg0(Id, cls("NSTitlebarAccessoryViewController"), sel("alloc")), sel("init"));
    if (controller == null) return error.MacOSTitlebarAccessoryUnavailable;

    msg1(void, controller, sel("setView:"), container);
    msg1(void, controller, sel("setLayoutAttribute:"), NSLayoutAttributeLeft);
    msg1(void, window_handle, sel("addTitlebarAccessoryViewController:"), controller);
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

    c.objc_registerClassPair(target_class);
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
    noteExternalLoad();
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

fn reload(target: Id, _: Sel, _: Id) callconv(.c) void {
    const webview = getIvar(target, "webView") orelse return;

    if (current_page_is_loading) {
        _ = msg0(Id, webview, sel("stopLoading"));
        setLoadingState(false);
        return;
    }

    if (current_page_is_internal) {
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
    noteInternalLoad();
}

fn navigationStarted(target: Id, _: Sel, webview: Id, _: Id) callconv(.c) void {
    _ = target;
    setLoadingState(true);
    updateAddressFromWebView(webview);
    emitNavigationFromWebView(webview, .loading);
}

fn navigationChanged(target: Id, _: Sel, webview: Id, _: Id) callconv(.c) void {
    _ = target;
    updateAddressFromWebView(webview);
    emitNavigationFromWebView(webview, if (current_page_is_loading) .loading else .idle);
}

fn navigationFinished(target: Id, _: Sel, webview: Id, _: Id) callconv(.c) void {
    _ = target;
    setLoadingState(false);
    updateAddressFromWebView(webview);
    updateWindowTitleFromWebView(webview);
    updateFaviconFromWebView(webview);
    emitNavigationFromWebView(webview, .idle);
}

fn navigationFailed(target: Id, _: Sel, webview: Id, _: Id, _: Id) callconv(.c) void {
    _ = target;
    setLoadingState(false);
    updateAddressFromWebView(webview);
    emitNavigationFromWebView(webview, .failed);
}

fn updateAddressFromWebView(webview: Id) void {
    const url = msg0(Id, webview, sel("URL"));
    if (url == null) {
        if (current_page_is_internal) setCurrentAddress("nimlo://start");
        return;
    }

    const absolute = msg0(Id, url, sel("absoluteString"));
    const raw = msg0(?[*:0]const u8, absolute, sel("UTF8String")) orelse return;
    const address = std.mem.span(raw);
    if (address.len == 0) return;

    if (current_page_is_internal and std.mem.startsWith(u8, address, "about:")) {
        setCurrentAddress("nimlo://start");
        return;
    }

    current_page_is_internal = false;
    setCurrentAddress(address);
}

fn updateWindowTitleFromWebView(webview: Id) void {
    if (current_page_is_internal) {
        setCurrentTabTitle("Nimlo");
        setWindowTitle("Nimlo");
        return;
    }

    const title = msg0(Id, webview, sel("title"));
    if (title == null) {
        setCurrentTabTitle("Nimlo");
        setWindowTitle("Nimlo");
        return;
    }

    const raw = msg0(?[*:0]const u8, title, sel("UTF8String")) orelse {
        setCurrentTabTitle("Nimlo");
        setWindowTitle("Nimlo");
        return;
    };
    const page_title = std.mem.span(raw);
    if (page_title.len == 0) {
        setCurrentTabTitle("Nimlo");
        setWindowTitle("Nimlo");
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

fn setCurrentAddress(address: [:0]const u8) void {
    if (current_address_field) |address_field| {
        msg1(void, address_field, sel("setStringValue:"), nsString(address));
    }
}

fn setCurrentTabTitle(title: [:0]const u8) void {
    if (current_tab_label) |label| {
        msg1(void, label, sel("setStringValue:"), nsString(title));
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

fn updateFaviconFromWebView(webview: Id) void {
    if (current_page_is_internal) {
        setCurrentTabIcon(systemSymbol("sparkles", "Nimlo"));
        return;
    }

    const favicon_url = declaredFaviconUrl(webview) orelse rootFaviconUrl(webview) orelse {
        setCurrentTabIcon(defaultFavicon());
        return;
    };
    const ns_url = msg1(Id, cls("NSURL"), sel("URLWithString:"), nsString(favicon_url));
    if (ns_url == null) {
        setCurrentTabIcon(defaultFavicon());
        return;
    }

    const image = msg1(Id, msg0(Id, cls("NSImage"), sel("alloc")), sel("initWithContentsOfURL:"), ns_url);
    setCurrentTabIcon(if (image) |value| value else defaultFavicon());
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

fn emitNavigationFromWebView(webview: Id, loading_state: webview_events.LoadingState) void {
    var url_text: []const u8 = "";
    var title_text: []const u8 = "";

    if (current_page_is_internal) {
        url_text = "nimlo://start";
        title_text = "Nimlo";
    } else {
        if (webViewUrl(webview)) |url| {
            url_text = url;
        }

        if (webViewTitle(webview)) |title| {
            title_text = title;
        }
    }

    if (url_text.len == 0) return;

    webview_events.emitNavigation(.{
        .url = url_text,
        .title = title_text,
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

fn setLoadingState(is_loading: bool) void {
    current_page_is_loading = is_loading;

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
