//! Catalog of content-blocking filter lists: which lists exist, where they
//! update from, whether they are enabled, and their parse/update metadata.
//! Persisted as JSONL (`lists.jsonl`) next to the raw list text files
//! (`<id>.txt`) in the filters directory (docs/CONTENT_BLOCKING.md, Phase E).

const std = @import("std");

pub const FilterListRecord = struct {
    /// Internal identifier, also the list's file stem ("easylist" →
    /// "easylist.txt"). Lowercase alphanumerics and dashes only.
    id: []const u8,
    name: []const u8,
    source_url: []const u8,
    enabled: bool,
    /// Unix seconds of the last successful update; 0 = bundled snapshot.
    updated_at: i64,
    /// Entity tag from the last download, for a future conditional GET.
    etag: []const u8 = "",
    rules_accepted: u64 = 0,
    rules_dropped: u64 = 0,
};

const PersistedFilterListRecord = struct {
    id: []const u8,
    name: []const u8 = "",
    source_url: []const u8 = "",
    enabled: bool = true,
    updated_at: i64 = 0,
    etag: []const u8 = "",
    rules_accepted: u64 = 0,
    rules_dropped: u64 = 0,
};

pub const FilterListStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(FilterListRecord),

    pub fn init(allocator: std.mem.Allocator) FilterListStore {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *FilterListStore) void {
        for (self.items.items) |record| {
            self.freeRecordStrings(record);
        }
        self.items.deinit(self.allocator);
    }

    pub fn records(self: *const FilterListStore) []const FilterListRecord {
        return self.items.items;
    }

    pub fn findRecord(self: *const FilterListStore, id: []const u8) ?*const FilterListRecord {
        for (self.items.items) |*record| {
            if (std.mem.eql(u8, record.id, id)) return record;
        }
        return null;
    }

    pub fn setEnabled(self: *FilterListStore, id: []const u8, enabled: bool) bool {
        for (self.items.items) |*record| {
            if (!std.mem.eql(u8, record.id, id)) continue;
            record.enabled = enabled;
            return true;
        }
        return false;
    }

    pub fn recordUpdate(
        self: *FilterListStore,
        id: []const u8,
        updated_at: i64,
        etag: []const u8,
        rules_accepted: u64,
        rules_dropped: u64,
    ) !bool {
        for (self.items.items) |*record| {
            if (!std.mem.eql(u8, record.id, id)) continue;

            const owned_etag = try self.allocator.dupe(u8, etag);
            self.allocator.free(record.etag);
            record.etag = owned_etag;
            record.updated_at = updated_at;
            record.rules_accepted = rules_accepted;
            record.rules_dropped = rules_dropped;
            return true;
        }
        return false;
    }

    pub fn upsert(self: *FilterListStore, record: FilterListRecord) !void {
        if (!isValidListId(record.id)) return error.InvalidListId;

        for (self.items.items) |*existing| {
            if (!std.mem.eql(u8, existing.id, record.id)) continue;

            const replacement = try self.dupeRecord(record);
            self.freeRecordStrings(existing.*);
            existing.* = replacement;
            return;
        }

        try self.items.append(self.allocator, try self.dupeRecord(record));
    }

    /// Seeds a catalog entry plus its list text on first run. Returns true
    /// when the record was missing and has been created.
    pub fn ensureDefault(
        self: *FilterListStore,
        dir: std.Io.Dir,
        io: std.Io,
        directory_path: []const u8,
        record: FilterListRecord,
        snapshot_text: []const u8,
    ) !bool {
        if (self.findRecord(record.id) != null) return false;

        try self.upsert(record);
        try writeListText(dir, io, self.allocator, directory_path, record.id, snapshot_text);
        return true;
    }

    pub fn loadFromFile(self: *FilterListStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        const contents = dir.readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);

        var loaded = FilterListStore.init(self.allocator);
        errdefer loaded.deinit();

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

            var parsed = std.json.parseFromSlice(PersistedFilterListRecord, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            if (!isValidListId(parsed.value.id)) continue;
            loaded.upsert(.{
                .id = parsed.value.id,
                .name = parsed.value.name,
                .source_url = parsed.value.source_url,
                .enabled = parsed.value.enabled,
                .updated_at = parsed.value.updated_at,
                .etag = parsed.value.etag,
                .rules_accepted = parsed.value.rules_accepted,
                .rules_dropped = parsed.value.rules_dropped,
            }) catch continue;
        }

        self.clearRecords();
        self.items.deinit(self.allocator);
        self.items = loaded.items;
        loaded.items = .empty;
    }

    pub fn saveToFile(self: *FilterListStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (self.items.items) |record| {
            try output.appendSlice(self.allocator, "{\"id\":\"");
            try appendJsonStringContent(&output, self.allocator, record.id);
            try output.appendSlice(self.allocator, "\",\"name\":\"");
            try appendJsonStringContent(&output, self.allocator, record.name);
            try output.appendSlice(self.allocator, "\",\"source_url\":\"");
            try appendJsonStringContent(&output, self.allocator, record.source_url);
            try output.appendSlice(self.allocator, "\",\"etag\":\"");
            try appendJsonStringContent(&output, self.allocator, record.etag);
            const suffix = try std.fmt.allocPrint(
                self.allocator,
                "\",\"enabled\":{},\"updated_at\":{d},\"rules_accepted\":{d},\"rules_dropped\":{d}}}\n",
                .{ record.enabled, record.updated_at, record.rules_accepted, record.rules_dropped },
            );
            defer self.allocator.free(suffix);
            try output.appendSlice(self.allocator, suffix);
        }

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.items,
        });
    }

    fn clearRecords(self: *FilterListStore) void {
        for (self.items.items) |record| {
            self.freeRecordStrings(record);
        }
        self.items.clearRetainingCapacity();
    }

    fn dupeRecord(self: *FilterListStore, record: FilterListRecord) !FilterListRecord {
        const id = try self.allocator.dupe(u8, record.id);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, record.name);
        errdefer self.allocator.free(name);
        const source_url = try self.allocator.dupe(u8, record.source_url);
        errdefer self.allocator.free(source_url);
        const etag = try self.allocator.dupe(u8, record.etag);
        errdefer self.allocator.free(etag);

        return .{
            .id = id,
            .name = name,
            .source_url = source_url,
            .enabled = record.enabled,
            .updated_at = record.updated_at,
            .etag = etag,
            .rules_accepted = record.rules_accepted,
            .rules_dropped = record.rules_dropped,
        };
    }

    fn freeRecordStrings(self: *FilterListStore, record: FilterListRecord) void {
        self.allocator.free(record.id);
        self.allocator.free(record.name);
        self.allocator.free(record.source_url);
        self.allocator.free(record.etag);
    }
};

pub fn isValidListId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |char| {
        const ok = std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn listTextPath(allocator: std.mem.Allocator, directory_path: []const u8, id: []const u8) ![]u8 {
    if (!isValidListId(id)) return error.InvalidListId;
    return std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{ directory_path, id });
}

pub fn readListText(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    directory_path: []const u8,
    id: []const u8,
) ![]u8 {
    const path = try listTextPath(allocator, directory_path, id);
    defer allocator.free(path);
    return dir.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
}

/// Replaces a list's text through a temp file + rename so a crash mid-write
/// never leaves a truncated list behind.
pub fn writeListText(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    directory_path: []const u8,
    id: []const u8,
    text: []const u8,
) !void {
    const path = try listTextPath(allocator, directory_path, id);
    defer allocator.free(path);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    try dir.writeFile(io, .{
        .sub_path = temp_path,
        .data = text,
    });
    try dir.rename(temp_path, dir, path, io);
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

fn testRecord(id: []const u8) FilterListRecord {
    return .{
        .id = id,
        .name = "Test List",
        .source_url = "https://lists.example/test.txt",
        .enabled = true,
        .updated_at = 0,
    };
}

test "upsert inserts and replaces by id" {
    var store = FilterListStore.init(std.testing.allocator);
    defer store.deinit();

    try store.upsert(testRecord("easylist"));
    try store.upsert(testRecord("easyprivacy"));
    try std.testing.expectEqual(@as(usize, 2), store.records().len);

    var replacement = testRecord("easylist");
    replacement.updated_at = 42;
    try store.upsert(replacement);

    try std.testing.expectEqual(@as(usize, 2), store.records().len);
    try std.testing.expectEqual(@as(i64, 42), store.findRecord("easylist").?.updated_at);
}

test "invalid ids are rejected" {
    var store = FilterListStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidListId, store.upsert(testRecord("../escape")));
    try std.testing.expectError(error.InvalidListId, store.upsert(testRecord("UPPER")));
    try std.testing.expectError(error.InvalidListId, store.upsert(testRecord("")));
    try std.testing.expectError(error.InvalidListId, listTextPath(std.testing.allocator, "/tmp", "a/b"));
}

test "enable toggle and update metadata" {
    var store = FilterListStore.init(std.testing.allocator);
    defer store.deinit();
    try store.upsert(testRecord("easylist"));

    try std.testing.expect(store.setEnabled("easylist", false));
    try std.testing.expect(!store.findRecord("easylist").?.enabled);
    try std.testing.expect(!store.setEnabled("missing", true));

    try std.testing.expect(try store.recordUpdate("easylist", 1234, "\"etag-1\"", 50_000, 12));
    const updated = store.findRecord("easylist").?;
    try std.testing.expectEqual(@as(i64, 1234), updated.updated_at);
    try std.testing.expectEqualStrings("\"etag-1\"", updated.etag);
    try std.testing.expectEqual(@as(u64, 50_000), updated.rules_accepted);
}

test "save and load round-trips the catalog" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var saved = FilterListStore.init(std.testing.allocator);
    defer saved.deinit();
    try saved.upsert(testRecord("easylist"));
    try std.testing.expect(saved.setEnabled("easylist", false));
    try std.testing.expect(try saved.recordUpdate("easylist", 77, "tag\"quoted\"", 5, 1));

    try saved.saveToFile(tmp_dir.dir, std.testing.io, "lists.jsonl");

    var loaded = FilterListStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "lists.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.records().len);
    const record = loaded.findRecord("easylist").?;
    try std.testing.expectEqualStrings("Test List", record.name);
    try std.testing.expectEqualStrings("https://lists.example/test.txt", record.source_url);
    try std.testing.expectEqualStrings("tag\"quoted\"", record.etag);
    try std.testing.expect(!record.enabled);
    try std.testing.expectEqual(@as(i64, 77), record.updated_at);
    try std.testing.expectEqual(@as(u64, 5), record.rules_accepted);
}

test "load skips malformed and invalid-id lines" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "lists.jsonl",
        .data =
        \\not json
        \\{"id":"../evil","name":"x"}
        \\{"id":"easylist","name":"EasyList","source_url":"https://easylist.to/easylist/easylist.txt"}
        \\
        ,
    });

    var loaded = FilterListStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "lists.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.records().len);
    try std.testing.expectEqualStrings("easylist", loaded.records()[0].id);
}

test "ensureDefault seeds record and text once" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = FilterListStore.init(std.testing.allocator);
    defer store.deinit();

    const seeded = try store.ensureDefault(tmp_dir.dir, std.testing.io, ".", testRecord("easylist"), "||ads.example.com^\n");
    try std.testing.expect(seeded);
    const again = try store.ensureDefault(tmp_dir.dir, std.testing.io, ".", testRecord("easylist"), "other text");
    try std.testing.expect(!again);

    const text = try readListText(tmp_dir.dir, std.testing.io, std.testing.allocator, ".", "easylist");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("||ads.example.com^\n", text);
}

test "writeListText replaces atomically via rename" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try writeListText(tmp_dir.dir, std.testing.io, std.testing.allocator, ".", "easylist", "first");
    try writeListText(tmp_dir.dir, std.testing.io, std.testing.allocator, ".", "easylist", "second");

    const text = try readListText(tmp_dir.dir, std.testing.io, std.testing.allocator, ".", "easylist");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("second", text);

    // No stray temp file left behind.
    const temp_missing = tmp_dir.dir.readFileAlloc(std.testing.io, "easylist.txt.tmp", std.testing.allocator, .limited(16));
    try std.testing.expectError(error.FileNotFound, temp_missing);
}
