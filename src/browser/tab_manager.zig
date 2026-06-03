const std = @import("std");
const tab_model = @import("tab.zig");

pub const Tab = tab_model.Tab;
pub const TabId = tab_model.TabId;

pub const TabManager = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(Tab),
    active_tab_id: ?TabId,
    next_tab_id: TabId,

    pub fn init(allocator: std.mem.Allocator) TabManager {
        return .{
            .allocator = allocator,
            .tabs = .empty,
            .active_tab_id = null,
            .next_tab_id = 1,
        };
    }

    pub fn deinit(self: *TabManager) void {
        self.tabs.deinit(self.allocator);
    }

    pub fn createTab(self: *TabManager, start_url: []const u8, is_private: bool) !TabId {
        const id = self.next_tab_id;
        self.next_tab_id += 1;

        try self.tabs.append(self.allocator, Tab.init(id, start_url, is_private));
        self.active_tab_id = id;
        return id;
    }

    pub fn closeTab(self: *TabManager, id: TabId) bool {
        const index = self.indexOf(id) orelse return false;
        _ = self.tabs.orderedRemove(index);

        if (self.active_tab_id == id) {
            self.active_tab_id = if (self.tabs.items.len == 0)
                null
            else if (index < self.tabs.items.len)
                self.tabs.items[index].id
            else
                self.tabs.items[self.tabs.items.len - 1].id;
        }

        return true;
    }

    pub fn activateTab(self: *TabManager, id: TabId) bool {
        if (self.indexOf(id) == null) return false;

        self.active_tab_id = id;
        return true;
    }

    pub fn activeTab(self: *TabManager) ?*Tab {
        const id = self.active_tab_id orelse return null;
        const index = self.indexOf(id) orelse return null;
        return &self.tabs.items[index];
    }

    pub fn findTab(self: *TabManager, id: TabId) ?*Tab {
        const index = self.indexOf(id) orelse return null;
        return &self.tabs.items[index];
    }

    pub fn findTabByWebView(self: *TabManager, handle: ?*anyopaque) ?*Tab {
        if (handle == null) return null;

        for (self.tabs.items) |*tab| {
            if (tab.webview_handle == handle) return tab;
        }

        return null;
    }

    pub fn len(self: *const TabManager) usize {
        return self.tabs.items.len;
    }

    fn indexOf(self: *const TabManager, id: TabId) ?usize {
        for (self.tabs.items, 0..) |tab, index| {
            if (tab.id == id) return index;
        }

        return null;
    }
};

test "manager starts empty" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.len());
    try std.testing.expect(manager.active_tab_id == null);
    try std.testing.expect(manager.activeTab() == null);
}

test "createTab appends and activates tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.createTab("nimlo://start", false);

    try std.testing.expectEqual(@as(TabId, 1), id);
    try std.testing.expectEqual(@as(usize, 1), manager.len());
    try std.testing.expectEqual(id, manager.active_tab_id.?);
    try std.testing.expectEqualStrings("nimlo://start", manager.activeTab().?.current_url);
}

test "activateTab switches active tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);

    try std.testing.expectEqual(second, manager.active_tab_id.?);
    try std.testing.expect(manager.activateTab(first));
    try std.testing.expectEqual(first, manager.active_tab_id.?);
    try std.testing.expectEqualStrings("nimlo://start", manager.activeTab().?.current_url);
}

test "activateTab rejects unknown tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    _ = try manager.createTab("nimlo://start", false);

    try std.testing.expect(!manager.activateTab(99));
    try std.testing.expectEqual(@as(TabId, 1), manager.active_tab_id.?);
}

test "closeTab removes inactive tab without changing active tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);

    try std.testing.expect(manager.closeTab(first));
    try std.testing.expectEqual(@as(usize, 1), manager.len());
    try std.testing.expectEqual(second, manager.active_tab_id.?);
}

test "closeTab chooses next tab when closing active tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    _ = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);
    const third = try manager.createTab("https://ziglang.org", false);

    try std.testing.expect(manager.activateTab(second));
    try std.testing.expect(manager.closeTab(second));
    try std.testing.expectEqual(@as(usize, 2), manager.len());
    try std.testing.expectEqual(third, manager.active_tab_id.?);
}

test "closeTab chooses previous tab when closing last active tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);

    try std.testing.expect(manager.closeTab(second));
    try std.testing.expectEqual(@as(usize, 1), manager.len());
    try std.testing.expectEqual(first, manager.active_tab_id.?);
}

test "closeTab clears active tab when final tab closes" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const id = try manager.createTab("nimlo://start", false);

    try std.testing.expect(manager.closeTab(id));
    try std.testing.expectEqual(@as(usize, 0), manager.len());
    try std.testing.expect(manager.active_tab_id == null);
    try std.testing.expect(manager.activeTab() == null);
}

test "closeTab rejects unknown tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    _ = try manager.createTab("nimlo://start", false);

    try std.testing.expect(!manager.closeTab(99));
    try std.testing.expectEqual(@as(usize, 1), manager.len());
}
