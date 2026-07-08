//! Runtime request matcher over canonical network rules: answers "should
//! this request load?". On Windows this runs inside WebView2's
//! WebResourceRequested hot path; on macOS WebKit enforces compiled rules
//! instead and this module serves as the correctness oracle for the JSON
//! emitter (docs/CONTENT_BLOCKING.md, Phases C/D).
//!
//! Indexing follows uBlock Origin's token-bucket idea, simplified: each rule
//! is filed under one "good" token of its pattern (a token guaranteed to be
//! boundary-aligned in any URL the pattern matches); rules without a good
//! token go to a tokenless list that is always checked. Lookup unions the
//! buckets of the URL's tokens, then verifies candidates exactly.

const std = @import("std");
pub const filter = @import("filter.zig");

pub const Verdict = enum { allow, block };

pub const Request = struct {
    url: []const u8,
    /// Host of the document issuing the request; empty for main-frame
    /// navigations (treated as first-party to themselves).
    document_host: []const u8 = "",
    /// Exactly one bit set.
    resource_type: filter.ResourceTypes = .{ .other = true },
};

pub const Matcher = struct {
    allocator: std.mem.Allocator,
    /// Borrowed; must outlive the matcher (typically the ParsedList arena).
    rules: []const filter.NetworkRule,
    block_buckets: TokenMap,
    exception_buckets: TokenMap,
    tokenless_block: std.ArrayList(u32),
    tokenless_exception: std.ArrayList(u32),
    /// Owns lowered token keys for match-case rule patterns.
    key_arena: std.heap.ArenaAllocator,
    url_lower_buffer: std.ArrayList(u8),
    host_lower_buffer: std.ArrayList(u8),

    const TokenMap = std.StringHashMapUnmanaged(std.ArrayList(u32));

    pub fn init(allocator: std.mem.Allocator, rules: []const filter.NetworkRule) !Matcher {
        var self = Matcher{
            .allocator = allocator,
            .rules = rules,
            .block_buckets = .empty,
            .exception_buckets = .empty,
            .tokenless_block = .empty,
            .tokenless_exception = .empty,
            .key_arena = std.heap.ArenaAllocator.init(allocator),
            .url_lower_buffer = .empty,
            .host_lower_buffer = .empty,
        };
        errdefer self.deinit();

        for (rules, 0..) |rule, index| {
            try self.indexRule(rule, @intCast(index));
        }
        return self;
    }

    pub fn deinit(self: *Matcher) void {
        var maps = [_]*TokenMap{ &self.block_buckets, &self.exception_buckets };
        for (&maps) |map| {
            var it = map.valueIterator();
            while (it.next()) |bucket| bucket.deinit(self.allocator);
            map.deinit(self.allocator);
        }
        self.tokenless_block.deinit(self.allocator);
        self.tokenless_exception.deinit(self.allocator);
        self.url_lower_buffer.deinit(self.allocator);
        self.host_lower_buffer.deinit(self.allocator);
        self.key_arena.deinit();
        self.* = undefined;
    }

    pub fn verdict(self: *Matcher, request: Request) Verdict {
        const url_lower = self.lowerInto(&self.url_lower_buffer, request.url) catch return .allow;
        const host = hostRange(url_lower);
        const request_host = url_lower[host.start..host.end];

        const doc_host_raw = if (request.document_host.len > 0) request.document_host else request_host;
        const doc_host = if (request.document_host.len > 0)
            self.lowerInto(&self.host_lower_buffer, doc_host_raw) catch return .allow
        else
            request_host;

        const is_third_party = !std.mem.eql(
            u8,
            registrableDomain(request_host),
            registrableDomain(doc_host),
        );

        const context = MatchContext{
            .url_lower = url_lower,
            .url_original = request.url,
            .host = host,
            .document_host = doc_host,
            .is_third_party = is_third_party,
            .resource_type = request.resource_type,
        };

        if (!self.anyMatch(&self.block_buckets, self.tokenless_block.items, context)) {
            return .allow;
        }
        if (self.anyMatch(&self.exception_buckets, self.tokenless_exception.items, context)) {
            return .allow;
        }
        return .block;
    }

    const MatchContext = struct {
        url_lower: []const u8,
        url_original: []const u8,
        host: HostRange,
        document_host: []const u8,
        is_third_party: bool,
        resource_type: filter.ResourceTypes,
    };

    fn anyMatch(self: *Matcher, buckets: *const TokenMap, tokenless: []const u32, context: MatchContext) bool {
        for (tokenless) |rule_index| {
            if (self.ruleMatches(rule_index, context)) return true;
        }

        var tokens = TokenIterator{ .text = context.url_lower };
        while (tokens.next()) |token| {
            const bucket = buckets.get(token) orelse continue;
            for (bucket.items) |rule_index| {
                if (self.ruleMatches(rule_index, context)) return true;
            }
        }
        return false;
    }

    fn ruleMatches(self: *Matcher, rule_index: u32, context: MatchContext) bool {
        const rule = self.rules[rule_index];

        switch (rule.party) {
            .third => if (!context.is_third_party) return false,
            .first => if (context.is_third_party) return false,
            .any => {},
        }
        if (!rule.types.isEmpty() and !rule.types.contains(context.resource_type)) return false;
        if (rule.types_excluded.contains(context.resource_type)) return false;

        if (rule.domains.len > 0) {
            var included = false;
            for (rule.domains) |domain| {
                if (hostMatchesDomain(context.document_host, domain)) {
                    included = true;
                    break;
                }
            }
            if (!included) return false;
        }
        for (rule.domains_excluded) |domain| {
            if (hostMatchesDomain(context.document_host, domain)) return false;
        }

        const url = if (rule.match_case) context.url_original else context.url_lower;
        return patternMatches(rule, url, context.host);
    }

    fn indexRule(self: *Matcher, rule: filter.NetworkRule, index: u32) !void {
        const token = try self.bestToken(rule);
        if (token) |key| {
            const map = if (rule.is_exception) &self.exception_buckets else &self.block_buckets;
            const entry = try map.getOrPut(self.allocator, key);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.allocator, index);
        } else {
            const list = if (rule.is_exception) &self.tokenless_exception else &self.tokenless_block;
            try list.append(self.allocator, index);
        }
    }

    /// The longest token of the pattern that is guaranteed to appear
    /// boundary-aligned in any matching URL. A token edge is unreliable when
    /// it touches a `*` or an unanchored pattern edge (the URL could extend
    /// the token there: pattern "ads" must match ".../loads.js").
    fn bestToken(self: *Matcher, rule: filter.NetworkRule) !?[]const u8 {
        const pattern = if (rule.match_case)
            try lowercaseDupe(self.key_arena.allocator(), rule.pattern)
        else
            rule.pattern;

        var best: ?[]const u8 = null;
        var start: usize = 0;
        while (start < pattern.len) {
            if (!isTokenChar(pattern[start])) {
                start += 1;
                continue;
            }
            var end = start;
            while (end < pattern.len and isTokenChar(pattern[end])) end += 1;

            const left_ok = if (start == 0)
                rule.domain_anchored or rule.start_anchored
            else
                pattern[start - 1] != '*';
            const right_ok = if (end == pattern.len)
                rule.end_anchored
            else
                pattern[end] != '*';

            if (left_ok and right_ok) {
                const token = pattern[start..end];
                if (best == null or token.len > best.?.len) best = token;
            }
            start = end;
        }
        return best;
    }

    fn lowerInto(self: *Matcher, buffer: *std.ArrayList(u8), text: []const u8) ![]const u8 {
        buffer.clearRetainingCapacity();
        try buffer.ensureTotalCapacity(self.allocator, text.len);
        for (text) |char| buffer.appendAssumeCapacity(std.ascii.toLower(char));
        return buffer.items;
    }
};

const TokenIterator = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *TokenIterator) ?[]const u8 {
        while (self.index < self.text.len and !isTokenChar(self.text[self.index])) self.index += 1;
        if (self.index >= self.text.len) return null;
        const start = self.index;
        while (self.index < self.text.len and isTokenChar(self.text[self.index])) self.index += 1;
        return self.text[start..self.index];
    }
};

pub const HostRange = struct {
    start: usize,
    end: usize,
};

pub fn hostRange(url: []const u8) HostRange {
    var start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| start = scheme_end + 3;

    var end = url.len;
    for (url[start..], start..) |char, index| {
        if (char == '/' or char == '?' or char == '#') {
            end = index;
            break;
        }
    }

    if (std.mem.lastIndexOfScalar(u8, url[start..end], '@')) |at| start += at + 1;

    if (std.mem.lastIndexOfScalar(u8, url[start..end], ':')) |colon| {
        const port = url[start + colon + 1 .. end];
        var all_digits = port.len > 0;
        for (port) |char| {
            if (!std.ascii.isDigit(char)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) end = start + colon;
    }

    return .{ .start = start, .end = end };
}

/// Pragmatic eTLD+1 without a public-suffix table: last two labels, or last
/// three under a small set of common second-level suffixes. Good enough for
/// first/third-party classification; a full PSL can slot in later.
pub fn registrableDomain(host: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, host, ".");
    if (trimmed.len == 0) return trimmed;
    if (isIpv4(trimmed)) return trimmed;

    const last_dot = std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse return trimmed;
    const second_dot = std.mem.lastIndexOfScalar(u8, trimmed[0..last_dot], '.') orelse return trimmed;
    const last_two = trimmed[second_dot + 1 ..];

    const second_level_suffixes = [_][]const u8{
        "co.uk",  "ac.uk",  "gov.uk", "org.uk", "net.uk",
        "co.jp",  "ne.jp",  "or.jp",  "com.au", "net.au",
        "org.au", "co.nz",  "co.in",  "com.br", "com.mx",
        "com.tr", "com.cn", "com.tw", "com.hk", "com.sg",
        "co.kr",  "co.za",  "com.ar",
    };
    for (second_level_suffixes) |suffix| {
        if (std.mem.eql(u8, last_two, suffix)) {
            const third_dot = std.mem.lastIndexOfScalar(u8, trimmed[0..second_dot], '.') orelse return trimmed;
            return trimmed[third_dot + 1 ..];
        }
    }
    return last_two;
}

pub fn hostMatchesDomain(host: []const u8, domain: []const u8) bool {
    if (host.len < domain.len) return false;
    if (!std.mem.endsWith(u8, host, domain)) return false;
    return host.len == domain.len or host[host.len - domain.len - 1] == '.';
}

fn patternMatches(rule: filter.NetworkRule, url: []const u8, host: HostRange) bool {
    const pattern = rule.pattern;
    if (pattern.len == 0) return true; // pure-option match-all rule

    if (rule.start_anchored) {
        return matchHere(url, 0, pattern, rule.end_anchored);
    }
    if (rule.domain_anchored) {
        // Must start at the host or at a subdomain boundary within it.
        var pos = host.start;
        while (pos < host.end) {
            if (matchHere(url, pos, pattern, rule.end_anchored)) return true;
            const dot = std.mem.indexOfScalarPos(u8, url[0..host.end], pos, '.') orelse return false;
            pos = dot + 1;
        }
        return false;
    }

    var pos: usize = 0;
    while (pos <= url.len) : (pos += 1) {
        if (matchHere(url, pos, pattern, rule.end_anchored)) return true;
    }
    return false;
}

fn matchHere(url: []const u8, start: usize, pattern: []const u8, end_anchored: bool) bool {
    var segments = std.mem.splitScalar(u8, pattern, '*');
    var pos = start;
    var is_first = true;

    while (segments.next()) |segment| {
        const is_last = segments.peek() == null;

        if (segment.len == 0) {
            // Adjacent/leading '*': nothing to match; a trailing '*' also
            // absorbs any end anchor (the parser trims that case anyway).
            if (is_last and !is_first) return true;
            is_first = false;
            continue;
        }

        if (is_first) {
            pos = matchSegmentAt(url, pos, segment) orelse return false;
            is_first = false;
        } else if (is_last and end_anchored) {
            var search = pos;
            var matched = false;
            while (search <= url.len) : (search += 1) {
                if (matchSegmentAt(url, search, segment)) |segment_end| {
                    if (segment_end == url.len) {
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched) return false;
            pos = url.len;
        } else {
            var search = pos;
            var matched = false;
            while (search <= url.len) : (search += 1) {
                if (matchSegmentAt(url, search, segment)) |segment_end| {
                    pos = segment_end;
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
    }

    return !end_anchored or pos == url.len;
}

/// Matches one wildcard-free pattern segment at `start`; returns the URL
/// position after the match. `^` matches a separator character or,
/// zero-width, the end of the URL (ABP semantics).
fn matchSegmentAt(url: []const u8, start: usize, segment: []const u8) ?usize {
    var pos = start;
    for (segment) |pattern_char| {
        if (pattern_char == '^') {
            if (pos == url.len) continue;
            if (!isSeparator(url[pos])) return null;
            pos += 1;
            continue;
        }
        if (pos >= url.len or url[pos] != pattern_char) return null;
        pos += 1;
    }
    return pos;
}

fn isTokenChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char);
}

fn isSeparator(char: u8) bool {
    return !std.ascii.isAlphanumeric(char) and switch (char) {
        '_', '-', '.', '%' => false,
        else => true,
    };
}

fn isIpv4(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |char| {
        if (!std.ascii.isDigit(char) and char != '.') return false;
    }
    return true;
}

fn lowercaseDupe(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, text);
    for (copy) |*char| char.* = std.ascii.toLower(char.*);
    return copy;
}

// --- tests ---------------------------------------------------------------

const abp_parser = @import("abp_parser.zig");

const TestSetup = struct {
    parsed: abp_parser.ParsedList,
    matcher: Matcher,

    fn init(list_text: []const u8) !TestSetup {
        var parsed = try abp_parser.parseList(std.testing.allocator, list_text);
        errdefer parsed.deinit();
        const matcher = try Matcher.init(std.testing.allocator, parsed.network);
        return .{ .parsed = parsed, .matcher = matcher };
    }

    fn deinit(self: *TestSetup) void {
        self.matcher.deinit();
        self.parsed.deinit();
    }
};

test "host range extraction" {
    const cases = .{
        .{ "https://example.com/path", "example.com" },
        .{ "https://example.com", "example.com" },
        .{ "https://user@example.com:8080/x?q=1", "example.com" },
        .{ "http://127.0.0.1:8000/", "127.0.0.1" },
        .{ "example.com/no-scheme", "example.com" },
    };
    inline for (cases) |case| {
        const range = hostRange(case[0]);
        try std.testing.expectEqualStrings(case[1], case[0][range.start..range.end]);
    }
}

test "registrable domain heuristic" {
    try std.testing.expectEqualStrings("example.com", registrableDomain("www.example.com"));
    try std.testing.expectEqualStrings("example.com", registrableDomain("example.com"));
    try std.testing.expectEqualStrings("shop.co.uk", registrableDomain("sub.shop.co.uk"));
    try std.testing.expectEqualStrings("localhost", registrableDomain("localhost"));
    try std.testing.expectEqualStrings("192.168.0.1", registrableDomain("192.168.0.1"));
}

test "domain-anchored rule matches host and subdomains only" {
    var setup = try TestSetup.init("||ads.example.com^");
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://ads.example.com/banner.js" }));
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://eu.ads.example.com/x" }));
    // Token-boundary: a different host that merely contains the text.
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://badads.example.com.evil.net/x" }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://loadsads.example.com.example.org/x" }));
    // The pattern appearing in the path must not trip a domain anchor.
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://safe.example.org/ads.example.com/page" }));
}

test "separator matches end of URL" {
    var setup = try TestSetup.init("||example.com^");
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://example.com" }));
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://example.com/" }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://example.community.net/" }));
}

test "plain substring rule with unreliable token edges still matches" {
    var setup = try TestSetup.init("ads");
    defer setup.deinit();

    // "ads" is a partial token in "loads.js" — only a tokenless bucket
    // catches this.
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://cdn.example.com/loads.js" }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://cdn.example.com/app.js" }));
}

test "wildcards and anchors" {
    var setup = try TestSetup.init(
        \\banner/*/ad
        \\|https://exact.example.com/file.js|
    );
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://x.example.net/banner/top/ad.png" }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://x.example.net/banner/ad" }));
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://exact.example.com/file.js" }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://exact.example.com/file.js?v=2" }));
}

test "party options use registrable domains" {
    var setup = try TestSetup.init("||tracker.example.com^$third-party");
    defer setup.deinit();

    // Cross-site: third-party, blocked.
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{
        .url = "https://tracker.example.com/pixel.gif",
        .document_host = "news.example.org",
    }));
    // Same registrable domain: first-party, allowed.
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://tracker.example.com/pixel.gif",
        .document_host = "www.example.com",
    }));
    // Main-frame (no document host) is first-party to itself.
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://tracker.example.com/page" }));
}

test "resource type includes and excludes" {
    var setup = try TestSetup.init(
        \\||media.example.com^$script
        \\||assets.example.com^$~image
    );
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{
        .url = "https://media.example.com/app.js",
        .resource_type = .{ .script = true },
    }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://media.example.com/logo.png",
        .resource_type = .{ .image = true },
    }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://assets.example.com/logo.png",
        .resource_type = .{ .image = true },
    }));
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{
        .url = "https://assets.example.com/app.js",
        .resource_type = .{ .script = true },
    }));
}

test "document domain options scope rules" {
    var setup = try TestSetup.init("||widget.example.com^$domain=news.example|~beta.news.example");
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{
        .url = "https://widget.example.com/w.js",
        .document_host = "news.example",
    }));
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{
        .url = "https://widget.example.com/w.js",
        .document_host = "sport.news.example",
    }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://widget.example.com/w.js",
        .document_host = "beta.news.example",
    }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://widget.example.com/w.js",
        .document_host = "other.example",
    }));
}

test "exceptions trump block rules" {
    var setup = try TestSetup.init(
        \\||cdn.example.com^
        \\@@||cdn.example.com^$script
    );
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://cdn.example.com/lib.js",
        .resource_type = .{ .script = true },
    }));
    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{
        .url = "https://cdn.example.com/ad.png",
        .resource_type = .{ .image = true },
    }));
}

test "match-case rules compare against the original URL" {
    var setup = try TestSetup.init(
        \\AdServer/$match-case
    );
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{ .url = "https://x.example.com/AdServer/x" }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{ .url = "https://x.example.com/adserver/x" }));
}

test "pure-option rule matches its type everywhere in scope" {
    var setup = try TestSetup.init("$ping,domain=tracked.example");
    defer setup.deinit();

    try std.testing.expectEqual(Verdict.block, setup.matcher.verdict(.{
        .url = "https://anywhere.example.net/beacon",
        .document_host = "tracked.example",
        .resource_type = .{ .ping = true },
    }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://anywhere.example.net/beacon",
        .document_host = "other.example",
        .resource_type = .{ .ping = true },
    }));
    try std.testing.expectEqual(Verdict.allow, setup.matcher.verdict(.{
        .url = "https://anywhere.example.net/app.js",
        .document_host = "tracked.example",
        .resource_type = .{ .script = true },
    }));
}
