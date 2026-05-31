const std = @import("std");
const app = @import("app/app.zig");

pub fn main() !void {
    std.debug.print("Nimlo starting...\n", .{});
    std.debug.print("Nimlo MVP milestone 0.1\n", .{});

    try app.run();
}
