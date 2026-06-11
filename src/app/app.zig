const std = @import("std");
const browser = @import("../browser/browser.zig");
const preferences = @import("../storage/preferences.zig");
const private_mode = @import("../privacy/private_mode.zig");
const about_page = @import("../ui/about_page.zig");
const start_page = @import("../ui/start_page.zig");
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
    defer core.deinit();
    const data_dir_path = try defaultAppDataDirectoryPath(std.heap.page_allocator);
    defer std.heap.page_allocator.free(data_dir_path);
    try ensurePersistenceDirectory(data_dir_path);
    const history_path = try defaultHistoryPersistencePath(std.heap.page_allocator);
    defer std.heap.page_allocator.free(history_path);
    try core.enableHistoryPersistence(history_path);
    const bookmarks_path = try defaultBookmarksPersistencePath(std.heap.page_allocator);
    defer std.heap.page_allocator.free(bookmarks_path);
    try core.enableBookmarkPersistence(bookmarks_path);

    // TODO(app shell): add browser chrome, commands, menus, and shortcuts.
    // TODO(webview): replace the scaffold with a real system WebView mount.
    try core.start();
    try app_window.attachWebView(&engine);
    try loadHomepage(&engine, config.homepage_url);

    std.debug.print("Nimlo app shell placeholder ready.\n", .{});
    try app_window.show();
}

fn loadHomepage(engine: *webview.WebViewAdapter, homepage_url: []const u8) !void {
    if (std.mem.eql(u8, homepage_url, "nimlo://start")) {
        try engine.loadHtml(start_page.html, homepage_url);
        return;
    }
    if (std.mem.eql(u8, homepage_url, "nimlo://about")) {
        try engine.loadHtml(about_page.html, homepage_url);
        return;
    }

    try engine.load(homepage_url);
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
