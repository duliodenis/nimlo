const std = @import("std");
const browser = @import("../browser/browser.zig");
const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const window = @import("window.zig");
const webview = @import("../webview/webview_adapter.zig");

pub fn run() !void {
    const config = preferences.Preferences.default();
    const privacy = private_mode.PrivateModeConfig.default();
    var app_window = try window.AppWindow.create(.{
        .title = "Nimlo",
        .width = 1024,
        .height = 768,
    });
    var engine = webview.WebViewAdapter.init();
    var core = browser.Browser.init(config, privacy, &engine);

    // TODO(app shell): add browser chrome, commands, menus, and shortcuts.
    // TODO(webview): replace the scaffold with a real system WebView mount.
    try app_window.attachWebView(&engine);
    try core.start();
    try app_window.show();

    std.debug.print("Nimlo app shell placeholder ready.\n", .{});
}
