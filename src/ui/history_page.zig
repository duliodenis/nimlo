const std = @import("std");
const history = @import("../storage/history.zig");

pub fn render(allocator: std.mem.Allocator, entries: []const history.HistoryEntry) ![]u8 {
    const sorted_entries = try allocator.dupe(history.HistoryEntry, entries);
    defer allocator.free(sorted_entries);
    std.mem.sort(history.HistoryEntry, sorted_entries, {}, moreRecentThan);

    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>History</title>
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
        \\    .search{width:min(360px,44vw);height:34px;border:1px solid var(--line);border-radius:6px;background:var(--field);color:var(--text);padding:0 11px;font:inherit}
        \\    .search:focus{outline:2px solid color-mix(in srgb,var(--accent) 28%,transparent);border-color:var(--accent)}
        \\    .button-link{display:inline-flex;height:34px;border:1px solid var(--line);border-radius:6px;background:transparent;color:var(--text);padding:0 12px;font:inherit;font-weight:600;white-space:nowrap;align-items:center;text-decoration:none}
        \\    .button-link:hover{background:color-mix(in srgb,var(--text) 7%,transparent)}
        \\    .button-link.danger{border-color:#b42318;color:#b42318}
        \\    .button-link.danger:hover{background:color-mix(in srgb,#b42318 10%,transparent)}
        \\    .button-link.disabled{opacity:.45;pointer-events:none}
        \\    @media (prefers-color-scheme:dark){.button-link.danger{border-color:#f97066;color:#f97066}.button-link.danger:hover{background:color-mix(in srgb,#f97066 14%,transparent)}}
        \\    .text-button{height:34px;border:0;background:transparent;color:var(--accent);padding:0 4px;font:inherit;font-weight:600;white-space:nowrap;cursor:pointer}
        \\    .text-button:hover{text-decoration:underline;text-underline-offset:3px}
        \\    .confirm-text{color:var(--text);font-size:13px;font-weight:600}
        \\    .selection-bar{display:flex;gap:10px;align-items:center;justify-content:flex-end;margin:-6px 0 14px}
        \\    .selected-count{color:var(--muted);font-size:13px;margin-right:2px}
        \\    .panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden}
        \\    .day{border-top:1px solid var(--line)}
        \\    .day:first-child{border-top:0}
        \\    .day-header{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:0;padding:10px 16px;color:var(--muted);font-size:12px;font-weight:650;text-transform:uppercase;letter-spacing:0}
        \\    .day-title{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\    .day-select{height:auto;padding:0;font-size:12px;text-transform:none;letter-spacing:0}
        \\    .day-list{border-top:1px solid var(--line)}
        \\    .row{display:grid;grid-template-columns:22px minmax(0,1fr) 180px;gap:14px;padding:13px 16px;border-top:1px solid var(--line);align-items:center}
        \\    .row:first-child{border-top:0}
        \\    .select{width:16px;height:16px;margin:0;accent-color:var(--accent)}
        \\    .title{display:block;color:var(--text);font-weight:550;text-decoration:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\    a.title:hover{text-decoration:underline;text-underline-offset:3px}
        \\    .url{margin-top:4px;color:var(--muted);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\    time{color:var(--muted);font-size:12px;text-align:right;white-space:nowrap}
        \\    .empty{padding:44px 16px;text-align:center;color:var(--muted)}
        \\    .hidden{display:none}
        \\    @media (max-width:640px){main{padding:18px}header{display:block}.actions{margin-top:14px}.search{width:100%;min-width:0}.selection-bar{justify-content:flex-start}.row{grid-template-columns:22px 1fr;gap:8px 12px}time{grid-column:2;text-align:left}}
        \\  </style>
        \\</head>
        \\<body>
        \\  <main>
        \\    <header>
        \\      <div>
        \\        <h1>History</h1>
        \\        <div class="count" id="count">
    );
    try appendCount(&html, allocator, sorted_entries.len);
    try html.appendSlice(allocator,
        \\</div>
        \\      </div>
        \\      <div class="actions">
        \\        <input class="search" id="search" type="search" placeholder="Search history" autocomplete="off">
        \\        <a class="button-link danger
    );
    if (sorted_entries.len == 0) {
        try html.appendSlice(allocator, " disabled");
    }
    try html.appendSlice(allocator,
        \\" href="https://nimlo.internal/history/clear">Clear History</a>
        \\      </div>
        \\    </header>
        \\    <div class="selection-bar hidden" id="selection-bar">
        \\      <span class="selected-count" id="selected-count">0 selected</span>
        \\      <button class="text-button" id="select-visible" type="button">Select visible</button>
        \\      <button class="text-button" id="clear-selection" type="button">Clear selection</button>
        \\      <a class="button-link" id="open-selected" href="#">Open</a>
        \\      <button class="button-link danger" id="delete-selected" type="button">Delete</button>
        \\      <span class="confirm-text hidden" id="confirm-text">Delete selected history?</span>
        \\      <a class="button-link danger hidden" id="confirm-delete" href="#">Confirm delete</a>
        \\      <button class="button-link hidden" id="cancel-delete" type="button">Cancel</button>
        \\    </div>
        \\    <section class="panel" id="history">
    );

    if (sorted_entries.len == 0) {
        try html.appendSlice(allocator, "<div class=\"empty\">No history yet</div>");
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
        \\    const history = document.getElementById("history");
        \\    const selectionBar = document.getElementById("selection-bar");
        \\    const selectedCount = document.getElementById("selected-count");
        \\    const selectVisible = document.getElementById("select-visible");
        \\    const clearSelection = document.getElementById("clear-selection");
        \\    const openSelected = document.getElementById("open-selected");
        \\    const deleteSelected = document.getElementById("delete-selected");
        \\    const confirmText = document.getElementById("confirm-text");
        \\    const confirmDelete = document.getElementById("confirm-delete");
        \\    const cancelDelete = document.getElementById("cancel-delete");
        \\    let confirmingDelete = false;
        \\    let lastSelectedIndex = null;
        \\    const label = (value) => `${value} ${value === 1 ? "visit" : "visits"}`;
        \\    const selectedLabel = (value) => `${value} selected`;
        \\    const hostFromUrl = (value) => {
        \\      try {
        \\        return new URL(value).hostname.replace(/^www\./, "");
        \\      } catch {
        \\        return "";
        \\      }
        \\    };
        \\    const searchTokens = (value) => value.trim().toLowerCase().split(/\s+/).filter(Boolean);
        \\    const matchesSearch = (row, tokens) => tokens.length === 0 || tokens.every((token) => row.dataset.search.includes(token));
        \\    const selectedUrls = () => rows.filter((row) => row.querySelector(".select").checked).map((row) => row.dataset.url);
        \\    const visibleRows = () => rows.filter((row) => !row.classList.contains("hidden"));
        \\    const selectedRows = () => rows.filter((row) => row.querySelector(".select").checked);
        \\    const actionHref = (action, urls) => `https://nimlo.internal/history/${action}?urls=${encodeURIComponent(urls.join("\n"))}`;
        \\    const updateSelection = () => {
        \\      const urls = selectedUrls();
        \\      selectionBar.classList.toggle("hidden", urls.length === 0);
        \\      selectedCount.textContent = selectedLabel(urls.length);
        \\      openSelected.href = urls.length === 0 ? "#" : actionHref("open", urls);
        \\      confirmDelete.href = urls.length === 0 ? "#" : actionHref("delete", urls);
        \\      confirmingDelete = confirmingDelete && urls.length > 0;
        \\      selectionBar.classList.toggle("confirming", confirmingDelete);
        \\      selectVisible.classList.toggle("hidden", confirmingDelete);
        \\      clearSelection.classList.toggle("hidden", confirmingDelete);
        \\      openSelected.classList.toggle("hidden", confirmingDelete);
        \\      deleteSelected.classList.toggle("hidden", confirmingDelete);
        \\      confirmText.classList.toggle("hidden", !confirmingDelete);
        \\      confirmDelete.classList.toggle("hidden", !confirmingDelete);
        \\      cancelDelete.classList.toggle("hidden", !confirmingDelete);
        \\    };
        \\    const setRowsSelected = (targetRows, selected) => {
        \\      targetRows.forEach((row) => {
        \\        row.querySelector(".select").checked = selected;
        \\      });
        \\      if (!selected) lastSelectedIndex = null;
        \\      updateSelection();
        \\    };
        \\    const setRangeSelected = (fromIndex, toIndex, selected) => {
        \\      const start = Math.min(fromIndex, toIndex);
        \\      const end = Math.max(fromIndex, toIndex);
        \\      for (let index = start; index <= end; index += 1) {
        \\        rows[index].querySelector(".select").checked = selected;
        \\      }
        \\      updateSelection();
        \\    };
        \\    const cancelDeleteConfirmation = () => {
        \\      confirmingDelete = false;
        \\      updateSelection();
        \\    };
        \\    const groupLabel = (value) => {
        \\      if (!Number.isFinite(value) || value < 1000000000000) return "Earlier";
        \\      const date = new Date(value);
        \\      if (Number.isNaN(date.getTime())) return "Earlier";
        \\      const now = new Date();
        \\      const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
        \\      const startOfVisitedDay = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
        \\      const dayDelta = Math.round((startOfToday - startOfVisitedDay) / 86400000);
        \\      if (dayDelta === 0) return "Today";
        \\      if (dayDelta === 1) return "Yesterday";
        \\      return new Intl.DateTimeFormat([], { month: "short", day: "numeric", year: "numeric" }).format(date);
        \\    };
        \\    const formatVisitedAt = (value) => {
        \\      if (!Number.isFinite(value) || value < 1000000000000) return null;
        \\      const date = new Date(value);
        \\      if (Number.isNaN(date.getTime())) return null;
        \\      const now = new Date();
        \\      const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
        \\      const startOfVisitedDay = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
        \\      const dayDelta = Math.round((startOfToday - startOfVisitedDay) / 86400000);
        \\      const time = new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(date);
        \\      if (dayDelta === 0) return `Today, ${time}`;
        \\      if (dayDelta === 1) return `Yesterday, ${time}`;
        \\      return new Intl.DateTimeFormat([], { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }).format(date);
        \\    };
        \\    const buildDayGroups = () => {
        \\      if (rows.length === 0) return;
        \\      history.textContent = "";
        \\      const groups = new Map();
        \\      for (const row of rows) {
        \\        const visitedAt = Number.parseInt(row.querySelector("time[data-visited-at]")?.dataset.visitedAt ?? "", 10);
        \\        const day = groupLabel(visitedAt);
        \\        let group = groups.get(day);
        \\        if (!group) {
        \\          group = document.createElement("section");
        \\          group.className = "day";
        \\          group.dataset.day = day.toLowerCase();
        \\          const heading = document.createElement("h2");
        \\          heading.className = "day-header";
        \\          const title = document.createElement("span");
        \\          title.className = "day-title";
        \\          title.textContent = day;
        \\          const selectDay = document.createElement("button");
        \\          selectDay.className = "text-button day-select";
        \\          selectDay.type = "button";
        \\          selectDay.textContent = "Select day";
        \\          const list = document.createElement("div");
        \\          list.className = "day-list";
        \\          selectDay.addEventListener("click", () => setRowsSelected([...list.querySelectorAll(".row")], true));
        \\          heading.append(title, selectDay);
        \\          group.append(heading, list);
        \\          history.append(group);
        \\          groups.set(day, group);
        \\        }
        \\        group.querySelector(".day-list").append(row);
        \\      }
        \\    };
        \\    document.querySelectorAll("time[data-visited-at]").forEach((node) => {
        \\      const formatted = formatVisitedAt(Number.parseInt(node.dataset.visitedAt, 10));
        \\      if (formatted) node.textContent = formatted;
        \\    });
        \\    rows.forEach((row, index) => {
        \\      row.dataset.search = `${row.dataset.search} ${hostFromUrl(row.dataset.url)}`.toLowerCase();
        \\      row.querySelector(".select").addEventListener("click", (event) => {
        \\        if (event.shiftKey && lastSelectedIndex !== null) {
        \\          setRangeSelected(lastSelectedIndex, index, event.currentTarget.checked);
        \\        } else {
        \\          updateSelection();
        \\        }
        \\        lastSelectedIndex = index;
        \\      });
        \\    });
        \\    buildDayGroups();
        \\    updateSelection();
        \\    selectVisible.addEventListener("click", () => setRowsSelected(visibleRows(), true));
        \\    clearSelection.addEventListener("click", () => setRowsSelected(rows, false));
        \\    deleteSelected.addEventListener("click", () => {
        \\      confirmingDelete = selectedUrls().length > 0;
        \\      updateSelection();
        \\    });
        \\    cancelDelete.addEventListener("click", () => {
        \\      cancelDeleteConfirmation();
        \\    });
        \\    document.addEventListener("keydown", (event) => {
        \\      if (event.key === "Escape") {
        \\        if (confirmingDelete) {
        \\          cancelDeleteConfirmation();
        \\        } else if (selectedRows().length > 0) {
        \\          setRowsSelected(rows, false);
        \\        }
        \\      }
        \\      if (event.key === "Enter" && confirmingDelete) {
        \\        event.preventDefault();
        \\        confirmDelete.click();
        \\      }
        \\      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a" && event.target !== search) {
        \\        event.preventDefault();
        \\        setRowsSelected(visibleRows(), true);
        \\      }
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
        \\      document.querySelectorAll(".day").forEach((group) => {
        \\        const hasVisibleRows = [...group.querySelectorAll(".row")].some((row) => !row.classList.contains("hidden"));
        \\        group.classList.toggle("hidden", !hasVisibleRows);
        \\      });
        \\      count.textContent = query ? `${label(visible)} found` : label(rows.length);
        \\    });
        \\  </script>
        \\</body>
        \\</html>
    );

    return html.toOwnedSlice(allocator);
}

fn moreRecentThan(_: void, lhs: history.HistoryEntry, rhs: history.HistoryEntry) bool {
    if (lhs.visited_at == rhs.visited_at) {
        return std.mem.lessThan(u8, lhs.url, rhs.url);
    }
    return lhs.visited_at > rhs.visited_at;
}

fn appendEntry(html: *std.ArrayList(u8), allocator: std.mem.Allocator, entry: history.HistoryEntry) !void {
    try html.appendSlice(allocator, "<article class=\"row\" data-search=\"");
    try appendEscapedHtml(html, allocator, entry.title);
    try html.appendSlice(allocator, " ");
    try appendEscapedHtml(html, allocator, entry.url);
    try html.appendSlice(allocator, "\" data-url=\"");
    try appendEscapedHtml(html, allocator, entry.url);
    try html.appendSlice(allocator, "\"><input class=\"select\" type=\"checkbox\" aria-label=\"Select ");
    try appendEscapedHtml(html, allocator, titleForEntry(entry));
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
    try html.appendSlice(allocator, "</div></div><time data-visited-at=\"");
    const visited = try std.fmt.allocPrint(allocator, "{d}", .{entry.visited_at});
    defer allocator.free(visited);
    try html.appendSlice(allocator, visited);
    try html.appendSlice(allocator, "\">");
    const label = try visitedLabel(allocator, entry.visited_at);
    defer allocator.free(label);
    try appendEscapedHtml(html, allocator, label);
    try html.appendSlice(allocator, "</time></article>");
}

fn titleForEntry(entry: history.HistoryEntry) []const u8 {
    return if (entry.title.len == 0) entry.url else entry.title;
}

fn appendCount(html: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) !void {
    const text = try std.fmt.allocPrint(allocator, "{d} {s}", .{ count, if (count == 1) "visit" else "visits" });
    defer allocator.free(text);
    try html.appendSlice(allocator, text);
}

fn visitedLabel(allocator: std.mem.Allocator, visited_at: i64) ![]const u8 {
    if (isLegacyVisitValue(visited_at)) {
        return std.fmt.allocPrint(allocator, "Visit {d}", .{visited_at});
    }

    return std.fmt.allocPrint(allocator, "{d}", .{visited_at});
}

fn isLegacyVisitValue(visited_at: i64) bool {
    return visited_at > 0 and visited_at < 1_000_000_000_000;
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

test "renders empty history state" {
    const html = try render(std.testing.allocator, &.{});
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "No history yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "0 visits") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Clear History") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"button-link danger disabled\"") != null);
}

test "renders entries newest first and escapes content" {
    const entries = [_]history.HistoryEntry{
        .{ .url = "https://example.com/first", .title = "First", .visited_at = 1 },
        .{ .url = "https://example.com/?q=<tag>", .title = "Second & \"quoted\"", .visited_at = 2 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    const second_index = std.mem.indexOf(u8, html, "Second &amp; &quot;quoted&quot;").?;
    const first_index = std.mem.indexOf(u8, html, "First").?;
    try std.testing.expect(second_index < first_index);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://example.com/?q=&lt;tag&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Clear History") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://nimlo.internal/history/clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"button-link danger disabled\"") == null);
}

test "renders selection controls for history rows" {
    const entries = [_]history.HistoryEntry{
        .{ .url = "https://example.com/docs", .title = "Docs", .visited_at = 1 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"selection-bar hidden\" id=\"selection-bar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"select-visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"clear-selection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"open-selected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"delete-selected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"confirm-delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"cancel-delete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Delete selected history?") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"select\" type=\"checkbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const selectedUrls =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const visibleRows =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const selectedRows =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const setRowsSelected =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const setRangeSelected =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "let lastSelectedIndex = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "let confirmingDelete = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "selectionBar.classList.toggle(\"confirming\", confirmingDelete)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "confirmDelete.href = urls.length === 0 ? \"#\" : actionHref(\"delete\", urls)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "deleteSelected.addEventListener(\"click\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "cancelDelete.addEventListener(\"click\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "document.addEventListener(\"keydown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "event.key === \"Escape\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "event.key === \"Enter\" && confirmingDelete") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "event.key.toLowerCase() === \"a\" && event.target !== search") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "event.shiftKey && lastSelectedIndex !== null") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "setRowsSelected(visibleRows(), true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "setRowsSelected(rows, false)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "https://nimlo.internal/history/${action}?urls=") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "encodeURIComponent(urls.join(\"\\n\"))") != null);
}

test "includes day grouping and grouped search behavior" {
    const entries = [_]history.HistoryEntry{
        .{ .url = "https://example.com/today", .title = "Today", .visited_at = 1_799_999_999_000 },
        .{ .url = "https://example.com/older", .title = "Older", .visited_at = 1_799_913_599_000 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, ".day-header") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ".day-select") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const groupLabel =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const buildDayGroups =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "selectDay.textContent = \"Select day\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "setRowsSelected([...list.querySelectorAll(\".row\")], true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "history.textContent = \"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "group.classList.toggle(\"hidden\", !hasVisibleRows)") != null);
}

test "includes tokenized title url and hostname search" {
    const entries = [_]history.HistoryEntry{
        .{ .url = "https://www.nytimes.com/live/2026/06/07/world/iran-israel-missiles", .title = "Live Updates", .visited_at = 1_799_999_999_000 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "data-url=\"https://www.nytimes.com/live/2026/06/07/world/iran-israel-missiles\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const hostFromUrl =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const searchTokens =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "tokens.every((token) => row.dataset.search.includes(token))") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hostFromUrl(row.dataset.url)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ".toLowerCase()") != null);
}

test "does not create links for non-web schemes" {
    const entries = [_]history.HistoryEntry{
        .{ .url = "javascript:alert(1)", .title = "Bad Link", .visited_at = 1 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"title\">Bad Link</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"javascript:") == null);
}

test "renders legacy and real visited timestamps" {
    const entries = [_]history.HistoryEntry{
        .{ .url = "https://legacy.example", .title = "Legacy", .visited_at = 7 },
        .{ .url = "https://time.example", .title = "Time", .visited_at = 1_799_999_999_000 },
    };
    const html = try render(std.testing.allocator, &entries);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Visit 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-visited-at=\"1799999999000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "formatVisitedAt") != null);
}
