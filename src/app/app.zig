const builtin = @import("builtin");
const std = @import("std");
const browser = @import("../browser/browser.zig");
const tab_model = @import("../browser/tab.zig");
const preferences = @import("../storage/preferences.zig");
const filter_lists = @import("../storage/filter_lists.zig");
const filter_assets = @import("filter_lists_asset");
const site_policies = @import("../storage/site_policies.zig");
const abp_parser = @import("../blocking/abp_parser.zig");
const webkit_rules = @import("../blocking/webkit_rules.zig");
const content_blocking = @import("../webview/content_blocking.zig");
const private_mode = @import("../privacy/private_mode.zig");
const window = @import("window.zig");
const webview = @import("../webview/webview_adapter.zig");
const webview_events = @import("../webview/webview_events.zig");

const default_window_width = 1024;
const default_window_height = 768;

pub fn run() !void {
    var controller = try AppController.init(std.heap.page_allocator);
    defer controller.deinit();

    webview_events.setAppSink(.{
        .context = &controller,
        .on_new_window_requested = handleNewWindowRequested,
        .on_blocking_site_policies_changed = handleBlockingSitePoliciesChanged,
        .on_window_closed = handleWindowClosed,
        .on_tab_detached = handleTabDetached,
        .on_tab_detached_from_source = handleTabDetachedFromSource,
        .on_tab_move_target_available = handleTabMoveTargetAvailable,
        .on_tab_moved_to_existing_window = handleTabMovedToExistingWindow,
    });
    defer webview_events.clearAppSink();

    controller.rebuildContentBlocking();
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
    downloads_path: []const u8,
    filters_dir_path: []const u8,
    filter_store: filter_lists.FilterListStore,
    site_policies_path: []const u8,
    // Emitted WebKit JSON per enabled list, kept resident so per-site
    // policy toggles splice + recompile without re-running the parse/emit
    // pipeline (docs/CONTENT_BLOCKING.md, Phase G).
    blocking_base_sources: std.ArrayList(BlockingBaseSource),
    sessions: std.ArrayList(*BrowserWindowSession),

    fn init(allocator: std.mem.Allocator) !AppController {
        const data_dir_path = try defaultAppDataDirectoryPath(allocator);
        errdefer allocator.free(data_dir_path);
        try ensurePersistenceDirectory(data_dir_path);

        const history_path = try defaultHistoryPersistencePath(allocator);
        errdefer allocator.free(history_path);

        const bookmarks_path = try defaultBookmarksPersistencePath(allocator);
        errdefer allocator.free(bookmarks_path);

        const downloads_path = try defaultDownloadsPersistencePath(allocator);
        errdefer allocator.free(downloads_path);

        const filters_dir_path = try std.fmt.allocPrint(allocator, "{s}/filters", .{data_dir_path});
        errdefer allocator.free(filters_dir_path);
        try ensurePersistenceDirectory(filters_dir_path);

        var filter_store = filter_lists.FilterListStore.init(allocator);
        errdefer filter_store.deinit();
        initFilterLists(&filter_store, filters_dir_path) catch |err| {
            std.debug.print("filter list setup failed: {s}\n", .{@errorName(err)});
        };

        const site_policies_path = try std.fmt.allocPrint(allocator, "{s}/site_policies.jsonl", .{filters_dir_path});
        errdefer allocator.free(site_policies_path);

        const blocking_base_sources = buildBlockingBaseSources(allocator, &filter_store, filters_dir_path) catch |err| blk: {
            std.debug.print("content blocking setup failed: {s}\n", .{@errorName(err)});
            break :blk std.ArrayList(BlockingBaseSource).empty;
        };

        return .{
            .allocator = allocator,
            .config = preferences.Preferences.default(),
            .privacy = private_mode.PrivateModeConfig.default(),
            .data_dir_path = data_dir_path,
            .history_path = history_path,
            .bookmarks_path = bookmarks_path,
            .downloads_path = downloads_path,
            .filters_dir_path = filters_dir_path,
            .filter_store = filter_store,
            .site_policies_path = site_policies_path,
            .blocking_base_sources = blocking_base_sources,
            .sessions = .empty,
        };
    }

    fn deinit(self: *AppController) void {
        for (self.sessions.items) |session| {
            session.deinit();
            self.allocator.destroy(session);
        }
        self.sessions.deinit(self.allocator);
        for (self.blocking_base_sources.items) |source| {
            self.allocator.free(source.identifier);
            self.allocator.free(source.json);
        }
        self.blocking_base_sources.deinit(self.allocator);
        self.allocator.free(self.site_policies_path);
        self.filter_store.deinit();
        self.allocator.free(self.filters_dir_path);
        self.allocator.free(self.downloads_path);
        self.allocator.free(self.bookmarks_path);
        self.allocator.free(self.history_path);
        self.allocator.free(self.data_dir_path);
    }

    fn createWindow(self: *AppController) !void {
        _ = try self.createWindowWithInitialTab(null, null);
    }

    fn createWindowWithInitialTab(self: *AppController, initial_tab: ?webview_events.DetachedTab, placement: ?webview_events.DetachedWindowPlacement) !*BrowserWindowSession {
        const session = try self.allocator.create(BrowserWindowSession);
        errdefer self.allocator.destroy(session);

        session.* = undefined;
        session.window = try window.AppWindow.create(.{
            .title = "Nimlo",
            .width = if (placement) |value| windowDimension(value.width, default_window_width) else default_window_width,
            .height = if (placement) |value| windowDimension(value.height, default_window_height) else default_window_height,
            .top_left = if (placement) |value| .{ .x = value.top_left.x, .y = value.top_left.y } else null,
        });
        session.engine = webview.WebViewAdapter.init();
        session.core = browser.Browser.init(self.config, self.privacy, &session.engine);
        errdefer session.core.deinit();

        try session.core.enableHistoryPersistence(self.history_path);
        try session.core.enableBookmarkPersistence(self.bookmarks_path);
        try session.core.enableDownloadPersistence(self.downloads_path);
        try session.core.enableSitePolicyPersistence(self.site_policies_path);
        if (initial_tab) |tab| {
            try seedInitialTab(&session.core, tab);
        }
        try session.window.attachWebView(&session.engine);
        try session.core.start();
        try session.core.loadActiveTab();
        try session.window.present();
        session.core.publishChromeState();

        try self.sessions.append(self.allocator, session);
        return session;
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

    // Installs (or reinstalls) the platform rule lists: cached base JSON per
    // list, with the current per-site allow policy spliced in. Policies are
    // re-read from disk — browser sessions own the mutations.
    fn rebuildContentBlocking(self: *AppController) void {
        if (self.blocking_base_sources.items.len == 0) return;
        const allocator = self.allocator;

        var policies = site_policies.SitePolicyStore.init(allocator);
        defer policies.deinit();
        policies.loadFromFile(std.Io.Dir.cwd(), std.Options.debug_io, self.site_policies_path) catch |err| {
            std.debug.print("site policy load failed: {s}\n", .{@errorName(err)});
        };
        const hosts = policies.allowedHosts(allocator) catch return;
        defer allocator.free(hosts);

        var sources: std.ArrayList(content_blocking.RuleListSource) = .empty;
        var scratch: std.ArrayList([]const u8) = .empty;
        defer {
            for (scratch.items) |text| allocator.free(text);
            scratch.deinit(allocator);
            sources.deinit(allocator);
        }

        var hosts_hasher = std.hash.Wyhash.init(0);
        for (hosts) |host| {
            hosts_hasher.update(host);
            hosts_hasher.update("|");
        }
        const hosts_hash = hosts_hasher.final();

        // The self-test rules are always installed; they are inert outside
        // NIMLO_BLOCKING_TEST (a reserved element id and a reserved host).
        // They take the same splice path as every list: ignore-previous-rules
        // is scoped per list, so the allow rule must live in each one.
        const selftest_base = [_]BlockingBaseSource{.{
            .identifier = content_blocking.selftest_identifier,
            .json = content_blocking.selftest_rules_json,
        }};

        var all_bases: std.ArrayList(BlockingBaseSource) = .empty;
        defer all_bases.deinit(allocator);
        all_bases.append(allocator, selftest_base[0]) catch return;
        all_bases.appendSlice(allocator, self.blocking_base_sources.items) catch return;

        for (all_bases.items) |base| {
            if (hosts.len == 0) {
                sources.append(allocator, .{ .identifier = base.identifier, .json = base.json }) catch return;
                continue;
            }
            const spliced = webkit_rules.spliceSiteAllowRules(allocator, base.json, hosts) catch continue;
            scratch.append(allocator, spliced) catch {
                allocator.free(spliced);
                continue;
            };
            const identifier = std.fmt.allocPrint(allocator, "{s}+allow-{x}", .{ base.identifier, hosts_hash }) catch continue;
            scratch.append(allocator, identifier) catch {
                allocator.free(identifier);
                continue;
            };
            sources.append(allocator, .{ .identifier = identifier, .json = spliced }) catch return;
        }

        const compiled_dir_path = std.fmt.allocPrint(allocator, "{s}/compiled", .{self.filters_dir_path}) catch return;
        defer allocator.free(compiled_dir_path);
        ensurePersistenceDirectory(compiled_dir_path) catch return;

        content_blocking.setRuleLists(compiled_dir_path, sources.items);
        if (hosts.len > 0) {
            std.debug.print("content blocking: rebuilt with {d} site allow entries.\n", .{hosts.len});
        }
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

fn handleBlockingSitePoliciesChanged(context: *anyopaque) void {
    const controller: *AppController = @ptrCast(@alignCast(context));
    controller.rebuildContentBlocking();
}

fn handleTabDetached(context: *anyopaque, tab: webview_events.DetachedTab) void {
    const controller: *AppController = @ptrCast(@alignCast(context));
    _ = controller.createWindowWithInitialTab(tab, null) catch |err| {
        std.debug.print("detached tab window failed: {s}\n", .{@errorName(err)});
        return;
    };
}

fn handleTabDetachedFromSource(context: *anyopaque, request: webview_events.TabDetachRequest) ?*anyopaque {
    const controller: *AppController = @ptrCast(@alignCast(context));
    const source = controller.sessionForBrowserContext(request.source_context);

    const detached_session = controller.createWindowWithInitialTab(request.tab, request.placement) catch |err| {
        std.debug.print("detached tab window failed: {s}\n", .{@errorName(err)});
        return null;
    };
    if (source) |source_session| {
        if (source_session.core.tabs.len() == 0 and !request.defer_empty_source_close) {
            source_session.window.close();
        }
    }
    return detached_session.window.nativeHandle();
}

fn windowDimension(value: f64, fallback: u32) u32 {
    if (!std.math.isFinite(value) or value < 1) return fallback;
    return @intFromFloat(@round(value));
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

fn defaultHistoryPersistencePath(allocator: std.mem.Allocator) ![]u8 {
    return defaultPersistenceFilePath(allocator, "history.jsonl");
}

fn defaultBookmarksPersistencePath(allocator: std.mem.Allocator) ![]u8 {
    return defaultPersistenceFilePath(allocator, "bookmarks.jsonl");
}

fn defaultDownloadsPersistencePath(allocator: std.mem.Allocator) ![]u8 {
    return defaultPersistenceFilePath(allocator, "downloads.jsonl");
}

fn defaultPersistenceFilePath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const data_dir_path = try defaultAppDataDirectoryPath(allocator);
    defer allocator.free(data_dir_path);

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir_path, filename });
}

fn defaultAppDataDirectoryPath(allocator: std.mem.Allocator) ![]u8 {
    const home = homeDirectoryAlloc(allocator) catch {
        return allocator.dupe(u8, ".nimlo");
    };
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.nimlo", .{home});
}

fn homeDirectoryAlloc(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const environ: std.process.Environ = .{ .block = .global };
            return environ.getAlloc(allocator, "APPDATA");
        },
        else => {
            const home = std.c.getenv("HOME") orelse return error.MissingHomeDirectory;
            return allocator.dupe(u8, std.mem.span(home));
        },
    }
}

fn ensurePersistenceDirectory(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path);
}

// Loads the filter-list catalog and, on first run, seeds it with the
// bundled EasyList/EasyPrivacy snapshots so blocking works offline
// (docs/CONTENT_BLOCKING.md, Phase E).
fn initFilterLists(store: *filter_lists.FilterListStore, filters_dir_path: []const u8) !void {
    const io = std.Options.debug_io;
    var dir = try std.Io.Dir.cwd().openDir(io, filters_dir_path, .{});
    defer dir.close(io);

    store.loadFromFile(dir, io, "lists.jsonl") catch |err| {
        std.debug.print("filter list catalog load failed: {s}\n", .{@errorName(err)});
    };

    var seeded = false;
    if (try store.ensureDefault(dir, io, ".", .{
        .id = "easylist",
        .name = "EasyList",
        .source_url = "https://easylist.to/easylist/easylist.txt",
        .enabled = true,
        .updated_at = 0,
    }, filter_assets.easylist)) seeded = true;
    if (try store.ensureDefault(dir, io, ".", .{
        .id = "easyprivacy",
        .name = "EasyPrivacy",
        .source_url = "https://easylist.to/easylist/easyprivacy.txt",
        .enabled = true,
        .updated_at = 0,
    }, filter_assets.easyprivacy)) seeded = true;

    if (seeded) {
        try store.saveToFile(dir, io, "lists.jsonl");
        std.debug.print("content blocking: seeded bundled filter lists.\n", .{});
    }
    std.debug.print("content blocking: {d} filter lists in catalog.\n", .{store.records().len});
}

const BlockingBaseSource = struct {
    identifier: []const u8,
    json: []const u8,
};

// Converts every enabled filter list to the platform's rule payload
// (docs/CONTENT_BLOCKING.md, Phases F/G). Identifiers carry a content hash
// so unchanged lists hit the platform's compile cache and steady-state
// startups compile nothing.
fn buildBlockingBaseSources(
    allocator: std.mem.Allocator,
    store: *filter_lists.FilterListStore,
    filters_dir_path: []const u8,
) !std.ArrayList(BlockingBaseSource) {
    var bases: std.ArrayList(BlockingBaseSource) = .empty;
    if (!content_blocking.wantsRuleListPayloads()) return bases;

    const io = std.Options.debug_io;
    var dir = try std.Io.Dir.cwd().openDir(io, filters_dir_path, .{});
    defer dir.close(io);

    for (store.records()) |record| {
        if (!record.enabled) continue;

        const text = filter_lists.readListText(dir, io, allocator, ".", record.id) catch |err| {
            std.debug.print("content blocking: cannot read list {s}: {s}\n", .{ record.id, @errorName(err) });
            continue;
        };
        defer allocator.free(text);

        var parsed = abp_parser.parseList(allocator, text) catch |err| {
            std.debug.print("content blocking: cannot parse list {s}: {s}\n", .{ record.id, @errorName(err) });
            continue;
        };
        defer parsed.deinit();

        const emitted = try webkit_rules.emitJson(allocator, parsed.network, webkit_rules.default_rule_cap);
        errdefer allocator.free(emitted.json);
        const identifier = try std.fmt.allocPrint(allocator, "{s}-{x}", .{
            record.id,
            std.hash.Wyhash.hash(0, text),
        });
        errdefer allocator.free(identifier);

        try bases.append(allocator, .{ .identifier = identifier, .json = emitted.json });
        std.debug.print("content blocking: {s} → {d} WebKit rules ({d} capped, {d} unexpressible).\n", .{
            record.id,
            emitted.stats.emitted_total,
            emitted.stats.capped_blocks,
            emitted.stats.dropped_unexpressible,
        });
    }

    return bases;
}
