const std = @import("std");
const url_input = @import("../browser/url_input.zig");
const start_page = @import("../ui/start_page.zig");

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Class = ?*anyopaque;

const CGFloat = f64;

const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

const toolbar_height: CGFloat = 48;
const address_field_height: CGFloat = 28;
const address_field_margin: CGFloat = 12;

const NSViewMinYMargin: usize = 1 << 3;
const NSViewWidthSizable: usize = 1 << 1;
const NSViewHeightSizable: usize = 1 << 4;
const NSViewFlexibleSize = NSViewWidthSizable | NSViewHeightSizable;
const NSViewTopPinnedWidth = NSViewMinYMargin | NSViewWidthSizable;
const objc_pointer_alignment_log2: u8 = 3;

extern "c" fn objc_msgSend() void;

pub const MacOSWebView = struct {
    window_handle: Id = null,
    handle: Id = null,

    pub fn init() MacOSWebView {
        return .{};
    }

    pub fn attachToWindow(self: *MacOSWebView, window_handle: ?*anyopaque) !void {
        self.window_handle = window_handle;
        if (window_handle == null) return error.MacOSWindowHandleUnavailable;
        installAddressBarTargetClass();

        const content_view = msg0(Id, window_handle, sel("contentView"));
        if (content_view == null) return error.MacOSContentViewUnavailable;

        const bounds = msg0(CGRect, content_view, sel("bounds"));
        const webview_frame = CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = bounds.size.width,
                .height = @max(1, bounds.size.height - toolbar_height),
            },
        };
        const configuration = msg0(Id, msg0(Id, cls("WKWebViewConfiguration"), sel("alloc")), sel("init"));
        const webview = msg2(
            Id,
            msg0(Id, cls("WKWebView"), sel("alloc")),
            sel("initWithFrame:configuration:"),
            webview_frame,
            configuration,
        );
        if (webview == null) return error.MacOSWebViewUnavailable;

        msg1(void, webview, sel("setAutoresizingMask:"), NSViewFlexibleSize);
        msg1(void, content_view, sel("addSubview:"), webview);
        self.handle = webview;

        const address_field = try addAddressField(content_view, bounds, webview);
        msg1(void, window_handle, sel("makeFirstResponder:"), address_field);

        std.debug.print("macOS WKWebView attached to NSWindow.\n", .{});
        // TODO(webview adapter): report page load, title, URL, and navigation state events.
    }

    pub fn load(self: *MacOSWebView, url: []const u8) !void {
        if (self.handle == null) return error.MacOSWebViewUnavailable;

        const url_z = try std.heap.page_allocator.dupeZ(u8, url);
        const ns_url = msg1(Id, cls("NSURL"), sel("URLWithString:"), nsString(url_z));
        if (ns_url == null) return error.MacOSInvalidURL;

        const request = msg1(Id, cls("NSURLRequest"), sel("requestWithURL:"), ns_url);
        if (request == null) return error.MacOSURLRequestUnavailable;

        _ = msg1(Id, self.handle, sel("loadRequest:"), request);
        std.debug.print("macOS WKWebView loading: {s}\n", .{url});
    }

    pub fn loadHtml(self: *MacOSWebView, html: []const u8, base_url: []const u8) !void {
        if (self.handle == null) return error.MacOSWebViewUnavailable;

        const html_z = try std.heap.page_allocator.dupeZ(u8, html);

        // Keep Nimlo's internal route out of LaunchServices until we explicitly
        // register and handle the nimlo:// URL scheme.
        _ = msg2(
            Id,
            self.handle,
            sel("loadHTMLString:baseURL:"),
            nsString(html_z),
            @as(Id, null),
        );
        std.debug.print("macOS WKWebView loading internal page: {s}\n", .{base_url});
    }
};

fn addAddressField(content_view: Id, bounds: CGRect, webview: Id) !Id {
    const address_frame = CGRect{
        .origin = .{
            .x = address_field_margin,
            .y = bounds.size.height - toolbar_height + ((toolbar_height - address_field_height) / 2),
        },
        .size = .{
            .width = @max(1, bounds.size.width - (address_field_margin * 2)),
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

    const target = msg0(Id, msg0(Id, cls("NimloAddressBarTarget"), sel("alloc")), sel("init"));
    if (target == null) return error.MacOSAddressTargetUnavailable;

    _ = msg0(Id, target, sel("retain"));
    _ = c.object_setInstanceVariable(@ptrCast(@alignCast(target.?)), "addressField", text_field);
    _ = c.object_setInstanceVariable(@ptrCast(@alignCast(target.?)), "webView", webview);

    msg1(void, text_field, sel("setAutoresizingMask:"), NSViewTopPinnedWidth);
    msg1(void, text_field, sel("setPlaceholderString:"), nsString("Search or enter URL"));
    msg1(void, text_field, sel("setTarget:"), target);
    msg1(void, text_field, sel("setAction:"), sel("addressSubmitted:"));
    msg1(void, content_view, sel("addSubview:"), text_field);

    return text_field;
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
        const html_z = std.heap.page_allocator.dupeZ(u8, start_page.html) catch return;
        msg1(void, address_field, sel("setStringValue:"), nsString("nimlo://start"));
        _ = msg2(
            Id,
            webview,
            sel("loadHTMLString:baseURL:"),
            nsString(html_z),
            @as(Id, null),
        );
        std.debug.print("address bar loading internal page: {s}\n", .{normalized});
        return;
    }

    const url_z = std.heap.page_allocator.dupeZ(u8, normalized) catch return;
    const ns_url = msg1(Id, cls("NSURL"), sel("URLWithString:"), nsString(url_z));
    if (ns_url == null) return;

    const request = msg1(Id, cls("NSURLRequest"), sel("requestWithURL:"), ns_url);
    if (request == null) return;

    msg1(void, address_field, sel("setStringValue:"), nsString(url_z));
    _ = msg1(Id, webview, sel("loadRequest:"), request);
    std.debug.print("address bar loading: {s}\n", .{normalized});
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
