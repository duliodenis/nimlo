const std = @import("std");
const window = @import("window.zig");

pub const StubWindow = struct {
    title: []const u8,
    width: u32,
    height: u32,

    pub fn create(options: window.WindowOptions) !StubWindow {
        return .{
            .title = options.title,
            .width = options.width,
            .height = options.height,
        };
    }

    pub fn show(self: *StubWindow) !void {
        try self.present();
        try self.runEventLoop();
    }

    pub fn present(self: *StubWindow) !void {
        std.debug.print("window scaffold: {s} ({d}x{d})\n", .{
            self.title,
            self.width,
            self.height,
        });
        // TODO(app shell): add a platform window implementation for this OS.
    }

    pub fn focus(self: *StubWindow) !void {
        _ = self;
    }

    pub fn close(self: *StubWindow) void {
        _ = self;
    }

    pub fn runEventLoop(self: *StubWindow) !void {
        _ = self;
    }

    pub fn nativeHandle(self: *StubWindow) ?*anyopaque {
        _ = self;
        return null;
    }
};
