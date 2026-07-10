//! Page loaded by the NIMLO_BLOCKING_TEST self-test: the always-installed
//! self-test rule list (src/webview/content_blocking.zig) must hide the
//! marker element while leaving the control visible; the page reports the
//! verdict through its title, which flows out through the normal title
//! plumbing — the only observable signal macOS's rule engine offers.

const std = @import("std");
const content_blocking = @import("../webview/content_blocking.zig");

pub const url = "nimlo://blocking-selftest";
pub const title_pending = "PENDING";
pub const title_blocked_ok = "BLOCKED-OK";
pub const title_fail = "FAIL";

pub const html = std.fmt.comptimePrint(
    \\<!DOCTYPE html>
    \\<html><head><title>{[pending]s}</title></head><body>
    \\<div id="{[marker]s}">ad marker</div>
    \\<div id="nimlo-selftest-control">control</div>
    \\<script>
    \\function nimloCheck() {{
    \\  var marker = document.getElementById('{[marker]s}');
    \\  var control = document.getElementById('nimlo-selftest-control');
    \\  var markerHidden = getComputedStyle(marker).display === 'none';
    \\  var controlVisible = getComputedStyle(control).display !== 'none';
    \\  document.title = (markerHidden && controlVisible) ? '{[ok]s}' : '{[fail]s}';
    \\}}
    \\window.addEventListener('load', function () {{ setTimeout(nimloCheck, 100); }});
    \\</script>
    \\</body></html>
, .{
    .pending = title_pending,
    .marker = content_blocking.selftest_hidden_element_id,
    .ok = title_blocked_ok,
    .fail = title_fail,
});

test "self-test page embeds the marker the self-test rules hide" {
    try std.testing.expect(std.mem.indexOf(u8, html, content_blocking.selftest_hidden_element_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, title_blocked_ok) != null);
}
