const std = @import("std");

pub const HistoryEntry = struct {
    url: []const u8,
    title: []const u8,
    visited_at: i64,
};

const PersistedHistoryEntry = struct {
    url: []const u8,
    title: []const u8 = "",
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

    pub fn clear(self: *HistoryStore) void {
        for (self.items.items) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.title);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn maxVisitedAt(self: *const HistoryStore) i64 {
        var max: i64 = 0;
        for (self.items.items) |entry| {
            if (entry.visited_at > max) max = entry.visited_at;
        }
        return max;
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

    pub fn loadFromFile(self: *HistoryStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        const contents = dir.readFileAlloc(io, path, self.allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);

        var loaded = HistoryStore.init(self.allocator);
        errdefer loaded.deinit();

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

            var parsed = std.json.parseFromSlice(PersistedHistoryEntry, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            try loaded.recordVisit(
                parsed.value.url,
                parsed.value.title,
                parsed.value.visited_at,
            );
        }

        self.clear();
        self.items = loaded.items;
        loaded.items = .empty;
    }

    pub fn saveToFile(self: *const HistoryStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (self.items.items) |entry| {
            try output.append(self.allocator, '{');
            try output.appendSlice(self.allocator, "\"visited_at\":");
            const timestamp = try std.fmt.allocPrint(self.allocator, "{d}", .{entry.visited_at});
            defer self.allocator.free(timestamp);
            try output.appendSlice(self.allocator, timestamp);
            try output.appendSlice(self.allocator, ",\"url\":\"");
            try appendJsonStringContent(&output, self.allocator, entry.url);
            try output.appendSlice(self.allocator, "\",\"title\":\"");
            try appendJsonStringContent(&output, self.allocator, entry.title);
            try output.appendSlice(self.allocator, "\"}\n");
        }

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.items,
        });
    }

    pub fn clearAndSave(self: *HistoryStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        self.clear();
        try self.saveToFile(dir, io, path);
    }
};

pub fn shouldRecordUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    if (std.mem.startsWith(u8, url, "nimlo://")) return false;
    return true;
}

fn appendJsonStringContent(output: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '"' => try output.appendSlice(allocator, "\\\""),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => if (byte < 0x20) {
                const escaped = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{byte});
                defer allocator.free(escaped);
                try output.appendSlice(allocator, escaped);
            } else {
                try output.append(allocator, byte);
            },
        }
    }
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

test "saves and loads history file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var saved = HistoryStore.init(std.testing.allocator);
    defer saved.deinit();
    try saved.recordVisit("https://example.com/docs", "Example \"Docs\"", 11);
    try saved.recordVisit("https://ziglang.org/\nlearn", "Zig\nLearn", 12);

    try saved.saveToFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    var loaded = HistoryStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    try std.testing.expectEqual(@as(usize, 2), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/docs", loaded.entries()[0].url);
    try std.testing.expectEqualStrings("Example \"Docs\"", loaded.entries()[0].title);
    try std.testing.expectEqual(@as(i64, 11), loaded.entries()[0].visited_at);
    try std.testing.expectEqualStrings("https://ziglang.org/\nlearn", loaded.entries()[1].url);
    try std.testing.expectEqualStrings("Zig\nLearn", loaded.entries()[1].title);
    try std.testing.expectEqual(@as(i64, 12), loaded.entries()[1].visited_at);
    try std.testing.expectEqual(@as(i64, 12), loaded.maxVisitedAt());
}

test "missing history file loads as empty" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = HistoryStore.init(std.testing.allocator);
    defer store.deinit();

    try store.loadFromFile(tmp_dir.dir, std.testing.io, "missing.jsonl");

    try std.testing.expectEqual(@as(usize, 0), store.entries().len);
}

test "load skips malformed history lines" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "history.jsonl",
        .data =
        \\not json
        \\{"visited_at":21,"url":"https://example.com","title":"Example"}
        \\{"visited_at":"bad","url":"https://bad.example","title":"Bad"}
        \\
        ,
    });

    var store = HistoryStore.init(std.testing.allocator);
    defer store.deinit();

    try store.loadFromFile(tmp_dir.dir, std.testing.io, "history.jsonl");

    try std.testing.expectEqual(@as(usize, 1), store.entries().len);
    try std.testing.expectEqualStrings("https://example.com", store.entries()[0].url);
    try std.testing.expectEqual(@as(i64, 21), store.entries()[0].visited_at);
}

test "clear and save rewrites history file empty" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = HistoryStore.init(std.testing.allocator);
    defer store.deinit();
    try store.recordVisit("https://example.com", "Example", 31);

    try store.clearAndSave(tmp_dir.dir, std.testing.io, "history.jsonl");

    try std.testing.expectEqual(@as(usize, 0), store.entries().len);

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "history.jsonl", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 0), contents.len);
}
