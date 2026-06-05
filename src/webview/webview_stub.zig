const std = @import("std");

pub const StubWebView = struct {
    pub fn init() StubWebView {
        return .{};
    }

    pub fn attachToWindow(self: *StubWebView, window_handle: ?*anyopaque) !void {
        _ = self;
        _ = window_handle;
        std.debug.print("WebView scaffold attached.\n", .{});
        // TODO(webview adapter): add a platform WebView implementation for this OS.
    }

    pub fn load(self: *StubWebView, url: []const u8) !void {
        _ = self;
        _ = url;
    }

    pub fn loadHtml(self: *StubWebView, html: []const u8, base_url: []const u8) !void {
        _ = self;
        _ = html;
        _ = base_url;
    }

    pub fn createWebView(self: *StubWebView) !?*anyopaque {
        _ = self;
        return null;
    }

    pub fn showWebView(self: *StubWebView, handle: ?*anyopaque) void {
        _ = self;
        _ = handle;
    }

    pub fn destroyWebView(self: *StubWebView, handle: ?*anyopaque) void {
        _ = self;
        _ = handle;
    }

    pub fn activeHandle(self: *StubWebView) ?*anyopaque {
        _ = self;
        return null;
    }
};
