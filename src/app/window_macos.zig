const std = @import("std");
const window = @import("window.zig");
const chrome = @import("../ui/chrome_macos.zig");
const webview_events = @import("../webview/webview_events.zig");

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
const NSTerminateCancel: isize = 0;
const NSTerminateNow: isize = 1;
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
const min_visible_window_top_margin: CGFloat = 96;

extern "c" fn objc_msgSend() void;

var window_close_approved_for_termination = false;

pub const MacOSWindow = struct {
    title: [:0]const u8,
    width: u32,
    height: u32,
    top_left: ?window.ScreenPoint,
    app: Id,
    handle: Id,

    pub fn create(options: window.WindowOptions) !MacOSWindow {
        const title = try std.heap.page_allocator.dupeZ(u8, options.title);
        const app = try sharedApplication();
        const handle = try createNativeWindow(app, title, options.width, options.height);

        return .{
            .title = title,
            .width = options.width,
            .height = options.height,
            .top_left = options.top_left,
            .app = app,
            .handle = handle,
        };
    }

    pub fn show(self: *MacOSWindow) !void {
        try self.present();
        try self.runEventLoop();
    }

    pub fn present(self: *MacOSWindow) !void {
        if (self.top_left) |point| {
            const requested = CGPoint{
                .x = point.x,
                .y = point.y,
            };
            msg1(void, self.handle, sel("setFrameTopLeftPoint:"), clampedTopLeftPoint(self.handle, requested));
        } else {
            msg0(void, self.handle, sel("center"));
        }
        try self.focus();

        std.debug.print("macOS window ready: {s} ({d}x{d})\n", .{
            self.title,
            self.width,
            self.height,
        });
    }

    pub fn focus(self: *MacOSWindow) !void {
        msg1(void, self.handle, sel("makeKeyAndOrderFront:"), @as(Id, null));
        msg1(void, self.app, sel("activateIgnoringOtherApps:"), true);
    }

    pub fn close(self: *MacOSWindow) void {
        // Order the window off screen immediately, then close on the next
        // default-mode run-loop pass. A bare close can strand the window on
        // screen as an invisible click-eating ghost (macOS 26 close fade),
        // and callers may be inside menu dispatch or a mouse-tracking loop.
        msg1(void, self.handle, sel("orderOut:"), @as(Id, null));
        msg3(
            void,
            self.handle,
            sel("performSelector:withObject:afterDelay:"),
            sel("close"),
            @as(Id, null),
            @as(f64, 0),
        );
    }

    pub fn runEventLoop(self: *MacOSWindow) !void {
        // Read the NSApp handle before the self-test: the replayed drag can
        // close windows and free the session that owns this struct, so no
        // field access is safe after the call.
        const app = self.app;
        // The URL hook runs first so the tear-off self-test can drag a tab
        // that is showing an arbitrary page (e.g. an internal one).
        if (std.c.getenv("NIMLO_DOWNLOAD_TEST")) |url| {
            webview_events.emitUrlOpenRequested(std.mem.span(url));
        }
        if (std.c.getenv("NIMLO_TEAR_OFF_TEST") != null) chrome.runTearOffSelfTest();
        if (std.c.getenv("NIMLO_CLOSE_SOURCE_TEST")) |variant| chrome.scheduleCloseSourceSelfTest(std.mem.span(variant));
        if (std.c.getenv("NIMLO_BLOCKING_TEST") != null) chrome.scheduleBlockingSelfTest();
        msg0(void, app, sel("run"));
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
    installApplicationIcon(app);

    const delegate = msg0(Id, msg0(Id, cls("NimloAppDelegate"), sel("alloc")), sel("init"));
    msg1(void, app, sel("setDelegate:"), delegate);

    return app;
}

fn createNativeWindow(app: Id, title: [:0]const u8, width: u32, height: u32) !Id {
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
    msg1(void, handle, sel("setDelegate:"), msg0(Id, app, sel("delegate")));
    // No window open/close animations: the macOS 26 close fade can strand a
    // closed window on screen at alpha 0, invisibly swallowing all clicks.
    msg1(void, handle, sel("setAnimationBehavior:"), @as(isize, 2));
    return handle;
}

fn clampedTopLeftPoint(window_handle: Id, requested: CGPoint) CGPoint {
    const screen_frame = screenVisibleFrameContainingPoint(requested) orelse return requested;
    const window_frame = msg0(CGRect, window_handle, sel("frame"));

    const min_x = screen_frame.origin.x;
    const max_x = @max(min_x, screen_frame.origin.x + screen_frame.size.width - window_frame.size.width);
    const min_y = screen_frame.origin.y + @min(min_visible_window_top_margin, screen_frame.size.height);
    const max_y = screen_frame.origin.y + screen_frame.size.height;

    return .{
        .x = clampFloat(requested.x, min_x, max_x),
        .y = clampFloat(requested.y, min_y, max_y),
    };
}

fn screenVisibleFrameContainingPoint(point: CGPoint) ?CGRect {
    const screens = msg0(Id, cls("NSScreen"), sel("screens"));
    if (screens != null) {
        const count = msg0(usize, screens, sel("count"));
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const screen = msg1(Id, screens, sel("objectAtIndex:"), index);
            if (screen == null) continue;
            const frame = msg0(CGRect, screen, sel("frame"));
            if (pointInRect(point, frame)) return msg0(CGRect, screen, sel("visibleFrame"));
        }
    }

    const main_screen = msg0(Id, cls("NSScreen"), sel("mainScreen"));
    if (main_screen == null) return null;
    return msg0(CGRect, main_screen, sel("visibleFrame"));
}

fn pointInRect(point: CGPoint, rect: CGRect) bool {
    return point.x >= rect.origin.x and
        point.y >= rect.origin.y and
        point.x <= rect.origin.x + rect.size.width and
        point.y <= rect.origin.y + rect.size.height;
}

fn clampFloat(value: CGFloat, min_value: CGFloat, max_value: CGFloat) CGFloat {
    return @min(@max(value, min_value), max_value);
}

fn installApplicationIcon(app: Id) void {
    const bundle = msg0(Id, cls("NSBundle"), sel("mainBundle"));
    if (bundle == null) return;

    const path = msg2(Id, bundle, sel("pathForResource:ofType:"), nsString("Nimlo"), nsString("icns"));
    if (path == null) return;

    const image = msg1(Id, msg0(Id, cls("NSImage"), sel("alloc")), sel("initWithContentsOfFile:"), path);
    if (image == null) return;

    msg1(void, app, sel("setApplicationIconImage:"), image);
}

fn installAppDelegateClass() void {
    if (c.objc_getClass("NimloAppDelegate") != null) return;

    const superclass = c.objc_getClass("NSObject");
    const delegate_class = c.objc_allocateClassPair(superclass, "NimloAppDelegate", 0);
    if (delegate_class == null) return;

    _ = c.class_addMethod(
        delegate_class,
        c.sel_registerName("applicationShouldTerminate:"),
        @ptrCast(&applicationShouldTerminate),
        "q@:@",
    );
    _ = c.class_addMethod(
        delegate_class,
        c.sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"),
        @ptrCast(&applicationShouldTerminateAfterLastWindowClosed),
        "c@:@",
    );
    _ = c.class_addMethod(
        delegate_class,
        c.sel_registerName("windowShouldClose:"),
        @ptrCast(&windowShouldClose),
        "c@:@",
    );

    c.objc_registerClassPair(delegate_class);
}

fn applicationShouldTerminateAfterLastWindowClosed(_: Id, _: Sel, _: Id) callconv(.c) u8 {
    return 1;
}

fn applicationShouldTerminate(_: Id, _: Sel, _: Id) callconv(.c) isize {
    if (window_close_approved_for_termination) {
        window_close_approved_for_termination = false;
        return NSTerminateNow;
    }

    return if (chrome.confirmQuitIfNeeded()) NSTerminateNow else NSTerminateCancel;
}

fn windowShouldClose(_: Id, _: Sel, sender: Id) callconv(.c) u8 {
    const should_close = chrome.confirmWindowCloseIfNeeded(sender);
    // Only a last-window close can cascade into app termination; a stale
    // approval from closing an earlier window must not skip the quit prompt.
    window_close_approved_for_termination = should_close and chrome.chromeWindowCount() <= 1;
    return if (should_close) 1 else 0;
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

fn msg2(comptime ReturnType: type, receiver: Id, selector: Sel, arg1: anytype, arg2: anytype) ReturnType {
    const Arg1 = @TypeOf(arg1);
    const Arg2 = @TypeOf(arg2);
    const Fn = *const fn (Id, Sel, Arg1, Arg2) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, arg1, arg2);
}

fn msg3(comptime ReturnType: type, receiver: Id, selector: Sel, arg1: anytype, arg2: anytype, arg3: anytype) ReturnType {
    const Arg1 = @TypeOf(arg1);
    const Arg2 = @TypeOf(arg2);
    const Arg3 = @TypeOf(arg3);
    const Fn = *const fn (Id, Sel, Arg1, Arg2, Arg3) callconv(.c) ReturnType;
    return @as(Fn, @ptrCast(&objc_msgSend))(receiver, selector, arg1, arg2, arg3);
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
