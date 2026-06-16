const platform_window = @import("window_platform.zig");
const webview = @import("../webview/webview_adapter.zig");

pub const WindowOptions = struct {
    title: []const u8,
    width: u32,
    height: u32,
};

pub const AppWindow = struct {
    platform: platform_window.PlatformWindow,

    pub fn create(options: WindowOptions) !AppWindow {
        return .{
            .platform = try platform_window.PlatformWindow.create(options),
        };
    }

    pub fn attachWebView(self: *AppWindow, adapter: *webview.WebViewAdapter) !void {
        try adapter.attachToWindow(self.nativeHandle());
    }

    pub fn present(self: *AppWindow) !void {
        try self.platform.present();
    }

    pub fn focus(self: *AppWindow) !void {
        try self.platform.focus();
    }

    pub fn close(self: *AppWindow) void {
        self.platform.close();
    }

    pub fn runEventLoop(self: *AppWindow) !void {
        try self.platform.runEventLoop();
    }

    pub fn show(self: *AppWindow) !void {
        try self.platform.show();
    }

    pub fn nativeHandle(self: *AppWindow) ?*anyopaque {
        return self.platform.nativeHandle();
    }
};
