//! Canonical network rules → WebKit content-blocker JSON for
//! WKContentRuleListStore (docs/CONTENT_BLOCKING.md, Phase D). Emission is
//! deterministic: block rules in input order first, then all exceptions as
//! trailing ignore-previous-rules (WebKit evaluates in order; a later
//! ignore-previous-rules cancels earlier matched actions). The rule cap
//! reserves exceptions first — dropping an exception over-blocks and breaks
//! sites, dropping a block merely lets one request through.
//!
//! Fidelity notes (deliberate 0.8 simplifications, all counted in stats):
//! - `$subdocument` maps to resource-type "document" without a load-context
//!   restriction, so it also matches top-frame navigations to the same URL.
//! - `@@…$document` whole-page exceptions unblock matching document loads
//!   only; upgrading them to if-top-url scoping is a Phase F/I follow-up.
//! - A domain-scoped rule with both includes and excludes becomes a pair:
//!   the block with if-domain, plus an ignore-previous-rules with the
//!   excluded domains (which can also cancel earlier rules in that context).

const std = @import("std");
pub const filter = @import("filter.zig");

pub const default_rule_cap = 150_000;

/// Separator regex bodies for the ABP `^` wildcard: anything but
/// alphanumerics, `_`, `-`, `.`, `%` — and, for a trailing `^`, end-of-URL.
const separator_class = "[^-a-zA-Z0-9_.%]";
const trailing_separator = "(" ++ separator_class ++ ".*)?$";
const trailing_separator_then_end = "(" ++ separator_class ++ ")?$";
const domain_anchor_prefix = "^[^:]+://+([^:/]+\\.)?";

pub const EmitStats = struct {
    emitted_total: usize = 0,
    emitted_blocks: usize = 0,
    emitted_exceptions: usize = 0,
    /// Block rules not emitted because the cap was reached.
    capped_blocks: usize = 0,
    /// Rules whose type constraints cannot match anything in WebKit space.
    dropped_unexpressible: usize = 0,
    /// `@@…$document` exceptions emitted with partial (per-request) fidelity.
    document_exceptions_partial: usize = 0,

    pub fn emitted(self: EmitStats) usize {
        return self.emitted_total;
    }
};

pub const EmitResult = struct {
    json: []u8,
    stats: EmitStats,
};

pub fn emitJson(
    allocator: std.mem.Allocator,
    rules: []const filter.NetworkRule,
    rule_cap: usize,
) !EmitResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var stats = EmitStats{};

    // Reserve budget for exceptions first (see module comment).
    var exception_budget: usize = 0;
    for (rules) |rule| {
        if (rule.is_exception) exception_budget += 1;
    }
    exception_budget = @min(exception_budget, rule_cap);
    const block_budget = rule_cap - exception_budget;

    try out.append(allocator, '[');

    for (rules) |rule| {
        if (rule.is_exception) continue;
        const cost: usize = if (rule.domains.len > 0 and rule.domains_excluded.len > 0) 2 else 1;
        if (stats.emitted_blocks + cost > block_budget) {
            stats.capped_blocks += 1;
            continue;
        }
        const wk_types = webkitTypes(rule) orelse {
            stats.dropped_unexpressible += 1;
            continue;
        };

        try appendRule(allocator, &out, stats.emitted_total, rule, wk_types, .block, .include_domains);
        stats.emitted_total += 1;
        stats.emitted_blocks += 1;
        if (cost == 2) {
            try appendRule(allocator, &out, stats.emitted_total, rule, wk_types, .ignore_previous, .exclude_domains);
            stats.emitted_total += 1;
            stats.emitted_blocks += 1;
        }
    }

    for (rules) |rule| {
        if (!rule.is_exception) continue;
        if (stats.emitted_exceptions >= exception_budget) break;
        const wk_types = webkitTypes(rule) orelse {
            stats.dropped_unexpressible += 1;
            continue;
        };
        if (rule.types.document) stats.document_exceptions_partial += 1;

        try appendRule(allocator, &out, stats.emitted_total, rule, wk_types, .ignore_previous, .include_domains);
        stats.emitted_total += 1;
        stats.emitted_exceptions += 1;
    }

    try out.append(allocator, ']');
    return .{ .json = try out.toOwnedSlice(allocator), .stats = stats };
}

/// The url-filter regex for a rule, in WebKit's restricted syntax (no
/// alternation; groups with quantifiers are supported). Public for tests.
pub fn urlFilterForRule(allocator: std.mem.Allocator, rule: filter.NetworkRule) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (rule.domain_anchored) {
        try out.appendSlice(allocator, domain_anchor_prefix);
    } else if (rule.start_anchored) {
        try out.append(allocator, '^');
    }

    const pattern = rule.pattern;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const char = pattern[index];
        const is_last = index == pattern.len - 1;
        switch (char) {
            '*' => try out.appendSlice(allocator, ".*"),
            '^' => {
                if (is_last) {
                    // Trailing separator also matches end-of-URL.
                    const suffix = if (rule.end_anchored) trailing_separator_then_end else trailing_separator;
                    try out.appendSlice(allocator, suffix);
                    return out.toOwnedSlice(allocator);
                }
                try out.appendSlice(allocator, separator_class);
            },
            else => {
                if (isRegexMeta(char)) try out.append(allocator, '\\');
                try out.append(allocator, char);
            },
        }
    }

    if (rule.end_anchored) try out.append(allocator, '$');
    if (out.items.len == 0) try out.appendSlice(allocator, ".*");
    return out.toOwnedSlice(allocator);
}

fn isRegexMeta(char: u8) bool {
    return switch (char) {
        '.', '?', '+', '*', '(', ')', '[', ']', '{', '}', '^', '$', '|', '\\' => true,
        else => false,
    };
}

// WebKit resource-type space as a bitset aligned with `webkit_type_names`.
const wk_document: u16 = 1 << 0;
const wk_image: u16 = 1 << 1;
const wk_stylesheet: u16 = 1 << 2;
const wk_script: u16 = 1 << 3;
const wk_font: u16 = 1 << 4;
const wk_raw: u16 = 1 << 5;
const wk_svg: u16 = 1 << 6;
const wk_media: u16 = 1 << 7;
const wk_popup: u16 = 1 << 8;
const wk_ping: u16 = 1 << 9;

const webkit_type_names = [_][]const u8{
    "document", "image", "style-sheet", "script", "font",
    "raw",      "media", "popup",       "ping",   "svg-document",
};
const webkit_type_bits = [_]u16{
    wk_document, wk_image, wk_stylesheet, wk_script, wk_font,
    wk_raw,      wk_media, wk_popup,      wk_ping,   wk_svg,
};

/// ABP option-less rules apply to every request type except main documents
/// and popups (those require explicit opt-in).
const wk_default_types: u16 = wk_image | wk_stylesheet | wk_script | wk_font |
    wk_raw | wk_svg | wk_media | wk_ping;

fn mapAbpTypes(types: filter.ResourceTypes) u16 {
    var bits: u16 = 0;
    if (types.script) bits |= wk_script;
    if (types.image) bits |= wk_image | wk_svg;
    if (types.stylesheet) bits |= wk_stylesheet;
    if (types.subdocument) bits |= wk_document;
    if (types.xhr) bits |= wk_raw;
    if (types.document) bits |= wk_document;
    if (types.font) bits |= wk_font;
    if (types.media) bits |= wk_media;
    if (types.websocket) bits |= wk_raw;
    if (types.ping) bits |= wk_ping;
    if (types.object) bits |= wk_raw;
    if (types.popup) bits |= wk_popup;
    if (types.other) bits |= wk_raw;
    return bits;
}

/// The WebKit resource-type set for a rule, or null when the constraints
/// cannot match anything. Excludes remove whole WebKit types even when the
/// mapping is many-to-one (`~xhr` removes all of "raw") — under-blocking,
/// never over-blocking.
fn webkitTypes(rule: filter.NetworkRule) ?u16 {
    const included = if (rule.types.isEmpty()) wk_default_types else mapAbpTypes(rule.types);
    const result = included & ~mapAbpTypes(rule.types_excluded);
    return if (result == 0) null else result;
}

const Action = enum { block, ignore_previous };
const DomainMode = enum { include_domains, exclude_domains };

fn appendRule(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    emitted_so_far: usize,
    rule: filter.NetworkRule,
    wk_types: u16,
    action: Action,
    domain_mode: DomainMode,
) !void {
    if (emitted_so_far > 0) try out.append(allocator, ',');

    try out.appendSlice(allocator, "{\"trigger\":{\"url-filter\":");
    const url_filter = try urlFilterForRule(allocator, rule);
    defer allocator.free(url_filter);
    try appendJsonString(allocator, out, url_filter);

    if (rule.match_case) {
        try out.appendSlice(allocator, ",\"url-filter-is-case-sensitive\":true");
    }

    // Always explicit: omitting resource-type means "all types" to WebKit,
    // including document and popup, which ABP semantics reserve for opt-in.
    try out.appendSlice(allocator, ",\"resource-type\":[");
    var first = true;
    for (webkit_type_bits, webkit_type_names) |bit, name| {
        if (wk_types & bit == 0) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendJsonString(allocator, out, name);
    }
    try out.append(allocator, ']');

    switch (rule.party) {
        .third => try out.appendSlice(allocator, ",\"load-type\":[\"third-party\"]"),
        .first => try out.appendSlice(allocator, ",\"load-type\":[\"first-party\"]"),
        .any => {},
    }

    switch (domain_mode) {
        .include_domains => {
            if (rule.domains.len > 0) {
                try appendDomainList(allocator, out, "if-domain", rule.domains);
            } else if (rule.domains_excluded.len > 0) {
                try appendDomainList(allocator, out, "unless-domain", rule.domains_excluded);
            }
        },
        .exclude_domains => {
            try appendDomainList(allocator, out, "if-domain", rule.domains_excluded);
        },
    }

    try out.appendSlice(allocator, "},\"action\":{\"type\":");
    try appendJsonString(allocator, out, switch (action) {
        .block => "block",
        .ignore_previous => "ignore-previous-rules",
    });
    try out.appendSlice(allocator, "}}");
}

fn appendDomainList(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    domains: []const []const u8,
) !void {
    try out.append(allocator, ',');
    try appendJsonString(allocator, out, key);
    try out.appendSlice(allocator, ":[");
    for (domains, 0..) |domain, index| {
        if (index > 0) try out.append(allocator, ',');
        // Leading '*' = "this domain and its subdomains" (ABP semantics).
        try out.append(allocator, '"');
        try out.append(allocator, '*');
        try appendJsonStringBody(allocator, out, domain);
        try out.append(allocator, '"');
    }
    try out.append(allocator, ']');
}

/// Splices a per-site allow rule into an emitted rule-list JSON: an
/// `ignore-previous-rules` action scoped by `if-domain` to the allowed
/// hosts (with subdomains). It must live INSIDE each list because WebKit
/// scopes ignore-previous-rules per rule list — a separate exceptions list
/// does not reach earlier lists (verified empirically; see Appendix A,
/// Phase G). Returns a copy of `base_json` when there is nothing to splice.
pub fn spliceSiteAllowRules(
    allocator: std.mem.Allocator,
    base_json: []const u8,
    allowed_hosts: []const []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, base_json, " \t\r\n");
    if (allowed_hosts.len == 0 or trimmed.len < 2 or trimmed[trimmed.len - 1] != ']') {
        return allocator.dupe(u8, base_json);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const body = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
    try out.appendSlice(allocator, body);
    // `body` still starts with '['; only a non-empty list needs a comma.
    if (!std.mem.eql(u8, body, "[")) try out.append(allocator, ',');

    try out.appendSlice(allocator, "{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[");
    for (allowed_hosts, 0..) |host, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try out.append(allocator, '*');
        try appendJsonStringBody(allocator, &out, host);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "]},\"action\":{\"type\":\"ignore-previous-rules\"}}]");

    return out.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    try appendJsonStringBody(allocator, out, text);
    try out.append(allocator, '"');
}

fn appendJsonStringBody(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => {
                if (char < 0x20) {
                    var buffer: [6]u8 = undefined;
                    const encoded = std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{char}) catch unreachable;
                    try out.appendSlice(allocator, encoded);
                } else {
                    try out.append(allocator, char);
                }
            },
        }
    }
}

// --- tests ---------------------------------------------------------------

const abp_parser = @import("abp_parser.zig");
const matcher_mod = @import("matcher.zig");

test "url-filter translation shapes" {
    const cases = .{
        .{ "||ads.example.com^", "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com([^-a-zA-Z0-9_.%].*)?$" },
        .{ "|https://exact.example.com/file.js|", "^https://exact\\.example\\.com/file\\.js$" },
        .{ "banner/*/ad", "banner/.*/ad" },
        .{ "example.com^ads", "example\\.com[^-a-zA-Z0-9_.%]ads" },
        .{ "ads?id=1", "ads\\?id=1" },
    };
    inline for (cases) |case| {
        var parsed = try abp_parser.parseList(std.testing.allocator, case[0]);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.network.len);

        const url_filter = try urlFilterForRule(std.testing.allocator, parsed.network[0]);
        defer std.testing.allocator.free(url_filter);
        try std.testing.expectEqualStrings(case[1], url_filter);
    }
}

test "golden JSON for a small list" {
    var parsed = try abp_parser.parseList(std.testing.allocator,
        \\||ads.example.com^$script,third-party
        \\@@||cdn.example.com^
    );
    defer parsed.deinit();

    const result = try emitJson(std.testing.allocator, parsed.network, default_rule_cap);
    defer std.testing.allocator.free(result.json);

    const expected =
        "[{\"trigger\":{\"url-filter\":\"^[^:]+://+([^:/]+\\\\.)?ads\\\\.example\\\\.com([^-a-zA-Z0-9_.%].*)?$\"," ++
        "\"resource-type\":[\"script\"],\"load-type\":[\"third-party\"]},\"action\":{\"type\":\"block\"}}," ++
        "{\"trigger\":{\"url-filter\":\"^[^:]+://+([^:/]+\\\\.)?cdn\\\\.example\\\\.com([^-a-zA-Z0-9_.%].*)?$\"," ++
        "\"resource-type\":[\"image\",\"style-sheet\",\"script\",\"font\",\"raw\",\"media\",\"ping\",\"svg-document\"]}," ++
        "\"action\":{\"type\":\"ignore-previous-rules\"}}]";
    try std.testing.expectEqualStrings(expected, result.json);
    try std.testing.expectEqual(@as(usize, 1), result.stats.emitted_blocks);
    try std.testing.expectEqual(@as(usize, 1), result.stats.emitted_exceptions);
}

test "emitted JSON parses as JSON and orders exceptions last" {
    var parsed = try abp_parser.parseList(std.testing.allocator,
        \\||ads.example.com^
        \\@@||ads.example.com^$script
        \\||tracker.example.net^$domain=news.example|~beta.news.example
        \\||CDN.Example.org/Path$match-case
        \\$ping,domain=tracked.example
    );
    defer parsed.deinit();

    const result = try emitJson(std.testing.allocator, parsed.network, default_rule_cap);
    defer std.testing.allocator.free(result.json);

    var parsed_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.json, .{});
    defer parsed_json.deinit();

    const array = parsed_json.value.array.items;
    try std.testing.expectEqual(result.stats.emitted_total, array.len);
    // Four block rules + the mixed-domain pair expansion + one exception.
    try std.testing.expectEqual(@as(usize, 6), array.len);
    const last_action = array[array.len - 1].object.get("action").?.object.get("type").?.string;
    try std.testing.expectEqualStrings("ignore-previous-rules", last_action);

    const pair_cancel = array[2].object;
    try std.testing.expectEqualStrings(
        "ignore-previous-rules",
        pair_cancel.get("action").?.object.get("type").?.string,
    );
    const pair_domains = pair_cancel.get("trigger").?.object.get("if-domain").?.array.items;
    try std.testing.expectEqualStrings("*beta.news.example", pair_domains[0].string);

    const case_rule = array[3].object.get("trigger").?.object;
    try std.testing.expect(case_rule.get("url-filter-is-case-sensitive").?.bool);
}

test "generic rules exclude document and popup types" {
    var parsed = try abp_parser.parseList(std.testing.allocator, "||ads.example.com^");
    defer parsed.deinit();

    const result = try emitJson(std.testing.allocator, parsed.network, default_rule_cap);
    defer std.testing.allocator.free(result.json);

    // Default type set is implicit: no resource-type key, which WebKit
    // treats as all types — so we must emit the explicit non-document set.
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"resource-type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"document\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"popup\"") == null);
}

test "cap reserves exceptions and counts capped blocks" {
    var parsed = try abp_parser.parseList(std.testing.allocator,
        \\||a.example.com^
        \\||b.example.com^
        \\||c.example.com^
        \\@@||cdn.example.com^
    );
    defer parsed.deinit();

    const result = try emitJson(std.testing.allocator, parsed.network, 3);
    defer std.testing.allocator.free(result.json);

    try std.testing.expectEqual(@as(usize, 2), result.stats.emitted_blocks);
    try std.testing.expectEqual(@as(usize, 1), result.stats.emitted_exceptions);
    try std.testing.expectEqual(@as(usize, 1), result.stats.capped_blocks);
}

test "unexpressible type sets are dropped and counted" {
    var parsed = try abp_parser.parseList(std.testing.allocator, "||x.example.com^$script,~script");
    defer parsed.deinit();

    const result = try emitJson(std.testing.allocator, parsed.network, default_rule_cap);
    defer std.testing.allocator.free(result.json);

    try std.testing.expectEqualStrings("[]", result.json);
    try std.testing.expectEqual(@as(usize, 1), result.stats.dropped_unexpressible);
}

// A tiny interpreter for exactly the regex subset the emitter produces
// (literals, escapes, '.', classes with ranges/negation, '*'/'+'/'?'
// quantifiers, non-nested optional groups, '^'/'$'). It exists so the
// matcher and the emitted url-filters can be executed against the same
// URLs: the cross-check below is the emitter's real spec.
const mini_regex = struct {
    fn matches(re: []const u8, url: []const u8) !bool {
        // Expand non-nested "(…)?" groups into present/absent variants.
        if (std.mem.indexOfScalar(u8, re, '(')) |open| {
            const close = std.mem.indexOfScalarPos(u8, re, open, ')') orelse return error.BadGroup;
            if (close + 1 >= re.len or re[close + 1] != '?') return error.BadGroup;

            var with_group: std.ArrayList(u8) = .empty;
            defer with_group.deinit(std.testing.allocator);
            try with_group.appendSlice(std.testing.allocator, re[0..open]);
            try with_group.appendSlice(std.testing.allocator, re[open + 1 .. close]);
            try with_group.appendSlice(std.testing.allocator, re[close + 2 ..]);
            if (try matches(with_group.items, url)) return true;

            var without_group: std.ArrayList(u8) = .empty;
            defer without_group.deinit(std.testing.allocator);
            try without_group.appendSlice(std.testing.allocator, re[0..open]);
            try without_group.appendSlice(std.testing.allocator, re[close + 2 ..]);
            return matches(without_group.items, url);
        }

        if (re.len > 0 and re[0] == '^') {
            return matchSequence(re[1..], url, 0);
        }
        // url-filter is a search, not a full match.
        var start: usize = 0;
        while (start <= url.len) : (start += 1) {
            if (matchSequence(re, url, start)) return true;
        }
        return false;
    }

    fn matchSequence(re: []const u8, url: []const u8, position: usize) bool {
        if (re.len == 0) return true;
        if (re[0] == '$' and re.len == 1) return position == url.len;

        const element_len: usize = switch (re[0]) {
            '\\' => 2,
            '[' => (std.mem.indexOfScalarPos(u8, re, 1, ']') orelse unreachable) + 1,
            else => 1,
        };
        const element = re[0..element_len];
        const quantifier: u8 = if (element_len < re.len) re[element_len] else 0;

        switch (quantifier) {
            '*', '+' => {
                const rest = re[element_len + 1 ..];
                var pos = position;
                if (quantifier == '+') {
                    if (!elementMatches(element, url, pos)) return false;
                    pos += 1;
                }
                while (true) {
                    if (matchSequence(rest, url, pos)) return true;
                    if (!elementMatches(element, url, pos)) return false;
                    pos += 1;
                }
            },
            '?' => {
                const rest = re[element_len + 1 ..];
                if (elementMatches(element, url, position) and matchSequence(rest, url, position + 1)) {
                    return true;
                }
                return matchSequence(rest, url, position);
            },
            else => {
                if (!elementMatches(element, url, position)) return false;
                return matchSequence(re[element_len..], url, position + 1);
            },
        }
    }

    fn elementMatches(element: []const u8, url: []const u8, position: usize) bool {
        if (position >= url.len) return false;
        const char = url[position];
        return switch (element[0]) {
            '\\' => char == element[1],
            '.' => true,
            '[' => classMatches(element[1 .. element.len - 1], char),
            else => char == element[0],
        };
    }

    fn classMatches(body: []const u8, char: u8) bool {
        var negated = false;
        var set = body;
        if (set.len > 0 and set[0] == '^') {
            negated = true;
            set = set[1..];
        }

        var found = false;
        var index: usize = 0;
        while (index < set.len) {
            if (index + 2 < set.len and set[index + 1] == '-') {
                if (char >= set[index] and char <= set[index + 2]) found = true;
                index += 3;
            } else {
                if (char == set[index]) found = true;
                index += 1;
            }
        }
        return found != negated;
    }
};

test "cross-check: matcher and emitted url-filter agree on pattern semantics" {
    const cases = .{
        // pattern-only rule line, URL, should match
        .{ "||ads.example.com^", "https://ads.example.com/banner.js", true },
        .{ "||ads.example.com^", "https://eu.ads.example.com/x", true },
        .{ "||ads.example.com^", "https://badads.example.com.evil.net/x", false },
        .{ "||ads.example.com^", "https://safe.example.org/ads.example.com/page", false },
        .{ "||example.com^", "https://example.com", true },
        .{ "||example.com^", "https://example.com/", true },
        .{ "||example.com^", "https://example.community.net/", false },
        .{ "banner/*/ad", "https://x.example.net/banner/top/ad.png", true },
        .{ "banner/*/ad", "https://x.example.net/banner/ad", false },
        .{ "|https://exact.example.com/file.js|", "https://exact.example.com/file.js", true },
        .{ "|https://exact.example.com/file.js|", "https://exact.example.com/file.js?v=2", false },
        .{ "ads?id=1", "https://x.example.com/ads?id=1", true },
        .{ "ads?id=1", "https://x.example.com/adsxid=1", false },
        .{ "example.com^ads", "https://example.com/ads", true },
        .{ "example.com^ads", "https://example.com.ads.net/", false },
        .{ "ads", "https://cdn.example.com/loads.js", true },
    };

    inline for (cases) |case| {
        var parsed = try abp_parser.parseList(std.testing.allocator, case[0]);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.network.len);

        var matcher = try matcher_mod.Matcher.init(std.testing.allocator, parsed.network);
        defer matcher.deinit();
        const matcher_says = matcher.verdict(.{ .url = case[1] }) == .block;

        const url_filter = try urlFilterForRule(std.testing.allocator, parsed.network[0]);
        defer std.testing.allocator.free(url_filter);
        const regex_says = try mini_regex.matches(url_filter, case[1]);

        try std.testing.expectEqual(case[2], matcher_says);
        try std.testing.expectEqual(case[2], regex_says);
    }
}

test "spliceSiteAllowRules appends a scoped ignore rule inside the list" {
    const base =
        \\[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]
    ;
    const hosts = [_][]const u8{ "news.example", "shop.example" };
    const spliced = try spliceSiteAllowRules(std.testing.allocator, base, &hosts);
    defer std.testing.allocator.free(spliced);

    try std.testing.expectEqualStrings(
        \\[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}},{"trigger":{"url-filter":".*","if-domain":["*news.example","*shop.example"]},"action":{"type":"ignore-previous-rules"}}]
    , spliced);

    // Still valid JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, spliced, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

test "spliceSiteAllowRules handles empty inputs" {
    const no_hosts = try spliceSiteAllowRules(std.testing.allocator, "[{\"x\":1}]", &.{});
    defer std.testing.allocator.free(no_hosts);
    try std.testing.expectEqualStrings("[{\"x\":1}]", no_hosts);

    const hosts = [_][]const u8{"news.example"};
    const empty_base = try spliceSiteAllowRules(std.testing.allocator, "[]", &hosts);
    defer std.testing.allocator.free(empty_base);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, empty_base, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
}
