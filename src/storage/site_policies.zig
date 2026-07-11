//! Per-site content-blocking policies (docs/CONTENT_BLOCKING.md, Phase G).
//! 0.8 ships allow-only: a host on the list has network blocking disabled
//! for documents on that host and its subdomains. Persisted as JSONL
//! (`site_policies.jsonl`) beside the filter lists.

const std = @import("std");

pub const SitePolicyRecord = struct {
    host: []const u8,
    added_at: i64,
};

const PersistedSitePolicyRecord = struct {
    host: []const u8,
    added_at: i64 = 0,
};

pub const SitePolicyStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(SitePolicyRecord),

    pub fn init(allocator: std.mem.Allocator) SitePolicyStore {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *SitePolicyStore) void {
        for (self.items.items) |record| {
            self.allocator.free(record.host);
        }
        self.items.deinit(self.allocator);
    }

    pub fn records(self: *const SitePolicyStore) []const SitePolicyRecord {
        return self.items.items;
    }

    /// Hosts in insertion order, for building the platform allow rule.
    pub fn allowedHosts(self: *const SitePolicyStore, allocator: std.mem.Allocator) ![]const []const u8 {
        const hosts = try allocator.alloc([]const u8, self.items.items.len);
        for (self.items.items, 0..) |record, index| {
            hosts[index] = record.host;
        }
        return hosts;
    }

    /// True when `host` or any of its parent domains has an allow policy.
    pub fn isAllowed(self: *const SitePolicyStore, host: []const u8) bool {
        var buffer: [256]u8 = undefined;
        const normalized = normalizeHost(&buffer, host) orelse return false;
        for (self.items.items) |record| {
            if (hostMatchesPolicyDomain(normalized, record.host)) return true;
        }
        return false;
    }

    /// Adds an allow policy; returns false when it was already covered by
    /// an identical entry.
    pub fn allow(self: *SitePolicyStore, host: []const u8, added_at: i64) !bool {
        var buffer: [256]u8 = undefined;
        const normalized = normalizeHost(&buffer, host) orelse return error.InvalidHost;
        for (self.items.items) |record| {
            if (std.mem.eql(u8, record.host, normalized)) return false;
        }

        const owned = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(owned);
        try self.items.append(self.allocator, .{ .host = owned, .added_at = added_at });
        return true;
    }

    /// Removes the exact-host policy; returns false when absent.
    pub fn remove(self: *SitePolicyStore, host: []const u8) bool {
        var buffer: [256]u8 = undefined;
        const normalized = normalizeHost(&buffer, host) orelse return false;
        for (self.items.items, 0..) |record, index| {
            if (!std.mem.eql(u8, record.host, normalized)) continue;
            self.allocator.free(record.host);
            _ = self.items.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn loadFromFile(self: *SitePolicyStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        const contents = dir.readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);

        var loaded = SitePolicyStore.init(self.allocator);
        errdefer loaded.deinit();

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

            var parsed = std.json.parseFromSlice(PersistedSitePolicyRecord, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            _ = loaded.allow(parsed.value.host, parsed.value.added_at) catch continue;
        }

        for (self.items.items) |record| {
            self.allocator.free(record.host);
        }
        self.items.deinit(self.allocator);
        self.items = loaded.items;
        loaded.items = .empty;
    }

    pub fn saveToFile(self: *SitePolicyStore, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (self.items.items) |record| {
            const line = try std.fmt.allocPrint(
                self.allocator,
                "{{\"host\":\"{s}\",\"added_at\":{d}}}\n",
                .{ record.host, record.added_at },
            );
            defer self.allocator.free(line);
            try output.appendSlice(self.allocator, line);
        }

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.items,
        });
    }
};

/// Lowercases and validates a host into `buffer`: non-empty, ASCII
/// hostname characters only, no ports/paths/userinfo. Hosts come from
/// URLs the webview already resolved, so anything else is a caller bug.
fn normalizeHost(buffer: []u8, host: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, host, " \t");
    if (trimmed.len == 0 or trimmed.len > buffer.len) return null;
    for (trimmed, 0..) |char, index| {
        const lower = std.ascii.toLower(char);
        const ok = std.ascii.isAlphanumeric(lower) or lower == '.' or lower == '-';
        if (!ok) return null;
        buffer[index] = lower;
    }
    return buffer[0..trimmed.len];
}

fn hostMatchesPolicyDomain(host: []const u8, domain: []const u8) bool {
    if (host.len < domain.len) return false;
    if (!std.mem.endsWith(u8, host, domain)) return false;
    return host.len == domain.len or host[host.len - domain.len - 1] == '.';
}

test "allow, subdomain coverage, and remove" {
    var store = SitePolicyStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expect(try store.allow("News.Example", 10));
    try std.testing.expect(!try store.allow("news.example", 20));

    try std.testing.expect(store.isAllowed("news.example"));
    try std.testing.expect(store.isAllowed("sub.news.example"));
    try std.testing.expect(store.isAllowed("NEWS.EXAMPLE"));
    try std.testing.expect(!store.isAllowed("other.example"));
    try std.testing.expect(!store.isAllowed("badnews.example"));

    try std.testing.expect(store.remove("news.example"));
    try std.testing.expect(!store.remove("news.example"));
    try std.testing.expect(!store.isAllowed("news.example"));
}

test "invalid hosts are rejected" {
    var store = SitePolicyStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidHost, store.allow("", 1));
    try std.testing.expectError(error.InvalidHost, store.allow("host/path", 1));
    try std.testing.expectError(error.InvalidHost, store.allow("host:8080", 1));
    try std.testing.expect(!store.isAllowed("host:8080"));
}

test "save and load round-trips policies" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var saved = SitePolicyStore.init(std.testing.allocator);
    defer saved.deinit();
    _ = try saved.allow("news.example", 11);
    _ = try saved.allow("shop.example", 22);

    try saved.saveToFile(tmp_dir.dir, std.testing.io, "site_policies.jsonl");

    var loaded = SitePolicyStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "site_policies.jsonl");

    try std.testing.expectEqual(@as(usize, 2), loaded.records().len);
    try std.testing.expect(loaded.isAllowed("news.example"));
    try std.testing.expectEqual(@as(i64, 22), loaded.records()[1].added_at);

    const hosts = try loaded.allowedHosts(std.testing.allocator);
    defer std.testing.allocator.free(hosts);
    try std.testing.expectEqualStrings("news.example", hosts[0]);
}

test "load skips malformed lines and missing file loads empty" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "site_policies.jsonl",
        .data =
        \\garbage
        \\{"host":"bad host with spaces"}
        \\{"host":"good.example","added_at":5}
        \\
        ,
    });

    var loaded = SitePolicyStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromFile(tmp_dir.dir, std.testing.io, "site_policies.jsonl");
    try std.testing.expectEqual(@as(usize, 1), loaded.records().len);

    var empty = SitePolicyStore.init(std.testing.allocator);
    defer empty.deinit();
    try empty.loadFromFile(tmp_dir.dir, std.testing.io, "missing.jsonl");
    try std.testing.expectEqual(@as(usize, 0), empty.records().len);
}
