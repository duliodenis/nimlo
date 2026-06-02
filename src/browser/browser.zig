const std = @import("std");
const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const tab_manager = @import("tab_manager.zig");
const tab_model = @import("tab.zig");
const webview = @import("../webview/webview_adapter.zig");
const webview_events = @import("../webview/webview_events.zig");

pub const Browser = struct {
    allocator: std.mem.Allocator,
    preferences: preferences.Preferences,
    private_mode: private_mode.PrivateModeConfig,
    tabs: tab_manager.TabManager,
    webview_adapter: *webview.WebViewAdapter,

    pub fn init(
        prefs: preferences.Preferences,
        privacy: private_mode.PrivateModeConfig,
        adapter: *webview.WebViewAdapter,
    ) Browser {
        const allocator = std.heap.page_allocator;

        return .{
            .allocator = allocator,
            .preferences = prefs,
            .private_mode = privacy,
            .tabs = tab_manager.TabManager.init(allocator),
            .webview_adapter = adapter,
        };
    }

    pub fn start(self: *Browser) !void {
        if (self.tabs.len() == 0) {
            _ = try self.tabs.createTab(
                self.preferences.homepage_url,
                self.private_mode.enabled,
            );
        }

        self.webview_adapter.setEventSink(.{
            .context = self,
            .on_navigation = handleNavigationEvent,
        });
    }

    pub fn deinit(self: *Browser) void {
        webview_events.clearSink();
        self.tabs.deinit();
    }

    fn handleNavigationEvent(context: *anyopaque, event: webview_events.NavigationEvent) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        const active_tab = self.tabs.activeTab() orelse return;

        const url = self.allocator.dupe(u8, event.url) catch return;
        const title = self.allocator.dupe(u8, event.title) catch "";

        active_tab.updateNavigation(.{
            .current_url = url,
            .title = title,
            .loading_state = mapLoadingState(event.loading_state),
            .can_go_back = event.can_go_back,
            .can_go_forward = event.can_go_forward,
        });
    }

    fn mapLoadingState(state: webview_events.LoadingState) tab_model.LoadingState {
        return switch (state) {
            .idle => .idle,
            .loading => .loading,
            .failed => .failed,
        };
    }
};

test "start creates one active startup tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();

    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    const active_tab = browser.tabs.activeTab().?;
    try std.testing.expectEqualStrings("nimlo://start", active_tab.current_url);
    try std.testing.expectEqual(tab_model.LoadingState.idle, active_tab.loading_state);
}

test "navigation event updates active tab state" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitNavigation(.{
        .url = "https://example.com/docs",
        .title = "Example Docs",
        .loading_state = .idle,
        .can_go_back = true,
        .can_go_forward = false,
    });

    const active_tab = browser.tabs.activeTab().?;
    try std.testing.expectEqualStrings("https://example.com/docs", active_tab.current_url);
    try std.testing.expectEqualStrings("Example Docs", active_tab.title);
    try std.testing.expectEqual(tab_model.LoadingState.idle, active_tab.loading_state);
    try std.testing.expect(active_tab.can_go_back);
    try std.testing.expect(!active_tab.can_go_forward);
}

test "navigation event maps loading state" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example",
        .loading_state = .loading,
    });
    try std.testing.expectEqual(tab_model.LoadingState.loading, browser.tabs.activeTab().?.loading_state);

    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example",
        .loading_state = .failed,
    });
    try std.testing.expectEqual(tab_model.LoadingState.failed, browser.tabs.activeTab().?.loading_state);

    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example",
        .loading_state = .idle,
    });
    try std.testing.expectEqual(tab_model.LoadingState.idle, browser.tabs.activeTab().?.loading_state);
}

test "start does not create duplicate startup tabs" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    try browser.start();

    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
}
