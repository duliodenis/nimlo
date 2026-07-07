//! Platform-neutral routing for navigation originating inside internal
//! pages (nimlo://history, nimlo://downloads, ...). Action URLs under
//! https://nimlo.internal/ either emit a browser event here (portable) or
//! return a decision the platform chrome must execute natively.

const std = @import("std");
const web_strings = @import("web_strings.zig");
const webview_events = @import("../webview/webview_events.zig");

pub const Decision = enum {
    // Not an internal-page action; the platform continues its policy chain.
    not_internal,
    // A browser event was emitted; the platform cancels the navigation.
    handled,
    // Platform-executed actions; the platform performs them and cancels.
    clear_history,
    open_download_path,
    reveal_download_path,
};

// Routing for a navigation request from a webview that is showing an
// internal page. Mirrors the order of the original chrome intercepts,
// including the trailing rule that external web links open in a tab.
pub fn dispatch(webview_handle: ?*anyopaque, url: []const u8) Decision {
    if (std.mem.eql(u8, url, "https://nimlo.internal/history/clear")) {
        return .clear_history;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/history/delete?")) {
        webview_events.emitHistoryUrlsDeleteRequested(webview_handle, url);
        return .handled;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/history/open?")) {
        webview_events.emitHistoryUrlsOpenRequested(webview_handle, url);
        return .handled;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/bookmarks/tag/add?")) {
        webview_events.emitBookmarkTagAddRequested(webview_handle, url);
        return .handled;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/bookmarks/delete?")) {
        webview_events.emitBookmarkUrlsDeleteRequested(webview_handle, url);
        return .handled;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/bookmarks/tag/remove?")) {
        webview_events.emitBookmarkTagRemoveRequested(webview_handle, url);
        return .handled;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/downloads/open?")) {
        return .open_download_path;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/downloads/reveal?")) {
        return .reveal_download_path;
    }
    if (std.mem.startsWith(u8, url, "https://nimlo.internal/downloads/remove?")) {
        webview_events.emitDownloadsRemoveRequested(webview_handle, url);
        return .handled;
    }
    if (std.mem.eql(u8, url, "https://nimlo.internal/downloads/clear")) {
        webview_events.emitDownloadsClearRequested(webview_handle);
        return .handled;
    }
    if (web_strings.isExternalWebUrl(url)) {
        webview_events.emitUrlOpenRequested(url);
        return .handled;
    }
    return .not_internal;
}

// Decoded absolute file path from an action URL's `path` query parameter,
// zero-terminated for platform file APIs. Errors when absent or relative.
pub fn pathFromActionUrl(allocator: std.mem.Allocator, request_url: []const u8) ![:0]u8 {
    const marker = "?path=";
    const marker_index = std.mem.indexOf(u8, request_url, marker) orelse return error.MissingPathParameter;
    const encoded = request_url[marker_index + marker.len ..];
    if (encoded.len == 0) return error.MissingPathParameter;

    const path = try web_strings.percentDecodeQueryAlloc(allocator, encoded);
    errdefer allocator.free(path);
    if (path.len == 0 or path[0] != '/') return error.NotAbsolutePath;
    return path;
}

const TestCounters = struct {
    history_delete: usize = 0,
    history_open: usize = 0,
    bookmark_tag_add: usize = 0,
    bookmark_delete: usize = 0,
    bookmark_tag_remove: usize = 0,
    downloads_remove: usize = 0,
    downloads_clear: usize = 0,
    url_open: usize = 0,
};

var test_counters: TestCounters = .{};

fn testNavigationStub(_: *anyopaque, _: webview_events.NavigationEvent) void {}

fn installTestSink() void {
    test_counters = .{};
    webview_events.setSink(.{
        .context = @constCast(@ptrCast(&test_counters)),
        .on_navigation = testNavigationStub,
        .on_url_open_requested = struct {
            fn f(_: *anyopaque, _: []const u8) void {
                test_counters.url_open += 1;
            }
        }.f,
        .on_history_urls_delete_requested = struct {
            fn f(_: *anyopaque, _: ?*anyopaque, _: []const u8) void {
                test_counters.history_delete += 1;
            }
        }.f,
        .on_history_urls_open_requested = struct {
            fn f(_: *anyopaque, _: ?*anyopaque, _: []const u8) void {
                test_counters.history_open += 1;
            }
        }.f,
        .on_bookmark_tag_add_requested = struct {
            fn f(_: *anyopaque, _: ?*anyopaque, _: []const u8) void {
                test_counters.bookmark_tag_add += 1;
            }
        }.f,
        .on_bookmark_urls_delete_requested = struct {
            fn f(_: *anyopaque, _: ?*anyopaque, _: []const u8) void {
                test_counters.bookmark_delete += 1;
            }
        }.f,
        .on_bookmark_tag_remove_requested = struct {
            fn f(_: *anyopaque, _: ?*anyopaque, _: []const u8) void {
                test_counters.bookmark_tag_remove += 1;
            }
        }.f,
        .on_downloads_remove_requested = struct {
            fn f(_: *anyopaque, _: ?*anyopaque, _: []const u8) void {
                test_counters.downloads_remove += 1;
            }
        }.f,
        .on_downloads_clear_requested = struct {
            fn f(_: *anyopaque, _: ?*anyopaque) void {
                test_counters.downloads_clear += 1;
            }
        }.f,
    });
}

test "emit routes fire the matching event and report handled" {
    installTestSink();
    defer webview_events.clearSink();

    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://nimlo.internal/history/delete?urls=x"));
    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://nimlo.internal/history/open?urls=x"));
    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://nimlo.internal/bookmarks/tag/add?url=x&tag=y"));
    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://nimlo.internal/bookmarks/delete?urls=x"));
    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://nimlo.internal/bookmarks/tag/remove?url=x&tag=y"));
    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://nimlo.internal/downloads/remove?ids=1"));
    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://nimlo.internal/downloads/clear"));

    try std.testing.expectEqual(@as(usize, 1), test_counters.history_delete);
    try std.testing.expectEqual(@as(usize, 1), test_counters.history_open);
    try std.testing.expectEqual(@as(usize, 1), test_counters.bookmark_tag_add);
    try std.testing.expectEqual(@as(usize, 1), test_counters.bookmark_delete);
    try std.testing.expectEqual(@as(usize, 1), test_counters.bookmark_tag_remove);
    try std.testing.expectEqual(@as(usize, 1), test_counters.downloads_remove);
    try std.testing.expectEqual(@as(usize, 1), test_counters.downloads_clear);
    try std.testing.expectEqual(@as(usize, 0), test_counters.url_open);
}

test "platform routes return their decision without emitting" {
    installTestSink();
    defer webview_events.clearSink();

    try std.testing.expectEqual(Decision.clear_history, dispatch(null, "https://nimlo.internal/history/clear"));
    try std.testing.expectEqual(Decision.open_download_path, dispatch(null, "https://nimlo.internal/downloads/open?path=/tmp/x"));
    try std.testing.expectEqual(Decision.reveal_download_path, dispatch(null, "https://nimlo.internal/downloads/reveal?path=/tmp/x"));
    try std.testing.expectEqual(@as(usize, 0), test_counters.url_open);
}

test "external links from internal pages open in a tab" {
    installTestSink();
    defer webview_events.clearSink();

    try std.testing.expectEqual(Decision.handled, dispatch(null, "https://example.com/page"));
    try std.testing.expectEqual(@as(usize, 1), test_counters.url_open);
    try std.testing.expectEqual(Decision.not_internal, dispatch(null, "nimlo://start"));
    try std.testing.expectEqual(Decision.not_internal, dispatch(null, "file:///tmp"));
}

test "path extraction decodes and validates" {
    const path = try pathFromActionUrl(std.testing.allocator, "https://nimlo.internal/downloads/open?path=/Users/dd/Downloads/annual%20report.pdf");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/Users/dd/Downloads/annual report.pdf", path);

    try std.testing.expectError(error.MissingPathParameter, pathFromActionUrl(std.testing.allocator, "https://nimlo.internal/downloads/open"));
    try std.testing.expectError(error.MissingPathParameter, pathFromActionUrl(std.testing.allocator, "https://nimlo.internal/downloads/open?path="));
    try std.testing.expectError(error.NotAbsolutePath, pathFromActionUrl(std.testing.allocator, "https://nimlo.internal/downloads/open?path=relative"));
}
