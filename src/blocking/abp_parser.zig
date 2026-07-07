//! EasyList/ABP filter-list syntax → canonical rules (src/blocking/filter.zig).
//! Unsupported constructs are classified into ParseStats, never errors: a
//! filter list must parse end-to-end no matter what future syntax appears in
//! it. Capability decisions and measured category counts are recorded in
//! docs/CONTENT_BLOCKING.md, Appendix A.

const std = @import("std");
pub const filter = @import("filter.zig");

pub const ParsedList = struct {
    arena: std.heap.ArenaAllocator,
    network: []filter.NetworkRule,
    cosmetic: []filter.CosmeticRule,
    stats: filter.ParseStats,

    pub fn deinit(self: *ParsedList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseList(base_allocator: std.mem.Allocator, text: []const u8) !ParsedList {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var network: std.ArrayList(filter.NetworkRule) = .empty;
    var cosmetic: std.ArrayList(filter.CosmeticRule) = .empty;
    var stats = filter.ParseStats{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        stats.lines += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) {
            stats.blank += 1;
            continue;
        }
        if (line[0] == '!') {
            stats.comments += 1;
            continue;
        }
        if (line[0] == '[') {
            stats.headers += 1;
            continue;
        }

        if (cosmeticSeparator(line)) |separator| {
            try parseCosmeticLine(allocator, &cosmetic, &stats, line, separator);
        } else {
            try parseNetworkLine(allocator, &network, &stats, line);
        }
    }

    return .{
        .arena = arena,
        .network = try network.toOwnedSlice(allocator),
        .cosmetic = try cosmetic.toOwnedSlice(allocator),
        .stats = stats,
    };
}

const CosmeticSeparator = struct {
    index: usize,
    len: usize,
    kind: enum { hide, unhide, unsupported },
};

fn cosmeticSeparator(line: []const u8) ?CosmeticSeparator {
    // Procedural/snippet variants first; none of them contain a plain "##".
    inline for ([_][]const u8{ "#?#", "#$#", "#%#" }) |marker| {
        if (std.mem.indexOf(u8, line, marker)) |index| {
            return .{ .index = index, .len = marker.len, .kind = .unsupported };
        }
    }
    if (std.mem.indexOf(u8, line, "#@#")) |index| {
        return .{ .index = index, .len = 3, .kind = .unhide };
    }
    if (std.mem.indexOf(u8, line, "##")) |index| {
        // Scriptlet injection (uBO syntax) rides the "##" separator.
        if (std.mem.startsWith(u8, line[index..], "##+js(")) {
            return .{ .index = index, .len = 2, .kind = .unsupported };
        }
        return .{ .index = index, .len = 2, .kind = .hide };
    }
    return null;
}

fn parseCosmeticLine(
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(filter.CosmeticRule),
    stats: *filter.ParseStats,
    line: []const u8,
    separator: CosmeticSeparator,
) !void {
    if (separator.kind == .unsupported) {
        stats.dropped_procedural += 1;
        return;
    }

    const selector = std.mem.trim(u8, line[separator.index + separator.len ..], " \t");
    if (selector.len == 0) {
        stats.dropped_malformed += 1;
        return;
    }

    var rule = filter.CosmeticRule{
        .selector = try allocator.dupe(u8, selector),
        .is_exception = separator.kind == .unhide,
    };

    const prefix = line[0..separator.index];
    if (prefix.len > 0) {
        var domains: std.ArrayList([]const u8) = .empty;
        var excluded: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, prefix, ',');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len == 0) continue;
            if (entry[0] == '~') {
                if (entry.len == 1) continue;
                try excluded.append(allocator, try lowercaseDupe(allocator, entry[1..]));
            } else {
                try domains.append(allocator, try lowercaseDupe(allocator, entry));
            }
        }
        rule.domains = try domains.toOwnedSlice(allocator);
        rule.domains_excluded = try excluded.toOwnedSlice(allocator);
    }

    try rules.append(allocator, rule);
    if (rule.is_exception) {
        stats.cosmetic_exceptions += 1;
    } else {
        stats.cosmetic_rules += 1;
    }
}

fn parseNetworkLine(
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(filter.NetworkRule),
    stats: *filter.ParseStats,
    full_line: []const u8,
) !void {
    var line = full_line;
    var rule = filter.NetworkRule{ .pattern = "" };

    if (std.mem.startsWith(u8, line, "@@")) {
        rule.is_exception = true;
        line = line[2..];
    }

    // Raw regex rules: the whole body is /…/, optionally with options.
    if (line.len >= 2 and line[0] == '/') {
        if (line[line.len - 1] == '/' or std.mem.indexOf(u8, line, "/$") != null) {
            stats.dropped_regex += 1;
            return;
        }
    }

    // Options live after the last '$' whose suffix uses the option charset;
    // otherwise the '$' belongs to the URL pattern.
    var pattern = line;
    var options_text: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, line, '$')) |dollar| {
        const suffix = line[dollar + 1 ..];
        if (suffix.len > 0 and isOptionText(suffix)) {
            pattern = line[0..dollar];
            options_text = suffix;
        }
    }

    var soft_ignored = false;
    if (options_text) |options| {
        switch (try applyOptions(allocator, &rule, options, &soft_ignored)) {
            .ok => {},
            .unsupported => {
                stats.dropped_options += 1;
                return;
            },
            .malformed => {
                stats.dropped_malformed += 1;
                return;
            },
        }
    }

    if (std.mem.startsWith(u8, pattern, "||")) {
        rule.domain_anchored = true;
        pattern = pattern[2..];
    } else if (std.mem.startsWith(u8, pattern, "|")) {
        rule.start_anchored = true;
        pattern = pattern[1..];
    }
    if (pattern.len > 0 and pattern[pattern.len - 1] == '|') {
        rule.end_anchored = true;
        pattern = pattern[0 .. pattern.len - 1];
    }

    // Leading/trailing '*' make the adjacent anchor meaningless and are
    // no-ops for substring matching.
    while (pattern.len > 0 and pattern[0] == '*') {
        pattern = pattern[1..];
        rule.start_anchored = false;
        rule.domain_anchored = false;
    }
    while (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        pattern = pattern[0 .. pattern.len - 1];
        rule.end_anchored = false;
    }

    // A bare match-everything line ("*" or "") is a list bug, not a rule.
    if (pattern.len == 0 and options_text == null) {
        stats.dropped_malformed += 1;
        return;
    }

    rule.pattern = if (rule.match_case)
        try allocator.dupe(u8, pattern)
    else
        try lowercaseDupe(allocator, pattern);

    try rules.append(allocator, rule);
    if (soft_ignored) stats.options_ignored += 1;
    if (rule.is_exception) {
        stats.network_exceptions += 1;
    } else {
        stats.network_rules += 1;
    }
}

const OptionOutcome = enum { ok, unsupported, malformed };

fn applyOptions(
    allocator: std.mem.Allocator,
    rule: *filter.NetworkRule,
    options_text: []const u8,
    soft_ignored: *bool,
) !OptionOutcome {
    var include = filter.ResourceTypes{};
    var exclude = filter.ResourceTypes{};

    var it = std.mem.splitScalar(u8, options_text, ',');
    while (it.next()) |raw| {
        const option = std.mem.trim(u8, raw, " \t");
        if (option.len == 0) return .malformed;

        if (std.mem.eql(u8, option, "third-party") or std.mem.eql(u8, option, "3p")) {
            rule.party = .third;
        } else if (std.mem.eql(u8, option, "~third-party") or
            std.mem.eql(u8, option, "first-party") or
            std.mem.eql(u8, option, "1p"))
        {
            rule.party = .first;
        } else if (std.mem.eql(u8, option, "match-case")) {
            rule.match_case = true;
        } else if (std.mem.startsWith(u8, option, "domain=")) {
            if (try parseDomainsOption(allocator, rule, option["domain=".len..]) == .malformed) {
                return .malformed;
            }
        } else if (std.mem.eql(u8, option, "important")) {
            // Priority override; matcher/emitter approximate it, see Appendix A.
            soft_ignored.* = true;
        } else if (resourceType(option)) |kind| {
            include = typeUnion(include, kind);
        } else if (option[0] == '~') {
            const kind = resourceType(option[1..]) orelse return .unsupported;
            exclude = typeUnion(exclude, kind);
        } else {
            // Covers $generichide/$elemhide (cosmetic-control — treating them
            // as network exceptions would wrongly unblock requests),
            // $redirect=/$csp=/$removeparam=, $badfilter, and anything new.
            return .unsupported;
        }
    }

    rule.types = include;
    rule.types_excluded = exclude;
    return .ok;
}

const DomainsOutcome = enum { ok, malformed };

fn parseDomainsOption(
    allocator: std.mem.Allocator,
    rule: *filter.NetworkRule,
    value: []const u8,
) !DomainsOutcome {
    if (value.len == 0) return .malformed;

    var domains: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, '|');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (entry[0] == '~') {
            if (entry.len == 1) continue;
            try excluded.append(allocator, try lowercaseDupe(allocator, entry[1..]));
        } else {
            try domains.append(allocator, try lowercaseDupe(allocator, entry));
        }
    }
    if (domains.items.len == 0 and excluded.items.len == 0) return .malformed;

    rule.domains = try domains.toOwnedSlice(allocator);
    rule.domains_excluded = try excluded.toOwnedSlice(allocator);
    return .ok;
}

fn resourceType(name: []const u8) ?filter.ResourceTypes {
    const map = .{
        .{ "script", filter.ResourceTypes{ .script = true } },
        .{ "image", filter.ResourceTypes{ .image = true } },
        .{ "img", filter.ResourceTypes{ .image = true } },
        .{ "stylesheet", filter.ResourceTypes{ .stylesheet = true } },
        .{ "css", filter.ResourceTypes{ .stylesheet = true } },
        .{ "subdocument", filter.ResourceTypes{ .subdocument = true } },
        .{ "frame", filter.ResourceTypes{ .subdocument = true } },
        .{ "xmlhttprequest", filter.ResourceTypes{ .xhr = true } },
        .{ "xhr", filter.ResourceTypes{ .xhr = true } },
        .{ "document", filter.ResourceTypes{ .document = true } },
        .{ "doc", filter.ResourceTypes{ .document = true } },
        .{ "font", filter.ResourceTypes{ .font = true } },
        .{ "media", filter.ResourceTypes{ .media = true } },
        .{ "websocket", filter.ResourceTypes{ .websocket = true } },
        .{ "object", filter.ResourceTypes{ .object = true } },
        .{ "object-subrequest", filter.ResourceTypes{ .object = true } },
        .{ "ping", filter.ResourceTypes{ .ping = true } },
        .{ "beacon", filter.ResourceTypes{ .ping = true } },
        .{ "popup", filter.ResourceTypes{ .popup = true } },
        .{ "other", filter.ResourceTypes{ .other = true } },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn typeUnion(a: filter.ResourceTypes, b: filter.ResourceTypes) filter.ResourceTypes {
    return @bitCast(@as(u16, @bitCast(a)) | @as(u16, @bitCast(b)));
}

fn isOptionText(text: []const u8) bool {
    for (text) |char| {
        const ok = std.ascii.isAlphanumeric(char) or switch (char) {
            '-', '=', '~', ',', '|', '.', '_' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

fn lowercaseDupe(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, text);
    for (copy) |*char| char.* = std.ascii.toLower(char.*);
    return copy;
}

// --- tests ---------------------------------------------------------------

fn parseSingle(text: []const u8) !ParsedList {
    return parseList(std.testing.allocator, text);
}

test "comments, headers, and blank lines are counted, not parsed" {
    var parsed = try parseSingle("[Adblock Plus 2.0]\n! Title: EasyList\n\n||ads.example.com^");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.stats.headers);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.comments);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.blank);
    try std.testing.expectEqual(@as(usize, 1), parsed.network.len);
}

test "domain-anchored block rule" {
    var parsed = try parseSingle("||ads.example.com^");
    defer parsed.deinit();

    const rule = parsed.network[0];
    try std.testing.expect(rule.domain_anchored);
    try std.testing.expect(!rule.is_exception);
    try std.testing.expectEqualStrings("ads.example.com^", rule.pattern);
    try std.testing.expect(rule.types.isEmpty());
    try std.testing.expectEqual(filter.Party.any, rule.party);
}

test "exception rule with types and domain option" {
    var parsed = try parseSingle("@@||cdn.example.com^$script,xmlhttprequest,domain=news.example|~beta.news.example");
    defer parsed.deinit();

    const rule = parsed.network[0];
    try std.testing.expect(rule.is_exception);
    try std.testing.expect(rule.types.script);
    try std.testing.expect(rule.types.xhr);
    try std.testing.expect(!rule.types.image);
    try std.testing.expectEqual(@as(usize, 1), rule.domains.len);
    try std.testing.expectEqualStrings("news.example", rule.domains[0]);
    try std.testing.expectEqualStrings("beta.news.example", rule.domains_excluded[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.network_exceptions);
}

test "start and end anchors" {
    var parsed = try parseSingle("|https://exact.example.com/download|");
    defer parsed.deinit();

    const rule = parsed.network[0];
    try std.testing.expect(rule.start_anchored);
    try std.testing.expect(rule.end_anchored);
    try std.testing.expect(!rule.domain_anchored);
    try std.testing.expectEqualStrings("https://exact.example.com/download", rule.pattern);
}

test "party options and type exclusions" {
    var parsed = try parseSingle(
        \\||tracker.example.com^$third-party
        \\||widget.example.com^$~third-party
        \\||mixed.example.com^$~script,~image
    );
    defer parsed.deinit();

    try std.testing.expectEqual(filter.Party.third, parsed.network[0].party);
    try std.testing.expectEqual(filter.Party.first, parsed.network[1].party);
    const mixed = parsed.network[2];
    try std.testing.expect(mixed.types.isEmpty());
    try std.testing.expect(mixed.types_excluded.script);
    try std.testing.expect(mixed.types_excluded.image);
}

test "patterns lowercase by default, preserved with match-case" {
    var parsed = try parseSingle(
        \\||CDN.Example.com/Banner
        \\||CDN.Example.com/Banner$match-case
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("cdn.example.com/banner", parsed.network[0].pattern);
    try std.testing.expectEqualStrings("CDN.Example.com/Banner", parsed.network[1].pattern);
    try std.testing.expect(parsed.network[1].match_case);
}

test "important is accepted and counted as ignored" {
    var parsed = try parseSingle("||ads.example.com^$important,script");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.network.len);
    try std.testing.expect(parsed.network[0].types.script);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.options_ignored);
}

test "cosmetic-control and rewrite options drop the rule" {
    var parsed = try parseSingle(
        \\@@||site.example.com^$generichide
        \\||ads.example.com/x.js$redirect=noopjs
        \\||ads.example.com^$removeparam=utm_source
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.network.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.stats.dropped_options);
}

test "regex rules drop" {
    var parsed = try parseSingle(
        \\/banner[0-9]+\.gif/
        \\/ads\/popup/$image
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.network.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.stats.dropped_regex);
}

test "dollar inside a URL pattern is not an options separator" {
    var parsed = try parseSingle("||example.com/path/$file/download");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.network.len);
    try std.testing.expectEqualStrings("example.com/path/$file/download", parsed.network[0].pattern);
}

test "pure-option rule keeps an empty match-all pattern" {
    var parsed = try parseSingle("$ping,domain=example.com");
    defer parsed.deinit();

    const rule = parsed.network[0];
    try std.testing.expectEqualStrings("", rule.pattern);
    try std.testing.expect(rule.types.ping);
    try std.testing.expectEqualStrings("example.com", rule.domains[0]);
}

test "redundant wildcards trim and clear anchors" {
    var parsed = try parseSingle(
        \\|*banner/ads
        \\||ads.example.com/track*
    );
    defer parsed.deinit();

    const first = parsed.network[0];
    try std.testing.expect(!first.start_anchored);
    try std.testing.expectEqualStrings("banner/ads", first.pattern);
    const second = parsed.network[1];
    try std.testing.expect(second.domain_anchored);
    try std.testing.expect(!second.end_anchored);
    try std.testing.expectEqualStrings("ads.example.com/track", second.pattern);
}

test "bare wildcard line is malformed" {
    var parsed = try parseSingle("*");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.network.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.dropped_malformed);
}

test "cosmetic rules with domain scoping and exceptions" {
    var parsed = try parseSingle(
        \\##.ad-banner
        \\example.com,~m.example.com##.sidebar-ad
        \\example.com#@#.false-positive
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.stats.cosmetic_rules);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.cosmetic_exceptions);

    const generic = parsed.cosmetic[0];
    try std.testing.expectEqualStrings(".ad-banner", generic.selector);
    try std.testing.expectEqual(@as(usize, 0), generic.domains.len);

    const scoped = parsed.cosmetic[1];
    try std.testing.expectEqualStrings("example.com", scoped.domains[0]);
    try std.testing.expectEqualStrings("m.example.com", scoped.domains_excluded[0]);

    try std.testing.expect(parsed.cosmetic[2].is_exception);
}

test "procedural cosmetics and scriptlets drop" {
    var parsed = try parseSingle(
        \\example.com#?#div:has(.ad)
        \\example.com#$#body { overflow: auto !important; }
        \\example.com##+js(nowoif)
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.cosmetic.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.stats.dropped_procedural);
}

test "empty cosmetic selector is malformed" {
    var parsed = try parseSingle("example.com##");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.cosmetic.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.dropped_malformed);
}

test "stats reconcile against a mixed fixture" {
    const fixture =
        \\[Adblock Plus 2.0]
        \\! fixture list
        \\||ads.example.com^
        \\||tracker.example.com^$third-party
        \\@@||cdn.example.com^$script
        \\##.ad
        \\example.com#@#.ok
        \\/regex[0-9]/
        \\||x.example.com^$redirect=noopjs
        \\example.com#?#div:has(.ad)
        \\*
    ;
    var parsed = try parseSingle(fixture);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.stats.network_rules);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.network_exceptions);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.cosmetic_rules);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.cosmetic_exceptions);
    try std.testing.expectEqual(@as(usize, 5), parsed.stats.accepted());
    // regex + redirect + procedural + bare "*"
    try std.testing.expectEqual(@as(usize, 4), parsed.stats.dropped());
    try std.testing.expectEqual(@as(usize, 11), parsed.stats.lines);
}
