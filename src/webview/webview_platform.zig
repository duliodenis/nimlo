const builtin = @import("builtin");

pub const PlatformWebView = switch (builtin.os.tag) {
    .macos => @import("webview_macos.zig").MacOSWebView,
    .windows => @import("webview_win32.zig").Win32WebView,
    else => @import("webview_stub.zig").StubWebView,
};
