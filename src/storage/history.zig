const std = @import("std");

pub const HistoryEntry = struct {
    url: []const u8,
    title: []const u8,
    visited_at: i64,
};

pub const HistoryStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(HistoryEntry),

    pub fn init(allocator: std.mem.Allocator) HistoryStore {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *HistoryStore) void {
        for (self.items.items) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.title);
        }
        self.items.deinit(self.allocator);
    }

    pub fn entries(self: *const HistoryStore) []const HistoryEntry {
        return self.items.items;
    }

    pub fn recordVisit(self: *HistoryStore, url: []const u8, title: []const u8, visited_at: i64) !void {
        if (!shouldRecordUrl(url)) return;

        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);

        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);

        try self.items.append(self.allocator, .{
            .url = owned_url,
            .title = owned_title,
            .visited_at = visited_at,
        });
    }
};

pub fn shouldRecordUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    if (std.mem.startsWith(u8, url, "nimlo://")) return false;
    return true;
}

test "records visits in memory" {
    var store = HistoryStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordVisit("https://example.com/docs", "Example Docs", 1234);

    try std.testing.expectEqual(@as(usize, 1), store.entries().len);
    try std.testing.expectEqualStrings("https://example.com/docs", store.entries()[0].url);
    try std.testing.expectEqualStrings("Example Docs", store.entries()[0].title);
    try std.testing.expectEqual(@as(i64, 1234), store.entries()[0].visited_at);
}

test "skips internal urls" {
    var store = HistoryStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordVisit("nimlo://start", "Nimlo", 1);
    try store.recordVisit("nimlo://about", "About Nimlo", 2);

    try std.testing.expectEqual(@as(usize, 0), store.entries().len);
}

test "skips empty urls" {
    var store = HistoryStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordVisit("", "Untitled", 1);

    try std.testing.expectEqual(@as(usize, 0), store.entries().len);
}
