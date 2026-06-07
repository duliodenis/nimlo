const std = @import("std");

pub const TabId = u64;

pub const LoadingState = enum {
    idle,
    loading,
    failed,
};

pub const NavigationState = struct {
    current_url: []const u8,
    title: []const u8 = "",
    favicon_url: []const u8 = "",
    loading_state: LoadingState = .idle,
    can_go_back: bool = false,
    can_go_forward: bool = false,
};

pub const Tab = struct {
    id: TabId,
    title: []const u8,
    current_url: []const u8,
    favicon_url: []const u8,
    loading_state: LoadingState,
    can_go_back: bool,
    can_go_forward: bool,
    is_private: bool,
    webview_handle: ?*anyopaque,

    pub fn init(id: TabId, start_url: []const u8, is_private: bool) Tab {
        return .{
            .id = id,
            .title = initialTitle(start_url),
            .current_url = start_url,
            .favicon_url = "",
            .loading_state = .idle,
            .can_go_back = false,
            .can_go_forward = false,
            .is_private = is_private,
            .webview_handle = null,
        };
    }

    pub fn updateNavigation(self: *Tab, state: NavigationState) void {
        self.current_url = state.current_url;
        self.title = if (state.title.len == 0) fallbackTitle(state.current_url) else state.title;
        self.favicon_url = state.favicon_url;
        self.loading_state = state.loading_state;
        self.can_go_back = state.can_go_back;
        self.can_go_forward = state.can_go_forward;
    }

    pub fn setLoading(self: *Tab) void {
        self.loading_state = .loading;
    }

    pub fn setIdle(self: *Tab) void {
        self.loading_state = .idle;
    }

    pub fn setFailed(self: *Tab) void {
        self.loading_state = .failed;
    }

    pub fn attachWebView(self: *Tab, handle: ?*anyopaque) void {
        self.webview_handle = handle;
    }
};

fn fallbackTitle(url: []const u8) []const u8 {
    if (std.mem.eql(u8, url, "nimlo://start")) return "Nimlo";
    if (std.mem.eql(u8, url, "nimlo://about")) return "About Nimlo";
    if (std.mem.eql(u8, url, "nimlo://history")) return "History";

    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const host_start = scheme_end + 3;
    const host_end = std.mem.indexOfAnyPos(u8, url, host_start, "/?#") orelse url.len;
    if (host_start >= host_end) return url;

    return url[host_start..host_end];
}

fn initialTitle(url: []const u8) []const u8 {
    if (std.mem.eql(u8, url, "nimlo://about")) return "About Nimlo";
    if (std.mem.eql(u8, url, "nimlo://history")) return "History";
    return "Nimlo";
}

test "default tab state" {
    const tab = Tab.init(1, "nimlo://start", false);

    try std.testing.expectEqual(@as(TabId, 1), tab.id);
    try std.testing.expectEqualStrings("Nimlo", tab.title);
    try std.testing.expectEqualStrings("nimlo://start", tab.current_url);
    try std.testing.expectEqualStrings("", tab.favicon_url);
    try std.testing.expectEqual(LoadingState.idle, tab.loading_state);
    try std.testing.expect(!tab.can_go_back);
    try std.testing.expect(!tab.can_go_forward);
    try std.testing.expect(!tab.is_private);
    try std.testing.expect(tab.webview_handle == null);
}

test "about tab title" {
    const tab = Tab.init(7, "nimlo://about", false);

    try std.testing.expectEqualStrings("About Nimlo", tab.title);
    try std.testing.expectEqualStrings("nimlo://about", tab.current_url);
}

test "history tab title" {
    const tab = Tab.init(8, "nimlo://history", false);

    try std.testing.expectEqualStrings("History", tab.title);
    try std.testing.expectEqualStrings("nimlo://history", tab.current_url);
}

test "private tab state" {
    const tab = Tab.init(2, "nimlo://start", true);

    try std.testing.expect(tab.is_private);
}

test "navigation state update" {
    var tab = Tab.init(3, "nimlo://start", false);

    tab.updateNavigation(.{
        .current_url = "https://example.com/docs",
        .title = "Example Docs",
        .favicon_url = "https://example.com/favicon.ico",
        .loading_state = .loading,
        .can_go_back = true,
        .can_go_forward = false,
    });

    try std.testing.expectEqualStrings("https://example.com/docs", tab.current_url);
    try std.testing.expectEqualStrings("Example Docs", tab.title);
    try std.testing.expectEqualStrings("https://example.com/favicon.ico", tab.favicon_url);
    try std.testing.expectEqual(LoadingState.loading, tab.loading_state);
    try std.testing.expect(tab.can_go_back);
    try std.testing.expect(!tab.can_go_forward);
}

test "empty start page title falls back to Nimlo" {
    var tab = Tab.init(4, "nimlo://start", false);

    tab.updateNavigation(.{
        .current_url = "nimlo://start",
        .title = "",
    });

    try std.testing.expectEqualStrings("Nimlo", tab.title);
}

test "empty external page title falls back to URL host" {
    var tab = Tab.init(6, "nimlo://start", false);

    tab.updateNavigation(.{
        .current_url = "https://www.cnn.com/",
        .title = "",
    });

    try std.testing.expectEqualStrings("www.cnn.com", tab.title);
}

test "loading helpers update state" {
    var tab = Tab.init(5, "nimlo://start", false);

    tab.setLoading();
    try std.testing.expectEqual(LoadingState.loading, tab.loading_state);

    tab.setFailed();
    try std.testing.expectEqual(LoadingState.failed, tab.loading_state);

    tab.setIdle();
    try std.testing.expectEqual(LoadingState.idle, tab.loading_state);
}
