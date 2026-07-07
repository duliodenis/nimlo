//! Platform-neutral tab drag state and decisions: what a drag is doing,
//! when it becomes a tear-off, and where a torn-off window is placed.
//! Window/view handles are opaque pointers; all geometry is scalar, so any
//! platform chrome can drive this with its own event plumbing.

const std = @import("std");
const webview_events = @import("../webview/webview_events.zig");

pub const tab_tear_off_vertical_threshold: f64 = 18;

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const TabDragState = struct {
    // Active press/drag on a tab button.
    tab_id: ?u64 = null,
    last_index: ?usize = null,
    start_point: Point = .{},
    grab_in_button: Point = .{},
    has_moved: bool = false,
    source_window: ?*anyopaque = null,
    destination_window: ?*anyopaque = null,
    destination_index: ?usize = null,

    // Set while a torn-off window is following the cursor. The offset is the
    // vector from the cursor to the detached window's top-left, so the window
    // stays glued to the original grab point on every move.
    detached_window: ?*anyopaque = null,
    detached_offset: Point = .{},
    detached_close_on_release: ?*anyopaque = null,

    pub fn reset(self: *TabDragState) void {
        self.tab_id = null;
        self.last_index = null;
        self.start_point = .{};
        self.grab_in_button = .{};
        self.has_moved = false;
        self.source_window = null;
        self.destination_window = null;
        self.destination_index = null;
    }

    // Release outside every strip and drop target detaches the tab.
    pub fn shouldDetachOnRelease(self: *const TabDragState, released_in_source_strip: bool) bool {
        return self.has_moved and self.destination_window == null and !released_in_source_strip;
    }
};

pub fn isPastTearOffThreshold(cursor_y: f64, strip_y: f64, strip_height: f64) bool {
    return cursor_y < strip_y - tab_tear_off_vertical_threshold or
        cursor_y > strip_y + strip_height + tab_tear_off_vertical_threshold;
}

pub fn pointInRect(point: anytype, rect: anytype) bool {
    return point.x >= rect.origin.x and
        point.y >= rect.origin.y and
        point.x <= rect.origin.x + rect.size.width and
        point.y <= rect.origin.y + rect.size.height;
}

pub const PlacementInputs = struct {
    cursor: Point,
    source_frame_origin: Point,
    source_frame_height: f64,
    source_content_width: f64,
    source_content_height: f64,
    strip_origin: Point,
    strip_height: f64,
    grab_x: f64,
    single_tab_width: f64,
};

// Places the detached window so its single tab sits under the cursor at the
// same in-tab grab point the drag started with, and inherits the source
// window's content size. All coordinates are global screen points (y-up).
pub fn detachedPlacement(in: PlacementInputs) webview_events.DetachedWindowPlacement {
    const tab_area_left_inset = in.strip_origin.x - in.source_frame_origin.x;
    const top_inset = (in.source_frame_origin.y + in.source_frame_height) -
        (in.strip_origin.y + in.strip_height);
    const grab_dx = std.math.clamp(in.grab_x, @as(f64, 8), @max(@as(f64, 8), in.single_tab_width - 8));

    return .{
        .top_left = .{
            .x = in.cursor.x - tab_area_left_inset - grab_dx,
            .y = in.cursor.y + top_inset + in.strip_height / 2,
        },
        .width = in.source_content_width,
        .height = in.source_content_height,
    };
}

test "reset clears the press but keeps detached tracking" {
    var state = TabDragState{};
    state.tab_id = 4;
    state.has_moved = true;
    state.detached_window = @ptrFromInt(0x1000);
    state.reset();
    try std.testing.expectEqual(@as(?u64, null), state.tab_id);
    try std.testing.expect(!state.has_moved);
    try std.testing.expect(state.detached_window != null);
}

test "detach on release requires movement and no drop target" {
    var state = TabDragState{};
    try std.testing.expect(!state.shouldDetachOnRelease(false));
    state.has_moved = true;
    try std.testing.expect(state.shouldDetachOnRelease(false));
    try std.testing.expect(!state.shouldDetachOnRelease(true));
    state.destination_window = @ptrFromInt(0x1000);
    try std.testing.expect(!state.shouldDetachOnRelease(false));
}

test "tear-off threshold has a dead zone around the strip" {
    // Strip spans y 955..991 (the geometry from the verified self-test run).
    try std.testing.expect(!isPastTearOffThreshold(973, 955, 36));
    try std.testing.expect(!isPastTearOffThreshold(955 - 18, 955, 36));
    try std.testing.expect(!isPastTearOffThreshold(991 + 18, 955, 36));
    try std.testing.expect(isPastTearOffThreshold(955 - 18.5, 955, 36));
    try std.testing.expect(isPastTearOffThreshold(991 + 18.5, 955, 36));
}

test "detached placement reproduces the verified tear-off scenario" {
    // The self-test scenario proven on hardware: source frame (448,187)
    // 1024x800, strip at (526,955) h=36, grab 30pt into the tab,
    // cursor (572,893) -> expected top-left (464,907).
    const placement = detachedPlacement(.{
        .cursor = .{ .x = 572, .y = 893 },
        .source_frame_origin = .{ .x = 448, .y = 187 },
        .source_frame_height = 800,
        .source_content_width = 1024,
        .source_content_height = 768,
        .strip_origin = .{ .x = 526, .y = 955 },
        .strip_height = 36,
        .grab_x = 30,
        .single_tab_width = 220,
    });
    try std.testing.expectEqual(@as(f64, 464), placement.top_left.x);
    try std.testing.expectEqual(@as(f64, 907), placement.top_left.y);
    try std.testing.expectEqual(@as(f64, 1024), placement.width);
    try std.testing.expectEqual(@as(f64, 768), placement.height);
}

test "placement clamps the grab point into the single tab" {
    const base = PlacementInputs{
        .cursor = .{ .x = 500, .y = 500 },
        .source_frame_origin = .{ .x = 0, .y = 0 },
        .source_frame_height = 800,
        .source_content_width = 1024,
        .source_content_height = 768,
        .strip_origin = .{ .x = 80, .y = 764 },
        .strip_height = 36,
        .grab_x = 0,
        .single_tab_width = 220,
    };
    var far = base;
    far.grab_x = 600;
    const clamped_low = detachedPlacement(base);
    const clamped_high = detachedPlacement(far);
    // grab clamps to [8, 212]
    try std.testing.expectEqual(@as(f64, 500 - 80 - 8), clamped_low.top_left.x);
    try std.testing.expectEqual(@as(f64, 500 - 80 - 212), clamped_high.top_left.x);
}

test "point in rect boundaries are inclusive" {
    const rect = .{ .origin = .{ .x = 10.0, .y = 20.0 }, .size = .{ .width = 30.0, .height = 40.0 } };
    try std.testing.expect(pointInRect(.{ .x = 10.0, .y = 20.0 }, rect));
    try std.testing.expect(pointInRect(.{ .x = 40.0, .y = 60.0 }, rect));
    try std.testing.expect(!pointInRect(.{ .x = 9.9, .y = 30.0 }, rect));
    try std.testing.expect(!pointInRect(.{ .x = 40.1, .y = 30.0 }, rect));
}
