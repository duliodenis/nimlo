// Throwaway Phase A/B measurement harness: parse a real filter list and
// print stats. Run: zig run src/blocking/measure_main.zig -- <list.txt>
const std = @import("std");
const abp_parser = @import("abp_parser.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const path = args.next() orelse return error.MissingListPath;

    const io = std.Options.debug_io;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));

    const started = std.Io.Timestamp.now(io, .awake);
    var parsed = try abp_parser.parseList(allocator, text);
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    defer parsed.deinit();

    const s = parsed.stats;
    std.debug.print(
        "{s}: {d} lines in {d}ms\n  network={d} exceptions={d} cosmetic={d} cosmetic_exc={d}\n  ignored_opts={d} dropped: regex={d} procedural={d} options={d} malformed={d}\n  accepted={d} dropped_total={d}\n",
        .{ path, s.lines, elapsed_ms, s.network_rules, s.network_exceptions, s.cosmetic_rules, s.cosmetic_exceptions, s.options_ignored, s.dropped_regex, s.dropped_procedural, s.dropped_options, s.dropped_malformed, s.accepted(), s.dropped() },
    );
}
