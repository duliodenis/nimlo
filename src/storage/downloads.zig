const std = @import("std");

pub const DownloadState = enum {
    in_progress,
    completed,
    failed,

    pub fn label(self: DownloadState) []const u8 {
        return switch (self) {
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
        };
    }

    pub fn parse(text: []const u8) ?DownloadState {
        inline for (@typeInfo(DownloadState).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const DownloadEntry = struct {
    id: u64,
    url: []const u8,
    filename: []const u8,
    file_path: []const u8,
    size_bytes: u64,
    started_at: i64,
    state: DownloadState,
};

const PersistedDownloadEntry = struct {
    id: u64,
    url: []const u8,
    filename: []const u8 = "",
    file_path: []const u8 = "",
    size_bytes: u64 = 0,
    started_at: i64,
    state: []const u8 = "completed",
};

pub const DownloadStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(DownloadEntry),

    pub fn init(allocator: std.mem.Allocator) DownloadStore {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *DownloadStore) void {
        for (self.items.items) |entry| {
            self.freeEntryStrings(entry);
        }
        self.items.deinit(self.allocator);
    }

    pub fn entries(self: *const DownloadStore) []const DownloadEntry {
        return self.items.items;
    }

    pub fn clear(self: *DownloadStore) void {
        for (self.items.items) |entry| {
            self.freeEntryStrings(entry);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn findEntry(self: *const DownloadStore, id: u64) ?*const DownloadEntry {
        for (self.items.items) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    // Returns an id that is unique within the store, starting from the given
    // timestamp so ids stay roughly chronological.
    pub fn uniqueId(self: *const DownloadStore, started_at: i64) u64 {
        var candidate: u64 = if (started_at > 0) @intCast(started_at) else 1;
        while (self.findEntry(candidate) != null) candidate += 1;
        return candidate;
    }

    pub fn recordStart(self: *DownloadStore, entry: DownloadEntry) !void {
        if (entry.url.len == 0) return;

        try self.appendEntry(
            entry.id,
            entry.url,
            entry.filename,
            entry.file_path,
            entry.size_bytes,
            entry.started_at,
            entry.state,
        );
    }

    pub fn markCompleted(self: *DownloadStore, id: u64, size_bytes: u64) bool {
        for (self.items.items) |*entry| {
            if (entry.id != id) continue;
            entry.state = .completed;
            entry.size_bytes = size_bytes;
            return true;
        }
        return false;
    }

    pub fn markFailed(self: *DownloadStore, id: u64) bool {
        for (self.items.items) |*entry| {
            if (entry.id != id) continue;
            entry.state = .failed;
            return true;
        }
        return false;
    }

    pub fn removeId(self: *DownloadStore, id: u64) bool {
        var index: usize = 0;
        while (index < self.items.items.len) : (index += 1) {
            const entry = self.items.items[index];
            if (entry.id != id) continue;

            self.freeEntryStrings(entry);
            _ = self.items.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn removeIds(self: *DownloadStore, ids: []const u64) usize {
        var removed: usize = 0;
        for (ids) |id| {
            if (self.removeId(id)) removed += 1;
        }
        return removed;
    }

    pub fn loadFromFile(self: *DownloadStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        const contents = dir.readFileAlloc(io, path, self.allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);

        var loaded = DownloadStore.init(self.allocator);
        errdefer loaded.deinit();

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

            var parsed = std.json.parseFromSlice(PersistedDownloadEntry, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            if (parsed.value.url.len == 0) continue;
            const state = DownloadState.parse(parsed.value.state) orelse continue;
            try loaded.appendEntry(
                parsed.value.id,
                parsed.value.url,
                parsed.value.filename,
                parsed.value.file_path,
                parsed.value.size_bytes,
                parsed.value.started_at,
                // A persisted in-progress download can no longer be running;
                // the app that owned it is gone.
                if (state == .in_progress) .failed else state,
            );
        }

        loaded.canonicalize();

        self.clear();
        self.items.deinit(self.allocator);
        self.items = loaded.items;
        loaded.items = .empty;
    }

    pub fn saveToFile(self: *DownloadStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        self.canonicalize();

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (self.items.items) |entry| {
            const prefix = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"started_at\":{d},\"size_bytes\":{d},\"state\":\"{s}\",\"url\":\"",
                .{ entry.id, entry.started_at, entry.size_bytes, entry.state.label() },
            );
            defer self.allocator.free(prefix);
            try output.appendSlice(self.allocator, prefix);
            try appendJsonStringContent(&output, self.allocator, entry.url);
            try output.appendSlice(self.allocator, "\",\"filename\":\"");
            try appendJsonStringContent(&output, self.allocator, entry.filename);
            try output.appendSlice(self.allocator, "\",\"file_path\":\"");
            try appendJsonStringContent(&output, self.allocator, entry.file_path);
            try output.appendSlice(self.allocator, "\"}\n");
        }

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.items,
        });
    }

    pub fn clearAndSave(self: *DownloadStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        self.clear();
        try self.saveToFile(dir, io, path);
    }

    pub fn canonicalize(self: *DownloadStore) void {
        std.mem.sort(DownloadEntry, self.items.items, {}, moreRecentThan);
    }

    fn moreRecentThan(_: void, lhs: DownloadEntry, rhs: DownloadEntry) bool {
        if (lhs.started_at == rhs.started_at) {
            return lhs.id > rhs.id;
        }
        return lhs.started_at > rhs.started_at;
    }

    fn appendEntry(
        self: *DownloadStore,
        id: u64,
        url: []const u8,
        filename: []const u8,
        file_path: []const u8,
        size_bytes: u64,
        started_at: i64,
        state: DownloadState,
    ) !void {
        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);

        const owned_filename = try self.allocator.dupe(u8, filename);
        errdefer self.allocator.free(owned_filename);

        const owned_file_path = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(owned_file_path);

        try self.items.append(self.allocator, .{
            .id = id,
            .url = owned_url,
            .filename = owned_filename,
            .file_path = owned_file_path,
            .size_bytes = size_bytes,
            .started_at = started_at,
            .state = state,
        });
    }

    fn freeEntryStrings(self: *DownloadStore, entry: DownloadEntry) void {
        self.allocator.free(entry.url);
        self.allocator.free(entry.filename);
        self.allocator.free(entry.file_path);
    }
};

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

fn testEntry(id: u64, url: []const u8, started_at: i64) DownloadEntry {
    return .{
        .id = id,
        .url = url,
        .filename = "file.zip",
        .file_path = "/tmp/file.zip",
        .size_bytes = 0,
        .started_at = started_at,
        .state = .in_progress,
    };
}

test "records download starts and transitions state" {
    var store = DownloadStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordStart(testEntry(1, "https://example.com/a.zip", 100));
    try store.recordStart(testEntry(2, "https://example.com/b.zip", 200));

    try std.testing.expectEqual(@as(usize, 2), store.entries().len);
    try std.testing.expect(store.markCompleted(1, 4096));
    try std.testing.expect(store.markFailed(2));
    try std.testing.expect(!store.markCompleted(99, 1));

    const completed = store.findEntry(1).?;
    try std.testing.expectEqual(DownloadState.completed, completed.state);
    try std.testing.expectEqual(@as(u64, 4096), completed.size_bytes);
    try std.testing.expectEqual(DownloadState.failed, store.findEntry(2).?.state);
}

test "skips empty urls" {
    var store = DownloadStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordStart(testEntry(1, "", 100));

    try std.testing.expectEqual(@as(usize, 0), store.entries().len);
}

test "unique id bumps past collisions" {
    var store = DownloadStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordStart(testEntry(100, "https://example.com/a.zip", 100));
    try store.recordStart(testEntry(101, "https://example.com/b.zip", 100));

    try std.testing.expectEqual(@as(u64, 102), store.uniqueId(100));
    try std.testing.expectEqual(@as(u64, 1), store.uniqueId(0));
}

test "canonicalize sorts newest first without deduping urls" {
    var store = DownloadStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordStart(testEntry(1, "https://example.com/a.zip", 100));
    try store.recordStart(testEntry(2, "https://example.com/a.zip", 300));
    try store.recordStart(testEntry(3, "https://example.com/b.zip", 200));

    store.canonicalize();

    try std.testing.expectEqual(@as(usize, 3), store.entries().len);
    try std.testing.expectEqual(@as(u64, 2), store.entries()[0].id);
    try std.testing.expectEqual(@as(u64, 3), store.entries()[1].id);
    try std.testing.expectEqual(@as(u64, 1), store.entries()[2].id);
}

test "removes downloads by id" {
    var store = DownloadStore.init(std.testing.allocator);
    defer store.deinit();

    try store.recordStart(testEntry(1, "https://example.com/a.zip", 100));
    try store.recordStart(testEntry(2, "https://example.com/b.zip", 200));
    try store.recordStart(testEntry(3, "https://example.com/c.zip", 300));

    const ids = [_]u64{ 2, 99, 1 };
    const removed = store.removeIds(&ids);

    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expectEqual(@as(usize, 1), store.entries().len);
    try std.testing.expectEqual(@as(u64, 3), store.entries()[0].id);
}

test "saves and loads downloads file with escaping" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var saved = DownloadStore.init(std.testing.allocator);
    defer saved.deinit();
    try saved.recordStart(.{
        .id = 7,
        .url = "https://example.com/report \"final\".pdf",
        .filename = "report \"final\".pdf",
        .file_path = "/Users/test/Downloads/report \"final\".pdf",
        .size_bytes = 0,
        .started_at = 11,
        .state = .in_progress,
    });
    try std.testing.expect(saved.markCompleted(7, 2048));

    try saved.saveToFile(tmp_dir.dir, std.testing.io, "downloads.jsonl");

    var loaded = DownloadStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "downloads.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
    const entry = loaded.entries()[0];
    try std.testing.expectEqual(@as(u64, 7), entry.id);
    try std.testing.expectEqualStrings("https://example.com/report \"final\".pdf", entry.url);
    try std.testing.expectEqualStrings("report \"final\".pdf", entry.filename);
    try std.testing.expectEqualStrings("/Users/test/Downloads/report \"final\".pdf", entry.file_path);
    try std.testing.expectEqual(@as(u64, 2048), entry.size_bytes);
    try std.testing.expectEqual(@as(i64, 11), entry.started_at);
    try std.testing.expectEqual(DownloadState.completed, entry.state);
}

test "load demotes stale in-progress downloads to failed" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "downloads.jsonl",
        .data =
        \\{"id":1,"started_at":10,"size_bytes":0,"state":"in_progress","url":"https://example.com/a.zip","filename":"a.zip","file_path":"/tmp/a.zip"}
        \\{"id":2,"started_at":20,"size_bytes":512,"state":"completed","url":"https://example.com/b.zip","filename":"b.zip","file_path":"/tmp/b.zip"}
        \\
        ,
    });

    var loaded = DownloadStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "downloads.jsonl");

    try std.testing.expectEqual(@as(usize, 2), loaded.entries().len);
    try std.testing.expectEqual(DownloadState.completed, loaded.findEntry(2).?.state);
    try std.testing.expectEqual(DownloadState.failed, loaded.findEntry(1).?.state);
}

test "load skips malformed and unknown-state lines" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "downloads.jsonl",
        .data =
        \\not json
        \\{"id":1,"started_at":10,"state":"exploded","url":"https://bad.example/a.zip"}
        \\{"id":2,"started_at":20,"size_bytes":64,"state":"completed","url":"https://example.com/b.zip","filename":"b.zip","file_path":"/tmp/b.zip"}
        \\{"id":"bad","started_at":30,"url":"https://bad.example/c.zip"}
        \\
        ,
    });

    var loaded = DownloadStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "downloads.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
    try std.testing.expectEqual(@as(u64, 2), loaded.entries()[0].id);
}

test "missing downloads file loads as empty" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = DownloadStore.init(std.testing.allocator);
    defer store.deinit();

    try store.loadFromFile(tmp_dir.dir, std.testing.io, "missing.jsonl");

    try std.testing.expectEqual(@as(usize, 0), store.entries().len);
}

test "clear and save rewrites downloads file empty" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = DownloadStore.init(std.testing.allocator);
    defer store.deinit();
    try store.recordStart(testEntry(1, "https://example.com/a.zip", 100));

    try store.clearAndSave(tmp_dir.dir, std.testing.io, "downloads.jsonl");

    try std.testing.expectEqual(@as(usize, 0), store.entries().len);

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "downloads.jsonl", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 0), contents.len);
}
