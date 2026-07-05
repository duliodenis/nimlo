const std = @import("std");
const bookmarks = @import("../storage/bookmarks.zig");
const downloads = @import("../storage/downloads.zig");
const downloads_page = @import("../ui/downloads_page.zig");
const history = @import("../storage/history.zig");
const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const tab_manager = @import("tab_manager.zig");
const tab_model = @import("tab.zig");
const about_page = @import("../ui/about_page.zig");
const bookmarks_page = @import("../ui/bookmarks_page.zig");
const history_page = @import("../ui/history_page.zig");
const start_page = @import("../ui/start_page.zig");
const webview = @import("../webview/webview_adapter.zig");
const webview_events = @import("../webview/webview_events.zig");

pub const Browser = struct {
    allocator: std.mem.Allocator,
    preferences: preferences.Preferences,
    private_mode: private_mode.PrivateModeConfig,
    tabs: tab_manager.TabManager,
    bookmarks: bookmarks.BookmarkStore,
    bookmarks_persistence_dir: ?std.Io.Dir,
    bookmarks_persistence_path: ?[]const u8,
    history: history.HistoryStore,
    next_history_timestamp: i64,
    history_persistence_dir: ?std.Io.Dir,
    history_persistence_path: ?[]const u8,
    downloads: downloads.DownloadStore,
    downloads_persistence_dir: ?std.Io.Dir,
    downloads_persistence_path: ?[]const u8,
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
            .bookmarks = bookmarks.BookmarkStore.init(allocator),
            .bookmarks_persistence_dir = null,
            .bookmarks_persistence_path = null,
            .history = history.HistoryStore.init(allocator),
            .next_history_timestamp = 0,
            .history_persistence_dir = null,
            .history_persistence_path = null,
            .downloads = downloads.DownloadStore.init(allocator),
            .downloads_persistence_dir = null,
            .downloads_persistence_path = null,
            .webview_adapter = adapter,
            .last_published_tabs = .empty,
        };
    }

    pub fn enableHistoryPersistence(self: *Browser, path: []const u8) !void {
        try self.enableHistoryPersistenceInDir(std.Io.Dir.cwd(), path);
    }

    pub fn enableBookmarkPersistence(self: *Browser, path: []const u8) !void {
        try self.enableBookmarkPersistenceInDir(std.Io.Dir.cwd(), path);
    }

    pub fn enableBookmarkPersistenceInDir(self: *Browser, dir: std.Io.Dir, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        try self.bookmarks.loadFromFile(dir, std.Options.debug_io, owned_path);

        if (self.bookmarks_persistence_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.bookmarks_persistence_dir = dir;
        self.bookmarks_persistence_path = owned_path;
        try self.bookmarks.saveToFile(dir, std.Options.debug_io, owned_path);
    }

    pub fn enableDownloadPersistence(self: *Browser, path: []const u8) !void {
        try self.enableDownloadPersistenceInDir(std.Io.Dir.cwd(), path);
    }

    pub fn enableDownloadPersistenceInDir(self: *Browser, dir: std.Io.Dir, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        try self.downloads.loadFromFile(dir, std.Options.debug_io, owned_path);

        if (self.downloads_persistence_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.downloads_persistence_dir = dir;
        self.downloads_persistence_path = owned_path;
        try self.downloads.saveToFile(dir, std.Options.debug_io, owned_path);
    }

    pub fn enableHistoryPersistenceInDir(self: *Browser, dir: std.Io.Dir, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        try self.history.loadFromFile(dir, std.Options.debug_io, owned_path);

        if (self.history_persistence_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.history_persistence_dir = dir;
        self.history_persistence_path = owned_path;
        self.next_history_timestamp = self.history.maxVisitedAt();
        try self.history.saveToFile(dir, std.Options.debug_io, owned_path);
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
            .on_active_tab_url_requested = handleActiveTabUrlRequested,
            .on_bookmark_current_page_toggle_requested = handleBookmarkCurrentPageToggleRequested,
            .on_internal_page_reload_requested = handleInternalPageReloadRequested,
            .on_history_clear_requested = handleHistoryClearRequested,
            .on_history_clear_confirmed_requested = handleHistoryClearConfirmedRequested,
            .on_history_urls_delete_requested = handleHistoryUrlsDeleteRequested,
            .on_history_urls_open_requested = handleHistoryUrlsOpenRequested,
            .on_bookmark_urls_delete_requested = handleBookmarkUrlsDeleteRequested,
            .on_bookmark_tag_add_requested = handleBookmarkTagAddRequested,
            .on_bookmark_tag_remove_requested = handleBookmarkTagRemoveRequested,
            .on_tab_activated_requested = handleTabActivatedRequested,
            .on_tab_closed_requested = handleTabClosedRequested,
            .on_tab_reordered_requested = handleTabReorderedRequested,
            .on_active_tab_detach_requested = handleActiveTabDetachRequested,
            .on_tab_detach_requested = handleTabDetachRequested,
            .on_active_tab_move_to_existing_window_requested = handleActiveTabMoveToExistingWindowRequested,
            .on_tab_move_to_window_requested = handleTabMoveToWindowRequested,
            .on_active_tab_back_requested = handleActiveTabBackRequested,
            .on_active_tab_forward_requested = handleActiveTabForwardRequested,
            .on_download_started = handleDownloadStarted,
            .on_download_finished = handleDownloadFinished,
            .on_download_failed = handleDownloadFailed,
            .on_downloads_remove_requested = handleDownloadsRemoveRequested,
            .on_downloads_clear_requested = handleDownloadsClearRequested,
        });
        self.publishTabsChanged();
    }

    pub fn publishChromeState(self: *Browser) void {
        self.publishTabsChanged();
    }

    // Loads the active tab's content, rendering internal pages through the
    // same dispatch as in-window navigation. Used when a window is created
    // around an existing tab (startup, tab tear-off, menu detach).
    pub fn loadActiveTab(self: *Browser) !void {
        const tab = self.tabs.activeTab() orelse return;
        try self.loadTab(tab.*);
    }

    pub fn addMovedTab(self: *Browser, moved_tab: webview_events.DetachedTab) !void {
        try self.addMovedTabAt(moved_tab, null);
    }

    pub fn addMovedTabAt(self: *Browser, moved_tab: webview_events.DetachedTab, insertion_index: ?usize) !void {
        const url = try self.allocator.dupe(u8, moved_tab.url);
        const title = try self.allocator.dupe(u8, moved_tab.title);
        const favicon_url = try self.allocator.dupe(u8, moved_tab.favicon_url);
        const id = if (insertion_index) |index|
            try self.tabs.createTabAt(url, moved_tab.is_private, index)
        else
            try self.tabs.createTab(url, moved_tab.is_private);
        const tab = self.tabs.findTab(id) orelse return;
        tab.title = if (title.len == 0) tab.title else title;
        tab.favicon_url = favicon_url;
        restoreTransferredHistory(tab, moved_tab);
        try self.showOrCreateWebViewForActiveTab(tab);
        self.publishTabsChanged();
    }

    pub fn deinit(self: *Browser) void {
        self.webview_adapter.clearEventSink();
        self.webview_adapter.clearChromeSink();
        self.last_published_tabs.deinit(self.allocator);
        self.bookmarks.deinit();
        if (self.bookmarks_persistence_path) |path| {
            self.allocator.free(path);
        }
        self.history.deinit();
        if (self.history_persistence_path) |path| {
            self.allocator.free(path);
        }
        self.downloads.deinit();
        if (self.downloads_persistence_path) |path| {
            self.allocator.free(path);
        }
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
        if (event.loading_state == .idle) {
            const history_url = self.allocator.dupe(u8, event.url) catch event.url;
            tab.recordHistoryUrl(history_url);
        } else {
            tab.updateHistoryCapabilities();
        }
        self.recordHistoryVisit(tab, event.loading_state);
        self.publishTabsChanged();
    }

    fn recordHistoryVisit(self: *Browser, tab: *tab_model.Tab, loading_state: webview_events.LoadingState) void {
        if (loading_state != .idle) return;
        if (tab.is_private) return;
        if (!history.shouldRecordUrl(tab.current_url)) return;

        const visited_at = self.nextHistoryTimestamp();
        self.history.recordVisit(tab.current_url, tab.title, visited_at) catch return;
        if (self.history_persistence_path) |path| {
            const dir = self.history_persistence_dir orelse std.Io.Dir.cwd();
            self.history.saveToFile(dir, std.Options.debug_io, path) catch {};
        }
    }

    fn nextHistoryTimestamp(self: *Browser) i64 {
        const now_ms = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
        if (now_ms > self.next_history_timestamp) {
            self.next_history_timestamp = now_ms;
        } else {
            self.next_history_timestamp += 1;
        }
        return self.next_history_timestamp;
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
        webview_events.emitAddressBarFocusRequested();
    }

    fn handleUrlOpenRequested(context: *anyopaque, url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.openOrActivateUrl(url) catch return;
    }

    fn handleActiveTabUrlRequested(context: *anyopaque, url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.loadUrlInActiveTab(url) catch return;
    }

    fn handleBookmarkCurrentPageToggleRequested(context: *anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.toggleBookmarkCurrentPage() catch return;
    }

    fn handleInternalPageReloadRequested(context: *anyopaque, source_handle: ?*anyopaque, url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        const tab = self.tabs.findTabByWebView(source_handle) orelse self.tabs.activeTab() orelse return;
        if (!std.mem.eql(u8, tab.current_url, url)) return;

        self.loadTab(tab.*) catch return;
        self.publishTabsChanged();
    }

    fn handleHistoryClearRequested(context: *anyopaque, source_handle: ?*anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (self.history.entries().len == 0) {
            webview_events.emitHistoryEmptyRequested();
            return;
        }

        webview_events.emitHistoryClearConfirmationRequested(source_handle);
    }

    fn handleHistoryClearConfirmedRequested(context: *anyopaque, source_handle: ?*anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.clearHistory() catch return;

        const tab = self.tabs.findTabByWebView(source_handle) orelse self.tabs.activeTab() orelse return;
        if (std.mem.eql(u8, tab.current_url, "nimlo://history")) {
            self.loadTab(tab.*) catch return;
        }
    }

    fn handleHistoryUrlsDeleteRequested(context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        var urls = parseHistoryActionUrls(self.allocator, request_url) catch return;
        defer urls.deinit();

        if (self.history.removeUrls(urls.items) == 0) return;
        if (self.history_persistence_path) |path| {
            const dir = self.history_persistence_dir orelse std.Io.Dir.cwd();
            self.history.saveToFile(dir, std.Options.debug_io, path) catch {};
        }

        const tab = self.tabs.findTabByWebView(source_handle) orelse self.tabs.activeTab() orelse return;
        if (std.mem.eql(u8, tab.current_url, "nimlo://history")) {
            self.loadTab(tab.*) catch return;
        }
    }

    fn handleHistoryUrlsOpenRequested(context: *anyopaque, _: ?*anyopaque, request_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        var urls = parseHistoryActionUrls(self.allocator, request_url) catch return;
        defer urls.deinit();

        for (urls.items) |url| {
            if (!history.shouldRecordUrl(url)) continue;
            self.openOrActivateUrl(url) catch continue;
        }
    }

    fn handleDownloadStarted(context: *anyopaque, info: webview_events.DownloadStartInfo) u64 {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (self.private_mode.enabled) return 0;
        if (info.url.len == 0) return 0;

        const id = self.downloads.uniqueId(info.started_at);
        self.downloads.recordStart(.{
            .id = id,
            .url = info.url,
            .filename = info.filename,
            .file_path = info.file_path,
            .size_bytes = 0,
            .started_at = info.started_at,
            .state = .in_progress,
        }) catch return 0;

        self.saveDownloadsIfPersistent();
        self.reloadDownloadsPageIfActive(null);
        return id;
    }

    fn handleDownloadFinished(context: *anyopaque, id: u64, size_bytes: u64) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (!self.downloads.markCompleted(id, size_bytes)) return;

        self.saveDownloadsIfPersistent();
        self.reloadDownloadsPageIfActive(null);
    }

    fn handleDownloadFailed(context: *anyopaque, id: u64) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (!self.downloads.markFailed(id)) return;

        self.saveDownloadsIfPersistent();
        self.reloadDownloadsPageIfActive(null);
    }

    fn handleDownloadsRemoveRequested(context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (self.removeDownloadIdsFromRequest(request_url) == 0) return;

        self.saveDownloadsIfPersistent();
        self.reloadDownloadsPageIfActive(source_handle);
    }

    fn handleDownloadsClearRequested(context: *anyopaque, source_handle: ?*anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (self.downloads.entries().len == 0) return;

        self.downloads.clear();
        self.saveDownloadsIfPersistent();
        self.reloadDownloadsPageIfActive(source_handle);
    }

    fn removeDownloadIdsFromRequest(self: *Browser, request_url: []const u8) usize {
        const query_start = std.mem.indexOfScalar(u8, request_url, '?') orelse return 0;
        const query = request_url[query_start + 1 ..];

        var removed: usize = 0;
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |param| {
            const equals = std.mem.indexOfScalar(u8, param, '=') orelse continue;
            if (!std.mem.eql(u8, param[0..equals], "ids")) continue;

            var ids = std.mem.splitScalar(u8, param[equals + 1 ..], ',');
            while (ids.next()) |text| {
                const id = std.fmt.parseInt(u64, std.mem.trim(u8, text, " "), 10) catch continue;
                if (self.downloads.removeId(id)) removed += 1;
            }
        }
        return removed;
    }

    fn saveDownloadsIfPersistent(self: *Browser) void {
        if (self.downloads_persistence_path) |path| {
            const dir = self.downloads_persistence_dir orelse std.Io.Dir.cwd();
            self.downloads.saveToFile(dir, std.Options.debug_io, path) catch {};
        }
    }

    fn reloadDownloadsPageIfActive(self: *Browser, source_handle: ?*anyopaque) void {
        const tab = self.tabs.findTabByWebView(source_handle) orelse self.tabs.activeTab() orelse return;
        if (std.mem.eql(u8, tab.current_url, "nimlo://downloads")) {
            self.loadTab(tab.*) catch return;
        }
    }

    fn handleBookmarkUrlsDeleteRequested(context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        var urls = parseHistoryActionUrls(self.allocator, request_url) catch return;
        defer urls.deinit();

        var changed = false;
        for (urls.items) |url| {
            changed = self.bookmarks.removeUrl(url) or changed;
        }
        if (!changed) return;

        self.saveBookmarksIfPersistent() catch return;
        self.reloadBookmarksPageIfActive(source_handle);
        self.publishTabsChanged();
    }

    fn handleBookmarkTagAddRequested(context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        var action = parseBookmarkTagAction(self.allocator, request_url) catch return;
        defer action.deinit();

        if (action.tag.len == 0) return;
        const changed = self.bookmarks.addTag(action.url, action.tag) catch return;
        if (!changed) return;

        self.saveBookmarksIfPersistent() catch return;
        self.reloadBookmarksPageIfActive(source_handle);
    }

    fn handleBookmarkTagRemoveRequested(context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        var action = parseBookmarkTagAction(self.allocator, request_url) catch return;
        defer action.deinit();

        const changed = self.bookmarks.removeTag(action.url, action.tag) catch return;
        if (!changed) return;

        self.saveBookmarksIfPersistent() catch return;
        self.reloadBookmarksPageIfActive(source_handle);
    }

    pub fn clearHistory(self: *Browser) !void {
        self.next_history_timestamp = 0;
        if (self.history_persistence_path) |path| {
            const dir = self.history_persistence_dir orelse std.Io.Dir.cwd();
            try self.history.clearAndSave(dir, std.Options.debug_io, path);
            return;
        }

        self.history.clear();
    }

    pub fn toggleBookmarkCurrentPage(self: *Browser) !void {
        const active_tab = self.tabs.activeTab() orelse return;
        if (!canBookmarkTab(active_tab.*)) return;

        if (self.isBookmarked(active_tab.current_url)) {
            _ = self.bookmarks.removeUrl(active_tab.current_url);
        } else {
            try self.bookmarks.addOrUpdate(
                active_tab.current_url,
                active_tab.title,
                currentTimestamp(),
            );
        }
        try self.saveBookmarksIfPersistent();
        self.publishTabsChanged();
    }

    fn saveBookmarksIfPersistent(self: *Browser) !void {
        if (self.bookmarks_persistence_path) |path| {
            const dir = self.bookmarks_persistence_dir orelse std.Io.Dir.cwd();
            try self.bookmarks.saveToFile(dir, std.Options.debug_io, path);
        }
    }

    fn reloadBookmarksPageIfActive(self: *Browser, source_handle: ?*anyopaque) void {
        const tab = self.tabs.findTabByWebView(source_handle) orelse self.tabs.activeTab() orelse return;
        if (std.mem.eql(u8, tab.current_url, "nimlo://bookmarks")) {
            self.loadTab(tab.*) catch return;
        }
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

    fn loadUrlInActiveTab(self: *Browser, url: []const u8) !void {
        const active_tab = self.tabs.activeTab() orelse return;
        const owned_url = try self.allocator.dupe(u8, url);
        active_tab.updateNavigation(.{
            .current_url = owned_url,
            .title = "",
            .loading_state = .loading,
        });
        active_tab.recordHistoryUrl(owned_url);

        if (active_tab.webview_handle) |handle| {
            self.webview_adapter.showWebView(handle);
        } else {
            const handle = try self.webview_adapter.createWebView();
            active_tab.attachWebView(handle);
            self.webview_adapter.showWebView(handle);
        }
        try self.loadTab(active_tab.*);
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
        if (self.tabs.len() == 1) {
            webview_events.emitAppCloseRequested();
            return;
        }

        if (!self.tabs.closeTab(tab_id)) return;

        self.webview_adapter.destroyWebView(closing_handle);

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

    fn handleActiveTabDetachRequested(context: *anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        const detached = self.detachActiveTabForWindowTransfer() orelse return;

        webview_events.emitTabDetached(transferPayloadFromTab(detached));
    }

    fn handleTabDetachRequested(context: *anyopaque, tab_id: u64, placement: ?webview_events.DetachedWindowPlacement, defer_empty_source_close: bool) ?*anyopaque {
        const self: *Browser = @ptrCast(@alignCast(context));
        const detached = self.detachTabForWindowTransfer(tab_id, true) orelse return null;

        return webview_events.emitTabDetachedFromSource(.{
            .source_context = self,
            .placement = placement,
            .defer_empty_source_close = defer_empty_source_close,
            .tab = transferPayloadFromTab(detached),
        });
    }

    fn handleActiveTabMoveToExistingWindowRequested(context: *anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        const active_id = self.tabs.active_tab_id orelse return;
        self.moveTabToWindow(active_id, null, null);
    }

    fn handleTabMoveToWindowRequested(context: *anyopaque, tab_id: u64, destination_window_handle: ?*anyopaque, insertion_index: ?usize) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.moveTabToWindow(tab_id, destination_window_handle, insertion_index);
    }

    fn moveTabToWindow(self: *Browser, tab_id: u64, destination_window_handle: ?*anyopaque, insertion_index: ?usize) void {
        if (!webview_events.emitTabMoveTargetAvailable(self, destination_window_handle)) return;

        const detached = self.detachTabForWindowTransfer(tab_id, true) orelse return;
        webview_events.emitTabMovedToExistingWindow(.{
            .source_context = self,
            .destination_window_handle = destination_window_handle,
            .insertion_index = insertion_index,
            .tab = transferPayloadFromTab(detached),
        });
    }

    fn handleActiveTabBackRequested(context: *anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.navigateActiveTabHistory(.back) catch return;
    }

    fn handleActiveTabForwardRequested(context: *anyopaque) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        self.navigateActiveTabHistory(.forward) catch return;
    }

    fn detachActiveTabForWindowTransfer(self: *Browser) ?tab_model.Tab {
        const active_id = self.tabs.active_tab_id orelse return null;
        return self.detachTabForWindowTransfer(active_id, false);
    }

    fn detachTabForWindowTransfer(self: *Browser, tab_id: tab_model.TabId, allow_final_tab: bool) ?tab_model.Tab {
        if (self.tabs.len() <= 1 and !allow_final_tab) return null;

        const detached = self.tabs.detachTab(tab_id) orelse return null;
        self.webview_adapter.destroyWebView(detached.webview_handle);

        if (self.tabs.activeTab()) |active_tab| {
            self.showOrCreateWebViewForActiveTab(active_tab) catch {};
        }
        self.publishTabsChanged();
        return detached;
    }

    const HistoryDirection = enum { back, forward };

    fn navigateActiveTabHistory(self: *Browser, direction: HistoryDirection) !void {
        const active_tab = self.tabs.activeTab() orelse return;
        const url = switch (direction) {
            .back => active_tab.historyBackUrl() orelse return,
            .forward => active_tab.historyForwardUrl() orelse return,
        };
        const owned_url = try self.allocator.dupe(u8, url);
        active_tab.updateNavigation(.{
            .current_url = owned_url,
            .title = "",
            .loading_state = .loading,
            .can_go_back = active_tab.can_go_back,
            .can_go_forward = active_tab.can_go_forward,
        });

        if (active_tab.webview_handle) |handle| {
            self.webview_adapter.showWebView(handle);
        } else {
            const handle = try self.webview_adapter.createWebView();
            active_tab.attachWebView(handle);
            self.webview_adapter.showWebView(handle);
        }
        try self.loadTab(active_tab.*);
        self.publishTabsChanged();
    }

    fn handleTabReorderedRequested(context: *anyopaque, from_index: usize, to_index: usize) void {
        const self: *Browser = @ptrCast(@alignCast(context));
        if (!self.tabs.moveTab(from_index, to_index)) return;

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
        if (std.mem.eql(u8, tab.current_url, "nimlo://bookmarks")) {
            self.bookmarks.canonicalize();
            const html = try bookmarks_page.render(self.allocator, self.bookmarks.entries());
            defer self.allocator.free(html);

            try self.webview_adapter.loadHtml(html, tab.current_url);
            return;
        }
        if (std.mem.eql(u8, tab.current_url, "nimlo://history")) {
            self.history.canonicalize();
            const html = try history_page.render(self.allocator, self.history.entries());
            defer self.allocator.free(html);

            try self.webview_adapter.loadHtml(html, tab.current_url);
            return;
        }
        if (std.mem.eql(u8, tab.current_url, "nimlo://downloads")) {
            self.downloads.canonicalize();
            const html = try downloads_page.render(self.allocator, self.downloads.entries());
            defer self.allocator.free(html);

            try self.webview_adapter.loadHtml(html, tab.current_url);
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
                .can_bookmark = canBookmarkTab(tab),
                .is_bookmarked = self.isBookmarked(tab.current_url),
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
            if (canBookmarkTab(tab) != snapshot.can_bookmark) return false;
            if (self.isBookmarked(tab.current_url) != snapshot.is_bookmarked) return false;
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

    fn isBookmarked(self: *const Browser, url: []const u8) bool {
        for (self.bookmarks.entries()) |entry| {
            if (std.mem.eql(u8, entry.url, url)) return true;
        }
        return false;
    }
};

fn currentTimestamp() i64 {
    return std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
}

fn canBookmarkTab(tab: tab_model.Tab) bool {
    if (tab.is_private) return false;
    return bookmarks.shouldStoreUrl(tab.current_url);
}

const ParsedHistoryUrls = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,

    fn deinit(self: *ParsedHistoryUrls) void {
        for (self.items) |url| {
            self.allocator.free(url);
        }
        self.allocator.free(self.items);
    }
};

const ParsedBookmarkTagAction = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    tag: []const u8,

    fn deinit(self: *ParsedBookmarkTagAction) void {
        self.allocator.free(self.url);
        self.allocator.free(self.tag);
    }
};

fn parseBookmarkTagAction(allocator: std.mem.Allocator, request_url: []const u8) !ParsedBookmarkTagAction {
    const query_start = std.mem.indexOfScalar(u8, request_url, '?') orelse return .{
        .allocator = allocator,
        .url = try allocator.dupe(u8, ""),
        .tag = try allocator.dupe(u8, ""),
    };
    const query = request_url[query_start + 1 ..];

    var url_value: ?[]u8 = null;
    errdefer if (url_value) |value| allocator.free(value);
    var tag_value: ?[]u8 = null;
    errdefer if (tag_value) |value| allocator.free(value);

    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        const equals = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..equals];
        const value = param[equals + 1 ..];
        if (std.mem.eql(u8, key, "url")) {
            if (url_value) |old| allocator.free(old);
            url_value = try percentDecodeAlloc(allocator, value);
        } else if (std.mem.eql(u8, key, "tag")) {
            if (tag_value) |old| allocator.free(old);
            tag_value = try percentDecodeAlloc(allocator, value);
        }
    }

    return .{
        .allocator = allocator,
        .url = url_value orelse try allocator.dupe(u8, ""),
        .tag = tag_value orelse try allocator.dupe(u8, ""),
    };
}

fn parseHistoryActionUrls(allocator: std.mem.Allocator, request_url: []const u8) !ParsedHistoryUrls {
    const query_start = std.mem.indexOfScalar(u8, request_url, '?') orelse return .{
        .allocator = allocator,
        .items = try allocator.alloc([]const u8, 0),
    };
    const query = request_url[query_start + 1 ..];
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (!std.mem.startsWith(u8, param, "urls=")) continue;

        const decoded = try percentDecodeAlloc(allocator, param["urls=".len..]);
        defer allocator.free(decoded);

        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item);
            items.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, decoded, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try items.append(allocator, try allocator.dupe(u8, line));
        }

        return .{
            .allocator = allocator,
            .items = try items.toOwnedSlice(allocator),
        };
    }

    return .{
        .allocator = allocator,
        .items = try allocator.alloc([]const u8, 0),
    };
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            const high = std.fmt.charToDigit(text[index + 1], 16) catch null;
            const low = std.fmt.charToDigit(text[index + 2], 16) catch null;
            if (high) |hi| {
                if (low) |lo| {
                    try output.append(allocator, @intCast((hi << 4) | lo));
                    index += 3;
                    continue;
                }
            }
        }

        try output.append(allocator, if (text[index] == '+') ' ' else text[index]);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn countTabsChanged(context: *anyopaque, tabs: []const webview_events.TabSnapshot) void {
    _ = tabs;
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

const HistoryClearPromptRecorder = struct {
    empty_count: usize = 0,
    confirmation_count: usize = 0,
    source_handle: ?*anyopaque = null,
};

const BookmarkChromeStateRecorder = struct {
    publish_count: usize = 0,
    can_bookmark: bool = false,
    is_bookmarked: bool = false,
};

const BookmarkUrlStateRecorder = struct {
    url: []const u8,
    is_bookmarked: bool = false,
};

const DetachedTabRecorder = struct {
    count: usize = 0,
    source_context: ?*anyopaque = null,
    title: []const u8 = "",
    url: []const u8 = "",
    is_private: bool = false,
};

const MovedTabRecorder = struct {
    target_available: bool = true,
    target_check_count: usize = 0,
    move_count: usize = 0,
    source_context: ?*anyopaque = null,
    destination_window_handle: ?*anyopaque = null,
    insertion_index: ?usize = null,
    title: []const u8 = "",
    url: []const u8 = "",
    is_private: bool = false,
    history_len: usize = 0,
    history_index: usize = 0,
    history_url_0: []const u8 = "",
};

fn recordHistoryEmptyPrompt(context: *anyopaque) void {
    const recorder: *HistoryClearPromptRecorder = @ptrCast(@alignCast(context));
    recorder.empty_count += 1;
}

fn recordHistoryClearConfirmationPrompt(context: *anyopaque, source_handle: ?*anyopaque) void {
    const recorder: *HistoryClearPromptRecorder = @ptrCast(@alignCast(context));
    recorder.confirmation_count += 1;
    recorder.source_handle = source_handle;
}

fn recordBookmarkChromeState(context: *anyopaque, tabs: []const webview_events.TabSnapshot) void {
    const recorder: *BookmarkChromeStateRecorder = @ptrCast(@alignCast(context));
    recorder.publish_count += 1;
    for (tabs) |tab| {
        if (!tab.is_active) continue;
        recorder.can_bookmark = tab.can_bookmark;
        recorder.is_bookmarked = tab.is_bookmarked;
        return;
    }
    recorder.can_bookmark = false;
    recorder.is_bookmarked = false;
}

fn recordBookmarkUrlState(context: *anyopaque, tabs: []const webview_events.TabSnapshot) void {
    const recorder: *BookmarkUrlStateRecorder = @ptrCast(@alignCast(context));
    for (tabs) |tab| {
        if (!std.mem.eql(u8, tab.url, recorder.url)) continue;
        recorder.is_bookmarked = tab.is_bookmarked;
        return;
    }
    recorder.is_bookmarked = false;
}

fn recordDetachedTab(context: *anyopaque, tab: webview_events.DetachedTab) void {
    const recorder: *DetachedTabRecorder = @ptrCast(@alignCast(context));
    recorder.count += 1;
    recorder.title = tab.title;
    recorder.url = tab.url;
    recorder.is_private = tab.is_private;
}

fn recordDetachedTabFromSource(context: *anyopaque, request: webview_events.TabDetachRequest) ?*anyopaque {
    const recorder: *DetachedTabRecorder = @ptrCast(@alignCast(context));
    recorder.count += 1;
    recorder.source_context = request.source_context;
    recorder.title = request.tab.title;
    recorder.url = request.tab.url;
    recorder.is_private = request.tab.is_private;
    return null;
}

fn recordTabMoveTargetAvailable(context: *anyopaque, source_context: *anyopaque, destination_window_handle: ?*anyopaque) bool {
    const recorder: *MovedTabRecorder = @ptrCast(@alignCast(context));
    recorder.target_check_count += 1;
    recorder.source_context = source_context;
    recorder.destination_window_handle = destination_window_handle;
    return recorder.target_available;
}

fn recordMovedTab(context: *anyopaque, request: webview_events.TabMoveRequest) void {
    const recorder: *MovedTabRecorder = @ptrCast(@alignCast(context));
    recorder.move_count += 1;
    recorder.source_context = request.source_context;
    recorder.destination_window_handle = request.destination_window_handle;
    recorder.insertion_index = request.insertion_index;
    recorder.title = request.tab.title;
    recorder.url = request.tab.url;
    recorder.is_private = request.tab.is_private;
    recorder.history_len = request.tab.history_len;
    recorder.history_index = request.tab.history_index;
    if (request.tab.history_len > 0) recorder.history_url_0 = request.tab.history_urls[0];
}

fn transferPayloadFromTab(tab: tab_model.Tab) webview_events.DetachedTab {
    var payload: webview_events.DetachedTab = .{
        .title = tab.title,
        .url = tab.current_url,
        .favicon_url = tab.favicon_url,
        .is_private = tab.is_private,
        .history_len = tab.history_len,
        .history_index = tab.history_index,
    };

    const count = @min(tab.history_len, webview_events.DetachedTab.max_history_entries);
    for (0..count) |index| {
        payload.history_urls[index] = tab.history_urls[index];
    }
    return payload;
}

fn restoreTransferredHistory(tab: *tab_model.Tab, payload: webview_events.DetachedTab) void {
    const count = @min(payload.history_len, tab_model.Tab.max_history_entries);
    if (count == 0) {
        tab.history_urls[0] = tab.current_url;
        tab.history_len = 1;
        tab.history_index = 0;
        tab.updateHistoryCapabilities();
        return;
    }

    for (0..count) |index| {
        tab.history_urls[index] = payload.history_urls[index];
    }
    tab.history_len = count;
    tab.history_index = @min(payload.history_index, count - 1);
    tab.updateHistoryCapabilities();
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
    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);
    try std.testing.expectEqualStrings("https://example.com/docs", browser.history.entries()[0].url);
    try std.testing.expectEqualStrings("Example Docs", browser.history.entries()[0].title);
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
    try std.testing.expectEqual(@as(usize, 0), browser.history.entries().len);

    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example",
        .loading_state = .failed,
    });
    try std.testing.expectEqual(tab_model.LoadingState.failed, browser.tabs.activeTab().?.loading_state);
    try std.testing.expectEqual(@as(usize, 0), browser.history.entries().len);

    webview_events.emitNavigation(.{
        .url = "https://example.com",
        .title = "Example",
        .loading_state = .idle,
    });
    try std.testing.expectEqual(tab_model.LoadingState.idle, browser.tabs.activeTab().?.loading_state);
    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);
}

test "internal navigation events are not recorded in history" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitNavigation(.{
        .url = "nimlo://start",
        .title = "Nimlo",
        .loading_state = .idle,
    });
    webview_events.emitNavigation(.{
        .url = "nimlo://about",
        .title = "About Nimlo",
        .loading_state = .idle,
    });

    try std.testing.expectEqual(@as(usize, 0), browser.history.entries().len);
}

test "private navigation events are not recorded in history" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        .{
            .enabled = true,
            .persist_history = false,
            .persist_session = false,
        },
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitNavigation(.{
        .url = "https://private.example",
        .title = "Private",
        .loading_state = .idle,
    });

    try std.testing.expectEqual(@as(usize, 0), browser.history.entries().len);
}

test "history persistence loads existing visits and saves new visits" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seeded = history.HistoryStore.init(std.testing.allocator);
    defer seeded.deinit();
    try seeded.recordVisit("https://example.com/old", "Old", 41);
    try seeded.saveToFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableHistoryPersistenceInDir(tmp_dir.dir, "history.jsonl");
    try browser.start();

    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);
    try std.testing.expectEqual(@as(i64, 41), browser.next_history_timestamp);

    webview_events.emitNavigation(.{
        .url = "https://example.com/new",
        .title = "New",
        .loading_state = .idle,
    });

    var loaded = history.HistoryStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    try std.testing.expectEqual(@as(usize, 2), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/new", loaded.entries()[1].url);
    try std.testing.expect(loaded.entries()[1].visited_at >= 1_000_000_000_000);
    try std.testing.expect(loaded.entries()[1].visited_at >= browser.history.entries()[0].visited_at);
}

test "bookmark persistence loads existing bookmarks and saves canonical file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seeded = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer seeded.deinit();
    try seeded.addOrUpdate("https://example.com/old", "Old", 41);
    try seeded.addOrUpdate("https://example.com/new", "New", 42);
    try seeded.saveToFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableBookmarkPersistenceInDir(tmp_dir.dir, "bookmarks.jsonl");

    try std.testing.expectEqual(@as(usize, 2), browser.bookmarks.entries().len);
    try std.testing.expectEqualStrings("https://example.com/new", browser.bookmarks.entries()[0].url);

    try browser.bookmarks.addOrUpdate("https://example.com/old", "Old Updated", 43);
    try browser.bookmarks.saveToFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    var loaded = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    try std.testing.expectEqual(@as(usize, 2), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/old", loaded.entries()[0].url);
    try std.testing.expectEqualStrings("Old Updated", loaded.entries()[0].title);
}

test "bookmark current page stores active external tab" {
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
    });
    webview_events.emitBookmarkCurrentPageToggleRequested();

    try std.testing.expectEqual(@as(usize, 1), browser.bookmarks.entries().len);
    try std.testing.expectEqualStrings("https://example.com/docs", browser.bookmarks.entries()[0].url);
    try std.testing.expectEqualStrings("Example Docs", browser.bookmarks.entries()[0].title);
    try std.testing.expect(browser.bookmarks.entries()[0].created_at >= 1_000_000_000_000);
}

test "bookmark current page adds bookmark and persists it" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableBookmarkPersistenceInDir(tmp_dir.dir, "bookmarks.jsonl");
    try browser.start();
    webview_events.emitNavigation(.{
        .url = "https://example.com/docs",
        .title = "Loading",
        .loading_state = .idle,
    });
    webview_events.emitBookmarkCurrentPageToggleRequested();
    try std.testing.expectEqual(@as(usize, 1), browser.bookmarks.entries().len);
    try std.testing.expectEqualStrings("Loading", browser.bookmarks.entries()[0].title);

    var loaded = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/docs", loaded.entries()[0].url);
    try std.testing.expectEqualStrings("Loading", loaded.entries()[0].title);
}

test "bookmark current page toggles existing bookmark off" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableBookmarkPersistenceInDir(tmp_dir.dir, "bookmarks.jsonl");
    try browser.start();
    webview_events.emitNavigation(.{
        .url = "https://example.com/docs",
        .title = "Example Docs",
        .loading_state = .idle,
    });
    webview_events.emitBookmarkCurrentPageToggleRequested();
    webview_events.emitBookmarkCurrentPageToggleRequested();

    try std.testing.expectEqual(@as(usize, 0), browser.bookmarks.entries().len);

    var loaded = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    try std.testing.expectEqual(@as(usize, 0), loaded.entries().len);
}

test "bookmark current page publishes chrome bookmark state" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = BookmarkChromeStateRecorder{};
    webview_events.setChromeSink(.{
        .context = &recorder,
        .on_tabs_changed = recordBookmarkChromeState,
    });

    try browser.start();
    try std.testing.expect(!recorder.can_bookmark);
    try std.testing.expect(!recorder.is_bookmarked);

    webview_events.emitNavigation(.{
        .url = "https://example.com/docs",
        .title = "Example Docs",
        .loading_state = .idle,
    });
    try std.testing.expect(recorder.can_bookmark);
    try std.testing.expect(!recorder.is_bookmarked);

    webview_events.emitBookmarkCurrentPageToggleRequested();
    try std.testing.expect(recorder.can_bookmark);
    try std.testing.expect(recorder.is_bookmarked);

    webview_events.emitBookmarkCurrentPageToggleRequested();
    try std.testing.expect(recorder.can_bookmark);
    try std.testing.expect(!recorder.is_bookmarked);
}

test "bookmark tag action urls update memory and persistence" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableBookmarkPersistenceInDir(tmp_dir.dir, "bookmarks.jsonl");
    try browser.start();
    webview_events.emitNavigation(.{
        .url = "https://example.com/docs",
        .title = "Example Docs",
        .loading_state = .idle,
    });
    webview_events.emitBookmarkCurrentPageToggleRequested();

    webview_events.emitBookmarkTagAddRequested(null, "https://nimlo.internal/bookmarks/tag/add?url=https%3A%2F%2Fexample.com%2Fdocs&tag=Zig+Docs");
    try std.testing.expectEqual(@as(usize, 1), browser.bookmarks.entries()[0].tags.len);
    try std.testing.expectEqualStrings("Zig Docs", browser.bookmarks.entries()[0].tags[0]);

    var loaded_after_add = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer loaded_after_add.deinit();
    try loaded_after_add.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");
    try std.testing.expectEqual(@as(usize, 1), loaded_after_add.entries()[0].tags.len);
    try std.testing.expectEqualStrings("Zig Docs", loaded_after_add.entries()[0].tags[0]);

    webview_events.emitBookmarkTagRemoveRequested(null, "https://nimlo.internal/bookmarks/tag/remove?url=https%3A%2F%2Fexample.com%2Fdocs&tag=zig%20docs");
    try std.testing.expectEqual(@as(usize, 0), browser.bookmarks.entries()[0].tags.len);

    var loaded_after_remove = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer loaded_after_remove.deinit();
    try loaded_after_remove.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");
    try std.testing.expectEqual(@as(usize, 0), loaded_after_remove.entries()[0].tags.len);
}

test "bookmark delete action urls remove from memory persistence and chrome state" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seeded = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer seeded.deinit();
    try seeded.addOrUpdate("https://example.com/docs", "Docs", 51);
    try seeded.addOrUpdate("https://example.com/keep", "Keep", 52);
    try seeded.saveToFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = BookmarkUrlStateRecorder{ .url = "https://example.com/docs" };
    webview_events.setChromeSink(.{
        .context = &recorder,
        .on_tabs_changed = recordBookmarkUrlState,
    });

    try browser.enableBookmarkPersistenceInDir(tmp_dir.dir, "bookmarks.jsonl");
    try browser.start();
    webview_events.emitNavigation(.{
        .url = "https://example.com/docs",
        .title = "Docs",
        .loading_state = .idle,
    });
    try std.testing.expect(recorder.is_bookmarked);
    webview_events.emitUrlOpenRequested("nimlo://bookmarks");
    try std.testing.expectEqualStrings("nimlo://bookmarks", browser.tabs.activeTab().?.current_url);

    webview_events.emitBookmarkUrlsDeleteRequested(null, "https://nimlo.internal/bookmarks/delete?urls=https%3A%2F%2Fexample.com%2Fdocs");

    try std.testing.expectEqual(@as(usize, 1), browser.bookmarks.entries().len);
    try std.testing.expectEqualStrings("https://example.com/keep", browser.bookmarks.entries()[0].url);
    try std.testing.expect(!recorder.is_bookmarked);

    var loaded = bookmarks.BookmarkStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/keep", loaded.entries()[0].url);
}

test "bookmark current page ignores internal and private tabs" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        .{
            .enabled = true,
            .persist_history = false,
            .persist_session = false,
        },
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitBookmarkCurrentPageToggleRequested();
    webview_events.emitNavigation(.{
        .url = "https://private.example",
        .title = "Private",
        .loading_state = .idle,
    });
    webview_events.emitBookmarkCurrentPageToggleRequested();

    try std.testing.expectEqual(@as(usize, 0), browser.bookmarks.entries().len);
}

test "history persistence updates latest visit for repeated completed navigation" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableHistoryPersistenceInDir(tmp_dir.dir, "history.jsonl");
    try browser.start();

    webview_events.emitNavigation(.{
        .url = "https://example.com/",
        .title = "Loading",
        .loading_state = .idle,
    });
    webview_events.emitNavigation(.{
        .url = "https://example.com/",
        .title = "Example",
        .loading_state = .loading,
    });
    webview_events.emitNavigation(.{
        .url = "https://example.com/",
        .title = "Example",
        .loading_state = .idle,
    });

    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);
    try std.testing.expectEqualStrings("Example", browser.history.entries()[0].title);

    var loaded = history.HistoryStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/", loaded.entries()[0].url);
    try std.testing.expectEqualStrings("Example", loaded.entries()[0].title);
    try std.testing.expect(loaded.entries()[0].visited_at >= 1_000_000_000_000);
}

test "selected history delete removes urls from memory and persistence" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seeded = history.HistoryStore.init(std.testing.allocator);
    defer seeded.deinit();
    try seeded.recordVisit("https://example.com/old", "Old", 51);
    try seeded.recordVisit("https://example.com/keep", "Keep", 52);
    try seeded.recordVisit("https://example.com/remove", "Remove", 53);
    try seeded.saveToFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableHistoryPersistenceInDir(tmp_dir.dir, "history.jsonl");
    try browser.start();

    webview_events.emitHistoryUrlsDeleteRequested(null, "https://nimlo.internal/history/delete?urls=https%3A%2F%2Fexample.com%2Fold%0Ahttps%3A%2F%2Fexample.com%2Fremove");

    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);
    try std.testing.expectEqualStrings("https://example.com/keep", browser.history.entries()[0].url);

    var loaded = history.HistoryStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/keep", loaded.entries()[0].url);
}

test "selected history open opens each selected url" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();

    webview_events.emitHistoryUrlsOpenRequested(null, "https://nimlo.internal/history/open?urls=https%3A%2F%2Fexample.com%2Fone%0Ahttps%3A%2F%2Fexample.com%2Ftwo");

    try std.testing.expectEqual(@as(usize, 3), browser.tabs.len());
    var found_one = false;
    var found_two = false;
    for (browser.tabs.tabs.items) |tab| {
        if (std.mem.eql(u8, tab.current_url, "https://example.com/one")) found_one = true;
        if (std.mem.eql(u8, tab.current_url, "https://example.com/two")) found_two = true;
    }
    try std.testing.expect(found_one);
    try std.testing.expect(found_two);
}

test "clear history request empties memory and persisted file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var seeded = history.HistoryStore.init(std.testing.allocator);
    defer seeded.deinit();
    try seeded.recordVisit("https://example.com/old", "Old", 51);
    try seeded.saveToFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.enableHistoryPersistenceInDir(tmp_dir.dir, "history.jsonl");
    try browser.start();
    webview_events.emitUrlOpenRequested("nimlo://history");

    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);

    const source_handle = browser.tabs.activeTab().?.webview_handle;
    webview_events.emitHistoryClearRequested(source_handle);
    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);

    webview_events.emitHistoryClearConfirmedRequested(source_handle);

    try std.testing.expectEqual(@as(usize, 0), browser.history.entries().len);
    try std.testing.expectEqual(@as(i64, 0), browser.next_history_timestamp);

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "history.jsonl", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 0), contents.len);
}

test "clear history request prompts from real store state" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = HistoryClearPromptRecorder{};
    webview_events.setChromeSink(.{
        .context = &recorder,
        .on_tabs_changed = ignoreTabsChanged,
        .on_history_empty_requested = recordHistoryEmptyPrompt,
        .on_history_clear_confirmation_requested = recordHistoryClearConfirmationPrompt,
    });

    try browser.start();
    const source_handle = browser.tabs.activeTab().?.webview_handle;

    webview_events.emitHistoryClearRequested(source_handle);
    try std.testing.expectEqual(@as(usize, 1), recorder.empty_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.confirmation_count);

    try browser.history.recordVisit("https://example.com", "Example", 71);

    webview_events.emitHistoryClearRequested(source_handle);
    try std.testing.expectEqual(@as(usize, 1), recorder.empty_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.confirmation_count);
    try std.testing.expectEqual(source_handle, recorder.source_handle);
    try std.testing.expectEqual(@as(usize, 1), browser.history.entries().len);

    webview_events.emitHistoryClearConfirmedRequested(source_handle);
    try std.testing.expectEqual(@as(usize, 0), browser.history.entries().len);
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

test "active tab url command loads current tab without creating another tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitNewTabRequested();
    const second = browser.tabs.active_tab_id.?;

    webview_events.emitActiveTabUrlRequested("https://example.com/docs");

    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    try std.testing.expectEqual(second, browser.tabs.active_tab_id.?);
    try std.testing.expectEqualStrings("https://example.com/docs", browser.tabs.activeTab().?.current_url);
}

test "open url command creates bookmarks tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    webview_events.emitUrlOpenRequested("nimlo://bookmarks");

    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    const active_tab = browser.tabs.activeTab().?;
    try std.testing.expectEqualStrings("nimlo://bookmarks", active_tab.current_url);
    try std.testing.expectEqualStrings("Bookmarks", active_tab.title);
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

test "tab reorder command moves tab and preserves active tab" {
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
    const third = try browser.tabs.createTab("https://ziglang.org", false);

    try std.testing.expect(browser.tabs.activateTab(second));
    webview_events.emitTabReorderedRequested(1, 0);

    try std.testing.expectEqual(second, browser.tabs.tabs.items[0].id);
    try std.testing.expectEqual(first, browser.tabs.tabs.items[1].id);
    try std.testing.expectEqual(third, browser.tabs.tabs.items[2].id);
    try std.testing.expectEqual(second, browser.tabs.active_tab_id.?);
}

test "active tab detach command removes active tab and reports detached tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = DetachedTabRecorder{};
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_detached = recordDetachedTab,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    webview_events.emitNewTabRequested();
    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    const second = browser.tabs.active_tab_id.?;
    browser.tabs.findTab(second).?.current_url = "https://example.com";
    browser.tabs.findTab(second).?.title = "Example";
    try std.testing.expect(browser.tabs.activateTab(second));

    webview_events.emitActiveTabDetachRequested();

    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualStrings("Example", recorder.title);
    try std.testing.expectEqualStrings("https://example.com", recorder.url);
    try std.testing.expect(!recorder.is_private);
    try std.testing.expectEqual(first, browser.tabs.active_tab_id.?);
}

test "active tab detach command ignores single-tab window" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = DetachedTabRecorder{};
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_detached = recordDetachedTab,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;

    webview_events.emitActiveTabDetachRequested();

    try std.testing.expectEqual(@as(usize, 0), recorder.count);
    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    try std.testing.expectEqual(first, browser.tabs.active_tab_id.?);
}

test "targeted tab detach command can detach final source tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = DetachedTabRecorder{};
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_detached_from_source = recordDetachedTabFromSource,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const only = browser.tabs.active_tab_id.?;
    browser.tabs.findTab(only).?.current_url = "https://cnn.example";
    browser.tabs.findTab(only).?.title = "CNN";

    _ = webview_events.emitTabDetachRequested(only, null, false);

    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&browser)), recorder.source_context);
    try std.testing.expectEqualStrings("CNN", recorder.title);
    try std.testing.expectEqualStrings("https://cnn.example", recorder.url);
    try std.testing.expectEqual(@as(usize, 0), browser.tabs.len());
    try std.testing.expect(browser.tabs.active_tab_id == null);
}

test "targeted tab detach command removes requested inactive tab and preserves active tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = DetachedTabRecorder{};
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_detached_from_source = recordDetachedTabFromSource,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    webview_events.emitNewTabRequested();
    const second = browser.tabs.active_tab_id.?;
    browser.tabs.findTab(second).?.current_url = "https://example.com";
    browser.tabs.findTab(second).?.title = "Example";
    webview_events.emitNewTabRequested();
    const third = browser.tabs.active_tab_id.?;

    _ = webview_events.emitTabDetachRequested(second, null, false);

    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&browser)), recorder.source_context);
    try std.testing.expectEqualStrings("Example", recorder.title);
    try std.testing.expectEqualStrings("https://example.com", recorder.url);
    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    try std.testing.expectEqual(third, browser.tabs.active_tab_id.?);
    try std.testing.expectEqual(first, browser.tabs.tabs.items[0].id);
    try std.testing.expectEqual(third, browser.tabs.tabs.items[1].id);
}

test "targeted tab detach command ignores unknown tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = DetachedTabRecorder{};
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_detached_from_source = recordDetachedTabFromSource,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    webview_events.emitNewTabRequested();
    const second = browser.tabs.active_tab_id.?;

    _ = webview_events.emitTabDetachRequested(99, null, false);

    try std.testing.expectEqual(@as(usize, 0), recorder.count);
    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    try std.testing.expectEqual(second, browser.tabs.active_tab_id.?);
    try std.testing.expectEqual(first, browser.tabs.tabs.items[0].id);
    try std.testing.expectEqual(second, browser.tabs.tabs.items[1].id);
}

test "active tab move command removes active tab and reports moved tab when target exists" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = MovedTabRecorder{ .target_available = true };
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_move_target_available = recordTabMoveTargetAvailable,
        .on_tab_moved_to_existing_window = recordMovedTab,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    webview_events.emitNewTabRequested();
    const second = browser.tabs.active_tab_id.?;
    browser.tabs.findTab(second).?.recordHistoryUrl("https://previous.example");
    browser.tabs.findTab(second).?.current_url = "https://example.com";
    browser.tabs.findTab(second).?.title = "Example";
    browser.tabs.findTab(second).?.recordHistoryUrl("https://example.com");

    webview_events.emitActiveTabMoveToExistingWindowRequested();

    try std.testing.expectEqual(@as(usize, 1), recorder.target_check_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.move_count);
    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    try std.testing.expectEqual(first, browser.tabs.active_tab_id.?);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&browser)), recorder.source_context);
    try std.testing.expectEqual(@as(?*anyopaque, null), recorder.destination_window_handle);
    try std.testing.expectEqual(@as(?usize, null), recorder.insertion_index);
    try std.testing.expectEqualStrings("Example", recorder.title);
    try std.testing.expectEqualStrings("https://example.com", recorder.url);
    try std.testing.expectEqual(@as(usize, 3), recorder.history_len);
    try std.testing.expectEqual(@as(usize, 2), recorder.history_index);
    try std.testing.expectEqualStrings("nimlo://start", recorder.history_url_0);
}

test "targeted tab move command removes requested inactive tab and reports destination" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = MovedTabRecorder{ .target_available = true };
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_move_target_available = recordTabMoveTargetAvailable,
        .on_tab_moved_to_existing_window = recordMovedTab,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    webview_events.emitNewTabRequested();
    const second = browser.tabs.active_tab_id.?;
    browser.tabs.findTab(second).?.current_url = "https://example.com";
    browser.tabs.findTab(second).?.title = "Example";
    webview_events.emitNewTabRequested();
    const third = browser.tabs.active_tab_id.?;
    const destination_window_handle: ?*anyopaque = @ptrFromInt(0x2);

    webview_events.emitTabMoveToWindowRequested(second, destination_window_handle, 1);

    try std.testing.expectEqual(@as(usize, 1), recorder.target_check_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.move_count);
    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    try std.testing.expectEqual(third, browser.tabs.active_tab_id.?);
    try std.testing.expectEqual(first, browser.tabs.tabs.items[0].id);
    try std.testing.expectEqual(third, browser.tabs.tabs.items[1].id);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&browser)), recorder.source_context);
    try std.testing.expectEqual(destination_window_handle, recorder.destination_window_handle);
    try std.testing.expectEqual(@as(?usize, 1), recorder.insertion_index);
    try std.testing.expectEqualStrings("Example", recorder.title);
    try std.testing.expectEqualStrings("https://example.com", recorder.url);
}

test "targeted tab move command can move final source tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = MovedTabRecorder{ .target_available = true };
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_move_target_available = recordTabMoveTargetAvailable,
        .on_tab_moved_to_existing_window = recordMovedTab,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const only = browser.tabs.active_tab_id.?;
    browser.tabs.findTab(only).?.current_url = "https://cnn.example";
    browser.tabs.findTab(only).?.title = "CNN";
    const destination_window_handle: ?*anyopaque = @ptrFromInt(0x3);

    webview_events.emitTabMoveToWindowRequested(only, destination_window_handle, 0);

    try std.testing.expectEqual(@as(usize, 1), recorder.target_check_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.move_count);
    try std.testing.expectEqual(@as(usize, 0), browser.tabs.len());
    try std.testing.expect(browser.tabs.active_tab_id == null);
    try std.testing.expectEqual(destination_window_handle, recorder.destination_window_handle);
    try std.testing.expectEqual(@as(?usize, 0), recorder.insertion_index);
    try std.testing.expectEqualStrings("CNN", recorder.title);
    try std.testing.expectEqualStrings("https://cnn.example", recorder.url);
}

test "active tab move command leaves source tab when no target window exists" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = MovedTabRecorder{ .target_available = false };
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_move_target_available = recordTabMoveTargetAvailable,
        .on_tab_moved_to_existing_window = recordMovedTab,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    webview_events.emitNewTabRequested();
    const second = browser.tabs.active_tab_id.?;

    webview_events.emitActiveTabMoveToExistingWindowRequested();

    try std.testing.expectEqual(@as(usize, 1), recorder.target_check_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.move_count);
    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    try std.testing.expectEqual(second, browser.tabs.active_tab_id.?);
}

test "targeted tab move command ignores unknown tab after target check" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var recorder = MovedTabRecorder{ .target_available = true };
    webview_events.setAppSink(.{
        .context = &recorder,
        .on_tab_move_target_available = recordTabMoveTargetAvailable,
        .on_tab_moved_to_existing_window = recordMovedTab,
    });
    defer webview_events.clearAppSink();

    try browser.start();
    const first = browser.tabs.active_tab_id.?;
    webview_events.emitNewTabRequested();
    const second = browser.tabs.active_tab_id.?;
    const destination_window_handle: ?*anyopaque = @ptrFromInt(0x4);

    webview_events.emitTabMoveToWindowRequested(99, destination_window_handle, 0);

    try std.testing.expectEqual(@as(usize, 1), recorder.target_check_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.move_count);
    try std.testing.expectEqual(destination_window_handle, recorder.destination_window_handle);
    try std.testing.expectEqual(@as(usize, 2), browser.tabs.len());
    try std.testing.expectEqual(second, browser.tabs.active_tab_id.?);
    try std.testing.expectEqual(first, browser.tabs.tabs.items[0].id);
    try std.testing.expectEqual(second, browser.tabs.tabs.items[1].id);
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

test "close final non-start tab command requests app close without replacing tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var close_request_count: usize = 0;
    webview_events.setChromeSink(.{
        .context = &close_request_count,
        .on_tabs_changed = ignoreTabsChanged,
        .on_app_close_requested = countAppCloseRequested,
    });

    try browser.start();
    const original = browser.tabs.active_tab_id.?;
    browser.tabs.activeTab().?.updateNavigation(.{
        .current_url = "https://example.com",
        .title = "Example",
    });

    webview_events.emitTabClosedRequested(original);

    try std.testing.expectEqual(@as(usize, 1), close_request_count);
    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    try std.testing.expectEqual(original, browser.tabs.active_tab_id.?);
    try std.testing.expectEqualStrings("https://example.com", browser.tabs.activeTab().?.current_url);
}

fn countAppCloseRequested(context: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

fn ignoreTabsChanged(_: *anyopaque, _: []const webview_events.TabSnapshot) void {}

test "close only start tab requests app close without replacing tab" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    var close_request_count: usize = 0;
    webview_events.setChromeSink(.{
        .context = &close_request_count,
        .on_tabs_changed = ignoreTabsChanged,
        .on_app_close_requested = countAppCloseRequested,
    });

    try browser.start();
    const original = browser.tabs.active_tab_id.?;

    webview_events.emitTabClosedRequested(original);

    try std.testing.expectEqual(@as(usize, 1), close_request_count);
    try std.testing.expectEqual(@as(usize, 1), browser.tabs.len());
    try std.testing.expectEqual(original, browser.tabs.active_tab_id.?);
    try std.testing.expectEqualStrings("nimlo://start", browser.tabs.activeTab().?.current_url);
}

test "download started records in-progress entry and returns id" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const id = webview_events.emitDownloadStartedForOwner(null, .{
        .url = "https://example.com/report.pdf",
        .filename = "report.pdf",
        .file_path = "/tmp/report.pdf",
        .started_at = 1_800_000_000_000,
    });

    try std.testing.expect(id != 0);
    try std.testing.expectEqual(@as(usize, 1), browser.downloads.entries().len);
    const entry = browser.downloads.findEntry(id).?;
    try std.testing.expectEqualStrings("https://example.com/report.pdf", entry.url);
    try std.testing.expectEqualStrings("report.pdf", entry.filename);
    try std.testing.expectEqual(downloads.DownloadState.in_progress, entry.state);
}

test "download started in private mode is not recorded" {
    var adapter = webview.WebViewAdapter.init();
    var privacy = private_mode.PrivateModeConfig.default();
    privacy.enabled = true;
    var browser = Browser.init(
        preferences.Preferences.default(),
        privacy,
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const id = webview_events.emitDownloadStartedForOwner(null, .{
        .url = "https://example.com/secret.pdf",
        .filename = "secret.pdf",
        .file_path = "/tmp/secret.pdf",
        .started_at = 1_800_000_000_000,
    });

    try std.testing.expectEqual(@as(u64, 0), id);
    try std.testing.expectEqual(@as(usize, 0), browser.downloads.entries().len);
}

test "download lifecycle completes and remove request deletes record" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const id = webview_events.emitDownloadStartedForOwner(null, .{
        .url = "https://example.com/data.zip",
        .filename = "data.zip",
        .file_path = "/tmp/data.zip",
        .started_at = 1_800_000_000_000,
    });
    try std.testing.expect(id != 0);

    webview_events.emitDownloadFinishedForOwner(null, id, 4096);
    const entry = browser.downloads.findEntry(id).?;
    try std.testing.expectEqual(downloads.DownloadState.completed, entry.state);
    try std.testing.expectEqual(@as(u64, 4096), entry.size_bytes);

    var request_buffer: [128]u8 = undefined;
    const request_url = try std.fmt.bufPrint(&request_buffer, "https://nimlo.internal/downloads/remove?ids={d}", .{id});
    webview_events.emitDownloadsRemoveRequested(null, request_url);
    try std.testing.expectEqual(@as(usize, 0), browser.downloads.entries().len);
}

test "download failure marks record failed and clear request empties store" {
    var adapter = webview.WebViewAdapter.init();
    var browser = Browser.init(
        preferences.Preferences.default(),
        private_mode.PrivateModeConfig.default(),
        &adapter,
    );
    defer browser.deinit();

    try browser.start();
    const id = webview_events.emitDownloadStartedForOwner(null, .{
        .url = "https://example.com/broken.zip",
        .filename = "broken.zip",
        .file_path = "/tmp/broken.zip",
        .started_at = 1_800_000_000_000,
    });
    try std.testing.expect(id != 0);

    webview_events.emitDownloadFailedForOwner(null, id);
    try std.testing.expectEqual(downloads.DownloadState.failed, browser.downloads.findEntry(id).?.state);

    webview_events.emitDownloadsClearRequested(null);
    try std.testing.expectEqual(@as(usize, 0), browser.downloads.entries().len);
}
