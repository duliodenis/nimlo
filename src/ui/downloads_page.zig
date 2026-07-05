const std = @import("std");
const downloads = @import("../storage/downloads.zig");

pub fn render(allocator: std.mem.Allocator, entries: []const downloads.DownloadEntry) ![]u8 {
    const sorted_entries = try allocator.dupe(downloads.DownloadEntry, entries);
    defer allocator.free(sorted_entries);
    std.mem.sort(downloads.DownloadEntry, sorted_entries, {}, moreRecentThan);

    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>Downloads</title>
        \\  <style>
        \\    :root{color-scheme:light dark;--bg:#f7f7f8;--panel:#fff;--text:#111318;--muted:#667085;--line:#d8dbe2;--accent:#0f6b5f;--field:#fff}
        \\    @media (prefers-color-scheme:dark){:root{--bg:#171819;--panel:#222427;--text:#f3f4f6;--muted:#a8b0bd;--line:#373a42;--accent:#50d3bd;--field:#1b1d20}}
        \\    *{box-sizing:border-box}
        \\    body{margin:0;background:var(--bg);color:var(--text);font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        \\    main{max-width:960px;margin:0 auto;padding:28px}
        \\    header{display:flex;gap:18px;align-items:center;justify-content:space-between;margin-bottom:18px}
        \\    h1{font-size:22px;line-height:1.2;margin:0;font-weight:650;letter-spacing:0}
        \\    .count{color:var(--muted);font-size:13px;margin-top:4px}
        \\    .actions{display:flex;gap:10px;align-items:center}
        \\    .button-link{display:inline-flex;height:34px;border:1px solid var(--line);border-radius:6px;background:transparent;color:var(--text);padding:0 12px;font:inherit;font-weight:600;white-space:nowrap;align-items:center;text-decoration:none;cursor:pointer}
        \\    .button-link:hover{background:color-mix(in srgb,var(--text) 7%,transparent)}
        \\    .button-link.danger{border-color:#b42318;color:#b42318}
        \\    .button-link.danger:hover{background:color-mix(in srgb,#b42318 10%,transparent)}
        \\    .button-link.disabled{opacity:.45;pointer-events:none}
        \\    @media (prefers-color-scheme:dark){.button-link.danger{border-color:#f97066;color:#f97066}.button-link.danger:hover{background:color-mix(in srgb,#f97066 14%,transparent)}}
        \\    .confirm-text{color:var(--text);font-size:13px;font-weight:600}
        \\    .panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden}
        \\    .row{display:grid;grid-template-columns:minmax(0,1fr) 200px;gap:14px;padding:13px 16px;border-top:1px solid var(--line);align-items:center}
        \\    .row:first-child{border-top:0}
        \\    .title{color:var(--text);font-weight:550;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\    .badge{display:inline-block;margin-left:8px;padding:1px 7px;border-radius:99px;font-size:11px;font-weight:650;vertical-align:1px}
        \\    .badge.in-progress{background:color-mix(in srgb,var(--accent) 16%,transparent);color:var(--accent)}
        \\    .badge.failed{background:color-mix(in srgb,#b42318 14%,transparent);color:#b42318}
        \\    @media (prefers-color-scheme:dark){.badge.failed{color:#f97066}}
        \\    .url{margin-top:4px;color:var(--muted);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\    .row-actions{margin-top:6px;font-size:12px}
        \\    .row-actions a{color:var(--accent);text-decoration:none;font-weight:600}
        \\    .row-actions a:hover{text-decoration:underline;text-underline-offset:3px}
        \\    .row-actions a.danger{color:#b42318}
        \\    @media (prefers-color-scheme:dark){.row-actions a.danger{color:#f97066}}
        \\    .row-actions .sep{color:var(--muted);margin:0 6px}
        \\    .meta{color:var(--muted);font-size:12px;text-align:right;white-space:nowrap}
        \\    .meta .size{display:block;font-weight:600}
        \\    .empty{padding:44px 16px;text-align:center;color:var(--muted)}
        \\    .hidden{display:none}
        \\    @media (max-width:640px){main{padding:18px}header{display:block}.actions{margin-top:14px}.row{grid-template-columns:1fr}.meta{text-align:left}}
        \\  </style>
        \\</head>
        \\<body>
        \\  <main>
        \\    <header>
        \\      <div>
        \\        <h1>Downloads</h1>
        \\        <div class="count" id="count">
    );
    try appendCount(&html, allocator, sorted_entries.len);
    try html.appendSlice(allocator,
        \\</div>
        \\      </div>
        \\      <div class="actions">
        \\        <span class="confirm-text hidden" id="confirm-text">Clear all download records?</span>
        \\        <a class="button-link danger hidden" id="confirm-clear" href="https://nimlo.internal/downloads/clear">Confirm clear</a>
        \\        <button class="button-link hidden" id="cancel-clear" type="button">Cancel</button>
        \\        <button class="button-link danger
    );
    if (sorted_entries.len == 0) {
        try html.appendSlice(allocator, " disabled");
    }
    try html.appendSlice(allocator,
        \\" id="clear-all" type="button">Clear All</button>
        \\      </div>
        \\    </header>
        \\    <section class="panel" id="downloads">
    );

    if (sorted_entries.len == 0) {
        try html.appendSlice(allocator, "<div class=\"empty\">No downloads yet</div>");
    } else {
        for (sorted_entries) |entry| {
            try appendEntry(&html, allocator, entry);
        }
    }

    try html.appendSlice(allocator,
        \\    </section>
        \\  </main>
        \\  <script>
        \\    const clearAll = document.getElementById("clear-all");
        \\    const confirmText = document.getElementById("confirm-text");
        \\    const confirmClear = document.getElementById("confirm-clear");
        \\    const cancelClear = document.getElementById("cancel-clear");
        \\    const setConfirming = (confirming) => {
        \\      clearAll.classList.toggle("hidden", confirming);
        \\      confirmText.classList.toggle("hidden", !confirming);
        \\      confirmClear.classList.toggle("hidden", !confirming);
        \\      cancelClear.classList.toggle("hidden", !confirming);
        \\    };
        \\    clearAll.addEventListener("click", () => setConfirming(true));
        \\    cancelClear.addEventListener("click", () => setConfirming(false));
        \\    document.addEventListener("keydown", (event) => {
        \\      if (event.key === "Escape") setConfirming(false);
        \\    });
        \\    const formatStartedAt = (value) => {
        \\      if (!Number.isFinite(value) || value < 1000000000000) return null;
        \\      const date = new Date(value);
        \\      if (Number.isNaN(date.getTime())) return null;
        \\      const now = new Date();
        \\      const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
        \\      const startOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
        \\      const dayDelta = Math.round((startOfToday - startOfDay) / 86400000);
        \\      const time = new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(date);
        \\      if (dayDelta === 0) return `Today, ${time}`;
        \\      if (dayDelta === 1) return `Yesterday, ${time}`;
        \\      return new Intl.DateTimeFormat([], { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }).format(date);
        \\    };
        \\    document.querySelectorAll("time[data-started-at]").forEach((node) => {
        \\      const formatted = formatStartedAt(Number.parseInt(node.dataset.startedAt, 10));
        \\      if (formatted) node.textContent = formatted;
        \\    });
        \\  </script>
        \\</body>
        \\</html>
    );

    return html.toOwnedSlice(allocator);
}

fn moreRecentThan(_: void, lhs: downloads.DownloadEntry, rhs: downloads.DownloadEntry) bool {
    if (lhs.started_at == rhs.started_at) {
        return lhs.id > rhs.id;
    }
    return lhs.started_at > rhs.started_at;
}

fn appendEntry(html: *std.ArrayList(u8), allocator: std.mem.Allocator, entry: downloads.DownloadEntry) !void {
    try html.appendSlice(allocator, "<article class=\"row\"><div><div class=\"title\">");
    try appendEscapedHtml(html, allocator, titleForEntry(entry));
    switch (entry.state) {
        .in_progress => try html.appendSlice(allocator, "<span class=\"badge in-progress\">In progress</span>"),
        .failed => try html.appendSlice(allocator, "<span class=\"badge failed\">Failed</span>"),
        .completed => {},
    }
    try html.appendSlice(allocator, "</div><div class=\"url\">");
    try appendEscapedHtml(html, allocator, entry.url);
    try html.appendSlice(allocator, "</div><div class=\"row-actions\">");

    if (entry.state == .completed and entry.file_path.len > 0) {
        try appendPathAction(html, allocator, "open", "Open", entry.file_path);
        try html.appendSlice(allocator, "<span class=\"sep\">&middot;</span>");
        try appendPathAction(html, allocator, "reveal", "Show in Finder", entry.file_path);
        try html.appendSlice(allocator, "<span class=\"sep\">&middot;</span>");
    }

    const remove_href = try std.fmt.allocPrint(allocator, "https://nimlo.internal/downloads/remove?ids={d}", .{entry.id});
    defer allocator.free(remove_href);
    try html.appendSlice(allocator, "<a class=\"danger\" href=\"");
    try html.appendSlice(allocator, remove_href);
    try html.appendSlice(allocator, "\">Remove</a></div></div><div class=\"meta\">");

    if (entry.state == .completed) {
        try html.appendSlice(allocator, "<span class=\"size\">");
        const size = try formatSize(allocator, entry.size_bytes);
        defer allocator.free(size);
        try appendEscapedHtml(html, allocator, size);
        try html.appendSlice(allocator, "</span>");
    }

    try html.appendSlice(allocator, "<time data-started-at=\"");
    const started = try std.fmt.allocPrint(allocator, "{d}", .{entry.started_at});
    defer allocator.free(started);
    try html.appendSlice(allocator, started);
    try html.appendSlice(allocator, "\">");
    try html.appendSlice(allocator, started);
    try html.appendSlice(allocator, "</time></div></article>");
}

fn appendPathAction(
    html: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    action: []const u8,
    label: []const u8,
    file_path: []const u8,
) !void {
    try html.appendSlice(allocator, "<a href=\"https://nimlo.internal/downloads/");
    try html.appendSlice(allocator, action);
    try html.appendSlice(allocator, "?path=");
    try appendPercentEncoded(html, allocator, file_path);
    try html.appendSlice(allocator, "\">");
    try html.appendSlice(allocator, label);
    try html.appendSlice(allocator, "</a>");
}

fn titleForEntry(entry: downloads.DownloadEntry) []const u8 {
    return if (entry.filename.len == 0) entry.url else entry.filename;
}

fn appendCount(html: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) !void {
    const text = try std.fmt.allocPrint(allocator, "{d} {s}", .{ count, if (count == 1) "download" else "downloads" });
    defer allocator.free(text);
    try html.appendSlice(allocator, text);
}

pub fn formatSize(allocator: std.mem.Allocator, size_bytes: u64) ![]u8 {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (size_bytes >= gb) {
        return std.fmt.allocPrint(allocator, "{d:.1} GB", .{@as(f64, @floatFromInt(size_bytes)) / gb});
    }
    if (size_bytes >= mb) {
        return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(size_bytes)) / mb});
    }
    if (size_bytes >= kb) {
        return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(size_bytes)) / kb});
    }
    return std.fmt.allocPrint(allocator, "{d} B", .{size_bytes});
}

fn appendPercentEncoded(output: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        const keep = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '.' or byte == '_' or byte == '~' or byte == '/';
        if (keep) {
            try output.append(allocator, byte);
        } else {
            const escaped = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{byte});
            defer allocator.free(escaped);
            try output.appendSlice(allocator, escaped);
        }
    }
}

fn appendEscapedHtml(output: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&#39;"),
            else => try output.append(allocator, byte),
        }
    }
}

fn testEntry(id: u64, filename: []const u8, started_at: i64, state: downloads.DownloadState) downloads.DownloadEntry {
    return .{
        .id = id,
        .url = "https://example.com/files/a.zip",
        .filename = filename,
        .file_path = "/Users/test/Downloads/a.zip",
        .size_bytes = 2048,
        .started_at = started_at,
        .state = state,
    };
}

test "renders empty downloads state" {
    const html = try render(std.testing.allocator, &.{});
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "No downloads yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "0 downloads") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Clear All") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"button-link danger disabled\"") != null);
}

test "renders entries newest first with escaped content" {
    const entries = [_]downloads.DownloadEntry{
        testEntry(1, "older.zip", 1_799_000_000_000, .completed),
        .{
            .id = 2,
            .url = "https://example.com/?q=<tag>",
            .filename = "new & \"quoted\".pdf",
            .file_path = "/Users/test/Downloads/new & \"quoted\".pdf",
            .size_bytes = 5,
            .started_at = 1_799_999_999_000,
            .state = .completed,
        },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    const newer_index = std.mem.indexOf(u8, html, "new &amp; &quot;quoted&quot;.pdf").?;
    const older_index = std.mem.indexOf(u8, html, "older.zip").?;
    try std.testing.expect(newer_index < older_index);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://example.com/?q=&lt;tag&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "2 downloads") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"button-link danger disabled\"") == null);
}

test "renders per-row actions with encoded paths and ids" {
    const entries = [_]downloads.DownloadEntry{
        .{
            .id = 42,
            .url = "https://example.com/report.pdf",
            .filename = "annual report.pdf",
            .file_path = "/Users/test/Downloads/annual report.pdf",
            .size_bytes = 1024,
            .started_at = 1_799_999_999_000,
            .state = .completed,
        },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "https://nimlo.internal/downloads/open?path=/Users/test/Downloads/annual%20report.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://nimlo.internal/downloads/reveal?path=/Users/test/Downloads/annual%20report.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://nimlo.internal/downloads/remove?ids=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://nimlo.internal/downloads/clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Show in Finder") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "1.0 KB") != null);
}

test "in-progress and failed rows show badges without open actions" {
    const entries = [_]downloads.DownloadEntry{
        testEntry(1, "partial.zip", 1_799_999_999_000, .in_progress),
        testEntry(2, "broken.zip", 1_799_999_998_000, .failed),
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "badge in-progress\">In progress<") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "badge failed\">Failed<") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/downloads/open?") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/downloads/reveal?") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/downloads/remove?ids=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/downloads/remove?ids=2") != null);
}

test "formats sizes in human units" {
    const cases = [_]struct { bytes: u64, expected: []const u8 }{
        .{ .bytes = 0, .expected = "0 B" },
        .{ .bytes = 512, .expected = "512 B" },
        .{ .bytes = 2048, .expected = "2.0 KB" },
        .{ .bytes = 5 * 1024 * 1024 + 300 * 1024, .expected = "5.3 MB" },
        .{ .bytes = 3 * 1024 * 1024 * 1024, .expected = "3.0 GB" },
    };
    for (cases) |case| {
        const text = try formatSize(std.testing.allocator, case.bytes);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "clear confirmation controls are wired" {
    const entries = [_]downloads.DownloadEntry{
        testEntry(1, "a.zip", 1_799_999_999_000, .completed),
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"clear-all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"confirm-clear\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"cancel-clear\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Clear all download records?") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "event.key === \"Escape\"") != null);
}
