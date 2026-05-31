const std = @import("std");
const browser = @import("../browser/browser.zig");
const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const webview = @import("../webview/webview_adapter.zig");

pub fn run() !void {
    const config = preferences.Preferences.default();
    const privacy = private_mode.PrivateModeConfig.default();
    var engine = webview.WebViewAdapter.init();
    var core = browser.Browser.init(config, privacy, &engine);

    // TODO(app shell): create the desktop window, browser chrome, commands, and shortcuts.
    // TODO(webview): mount a system WebView in the app shell when platform bindings exist.
    try core.start();

    std.debug.print("Nimlo app shell placeholder ready.\n", .{});
}
