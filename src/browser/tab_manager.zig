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
        _ = self.detachTab(id) orelse return false;
        return true;
    }

    pub fn detachTab(self: *TabManager, id: TabId) ?Tab {
        const index = self.indexOf(id) orelse return null;
        const detached = self.tabs.orderedRemove(index);

        if (self.active_tab_id == id) {
            self.active_tab_id = if (self.tabs.items.len == 0)
                null
            else if (index < self.tabs.items.len)
                self.tabs.items[index].id
            else
                self.tabs.items[self.tabs.items.len - 1].id;
        }

        return detached;
    }

    pub fn activateTab(self: *TabManager, id: TabId) bool {
        if (self.indexOf(id) == null) return false;

        self.active_tab_id = id;
        return true;
    }

    pub fn moveTab(self: *TabManager, from_index: usize, to_index: usize) bool {
        const tab_count = self.tabs.items.len;
        if (from_index >= tab_count or to_index >= tab_count) return false;
        if (from_index == to_index) return true;

        const tab = self.tabs.items[from_index];
        if (from_index < to_index) {
            std.mem.copyForwards(
                Tab,
                self.tabs.items[from_index..to_index],
                self.tabs.items[from_index + 1 .. to_index + 1],
            );
        } else {
            std.mem.copyBackwards(
                Tab,
                self.tabs.items[to_index + 1 .. from_index + 1],
                self.tabs.items[to_index..from_index],
            );
        }
        self.tabs.items[to_index] = tab;
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

test "moveTab moves tab forward by index" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);
    const third = try manager.createTab("https://ziglang.org", false);

    try std.testing.expect(manager.moveTab(0, 2));
    try expectTabOrder(&manager, &.{ second, third, first });
}

test "moveTab moves tab backward by index" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);
    const third = try manager.createTab("https://ziglang.org", false);

    try std.testing.expect(manager.moveTab(2, 0));
    try expectTabOrder(&manager, &.{ third, first, second });
}

test "moveTab preserves active tab identity" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);
    const third = try manager.createTab("https://ziglang.org", false);

    try std.testing.expect(manager.activateTab(second));
    try std.testing.expect(manager.moveTab(1, 0));
    try expectTabOrder(&manager, &.{ second, first, third });
    try std.testing.expectEqual(second, manager.active_tab_id.?);
    try std.testing.expectEqual(second, manager.activeTab().?.id);
}

test "moveTab treats same index as valid no-op" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);

    try std.testing.expect(manager.moveTab(1, 1));
    try expectTabOrder(&manager, &.{ first, second });
    try std.testing.expectEqual(second, manager.active_tab_id.?);
}

test "moveTab rejects indexes outside tab list" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);

    try std.testing.expect(!manager.moveTab(2, 0));
    try std.testing.expect(!manager.moveTab(0, 2));
    try expectTabOrder(&manager, &.{ first, second });
    try std.testing.expectEqual(second, manager.active_tab_id.?);
}

test "detachTab removes inactive tab and returns tab data" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);
    const third = try manager.createTab("https://ziglang.org", true);
    manager.findTab(third).?.title = "Zig";
    manager.findTab(third).?.attachWebView(@ptrFromInt(0x1));

    const detached = manager.detachTab(third).?;

    try std.testing.expectEqual(third, detached.id);
    try std.testing.expectEqualStrings("Zig", detached.title);
    try std.testing.expectEqualStrings("https://ziglang.org", detached.current_url);
    try std.testing.expect(detached.is_private);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x1)), detached.webview_handle);
    try expectTabOrder(&manager, &.{ first, second });
    try std.testing.expectEqual(second, manager.active_tab_id.?);
}

test "detachTab chooses next tab when detaching active middle tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);
    const third = try manager.createTab("https://ziglang.org", false);

    try std.testing.expect(manager.activateTab(second));
    const detached = manager.detachTab(second).?;

    try std.testing.expectEqual(second, detached.id);
    try expectTabOrder(&manager, &.{ first, third });
    try std.testing.expectEqual(third, manager.active_tab_id.?);
}

test "detachTab chooses previous tab when detaching last active tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);
    const second = try manager.createTab("https://example.com", false);

    const detached = manager.detachTab(second).?;

    try std.testing.expectEqual(second, detached.id);
    try expectTabOrder(&manager, &.{first});
    try std.testing.expectEqual(first, manager.active_tab_id.?);
}

test "detachTab clears active tab when final tab detaches" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);

    const detached = manager.detachTab(first).?;

    try std.testing.expectEqual(first, detached.id);
    try std.testing.expectEqual(@as(usize, 0), manager.len());
    try std.testing.expect(manager.active_tab_id == null);
    try std.testing.expect(manager.activeTab() == null);
}

test "detachTab rejects unknown tab" {
    var manager = TabManager.init(std.testing.allocator);
    defer manager.deinit();

    const first = try manager.createTab("nimlo://start", false);

    try std.testing.expect(manager.detachTab(99) == null);
    try expectTabOrder(&manager, &.{first});
    try std.testing.expectEqual(first, manager.active_tab_id.?);
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

fn expectTabOrder(manager: *const TabManager, expected_ids: []const TabId) !void {
    try std.testing.expectEqual(expected_ids.len, manager.tabs.items.len);
    for (expected_ids, 0..) |expected_id, index| {
        try std.testing.expectEqual(expected_id, manager.tabs.items[index].id);
    }
}
