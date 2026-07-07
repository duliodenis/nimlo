//! Canonical content-filter rule model, shared by the ABP parser, the
//! runtime matcher (Windows request path + test oracle), and the WebKit
//! content-blocker JSON emitter (macOS). Platform-neutral by design; see
//! docs/CONTENT_BLOCKING.md.

const std = @import("std");

/// Request resource classes a rule can include or exclude. An empty set on
/// a rule means "all types" (ABP semantics for option-less rules).
pub const ResourceTypes = packed struct(u16) {
    script: bool = false,
    image: bool = false,
    stylesheet: bool = false,
    subdocument: bool = false,
    xhr: bool = false,
    document: bool = false,
    font: bool = false,
    media: bool = false,
    websocket: bool = false,
    ping: bool = false,
    object: bool = false,
    popup: bool = false,
    other: bool = false,
    _padding: u3 = 0,

    pub fn isEmpty(self: ResourceTypes) bool {
        return @as(u16, @bitCast(self)) == 0;
    }

    pub fn contains(self: ResourceTypes, other: ResourceTypes) bool {
        const self_bits: u16 = @bitCast(self);
        const other_bits: u16 = @bitCast(other);
        return (self_bits & other_bits) != 0;
    }
};

pub const Party = enum {
    any,
    first,
    third,
};

/// A network block or exception rule, normalized: anchors stripped into
/// flags, pattern lowercased unless `match_case`, options decomposed.
pub const NetworkRule = struct {
    /// Pattern body without anchor characters; may contain `*` wildcards and
    /// `^` separators (interpreted by the matcher/emitter). Empty means
    /// match-all (pure-option rules).
    pattern: []const u8,
    is_exception: bool = false,
    /// `||…` — pattern starts at a (sub)domain boundary.
    domain_anchored: bool = false,
    /// Leading `|` — pattern anchored to the start of the URL.
    start_anchored: bool = false,
    /// Trailing `|` — pattern anchored to the end of the URL.
    end_anchored: bool = false,
    match_case: bool = false,
    party: Party = .any,
    /// Types the rule applies to; empty = all types.
    types: ResourceTypes = .{},
    /// Types explicitly excluded (`$~script`).
    types_excluded: ResourceTypes = .{},
    /// `$domain=` include list (lowercase hosts). Empty = any document host.
    domains: []const []const u8 = &.{},
    /// `$domain=` exclude list (`~` entries).
    domains_excluded: []const []const u8 = &.{},
};

/// An element-hiding rule (`##`/`#@#`). Parsed and counted from 0.8 on, but
/// only enforced when cosmetic filtering ships (Phase I).
pub const CosmeticRule = struct {
    selector: []const u8,
    is_exception: bool = false,
    domains: []const []const u8 = &.{},
    domains_excluded: []const []const u8 = &.{},
};

/// Accounting for a full list parse. "Dropped" rules are the honest ledger
/// the settings page surfaces — nothing is silently eaten.
pub const ParseStats = struct {
    lines: usize = 0,
    blank: usize = 0,
    comments: usize = 0,
    headers: usize = 0,
    network_rules: usize = 0,
    network_exceptions: usize = 0,
    cosmetic_rules: usize = 0,
    cosmetic_exceptions: usize = 0,
    /// Accepted rules that carried a soft-ignored option (`$important`).
    options_ignored: usize = 0,
    dropped_regex: usize = 0,
    /// Procedural cosmetics (`#?#`, `#$#`, `#%#`) and scriptlets (`##+js`).
    dropped_procedural: usize = 0,
    /// Rules with unsupported or cosmetic-control options (`$redirect=`,
    /// `$csp=`, `$generichide`, unknown options, …).
    dropped_options: usize = 0,
    dropped_malformed: usize = 0,

    pub fn accepted(self: ParseStats) usize {
        return self.network_rules + self.network_exceptions +
            self.cosmetic_rules + self.cosmetic_exceptions;
    }

    pub fn dropped(self: ParseStats) usize {
        return self.dropped_regex + self.dropped_procedural +
            self.dropped_options + self.dropped_malformed;
    }
};

test "ResourceTypes set logic" {
    const none = ResourceTypes{};
    const scripts = ResourceTypes{ .script = true };
    const media_kinds = ResourceTypes{ .image = true, .media = true, .font = true };

    try std.testing.expect(none.isEmpty());
    try std.testing.expect(!scripts.isEmpty());
    try std.testing.expect(!scripts.contains(media_kinds));
    try std.testing.expect(media_kinds.contains(.{ .image = true }));
    try std.testing.expect(media_kinds.contains(.{ .image = true, .script = true }));
}

test "ParseStats accounting" {
    const stats = ParseStats{
        .network_rules = 5,
        .network_exceptions = 1,
        .cosmetic_rules = 3,
        .dropped_regex = 1,
        .dropped_options = 2,
    };
    try std.testing.expectEqual(@as(usize, 9), stats.accepted());
    try std.testing.expectEqual(@as(usize, 3), stats.dropped());
}
