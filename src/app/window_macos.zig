const std = @import("std");
const window = @import("window.zig");

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Class = ?*anyopaque;

const CGFloat = f64;

const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

const NSApplicationActivationPolicyRegular: isize = 0;
const NSBackingStoreBuffered: usize = 2;
const NSWindowTitleHidden: isize = 1;
const NSWindowStyleMaskTitled: usize = 1 << 0;
const NSWindowStyleMaskClosable: usize = 1 << 1;
const NSWindowStyleMaskMiniaturizable: usize = 1 << 2;
const NSWindowStyleMaskResizable: usize = 1 << 3;
const NSWindowStyleMaskDefault = NSWindowStyleMaskTitled |
    NSWindowStyleMaskClosable |
    NSWindowStyleMaskMiniaturizable |
    NSWindowStyleMaskResizable;

extern "c" fn objc_msgSend() void;

pub const MacOSWindow = struct {
    title: [:0]const u8,
    width: u32,
    height: u32,
    app: Id,
    handle: Id,

    pub fn create(options: window.WindowOptions) !MacOSWindow {
        const title = try std.heap.page_allocator.dupeZ(u8, options.title);
        const app = try sharedApplication();
        const handle = try createNativeWindow(title, options.width, options.height);

        return .{
            .title = title,
            .width = options.width,
            .height = options.height,
            .app = app,
            .handle = handle,
        };
    }

    pub fn show(self: *MacOSWindow) !void {
        msg0(void, self.handle, sel("center"));
        msg1(void, self.handle, sel("makeKeyAndOrderFront:"), @as(Id, null));
        msg1(void, self.app, sel("activateIgnoringOtherApps:"), true);

        std.debug.print("macOS window ready: {s} ({d}x{d})\n", .{
            self.title,
            self.width,
            self.height,
        });

        msg0(void, self.app, sel("run"));
    }

    pub fn nativeHandle(self: *MacOSWindow) ?*anyopaque {
        return self.handle;
    }
};

fn sharedApplication() !Id {
    installAppDelegateClass();

    const app = msg0(Id, cls("NSApplication"), sel("sharedApplication"));
    if (app == null) return error.MacOSApplicationUnavailable;

    _ = msg1(u8, app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    msg0(void, app, sel("finishLaunching"));

    const delegate = msg0(Id, msg0(Id, cls("NimloAppDelegate"), sel("alloc")), sel("init"));
    msg1(void, app, sel("setDelegate:"), delegate);

    return app;
}

fn createNativeWindow(title: [:0]const u8, width: u32, height: u32) !Id {
    const frame = CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        },
    };

    const ns_window = msg0(Id, cls("NSWindow"), sel("alloc"));
    const handle = msg5(
        Id,
        ns_window,
        sel("initWithContentRect:styleMask:backing:defer:"),
        frame,
        NSWindowStyleMaskDefault,
        NSBackingStoreBuffered,
        false,
    );
    if (handle == null) return error.MacOSWindowUnavailable;

    msg1(void, handle, sel("setTitle:"), nsString(title));
    msg1(void, handle, sel("setTitleVisibility:"), NSWindowTitleHidden);
    return handle;
}

fn installAppDelegateClass() void {
    if (c.objc_getClass("NimloAppDelegate") != null) return;

    const superclass = c.objc_getClass("NSObject");
    const delegate_class = c.objc_allocateClassPair(superclass, "NimloAppDelegate", 0);
    if (delegate_class == null) return;

    _ = c.class_addMethod(
        delegate_class,
        c.sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"),
        @ptrCast(&applicationShouldTerminateAfterLastWindowClosed),
        "c@:@",
    );

    c.objc_registerClassPair(delegate_class);
}

fn applicationShouldTerminateAfterLastWindowClosed(_: Id, _: Sel, _: Id) callconv(.c) u8 {
    return 1;
}

fn cls(name: [:0]const u8) Class {
    return @ptrCast(c.objc_getClass(name));
}

fn sel(name: [:0]const u8) Sel {
    return @ptrCast(c.sel_registerName(name));
}

fn nsString(value: [:0]const u8) Id {
    return msg1(Id, cls("NSString"), sel("stringWithUTF8String:"), value.ptr);
}

fn msg0(comptime ReturnType: type, receiver: Id, selector: Sel) ReturnType {
    const Fn = *const fn (Id, Sel) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector);
}

fn msg1(comptime ReturnType: type, receiver: Id, selector: Sel, arg1: anytype) ReturnType {
    const Arg1 = @TypeOf(arg1);
    const Fn = *const fn (Id, Sel, Arg1) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, arg1);
}

fn msg5(
    comptime ReturnType: type,
    receiver: Id,
    selector: Sel,
    arg1: CGRect,
    arg2: usize,
    arg3: usize,
    arg4: bool,
) ReturnType {
    const Fn = *const fn (Id, Sel, CGRect, usize, usize, bool) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, arg1, arg2, arg3, arg4);
}
