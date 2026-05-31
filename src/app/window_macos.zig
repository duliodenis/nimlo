const std = @import("std");
const window = @import("window.zig");

pub const MacOSWindow = struct {
    title: []const u8,
    width: u32,
    height: u32,
    handle: ?*anyopaque = null,

    pub fn create(options: window.WindowOptions) !MacOSWindow {
        return .{
            .title = options.title,
            .width = options.width,
            .height = options.height,
        };
    }

    pub fn show(self: *MacOSWindow) !void {
        std.debug.print("macOS window scaffold: {s} ({d}x{d})\n", .{
            self.title,
            self.width,
            self.height,
        });
        // TODO(app shell): create an NSApplication/NSWindow and keep its native handle.
    }

    pub fn nativeHandle(self: *MacOSWindow) ?*anyopaque {
        return self.handle;
    }
};
