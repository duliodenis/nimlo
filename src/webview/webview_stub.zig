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
};
