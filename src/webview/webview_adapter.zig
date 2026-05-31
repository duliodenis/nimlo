pub const WebViewAdapter = struct {
    pub fn init() WebViewAdapter {
        return .{};
    }

    pub fn load(self: *WebViewAdapter, url: []const u8) !void {
        _ = self;
        _ = url;
        // TODO(webview adapter): call the platform WebView implementation.
    }
};
