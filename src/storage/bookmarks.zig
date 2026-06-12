const std = @import("std");

pub const BookmarkEntry = struct {
    url: []const u8,
    title: []const u8,
    created_at: i64,
    tags: []const []const u8 = &.{},
};

const PersistedBookmarkEntry = struct {
    url: []const u8,
    title: []const u8 = "",
    created_at: i64,
    tags: []const []const u8 = &.{},
};

pub const BookmarkStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(BookmarkEntry),

    pub fn init(allocator: std.mem.Allocator) BookmarkStore {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *BookmarkStore) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    pub fn entries(self: *const BookmarkStore) []const BookmarkEntry {
        return self.items.items;
    }

    pub fn clear(self: *BookmarkStore) void {
        for (self.items.items) |entry| {
            self.freeEntry(entry);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn addOrUpdate(self: *BookmarkStore, url: []const u8, title: []const u8, created_at: i64) !void {
        if (!shouldStoreUrl(url)) return;

        for (self.items.items) |*entry| {
            if (std.mem.eql(u8, entry.url, url)) {
                const owned_title = try self.allocator.dupe(u8, title);
                self.allocator.free(entry.title);
                entry.title = owned_title;
                entry.created_at = created_at;
                self.canonicalize();
                return;
            }
        }

        try self.appendBookmark(url, title, created_at, &.{});
        self.canonicalize();
    }

    pub fn setTags(self: *BookmarkStore, url: []const u8, tags: []const []const u8) !bool {
        for (self.items.items) |*entry| {
            if (!std.mem.eql(u8, entry.url, url)) continue;

            const owned_tags = try self.normalizedTags(tags);
            self.freeTags(entry.tags);
            entry.tags = owned_tags;
            return true;
        }

        return false;
    }

    pub fn addTag(self: *BookmarkStore, url: []const u8, tag: []const u8) !bool {
        for (self.items.items) |*entry| {
            if (!std.mem.eql(u8, entry.url, url)) continue;

            var combined: std.ArrayList([]const u8) = .empty;
            defer combined.deinit(self.allocator);

            try combined.appendSlice(self.allocator, entry.tags);
            try combined.append(self.allocator, tag);

            const owned_tags = try self.normalizedTags(combined.items);
            self.freeTags(entry.tags);
            entry.tags = owned_tags;
            return true;
        }

        return false;
    }

    pub fn removeTag(self: *BookmarkStore, url: []const u8, tag: []const u8) !bool {
        const normalized = try normalizeTag(self.allocator, tag);
        defer self.allocator.free(normalized);
        if (normalized.len == 0) return false;

        for (self.items.items) |*entry| {
            if (!std.mem.eql(u8, entry.url, url)) continue;

            var kept: std.ArrayList([]const u8) = .empty;
            defer kept.deinit(self.allocator);

            for (entry.tags) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, normalized)) continue;
                try kept.append(self.allocator, existing);
            }

            if (kept.items.len == entry.tags.len) return false;
            const owned_tags = try self.normalizedTags(kept.items);
            self.freeTags(entry.tags);
            entry.tags = owned_tags;
            return true;
        }

        return false;
    }

    pub fn removeUrl(self: *BookmarkStore, url: []const u8) bool {
        var index: usize = 0;
        while (index < self.items.items.len) : (index += 1) {
            const entry = &self.items.items[index];
            if (!std.mem.eql(u8, entry.url, url)) continue;

            self.freeEntry(entry.*);
            _ = self.items.orderedRemove(index);
            return true;
        }

        return false;
    }

    pub fn loadFromFile(self: *BookmarkStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        const contents = dir.readFileAlloc(io, path, self.allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);

        var loaded = BookmarkStore.init(self.allocator);
        errdefer loaded.deinit();

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

            var parsed = std.json.parseFromSlice(PersistedBookmarkEntry, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            if (!shouldStoreUrl(parsed.value.url)) continue;
            try loaded.appendBookmark(
                parsed.value.url,
                parsed.value.title,
                parsed.value.created_at,
                parsed.value.tags,
            );
        }

        loaded.canonicalize();

        self.clear();
        self.items.deinit(self.allocator);
        self.items = loaded.items;
        loaded.items = .empty;
    }

    pub fn saveToFile(self: *BookmarkStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        self.canonicalize();

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (self.items.items) |entry| {
            try output.append(self.allocator, '{');
            try output.appendSlice(self.allocator, "\"created_at\":");
            const timestamp = try std.fmt.allocPrint(self.allocator, "{d}", .{entry.created_at});
            defer self.allocator.free(timestamp);
            try output.appendSlice(self.allocator, timestamp);
            try output.appendSlice(self.allocator, ",\"url\":\"");
            try appendJsonStringContent(&output, self.allocator, entry.url);
            try output.appendSlice(self.allocator, "\",\"title\":\"");
            try appendJsonStringContent(&output, self.allocator, entry.title);
            try output.appendSlice(self.allocator, "\",\"tags\":[");
            for (entry.tags, 0..) |tag, index| {
                if (index > 0) try output.append(self.allocator, ',');
                try output.append(self.allocator, '"');
                try appendJsonStringContent(&output, self.allocator, tag);
                try output.append(self.allocator, '"');
            }
            try output.appendSlice(self.allocator, "]}\n");
        }

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.items,
        });
    }

    pub fn canonicalize(self: *BookmarkStore) void {
        self.compactRepeatedUrls();
        std.mem.sort(BookmarkEntry, self.items.items, {}, moreRecentThan);
    }

    fn compactRepeatedUrls(self: *BookmarkStore) void {
        var index: usize = 0;
        while (index < self.items.items.len) : (index += 1) {
            var duplicate_index = index + 1;
            while (duplicate_index < self.items.items.len) {
                const entry = &self.items.items[index];
                const duplicate = &self.items.items[duplicate_index];
                if (!std.mem.eql(u8, entry.url, duplicate.url)) {
                    duplicate_index += 1;
                    continue;
                }

                if (duplicate.created_at >= entry.created_at) {
                    self.allocator.free(entry.title);
                    self.freeTags(entry.tags);
                    entry.title = duplicate.title;
                    entry.tags = duplicate.tags;
                    entry.created_at = duplicate.created_at;
                    self.allocator.free(duplicate.url);
                } else {
                    self.freeEntry(duplicate.*);
                }
                _ = self.items.orderedRemove(duplicate_index);
            }
        }
    }

    fn appendBookmark(self: *BookmarkStore, url: []const u8, title: []const u8, created_at: i64, tags: []const []const u8) !void {
        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);

        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);

        const owned_tags = try self.normalizedTags(tags);
        errdefer self.freeTags(owned_tags);

        try self.items.append(self.allocator, .{
            .url = owned_url,
            .title = owned_title,
            .created_at = created_at,
            .tags = owned_tags,
        });
    }

    fn normalizedTags(self: *BookmarkStore, tags: []const []const u8) ![]const []const u8 {
        var normalized: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (normalized.items) |tag| self.allocator.free(tag);
            normalized.deinit(self.allocator);
        }

        for (tags) |tag| {
            const owned_tag = try normalizeTag(self.allocator, tag);
            if (owned_tag.len == 0) {
                self.allocator.free(owned_tag);
                continue;
            }

            var duplicate_index: ?usize = null;
            for (normalized.items, 0..) |existing, index| {
                if (std.ascii.eqlIgnoreCase(existing, owned_tag)) {
                    duplicate_index = index;
                    break;
                }
            }

            if (duplicate_index) |index| {
                self.allocator.free(normalized.items[index]);
                normalized.items[index] = owned_tag;
            } else {
                try normalized.append(self.allocator, owned_tag);
            }
        }

        std.mem.sort([]const u8, normalized.items, {}, tagLessThan);
        return try normalized.toOwnedSlice(self.allocator);
    }

    fn freeEntry(self: *BookmarkStore, entry: BookmarkEntry) void {
        self.allocator.free(entry.url);
        self.allocator.free(entry.title);
        self.freeTags(entry.tags);
    }

    fn freeTags(self: *BookmarkStore, tags: []const []const u8) void {
        for (tags) |tag| self.allocator.free(tag);
        self.allocator.free(tags);
    }
};

pub fn shouldStoreUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    if (std.mem.startsWith(u8, url, "nimlo://")) return false;
    return true;
}

fn moreRecentThan(_: void, lhs: BookmarkEntry, rhs: BookmarkEntry) bool {
    if (lhs.created_at == rhs.created_at) {
        return std.mem.lessThan(u8, lhs.url, rhs.url);
    }
    return lhs.created_at > rhs.created_at;
}

fn tagLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(lhs, rhs);
}

fn normalizeTag(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, tag, " \t\r\n");
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var last_was_space = false;
    for (trimmed) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (output.items.len == 0 or last_was_space) continue;
            try output.append(allocator, ' ');
            last_was_space = true;
            continue;
        }

        try output.append(allocator, byte);
        last_was_space = false;
    }

    if (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        _ = output.pop();
    }

    return output.toOwnedSlice(allocator);
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

test "adds and updates one bookmark per url" {
    var store = BookmarkStore.init(std.testing.allocator);
    defer store.deinit();

    try store.addOrUpdate("https://example.com/docs", "Loading", 10);
    try store.addOrUpdate("https://example.com/docs", "Example Docs", 11);

    try std.testing.expectEqual(@as(usize, 1), store.entries().len);
    try std.testing.expectEqualStrings("https://example.com/docs", store.entries()[0].url);
    try std.testing.expectEqualStrings("Example Docs", store.entries()[0].title);
    try std.testing.expectEqual(@as(i64, 11), store.entries()[0].created_at);
}

test "keeps canonical newest first ordering" {
    var store = BookmarkStore.init(std.testing.allocator);
    defer store.deinit();

    try store.addOrUpdate("https://example.com/old", "Old", 1);
    try store.addOrUpdate("https://example.com/new", "New", 3);
    try store.addOrUpdate("https://example.com/mid", "Mid", 2);

    try std.testing.expectEqualStrings("https://example.com/new", store.entries()[0].url);
    try std.testing.expectEqualStrings("https://example.com/mid", store.entries()[1].url);
    try std.testing.expectEqualStrings("https://example.com/old", store.entries()[2].url);
}

test "removes bookmark by url" {
    var store = BookmarkStore.init(std.testing.allocator);
    defer store.deinit();

    try store.addOrUpdate("https://example.com/remove", "Remove", 1);
    try store.addOrUpdate("https://example.com/keep", "Keep", 2);

    try std.testing.expect(store.removeUrl("https://example.com/remove"));
    try std.testing.expect(!store.removeUrl("https://example.com/missing"));
    try std.testing.expectEqual(@as(usize, 1), store.entries().len);
    try std.testing.expectEqualStrings("https://example.com/keep", store.entries()[0].url);
}

test "saves and loads bookmarks jsonl" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var saved = BookmarkStore.init(std.testing.allocator);
    defer saved.deinit();
    try saved.addOrUpdate("https://example.com/old", "Old", 1);
    try saved.addOrUpdate("https://example.com/new?q=\"zig\"", "New\nTitle", 2);
    try std.testing.expect(try saved.addTag("https://example.com/new?q=\"zig\"", "zig"));
    try std.testing.expect(try saved.addTag("https://example.com/new?q=\"zig\"", "docs"));
    try saved.saveToFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    var loaded = BookmarkStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    try std.testing.expectEqual(@as(usize, 2), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com/new?q=\"zig\"", loaded.entries()[0].url);
    try std.testing.expectEqualStrings("New\nTitle", loaded.entries()[0].title);
    try std.testing.expectEqual(@as(i64, 2), loaded.entries()[0].created_at);
    try std.testing.expectEqual(@as(usize, 2), loaded.entries()[0].tags.len);
    try std.testing.expectEqualStrings("docs", loaded.entries()[0].tags[0]);
    try std.testing.expectEqualStrings("zig", loaded.entries()[0].tags[1]);
    try std.testing.expectEqualStrings("https://example.com/old", loaded.entries()[1].url);
}

test "load ignores malformed internal and duplicate older entries" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "bookmarks.jsonl",
        .data =
        \\{"created_at":2,"url":"https://example.com","title":"New"}
        \\not json
        \\{"created_at":1,"url":"https://example.com","title":"Old"}
        \\{"created_at":3,"url":"nimlo://history","title":"History"}
        \\
        ,
    });

    var loaded = BookmarkStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "bookmarks.jsonl");

    try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
    try std.testing.expectEqualStrings("https://example.com", loaded.entries()[0].url);
    try std.testing.expectEqualStrings("New", loaded.entries()[0].title);
    try std.testing.expectEqual(@as(i64, 2), loaded.entries()[0].created_at);
    try std.testing.expectEqual(@as(usize, 0), loaded.entries()[0].tags.len);
}

test "normalizes dedupes and removes tags" {
    var store = BookmarkStore.init(std.testing.allocator);
    defer store.deinit();

    try store.addOrUpdate("https://example.com/docs", "Docs", 1);
    try std.testing.expect(try store.addTag("https://example.com/docs", "  Zig   Language  "));
    try std.testing.expect(try store.addTag("https://example.com/docs", "zig language"));
    try std.testing.expect(try store.addTag("https://example.com/docs", "Docs"));
    try std.testing.expect(try store.addTag("https://example.com/docs", " "));

    try std.testing.expectEqual(@as(usize, 2), store.entries()[0].tags.len);
    try std.testing.expectEqualStrings("Docs", store.entries()[0].tags[0]);
    try std.testing.expectEqualStrings("zig language", store.entries()[0].tags[1]);

    try std.testing.expect(try store.removeTag("https://example.com/docs", "ZIG  LANGUAGE"));
    try std.testing.expect(!try store.removeTag("https://example.com/docs", "missing"));
    try std.testing.expectEqual(@as(usize, 1), store.entries()[0].tags.len);
    try std.testing.expectEqualStrings("Docs", store.entries()[0].tags[0]);
}

test "updating bookmark preserves tags" {
    var store = BookmarkStore.init(std.testing.allocator);
    defer store.deinit();

    try store.addOrUpdate("https://example.com/docs", "Loading", 1);
    try std.testing.expect(try store.addTag("https://example.com/docs", "docs"));
    try store.addOrUpdate("https://example.com/docs", "Docs", 2);

    try std.testing.expectEqual(@as(usize, 1), store.entries().len);
    try std.testing.expectEqualStrings("Docs", store.entries()[0].title);
    try std.testing.expectEqual(@as(usize, 1), store.entries()[0].tags.len);
    try std.testing.expectEqualStrings("docs", store.entries()[0].tags[0]);
}

test "set tags replaces normalized tags" {
    var store = BookmarkStore.init(std.testing.allocator);
    defer store.deinit();

    try store.addOrUpdate("https://example.com/docs", "Docs", 1);
    try std.testing.expect(try store.setTags("https://example.com/docs", &.{ " Zig ", "zig", "Reference" }));

    try std.testing.expectEqual(@as(usize, 2), store.entries()[0].tags.len);
    try std.testing.expectEqualStrings("Reference", store.entries()[0].tags[0]);
    try std.testing.expectEqualStrings("zig", store.entries()[0].tags[1]);
}
