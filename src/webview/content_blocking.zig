//! Portable seam for content-blocking enforcement (docs/CONTENT_BLOCKING.md,
//! Phase F). The app layer converts filter lists to platform rule payloads
//! (WebKit content-blocker JSON via src/blocking/webkit_rules.zig) and hands
//! them over here; the platform side compiles/attaches them. Windows will
//! instead run the shared matcher per request (WINDOWS_PORT.md, Phase 8) —
//! the stub keeps every other platform building.

const builtin = @import("builtin");
const std = @import("std");

pub const RuleListSource = struct {
    /// Stable per-content identifier ("easylist-<hash>") so unchanged lists
    /// hit the platform compile cache.
    identifier: []const u8,
    /// WebKit content-blocker JSON.
    json: []const u8,
};

/// Built-in rules for NIMLO_BLOCKING_TEST: hides the self-test page's
/// marker element and blocks a reserved host, giving CI an observable
/// signal from an otherwise observation-free rule engine.
pub const selftest_identifier = "nimlo-selftest";
pub const selftest_hidden_element_id = "nimlo-selftest-ad";
pub const selftest_blocked_host = "selftest-blocked.nimlo.internal";
pub const selftest_rules_json =
    \\[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#nimlo-selftest-ad"}},
    \\ {"trigger":{"url-filter":"selftest-blocked\\.nimlo\\.internal"},"action":{"type":"block"}}]
;

const platform = switch (builtin.os.tag) {
    .macos => @import("content_blocking_macos.zig"),
    else => @import("content_blocking_stub.zig"),
};

/// Whether this platform consumes compiled rule payloads at all; lets the
/// app skip the parse/emit pipeline where enforcement works differently
/// (Windows matches at request time instead).
pub fn wantsRuleListPayloads() bool {
    return platform.wantsRuleListPayloads();
}

/// Replaces the platform's full rule-list set (initial install and every
/// per-site policy rebuild). Callers keep ownership of `sources`; the
/// platform copies what it needs before returning.
pub fn setRuleLists(compiled_store_path: []const u8, sources: []const RuleListSource) void {
    platform.setRuleLists(compiled_store_path, sources);
}

/// Rule lists still being looked up or compiled; 0 = steady state.
pub fn pendingListCount() usize {
    return platform.pendingListCount();
}

pub fn activeListCount() usize {
    return platform.activeListCount();
}

test "self-test rules are valid JSON with the expected shape" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, selftest_rules_json, .{});
    defer parsed.deinit();

    const rules = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), rules.items.len);
    const css_action = rules.items[0].object.get("action").?.object;
    try std.testing.expectEqualStrings("css-display-none", css_action.get("type").?.string);
    const selector = css_action.get("selector").?.string;
    try std.testing.expect(std.mem.indexOf(u8, selector, selftest_hidden_element_id) != null);
    const block_action = rules.items[1].object.get("action").?.object;
    try std.testing.expectEqualStrings("block", block_action.get("type").?.string);
}
