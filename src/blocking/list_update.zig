//! Filter-list update flow: download, validate, then replace — in that
//! order, so a garbage download can never brick blocking
//! (docs/CONTENT_BLOCKING.md, Phase E). The network fetch is synchronous;
//! the settings page (Phase H) runs it on a worker thread and marshals the
//! outcome back to the UI thread.
//!
//! 0.8 deviation from the plan: the GET is unconditional. Capturing the
//! response ETag needs std.http's lower-level request API; the catalog
//! already persists an `etag` field so conditional GET can slot in without
//! a schema change.

const std = @import("std");
const abp_parser = @import("abp_parser.zig");
const filter_lists = @import("../storage/filter_lists.zig");

/// A plausible filter list has at least this many usable network rules;
/// real lists carry tens of thousands (Appendix A). Error pages, truncated
/// downloads, and HTML bodies all fall far below it.
pub const min_plausible_network_rules = 100;

pub const max_list_bytes = 64 * 1024 * 1024;

pub const Validation = union(enum) {
    accepted: struct {
        rules_accepted: u64,
        rules_dropped: u64,
    },
    rejected,
};

pub fn validateListText(allocator: std.mem.Allocator, text: []const u8) Validation {
    var parsed = abp_parser.parseList(allocator, text) catch return .rejected;
    defer parsed.deinit();

    const stats = parsed.stats;
    const network_total = stats.network_rules + stats.network_exceptions;
    if (network_total < min_plausible_network_rules) return .rejected;

    return .{ .accepted = .{
        .rules_accepted = stats.accepted(),
        .rules_dropped = stats.dropped(),
    } };
}

pub const ApplyOutcome = enum {
    applied,
    rejected_invalid,
    unknown_list,
};

/// Validates downloaded text and, only if plausible, replaces the stored
/// list and its catalog metadata. The previous text survives any rejection.
pub fn applyListText(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *filter_lists.FilterListStore,
    directory_path: []const u8,
    id: []const u8,
    text: []const u8,
    now_seconds: i64,
) !ApplyOutcome {
    if (store.findRecord(id) == null) return .unknown_list;

    const validation = validateListText(allocator, text);
    const accepted = switch (validation) {
        .rejected => return .rejected_invalid,
        .accepted => |value| value,
    };

    try filter_lists.writeListText(dir, io, allocator, directory_path, id, text);
    _ = try store.recordUpdate(id, now_seconds, "", accepted.rules_accepted, accepted.rules_dropped);
    try store.saveToFile(dir, io, "lists.jsonl");
    return .applied;
}

pub const FetchOutcome = union(enum) {
    applied,
    rejected_invalid,
    unknown_list,
    http_status: u10,
    fetch_failed,
};

/// Downloads a list from its catalog source URL and applies it. Blocking;
/// see the module comment for the threading contract.
pub fn fetchAndApply(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *filter_lists.FilterListStore,
    directory_path: []const u8,
    id: []const u8,
    now_seconds: i64,
) !FetchOutcome {
    const record = store.findRecord(id) orelse return .unknown_list;

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = record.source_url },
        .response_writer = &body.writer,
    }) catch |err| {
        std.debug.print("filter list fetch failed ({s}): {s}\n", .{ id, @errorName(err) });
        return .fetch_failed;
    };
    if (result.status != .ok) {
        return .{ .http_status = @intFromEnum(result.status) };
    }

    return switch (try applyListText(dir, io, allocator, store, directory_path, id, body.written(), now_seconds)) {
        .applied => .applied,
        .rejected_invalid => .rejected_invalid,
        .unknown_list => .unknown_list,
    };
}

// --- tests ---------------------------------------------------------------

fn plausibleListText(allocator: std.mem.Allocator) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, "[Adblock Plus 2.0]\n! Title: Fixture\n");
    for (0..min_plausible_network_rules + 10) |index| {
        const line = try std.fmt.allocPrint(allocator, "||ad{d}.example.com^\n", .{index});
        defer allocator.free(line);
        try text.appendSlice(allocator, line);
    }
    return text.toOwnedSlice(allocator);
}

test "validation accepts a plausible list and rejects garbage" {
    const plausible = try plausibleListText(std.testing.allocator);
    defer std.testing.allocator.free(plausible);

    switch (validateListText(std.testing.allocator, plausible)) {
        .accepted => |stats| try std.testing.expectEqual(
            @as(u64, min_plausible_network_rules + 10),
            stats.rules_accepted,
        ),
        .rejected => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(Validation.rejected, validateListText(
        std.testing.allocator,
        "<!DOCTYPE html><html><body>503 Service Unavailable</body></html>",
    ));
    try std.testing.expectEqual(Validation.rejected, validateListText(std.testing.allocator, ""));
    // A handful of valid rules is still implausibly small for a real list.
    try std.testing.expectEqual(Validation.rejected, validateListText(
        std.testing.allocator,
        "||ads.example.com^\n||tracker.example.com^\n",
    ));
}

test "apply replaces text and metadata for a valid download" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = filter_lists.FilterListStore.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.ensureDefault(tmp_dir.dir, std.testing.io, ".", .{
        .id = "easylist",
        .name = "EasyList",
        .source_url = "https://easylist.to/easylist/easylist.txt",
        .enabled = true,
        .updated_at = 0,
    }, "||old.example.com^\n");

    const download = try plausibleListText(std.testing.allocator);
    defer std.testing.allocator.free(download);

    const outcome = try applyListText(tmp_dir.dir, std.testing.io, std.testing.allocator, &store, ".", "easylist", download, 999);
    try std.testing.expectEqual(ApplyOutcome.applied, outcome);

    const text = try filter_lists.readListText(tmp_dir.dir, std.testing.io, std.testing.allocator, ".", "easylist");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(download, text);

    const record = store.findRecord("easylist").?;
    try std.testing.expectEqual(@as(i64, 999), record.updated_at);
    try std.testing.expectEqual(@as(u64, min_plausible_network_rules + 10), record.rules_accepted);

    // The catalog was persisted alongside.
    var reloaded = filter_lists.FilterListStore.init(std.testing.allocator);
    defer reloaded.deinit();
    try reloaded.loadFromFile(tmp_dir.dir, std.testing.io, "lists.jsonl");
    try std.testing.expectEqual(@as(i64, 999), reloaded.findRecord("easylist").?.updated_at);
}

test "corrupted download leaves the previous list untouched" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = filter_lists.FilterListStore.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.ensureDefault(tmp_dir.dir, std.testing.io, ".", .{
        .id = "easylist",
        .name = "EasyList",
        .source_url = "https://easylist.to/easylist/easylist.txt",
        .enabled = true,
        .updated_at = 555,
    }, "||surviving.example.com^\n");

    const outcome = try applyListText(
        tmp_dir.dir,
        std.testing.io,
        std.testing.allocator,
        &store,
        ".",
        "easylist",
        "<html>garbage cdn error page</html>",
        999,
    );
    try std.testing.expectEqual(ApplyOutcome.rejected_invalid, outcome);

    const text = try filter_lists.readListText(tmp_dir.dir, std.testing.io, std.testing.allocator, ".", "easylist");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("||surviving.example.com^\n", text);
    try std.testing.expectEqual(@as(i64, 555), store.findRecord("easylist").?.updated_at);
}

test "apply refuses unknown list ids" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = filter_lists.FilterListStore.init(std.testing.allocator);
    defer store.deinit();

    const outcome = try applyListText(tmp_dir.dir, std.testing.io, std.testing.allocator, &store, ".", "mystery", "text", 1);
    try std.testing.expectEqual(ApplyOutcome.unknown_list, outcome);
}
