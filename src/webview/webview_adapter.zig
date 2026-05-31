const platform = @import("webview_platform.zig");

pub const WebViewAdapter = struct {
    platform: platform.PlatformWebView,

    pub fn init() WebViewAdapter {
        return .{
            .platform = platform.PlatformWebView.init(),
        };
    }

    pub fn attachToWindow(self: *WebViewAdapter, window_handle: ?*anyopaque) !void {
        try self.platform.attachToWindow(window_handle);
    }

    pub fn load(self: *WebViewAdapter, url: []const u8) !void {
        try self.platform.load(url);
    }
};
