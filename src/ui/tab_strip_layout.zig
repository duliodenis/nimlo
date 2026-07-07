//! Platform-neutral tab strip geometry: slot widths, hit-test indices, and
//! drop-indicator positions. All inputs are scalars so any platform chrome
//! can feed its own pixel measurements. No AppKit/ObjC dependencies.

const std = @import("std");

pub const tab_width: f64 = 220;
pub const min_tab_width: f64 = 76;
pub const tab_margin: f64 = 12;
pub const tab_strip_height: f64 = 36;
pub const titlebar_new_tab_button_size: f64 = 28;
pub const titlebar_new_tab_button_gap: f64 = 4;
pub const tab_drop_indicator_width: f64 = 3;
pub const tab_drop_indicator_height: f64 = 24;

// Usable tab area inside the strip container, after reserving space for the
// new-tab button and trailing margin.
pub fn tabAreaWidth(container_width: f64) f64 {
    const reserved = titlebar_new_tab_button_size + titlebar_new_tab_button_gap + tab_margin;
    return @max(min_tab_width, container_width - reserved);
}

pub fn tabWidthForCount(tab_count: usize, tab_area_width: f64) f64 {
    if (tab_count == 0) return tab_width;

    const count: f64 = @floatFromInt(tab_count);
    const total_gaps = if (tab_count > 1) titlebar_new_tab_button_gap * @as(f64, @floatFromInt(tab_count - 1)) else 0;
    const available = @max(min_tab_width, tab_area_width - total_gaps);
    return std.math.clamp(available / count, min_tab_width, tab_width);
}

// Index of the tab slot under x, clamped to the last tab. Used for reorder
// targeting while dragging within the strip.
pub fn tabIndexAtX(x: f64, tab_count: usize, tab_area_width: f64) ?usize {
    if (tab_count == 0) return null;

    const slot_width = tabWidthForCount(tab_count, tab_area_width);
    const stride = slot_width + titlebar_new_tab_button_gap;
    const clamped_x = @max(@as(f64, 0), x);
    var index: usize = @intFromFloat(@floor(clamped_x / stride));
    if (index >= tab_count) index = tab_count - 1;
    return index;
}

// Insertion slot for a cross-window drop at x; may equal tab_count (append).
pub fn insertionIndexAtX(x: f64, tab_count: usize, tab_area_width: f64) usize {
    if (tab_count == 0) return 0;

    const slot_width = tabWidthForCount(tab_count, tab_area_width);
    const stride = slot_width + titlebar_new_tab_button_gap;
    const clamped_x = @max(@as(f64, 0), x);
    const raw_index: usize = @intFromFloat(@floor(clamped_x / stride));
    return @min(raw_index, tab_count);
}

// X position of the insertion indicator for the given slot, centered in the
// gap between tabs and clamped to the tab area.
pub fn dropIndicatorX(insertion_index: usize, tab_count: usize, tab_area_width: f64) f64 {
    if (tab_count == 0) return 0;

    const slot_width = tabWidthForCount(tab_count, tab_area_width);
    const stride = slot_width + titlebar_new_tab_button_gap;
    const raw_x = if (insertion_index == 0)
        @as(f64, 0)
    else
        (@as(f64, @floatFromInt(insertion_index)) * stride) - (titlebar_new_tab_button_gap / 2) - (tab_drop_indicator_width / 2);

    return std.math.clamp(raw_x, 0, @max(@as(f64, 0), tab_area_width - tab_drop_indicator_width));
}

test "tab area width reserves button space and clamps" {
    try std.testing.expectEqual(@as(f64, 862), tabAreaWidth(906));
    try std.testing.expectEqual(min_tab_width, tabAreaWidth(10));
}

test "tab width caps at max and floors at min" {
    try std.testing.expectEqual(tab_width, tabWidthForCount(0, 500));
    try std.testing.expectEqual(tab_width, tabWidthForCount(1, 862));
    // 10 tabs in 400pt: (400 - 9*4)/10 = 36.4 -> clamped to min
    try std.testing.expectEqual(min_tab_width, tabWidthForCount(10, 400));
    // 4 tabs in 862pt: (862 - 12)/4 = 212.5, between min and max
    try std.testing.expectEqual(@as(f64, 212.5), tabWidthForCount(4, 862));
}

test "tab index clamps to bounds" {
    try std.testing.expectEqual(@as(?usize, null), tabIndexAtX(50, 0, 862));
    try std.testing.expectEqual(@as(?usize, 0), tabIndexAtX(-20, 3, 862));
    try std.testing.expectEqual(@as(?usize, 0), tabIndexAtX(10, 3, 862));
    try std.testing.expectEqual(@as(?usize, 2), tabIndexAtX(10_000, 3, 862));
}

test "insertion index can append past the last tab" {
    try std.testing.expectEqual(@as(usize, 0), insertionIndexAtX(50, 0, 862));
    try std.testing.expectEqual(@as(usize, 0), insertionIndexAtX(10, 2, 862));
    try std.testing.expectEqual(@as(usize, 2), insertionIndexAtX(10_000, 2, 862));
}

test "drop indicator stays inside the tab area" {
    try std.testing.expectEqual(@as(f64, 0), dropIndicatorX(0, 2, 862));
    const mid = dropIndicatorX(1, 2, 862);
    try std.testing.expect(mid > 0 and mid < 862 - tab_drop_indicator_width);
    const end = dropIndicatorX(2, 2, 862);
    try std.testing.expect(end <= 862 - tab_drop_indicator_width);
}
