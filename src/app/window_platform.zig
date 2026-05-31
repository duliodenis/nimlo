const builtin = @import("builtin");

pub const PlatformWindow = switch (builtin.os.tag) {
    .macos => @import("window_macos.zig").MacOSWindow,
    else => @import("window_stub.zig").StubWindow,
};
