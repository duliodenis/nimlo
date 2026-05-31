const builtin = @import("builtin");

pub const PlatformWebView = switch (builtin.os.tag) {
    .macos => @import("webview_macos.zig").MacOSWebView,
    else => @import("webview_stub.zig").StubWebView,
};
