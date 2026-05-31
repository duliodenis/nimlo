const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const webview = @import("../webview/webview_adapter.zig");

pub const Browser = struct {
    preferences: preferences.Preferences,
    private_mode: private_mode.PrivateModeConfig,
    webview_adapter: *webview.WebViewAdapter,

    pub fn init(
        prefs: preferences.Preferences,
        privacy: private_mode.PrivateModeConfig,
        adapter: *webview.WebViewAdapter,
    ) Browser {
        return .{
            .preferences = prefs,
            .private_mode = privacy,
            .webview_adapter = adapter,
        };
    }

    pub fn start(self: *Browser) !void {
        _ = self;
        // TODO(browser core): add navigation, tabs, URL/search routing, and browser events.
    }
};
