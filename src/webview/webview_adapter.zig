const platform = @import("webview_platform.zig");
const webview_events = @import("webview_events.zig");

pub const EventSink = webview_events.EventSink;

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

    pub fn loadHtml(self: *WebViewAdapter, html: []const u8, base_url: []const u8) !void {
        try self.platform.loadHtml(html, base_url);
    }

    pub fn createWebView(self: *WebViewAdapter) !?*anyopaque {
        return try self.platform.createWebView();
    }

    pub fn showWebView(self: *WebViewAdapter, handle: ?*anyopaque) void {
        self.platform.showWebView(handle);
    }

    pub fn destroyWebView(self: *WebViewAdapter, handle: ?*anyopaque) void {
        self.platform.destroyWebView(handle);
    }

    pub fn activeHandle(self: *WebViewAdapter) ?*anyopaque {
        return self.platform.activeHandle();
    }

    pub fn setEventSink(self: *WebViewAdapter, sink: EventSink) void {
        _ = self;
        webview_events.setSink(sink);
    }
};
