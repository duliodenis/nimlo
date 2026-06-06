const std = @import("std");
const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const tab_manager = @import("tab_manager.zig");
const tab_model = @import("tab.zig");
const about_page = @import("../ui/about_page.zig");
const start_page = @import("../ui/start_page.zig");
const webview = @import("../webview/webview_adapter.zig");
const webview_events = @import("../webview/webview_events.zig");

pub const Browser = struct {
    allocator: std.mem.Allocator,
    preferences: preferences.Preferences,
    private_mode: private_mode.PrivateModeConfig,
    tabs: tab_manager.TabManager,
    webview_adapter: *webview.WebViewAdapter,
    last_published_tabs: std.ArrayList(webview_events.TabSnapshot),

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
            .last_published_tabs = .empty,
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
            .on_new_tab_requested = handleNewTabRequested,
            .on_url_open_requested = handleUrlOpenRequested,
            .on_tab_activated_requested = handleTabActivatedRequested,
            .on_tab_closed_requested = handleTabClosedRequested,
        });
        self.publishTabsChanged();
    }

    pub fn deinit(self: *Browser) void {
        webview_events.clearSink();
        webview_events.clearChromeSink();
        self.last_published_tabs.deinit(self.allocator);
        self.tabs.deinit();
    }

    fn handleNavigationEvent(context: *anyopaque, event: webview_events.NavigationEvent) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        const tab = self.tabs.findTabByWebView(event.source_handle) orelse self.tabs.activeTab() orelse return;

        const url = self.allocator.dupe(u8, event.url) catch return;
        const title = self.allocator.dupe(u8, event.title) catch "";
        const favicon_url = self.allocator.dupe(u8, event.favicon_url) catch "";
        if (tab.webview_handle == null) {
            tab.attachWebView(event.source_handle orelse self.webview_adapter.activeHandle());
        }

        tab.updateNavigation(.{
            .current_url = url,
            .title = title,
            .favicon_url = favicon_url,
            .loading_state = mapLoadingState(event.loading_state),
            .can_go_back = event.can_go_back,
            .can_go_forward = event.can_go_forward,
        });
        self.publishTabsChanged();
    }

    fn handleNewTabRequested(context: *anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        _ = self.tabs.createTab(
            self.preferences.homepage_url,
            self.private_mode.enabled,
        ) catch return;
        const active_tab = self.tabs.activeTab() orelse return;
        const handle = self.webview_adapter.createWebView() catch return;
        active_tab.attachWebView(handle);
        self.webview_adapter.showWebView(handle);
        self.loadTab(active_tab.*) catch return;
        self.publishTabsChanged();
    }

    fn handleUrlOpenRequested(context: *anyopaque, url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.openOrActivateUrl(url) catch return;
    }

    fn openOrActivateUrl(self: *Browser, url: []const u8) !void {
        for (self.tabs.tabs.items) |tab| {
            if (std.mem.eql(u8, tab.current_url, url)) {
                if (!self.tabs.activateTab(tab.id)) return;
                const active_tab = self.tabs.activeTab() orelse return;
                try self.showOrCreateWebViewForActiveTab(active_tab);
                self.publishTabsChanged();
                return;
            }
        }

        const owned_url = try self.allocator.dupe(u8, url);
        _ = try self.tabs.createTab(owned_url, self.private_mode.enabled);
        const active_tab = self.tabs.activeTab() orelse return;
        try self.showOrCreateWebViewForActiveTab(active_tab);
        self.publishTabsChanged();
    }

    fn handleTabActivatedRequested(context: *anyopaque, tab_id: u64) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (!self.tabs.activateTab(tab_id)) return;
        const active_tab = self.tabs.activeTab() orelse return;

        self.showOrCreateWebViewForActiveTab(active_tab) catch return;
        self.publishTabsChanged();
    }

    fn showOrCreateWebViewForActiveTab(self: *Browser, active_tab: *tab_model.Tab) !void {
        if (active_tab.webview_handle) |handle| {
            self.webview_adapter.showWebView(handle);
        } else {
            const handle = try self.webview_adapter.createWebView();
            active_tab.attachWebView(handle);
            self.webview_adapter.showWebView(handle);
            try self.loadTab(active_tab.*);
        }
    }

    fn handleTabClosedRequested(context: *anyopaque, tab_id: u64) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        const closing_tab = self.tabs.findTab(tab_id) orelse return;
        const closing_handle = closing_tab.webview_handle;
        if (!self.tabs.closeTab(tab_id)) return;

        self.webview_adapter.destroyWebView(closing_handle);

        if (self.tabs.len() == 0) {
            _ = self.tabs.createTab(
                self.preferences.homepage_url,
                self.private_mode.enabled,
            ) catch return;
        }

        const active_tab = self.tabs.activeTab() orelse return;
        if (active_tab.webview_handle) |handle| {
            self.webview_adapter.showWebView(handle);
        } else {
            const handle = self.webview_adapter.createWebView() catch return;
            active_tab.attachWebView(handle);
            self.webview_adapter.showWebView(handle);
            self.loadTab(active_tab.*) catch return;
        }

        self.publishTabsChanged();
    }

    fn loadTab(self: *Browser, tab: tab_model.Tab) !void {
        if (std.mem.eql(u8, tab.current_url, "nimlo://start")) {
            // TODO(internal pages): move start-page HTML into a browser-owned internal page registry.
            try self.webview_adapter.loadHtml(start_page.html, tab.current_url);
            return;
        }
        if (std.mem.eql(u8, tab.current_url, "nimlo://about")) {
            try self.webview_adapter.loadHtml(about_page.html, tab.current_url);
            return;
        }

        try self.webview_adapter.load(tab.current_url);
    }

    fn publishTabsChanged(self: *Browser) void {
        if (self.currentTabsMatchLastPublished()) return;

        self.last_published_tabs.clearRetainingCapacity();
        self.last_published_tabs.ensureTotalCapacity(self.allocator, self.tabs.len()) catch return;

        for (self.tabs.tabs.items) |tab| {
            self.last_published_tabs.appendAssumeCapacity(.{
                .id = tab.id,
                .title = tab.title,
                .url = tab.current_url,
                .favicon_url = tab.favicon_url,
                .is_active = self.tabs.active_tab_id != null and self.tabs.active_tab_id.? == tab.id,
            });
        }

        webview_events.emitTabsChanged(self.last_published_tabs.items);
    }

    fn currentTabsMatchLastPublished(self: *Browser) bool {
        if (self.tabs.len() != self.last_published_tabs.items.len) return false;

        for (self.tabs.tabs.items, self.last_published_tabs.items) |tab, snapshot| {
            if (tab.id != snapshot.id) return false;
            if (!std.mem.eql(u8, tab.title, snapshot.title)) return false;
            if (!std.mem.eql(u8, tab.current_url, snapshot.url)) return false;
            if (!std.mem.eql(u8, tab.favicon_url, snapshot.favicon_url)) return false;

            const is_active = self.tabs.active_tab_id != null and self.tabs.active_tab_id.? == tab.id;
            if (is_active != snapshot.is_active) return false;
        }

        return true;
    }

    fn mapLoadingState(state: webview_events.LoadingState) tab_model.LoadingState {
        return switch (state) {
            .idle => .idle,
            .loading => .loading,
            .failed => .failed,
        };
    }
};

fn countTabsChanged(context: *anyopaque, tabs: []const webview_events.TabSnapshot) void {
    _ = tabs;
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

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
        .favicon_url = "https://example.com/favicon.ico",
        .loading_state = .idle,
        .can_go_back = true,
        .can_go_forward = false,
    });

    const active_tab = browser.tabs.activeTab().?;
    try std.testing.expectEqualStrings("https://example.com/docs", active_tab.current_url);
    try std.testing.expectEqualStrings("Example Docs", active_tab.title);
    try std.testing.expectEqualStrings("https://example.com/favicon.ico", active_tab.favicon_url);
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

test "duplicate tab snapshots are not republished" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var publish_count: usize = 0;
    webview_events.setChromeSink(.{
        .context = &publish_count,
        .on_tabs_changed = countTabsChanged,
    });

    try browser.start();
    try std.testing.expectEqual(@as(usize, 1), publish_count);

    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example",
        .loading_state = .idle,
    });
    try std.testing.expectEqual(@as(usize, 2), publish_count);

    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example",
        .loading_state = .loading,
    });
    try std.testing.expectEqual(@as(usize, 2), publish_count);

    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example Updated",
        .loading_state = .idle,
    });
    try std.testing.expectEqual(@as(usize, 3), publish_count);
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

test "new tab command creates and activates startup tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitNewTabRequested();

    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    const active_tab = browser.tabs.activeTab().?;
    try std.testing.expectEqualStrings("nimlo://start", active_tab.current_url);
    try std.testing.expectEqualStrings("Nimlo", active_tab.title);
}

test "open url command creates about tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitUrlOpenRequested("nimlo://about");

    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    const active_tab = browser.tabs.activeTab().?;
    try std.testing.expectEqualStrings("nimlo://about", active_tab.current_url);
    try std.testing.expectEqualStrings("About Nimlo", active_tab.title);
}

test "open url command activates existing about tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitUrlOpenRequested("nimlo://about");
    const about_tab_id = browser.tabs.active_tab_id.?;
    webview_events.emitNewTabRequested();

    try std.testing.expectEqual(@as(usize, 3), browser.tabs.len());
    try std.testing.expect(browser.tabs.active_tab_id.? != about_tab_id);

    webview_events.emitUrlOpenRequested("nimlo://about");

    try std.testing.expectEqual(@as(usize, 3), browser.tabs.len());
    try std.testing.expectEqual(about_tab_id, browser.tabs.active_tab_id.?);
}

test "about tab survives native internal navigation event" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitUrlOpenRequested("nimlo://about");

    webview_events.emitNavigation(.{
        .source_handle = browser.tabs.activeTab().?.webview_handle,
        .url = "nimlo://about",
        .title = "About Nimlo",
        .loading_state = .idle,
    });

    try std.testing.expectEqualStrings("nimlo://about", browser.tabs.activeTab().?.current_url);
    try std.testing.expectEqualStrings("About Nimlo", browser.tabs.activeTab().?.title);
}

test "tab activation command switches active tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    _ = try browser.tabs.createTab("https://example.com", false);

    webview_events.emitTabActivatedRequested(first);

    try std.testing.expectEqual(first, browser.tabs.active_tab_id.?);
}

test "navigation event updates tab matching source WebView handle" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const first = browser.tabs.activeTab().?;
    first.attachWebView(@ptrFromInt(0x1));
    _ = try browser.tabs.createTab("https://example.com", false);
    const second = browser.tabs.activeTab().?;
    second.attachWebView(@ptrFromInt(0x2));

    webview_events.emitNavigation(.{
        .source_handle = @ptrFromInt(0x1),
        .url = "https://cnn.example",
        .title = "CNN",
        .loading_state = .idle,
    });

    try std.testing.expectEqualStrings("CNN", browser.tabs.findTab(1).?.title);
    try std.testing.expectEqualStrings("Nimlo", browser.tabs.findTab(2).?.title);
    try std.testing.expectEqual(@as(tab_model.TabId, 2), browser.tabs.active_tab_id.?);
}

test "close tab command removes tab and activates adjacent tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    const second = try browser.tabs.createTab("https://example.com", false);

    webview_events.emitTabClosedRequested(second);

    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    try std.testing.expectEqual(first, browser.tabs.active_tab_id.?);
}

test "close final tab command creates a fresh startup tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const original = browser.tabs.active_tab_id.?;

    webview_events.emitTabClosedRequested(original);

    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    try std.testing.expect(browser.tabs.active_tab_id.? != original);
    try std.testing.expectEqualStrings("nimlo://start", browser.tabs.activeTab().?.current_url);
}
