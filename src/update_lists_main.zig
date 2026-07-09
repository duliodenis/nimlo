// Manual harness for the Phase E network update flow: seeds a throwaway
// catalog in the given directory, downloads the real EasyList, and applies
// it through the validate-before-replace path.
// Run: zig run src/update_lists_main.zig -- <scratch-dir>
const std = @import("std");
const filter_lists = @import("storage/filter_lists.zig");
const list_update = @import("blocking/list_update.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    const io = std.Options.debug_io;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const dir_path = args.next() orelse return error.MissingScratchDir;

    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var store = filter_lists.FilterListStore.init(allocator);
    defer store.deinit();
    try store.upsert(.{
        .id = "easylist",
        .name = "EasyList",
        .source_url = "https://easylist.to/easylist/easylist.txt",
        .enabled = true,
        .updated_at = 0,
    });

    std.debug.print("fetching {s}...\n", .{store.findRecord("easylist").?.source_url});
    const outcome = try list_update.fetchAndApply(dir, io, allocator, &store, ".", "easylist", 1);

    switch (outcome) {
        .applied => {
            const record = store.findRecord("easylist").?;
            std.debug.print(
                "applied: {d} rules accepted, {d} dropped; list stored in {s}/easylist.txt\n",
                .{ record.rules_accepted, record.rules_dropped, dir_path },
            );
        },
        .rejected_invalid => std.debug.print("rejected: download failed validation\n", .{}),
        .unknown_list => std.debug.print("unknown list id\n", .{}),
        .http_status => |status| std.debug.print("http error: {d}\n", .{status}),
        .fetch_failed => std.debug.print("fetch failed (network/TLS)\n", .{}),
    }
}
