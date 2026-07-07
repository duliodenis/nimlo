const builtin = @import("builtin");

pub const PlatformWindow = switch (builtin.os.tag) {
    .macos => @import("window_macos.zig").MacOSWindow,
    .windows => @import("window_win32.zig").Win32Window,
    else => @import("window_stub.zig").StubWindow,
};
