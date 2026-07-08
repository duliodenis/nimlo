// Measurement harness: parse a real filter list, print stats, then
// benchmark matcher verdicts over it (Phase C gate: indexed lookup must
// stay well under a millisecond per request against a full list).
// Run: zig run -OReleaseFast src/blocking/measure_main.zig -- <list.txt>
const std = @import("std");
const abp_parser = @import("abp_parser.zig");
const matcher_mod = @import("matcher.zig");
const webkit_rules = @import("webkit_rules.zig");

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

    const build_start = std.Io.Timestamp.now(io, .awake);
    var matcher = try matcher_mod.Matcher.init(allocator, parsed.network);
    defer matcher.deinit();
    const build_ms = build_start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    const sample_requests = [_]matcher_mod.Request{
        .{ .url = "https://www.example.com/index.html", .resource_type = .{ .document = true } },
        .{ .url = "https://cdn.example.net/assets/app.min.js", .document_host = "www.example.com", .resource_type = .{ .script = true } },
        .{ .url = "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", .document_host = "news.site.example", .resource_type = .{ .script = true } },
        .{ .url = "https://www.google-analytics.com/analytics.js", .document_host = "shop.example.org", .resource_type = .{ .script = true } },
        .{ .url = "https://static.doubleclick.net/instream/ad_status.js", .document_host = "video.example.com", .resource_type = .{ .script = true } },
        .{ .url = "https://images.example.org/photos/2026/07/skyline.jpg?w=1200", .document_host = "images.example.org", .resource_type = .{ .image = true } },
        .{ .url = "https://api.example.com/v2/session?token=abc123", .document_host = "app.example.com", .resource_type = .{ .xhr = true } },
        .{ .url = "https://tracker.metrics.example/pixel.gif?event=view&uid=42", .document_host = "blog.example.net", .resource_type = .{ .image = true } },
    };

    const iterations = 10_000;
    var blocked: usize = 0;
    const bench_start = std.Io.Timestamp.now(io, .awake);
    for (0..iterations) |round| {
        const request = sample_requests[round % sample_requests.len];
        if (matcher.verdict(request) == .block) blocked += 1;
    }
    const bench_ns = bench_start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
    const per_verdict_ns = @divTrunc(bench_ns, iterations);

    std.debug.print(
        "  matcher: index build {d}ms; {d} verdicts, {d} blocked, {d}ns/verdict\n",
        .{ build_ms, iterations, @divTrunc(blocked * sample_requests.len, iterations), per_verdict_ns },
    );

    const emit_start = std.Io.Timestamp.now(io, .awake);
    const emitted = try webkit_rules.emitJson(allocator, parsed.network, webkit_rules.default_rule_cap);
    defer allocator.free(emitted.json);
    const emit_ms = emit_start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    const e = emitted.stats;
    std.debug.print(
        "  webkit: {d} rules ({d} block, {d} exception) in {d}ms, {d}KB JSON; capped={d} unexpressible={d} doc_exceptions_partial={d}\n",
        .{ e.emitted_total, e.emitted_blocks, e.emitted_exceptions, emit_ms, emitted.json.len / 1024, e.capped_blocks, e.dropped_unexpressible, e.document_exceptions_partial },
    );
}
