const std = @import("std");
const browser = @import("../browser/browser.zig");
const tab_model = @import("../browser/tab.zig");
const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const about_page = @import("../ui/about_page.zig");
const start_page = @import("../ui/start_page.zig");
const window = @import("window.zig");
const webview = @import("../webview/webview_adapter.zig");
const webview_events = @import("../webview/webview_events.zig");

pub fn run() !void {
    var controller = try AppController.init(std.heap.page_allocator);
    defer controller.deinit();

    webview_events.setAppSink(.{
        .context = &controller,
        .on_new_window_requested = handleNewWindowRequested,
        .on_window_closed = handleWindowClosed,
        .on_tab_detached = handleTabDetached,
        .on_tab_move_target_available = handleTabMoveTargetAvailable,
        .on_tab_moved_to_existing_window = handleTabMovedToExistingWindow,
    });
    defer webview_events.clearAppSink();

    try controller.createWindow();
    std.debug.print("Nimlo app shell placeholder ready.\n", .{});
    try controller.run();
}

const AppController = struct {
    allocator: std.mem.Allocator,
    config: preferences.Preferences,
    privacy: private_mode.PrivateModeConfig,
    data_dir_path: []const u8,
    history_path: []const u8,
    bookmarks_path: []const u8,
    sessions: std.ArrayList(*BrowserWindowSession),

    fn init(allocator: std.mem.Allocator) !AppController {
        const data_dir_path = try defaultAppDataDirectoryPath(allocator);
        errdefer allocator.free(data_dir_path);
        try ensurePersistenceDirectory(data_dir_path);

        const history_path = try defaultHistoryPersistencePath(allocator);
        errdefer allocator.free(history_path);

        const bookmarks_path = try defaultBookmarksPersistencePath(allocator);
        errdefer allocator.free(bookmarks_path);

        return .{
            .allocator = allocator,
            .config = preferences.Preferences.default(),
            .privacy = private_mode.PrivateModeConfig.default(),
            .data_dir_path = data_dir_path,
            .history_path = history_path,
            .bookmarks_path = bookmarks_path,
            .sessions = .empty,
        };
    }

    fn deinit(self: *AppController) void {
        for (self.sessions.items) |session| {
            session.deinit();
            self.allocator.destroy(session);
        }
        self.sessions.deinit(self.allocator);
        self.allocator.free(self.bookmarks_path);
        self.allocator.free(self.history_path);
        self.allocator.free(self.data_dir_path);
    }

    fn createWindow(self: *AppController) !void {
        try self.createWindowWithInitialTab(null);
    }

    fn createWindowWithInitialTab(self: *AppController, initial_tab: ?webview_events.DetachedTab) !void {
        const session = try self.allocator.create(BrowserWindowSession);
        errdefer self.allocator.destroy(session);

        session.* = undefined;
        session.window = try window.AppWindow.create(.{
            .title = "Nimlo",
            .width = 1024,
            .height = 768,
        });
        session.engine = webview.WebViewAdapter.init();
        session.core = browser.Browser.init(self.config, self.privacy, &session.engine);
        errdefer session.core.deinit();

        try session.core.enableHistoryPersistence(self.history_path);
        try session.core.enableBookmarkPersistence(self.bookmarks_path);
        if (initial_tab) |tab| {
            try seedInitialTab(&session.core, tab);
        }
        try session.window.attachWebView(&session.engine);
        try session.core.start();
        try loadInitialUrl(&session.engine, if (initial_tab) |tab| tab.url else self.config.homepage_url);
        try session.window.present();
        session.core.publishChromeState();

        try self.sessions.append(self.allocator, session);
    }

    fn run(self: *AppController) !void {
        if (self.sessions.items.len == 0) return;

        try self.sessions.items[0].window.runEventLoop();
    }

    fn removeWindow(self: *AppController, window_handle: ?*anyopaque) void {
        var index: usize = 0;
        while (index < self.sessions.items.len) {
            const session = self.sessions.items[index];
            if (session.window.nativeHandle() != window_handle) {
                index += 1;
                continue;
            }

            _ = self.sessions.orderedRemove(index);
            session.deinit();
            self.allocator.destroy(session);
            return;
        }
    }

    fn newestOtherSession(self: *AppController, source_context: *anyopaque) ?*BrowserWindowSession {
        var index = self.sessions.items.len;
        while (index > 0) {
            index -= 1;
            const session = self.sessions.items[index];
            if (@as(*anyopaque, @ptrCast(&session.core)) == source_context) continue;
            return session;
        }
        return null;
    }

    fn sessionForMoveDestination(self: *AppController, source_context: *anyopaque, destination_window_handle: ?*anyopaque) ?*BrowserWindowSession {
        if (destination_window_handle == null) return self.newestOtherSession(source_context);

        for (self.sessions.items) |session| {
            if (session.window.nativeHandle() != destination_window_handle) continue;
            if (@as(*anyopaque, @ptrCast(&session.core)) == source_context) return null;
            return session;
        }
        return null;
    }

    fn sessionForBrowserContext(self: *AppController, browser_context: *anyopaque) ?*BrowserWindowSession {
        for (self.sessions.items) |session| {
            if (@as(*anyopaque, @ptrCast(&session.core)) == browser_context) return session;
        }
        return null;
    }
};

const BrowserWindowSession = struct {
    window: window.AppWindow,
    engine: webview.WebViewAdapter,
    core: browser.Browser,

    fn deinit(self: *BrowserWindowSession) void {
        self.core.deinit();
    }
};

fn handleNewWindowRequested(context: *anyopaque) void {
    const controller: *AppController = @ptrCast(@alignCast(context));
    controller.createWindow() catch |err| {
        std.debug.print("new window failed: {s}\n", .{@errorName(err)});
    };
}

fn handleTabDetached(context: *anyopaque, tab: webview_events.DetachedTab) void {
    const controller: *AppController = @ptrCast(@alignCast(context));
    controller.createWindowWithInitialTab(tab) catch |err| {
        std.debug.print("detached tab window failed: {s}\n", .{@errorName(err)});
    };
}

fn handleTabMoveTargetAvailable(context: *anyopaque, source_context: *anyopaque, destination_window_handle: ?*anyopaque) bool {
    const controller: *AppController = @ptrCast(@alignCast(context));
    return controller.sessionForMoveDestination(source_context, destination_window_handle) != null;
}

fn handleTabMovedToExistingWindow(context: *anyopaque, request: webview_events.TabMoveRequest) void {
    const controller: *AppController = @ptrCast(@alignCast(context));
    const destination = controller.sessionForMoveDestination(request.source_context, request.destination_window_handle) orelse return;
    const source = controller.sessionForBrowserContext(request.source_context);

    destination.window.focus() catch |err| {
        std.debug.print("destination window focus failed: {s}\n", .{@errorName(err)});
    };
    webview_events.activateSinkForOwner(destination.window.nativeHandle());
    webview_events.activateChromeSinkForOwner(destination.window.nativeHandle());
    destination.core.addMovedTabAt(request.tab, request.insertion_index) catch |err| {
        std.debug.print("move tab to window failed: {s}\n", .{@errorName(err)});
        return;
    };
    if (source) |source_session| {
        if (source_session.core.tabs.len() == 0) {
            source_session.window.close();
        }
    }
}

fn handleWindowClosed(context: *anyopaque, window_handle: ?*anyopaque) void {
    const controller: *AppController = @ptrCast(@alignCast(context));
    controller.removeWindow(window_handle);
}

fn seedInitialTab(core: *browser.Browser, tab: webview_events.DetachedTab) !void {
    const url = try core.allocator.dupe(u8, tab.url);
    const title = try core.allocator.dupe(u8, tab.title);
    const favicon_url = try core.allocator.dupe(u8, tab.favicon_url);
    const id = try core.tabs.createTab(url, tab.is_private);
    const initial = core.tabs.findTab(id) orelse return;
    initial.title = if (title.len == 0) initial.title else title;
    initial.favicon_url = favicon_url;
    const history_count = @min(tab.history_len, tab_model.Tab.max_history_entries);
    if (history_count > 0) {
        for (0..history_count) |index| {
            initial.history_urls[index] = tab.history_urls[index];
        }
        initial.history_len = history_count;
        initial.history_index = @min(tab.history_index, history_count - 1);
        initial.updateHistoryCapabilities();
    }
}

fn loadInitialUrl(engine: *webview.WebViewAdapter, url: []const u8) !void {
    if (std.mem.eql(u8, url, "nimlo://start")) {
        try engine.loadHtml(start_page.html, url);
        return;
    }
    if (std.mem.eql(u8, url, "nimlo://about")) {
        try engine.loadHtml(about_page.html, url);
        return;
    }

    try engine.load(url);
}

fn defaultHistoryPersistencePath(allocator: std.mem.Allocator) ![]u8 {
    return defaultPersistenceFilePath(allocator, "history.jsonl");
}

fn defaultBookmarksPersistencePath(allocator: std.mem.Allocator) ![]u8 {
    return defaultPersistenceFilePath(allocator, "bookmarks.jsonl");
}

fn defaultPersistenceFilePath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const data_dir_path = try defaultAppDataDirectoryPath(allocator);
    defer allocator.free(data_dir_path);

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir_path, filename });
}

fn defaultAppDataDirectoryPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("HOME")) |home_z| {
        return std.fmt.allocPrint(allocator, "{s}/.nimlo", .{std.mem.span(home_z)});
    }

    return allocator.dupe(u8, ".nimlo");
}

fn ensurePersistenceDirectory(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path);
}
