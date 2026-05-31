const std = @import("std");

pub const MacOSWebView = struct {
    window_handle: ?*anyopaque = null,

    pub fn init() MacOSWebView {
        return .{};
    }

    pub fn attachToWindow(self: *MacOSWebView, window_handle: ?*anyopaque) !void {
        self.window_handle = window_handle;
        std.debug.print("macOS WebView scaffold attached.\n", .{});
        // TODO(webview adapter): create WKWebView and attach it to the NSWindow content view.
        // TODO(webview adapter): report page load, title, URL, and navigation state events.
    }

    pub fn load(self: *MacOSWebView, url: []const u8) !void {
        _ = self;
        _ = url;
        // TODO(webview adapter): call WKWebView loadRequest for http/https URLs.
    }
};
