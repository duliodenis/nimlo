const content_blocking = @import("content_blocking.zig");

pub fn installRuleLists(compiled_store_path: []const u8, sources: []const content_blocking.RuleListSource) void {
    _ = compiled_store_path;
    _ = sources;
    // TODO(windows, WINDOWS_PORT.md Phase 8): enforce via the shared matcher
    // in WebResourceRequested instead of compiled rule payloads.
}

pub fn wantsRuleListPayloads() bool {
    return false;
}

pub fn pendingListCount() usize {
    return 0;
}

pub fn activeListCount() usize {
    return 0;
}
