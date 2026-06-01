const std = @import("std");
const url_input = @import("../browser/url_input.zig");
const start_page = @import("start_page.zig");

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

pub const toolbar_height: CGFloat = 48;

const address_field_height: CGFloat = 28;
const address_field_margin: CGFloat = 12;
const nav_button_size: CGFloat = 28;
const nav_button_gap: CGFloat = 8;

const NSViewMinYMargin: usize = 1 << 3;
const NSViewWidthSizable: usize = 1 << 1;
const NSViewTopPinned = NSViewMinYMargin;
const NSViewTopPinnedWidth = NSViewMinYMargin | NSViewWidthSizable;
const objc_pointer_alignment_log2: u8 = 3;

extern "c" fn objc_msgSend() void;

// TODO(browser core): replace this single-window flag with real navigation state.
var current_page_is_internal = false;

pub fn install(window_handle: Id, content_view: Id, bounds: CGRect, webview: Id) !Id {
    installAddressBarTargetClass();
    const address_field = try addToolbar(content_view, bounds, webview);
    msg1(void, window_handle, sel("makeFirstResponder:"), address_field);
    return address_field;
}

pub fn noteExternalLoad() void {
    current_page_is_internal = false;
}

pub fn noteInternalLoad() void {
    current_page_is_internal = true;
}

fn addToolbar(content_view: Id, bounds: CGRect, webview: Id) !Id {
    const target = msg0(Id, msg0(Id, cls("NimloAddressBarTarget"), sel("alloc")), sel("init"));
    if (target == null) return error.MacOSAddressTargetUnavailable;

    _ = msg0(Id, target, sel("retain"));
    _ = c.object_setInstanceVariable(@ptrCast(@alignCast(target.?)), "webView", webview);

    const button_y = toolbarControlY(bounds, nav_button_size);
    var button_x = address_field_margin;

    try addToolbarButton(content_view, target, "<", "Back", "goBack:", button_x, button_y);
    button_x += nav_button_size + nav_button_gap;
    try addToolbarButton(content_view, target, ">", "Forward", "goForward:", button_x, button_y);
    button_x += nav_button_size + nav_button_gap;
    try addToolbarButton(content_view, target, "R", "Reload", "reload:", button_x, button_y);

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

    msg1(void, text_field, sel("setAutoresizingMask:"), NSViewTopPinnedWidth);
    msg1(void, text_field, sel("setPlaceholderString:"), nsString("Search or enter URL"));
    msg1(void, text_field, sel("setTarget:"), target);
    msg1(void, text_field, sel("setAction:"), sel("addressSubmitted:"));
    msg1(void, content_view, sel("addSubview:"), text_field);

    return text_field;
}

fn addToolbarButton(
    content_view: Id,
    target: Id,
    title: [:0]const u8,
    tooltip: [:0]const u8,
    action: [:0]const u8,
    x: CGFloat,
    y: CGFloat,
) !void {
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

    msg1(void, button, sel("setAutoresizingMask:"), NSViewTopPinned);
    msg1(void, button, sel("setTitle:"), nsString(title));
    msg1(void, button, sel("setToolTip:"), nsString(tooltip));
    msg1(void, button, sel("setTarget:"), target);
    msg1(void, button, sel("setAction:"), sel(action));
    msg1(void, content_view, sel("addSubview:"), button);
}

fn toolbarControlY(bounds: CGRect, height: CGFloat) CGFloat {
    return bounds.size.height - toolbar_height + ((toolbar_height - height) / 2);
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
