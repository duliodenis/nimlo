const std = @import("std");
const bookmarks = @import("../storage/bookmarks.zig");

pub fn render(allocator: std.mem.Allocator, entries: []const bookmarks.BookmarkEntry) ![]u8 {
    const sorted_entries = try allocator.dupe(bookmarks.BookmarkEntry, entries);
    defer allocator.free(sorted_entries);
    std.mem.sort(bookmarks.BookmarkEntry, sorted_entries, {}, moreRecentThan);

    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>Bookmarks</title>
        \\  <style>
        \\    :root{color-scheme:light dark;--bg:#f7f7f8;--panel:#fff;--text:#111318;--muted:#667085;--line:#d8dbe2;--accent:#0f6b5f;--field:#fff}
        \\    @media (prefers-color-scheme:dark){:root{--bg:#171819;--panel:#222427;--text:#f3f4f6;--muted:#a8b0bd;--line:#373a42;--accent:#50d3bd;--field:#1b1d20}}
        \\    *{box-sizing:border-box}
        \\    body{margin:0;background:var(--bg);color:var(--text);font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        \\    main{max-width:920px;margin:0 auto;padding:28px}
        \\    header{display:flex;gap:18px;align-items:center;justify-content:space-between;margin-bottom:18px}
        \\    h1{font-size:22px;line-height:1.2;margin:0;font-weight:650;letter-spacing:0}
        \\    .count{color:var(--muted);font-size:13px;margin-top:4px}
        \\    .search{width:min(360px,44vw);height:34px;border:1px solid var(--line);border-radius:6px;background:var(--field);color:var(--text);padding:0 11px;font:inherit}
        \\    .search:focus{outline:2px solid color-mix(in srgb,var(--accent) 28%,transparent);border-color:var(--accent)}
        \\    .panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden}
        \\    .row{display:grid;grid-template-columns:minmax(0,1fr) 170px;gap:14px;padding:14px 16px;border-top:1px solid var(--line);align-items:center}
        \\    .row:first-child{border-top:0}
        \\    .title{display:block;color:var(--text);font-weight:550;text-decoration:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\    a.title:hover{text-decoration:underline;text-underline-offset:3px}
        \\    .url{margin-top:4px;color:var(--muted);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\    time{color:var(--muted);font-size:12px;text-align:right;white-space:nowrap}
        \\    .empty{padding:44px 16px;text-align:center;color:var(--muted)}
        \\    .hidden{display:none}
        \\    @media (max-width:640px){main{padding:18px}header{display:block}.search{width:100%;min-width:0;margin-top:14px}.row{grid-template-columns:1fr;gap:6px}time{text-align:left}}
        \\  </style>
        \\</head>
        \\<body>
        \\  <main>
        \\    <header>
        \\      <div>
        \\        <h1>Bookmarks</h1>
        \\        <div class="count" id="count">
    );
    try appendCount(&html, allocator, sorted_entries.len);
    try html.appendSlice(allocator,
        \\</div>
        \\      </div>
        \\      <input class="search" id="search" type="search" placeholder="Search bookmarks" autocomplete="off">
        \\    </header>
        \\    <section class="panel" id="bookmarks">
    );

    if (sorted_entries.len == 0) {
        try html.appendSlice(allocator, "<div class=\"empty\">No bookmarks yet</div>");
    } else {
        for (sorted_entries) |entry| {
            try appendEntry(&html, allocator, entry);
        }
    }

    try html.appendSlice(allocator,
        \\    </section>
        \\  </main>
        \\  <script>
        \\    const search = document.getElementById("search");
        \\    const rows = [...document.querySelectorAll(".row")];
        \\    const count = document.getElementById("count");
        \\    const label = (value) => `${value} ${value === 1 ? "bookmark" : "bookmarks"}`;
        \\    const hostFromUrl = (value) => {
        \\      try {
        \\        return new URL(value).hostname.replace(/^www\./, "");
        \\      } catch {
        \\        return "";
        \\      }
        \\    };
        \\    const searchTokens = (value) => value.trim().toLowerCase().split(/\s+/).filter(Boolean);
        \\    const matchesSearch = (row, tokens) => tokens.length === 0 || tokens.every((token) => row.dataset.search.includes(token));
        \\    const formatCreatedAt = (value) => {
        \\      if (!Number.isFinite(value) || value < 1000000000000) return null;
        \\      const date = new Date(value);
        \\      if (Number.isNaN(date.getTime())) return null;
        \\      return new Intl.DateTimeFormat([], { month: "short", day: "numeric", year: "numeric" }).format(date);
        \\    };
        \\    document.querySelectorAll("time[data-created-at]").forEach((node) => {
        \\      const formatted = formatCreatedAt(Number.parseInt(node.dataset.createdAt, 10));
        \\      if (formatted) node.textContent = formatted;
        \\    });
        \\    rows.forEach((row) => {
        \\      row.dataset.search = `${row.dataset.search} ${hostFromUrl(row.dataset.url)}`.toLowerCase();
        \\    });
        \\    search.addEventListener("input", () => {
        \\      const query = search.value.trim();
        \\      const tokens = searchTokens(query);
        \\      let visible = 0;
        \\      for (const row of rows) {
        \\        const match = matchesSearch(row, tokens);
        \\        row.classList.toggle("hidden", !match);
        \\        if (match) visible += 1;
        \\      }
        \\      count.textContent = query ? `${label(visible)} found` : label(rows.length);
        \\    });
        \\  </script>
        \\</body>
        \\</html>
    );

    return html.toOwnedSlice(allocator);
}

fn moreRecentThan(_: void, lhs: bookmarks.BookmarkEntry, rhs: bookmarks.BookmarkEntry) bool {
    if (lhs.created_at == rhs.created_at) {
        return std.mem.lessThan(u8, lhs.url, rhs.url);
    }
    return lhs.created_at > rhs.created_at;
}

fn appendEntry(html: *std.ArrayList(u8), allocator: std.mem.Allocator, entry: bookmarks.BookmarkEntry) !void {
    try html.appendSlice(allocator, "<article class=\"row\" data-search=\"");
    try appendEscapedHtml(html, allocator, entry.title);
    try html.appendSlice(allocator, " ");
    try appendEscapedHtml(html, allocator, entry.url);
    try html.appendSlice(allocator, "\" data-url=\"");
    try appendEscapedHtml(html, allocator, entry.url);
    try html.appendSlice(allocator, "\"><div>");

    if (isLinkableUrl(entry.url)) {
        try html.appendSlice(allocator, "<a class=\"title\" href=\"");
        try appendEscapedHtml(html, allocator, entry.url);
        try html.appendSlice(allocator, "\">");
        try appendEscapedHtml(html, allocator, titleForEntry(entry));
        try html.appendSlice(allocator, "</a>");
    } else {
        try html.appendSlice(allocator, "<span class=\"title\">");
        try appendEscapedHtml(html, allocator, titleForEntry(entry));
        try html.appendSlice(allocator, "</span>");
    }

    try html.appendSlice(allocator, "<div class=\"url\">");
    try appendEscapedHtml(html, allocator, entry.url);
    try html.appendSlice(allocator, "</div></div><time data-created-at=\"");
    const created = try std.fmt.allocPrint(allocator, "{d}", .{entry.created_at});
    defer allocator.free(created);
    try html.appendSlice(allocator, created);
    try html.appendSlice(allocator, "\">");
    const label = try createdLabel(allocator, entry.created_at);
    defer allocator.free(label);
    try appendEscapedHtml(html, allocator, label);
    try html.appendSlice(allocator, "</time></article>");
}

fn titleForEntry(entry: bookmarks.BookmarkEntry) []const u8 {
    return if (entry.title.len == 0) entry.url else entry.title;
}

fn appendCount(html: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) !void {
    const text = try std.fmt.allocPrint(allocator, "{d} {s}", .{ count, if (count == 1) "bookmark" else "bookmarks" });
    defer allocator.free(text);
    try html.appendSlice(allocator, text);
}

fn createdLabel(allocator: std.mem.Allocator, created_at: i64) ![]const u8 {
    if (created_at > 0 and created_at < 1_000_000_000_000) {
        return std.fmt.allocPrint(allocator, "Saved {d}", .{created_at});
    }

    return std.fmt.allocPrint(allocator, "{d}", .{created_at});
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

fn isLinkableUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "file://");
}

test "renders empty bookmarks state" {
    const html = try render(std.testing.allocator, &.{});
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "No bookmarks yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "0 bookmarks") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Search bookmarks") != null);
}

test "renders bookmarks newest first and escapes content" {
    const entries = [_]bookmarks.BookmarkEntry{
        .{ .url = "https://example.com/first", .title = "First", .created_at = 1 },
        .{ .url = "https://example.com/?q=<tag>", .title = "Second & \"quoted\"", .created_at = 2 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    const second_index = std.mem.indexOf(u8, html, "Second &amp; &quot;quoted&quot;").?;
    const first_index = std.mem.indexOf(u8, html, "First").?;
    try std.testing.expect(second_index < first_index);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://example.com/?q=&lt;tag&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "2 bookmarks") != null);
}

test "renders search by title url and hostname support" {
    const entries = [_]bookmarks.BookmarkEntry{
        .{ .url = "https://www.example.com/docs", .title = "Docs", .created_at = 1 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "data-search=\"Docs https://www.example.com/docs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hostFromUrl") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "row.dataset.search.includes(token)") != null);
}
