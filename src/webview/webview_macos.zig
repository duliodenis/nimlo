const std = @import("std");
const chrome = @import("../ui/chrome_macos.zig");

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Class = ?*anyopaque;

const NSViewWidthSizable: usize = 1 << 1;
const NSViewHeightSizable: usize = 1 << 4;
const NSViewFlexibleSize = NSViewWidthSizable | NSViewHeightSizable;

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

        const content_view = msg0(Id, window_handle, sel("contentView"));
        if (content_view == null) return error.MacOSContentViewUnavailable;

        const bounds = msg0(chrome.CGRect, content_view, sel("bounds"));
        const webview_frame = chrome.CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = bounds.size.width,
                .height = @max(1, bounds.size.height - chrome.toolbar_height),
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

        _ = try chrome.install(window_handle, content_view, bounds, webview);

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

        chrome.noteExternalLoad();
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
        chrome.noteInternalLoad();
        std.debug.print("macOS WKWebView loading internal page: {s}\n", .{base_url});
    }
};

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
