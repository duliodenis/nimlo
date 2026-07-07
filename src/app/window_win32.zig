//! Win32 window shell for Nimlo, mirroring window_macos.zig: raw C-ABI
//! declarations in-file, no SDK wrapper layer. All declarations use the C
//! calling convention, which equals stdcall on the 64-bit targets Nimlo
//! supports (x86_64, aarch64); 32-bit x86 Windows is unsupported.

const std = @import("std");
const window = @import("window.zig");
const webview_events = @import("../webview/webview_events.zig");

const Handle = ?*anyopaque;

const POINT = extern struct {
    x: i32,
    y: i32,
};

const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const MSG = extern struct {
    hwnd: Handle,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: POINT,
};

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (Handle, u32, usize, isize) callconv(.c) isize,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: Handle,
    hIcon: Handle,
    hCursor: Handle,
    hbrBackground: Handle,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: Handle,
};

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF_0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x8000_0000));
const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;
const SW_SHOW: i32 = 5;
const WM_SIZE: u32 = 0x0005;
const WM_ACTIVATE: u32 = 0x0006;
const WM_CLOSE: u32 = 0x0010;
const WM_DESTROY: u32 = 0x0002;
const WM_NCDESTROY: u32 = 0x0082;
const WA_INACTIVE: usize = 0;
const GWLP_USERDATA: i32 = -21;
const SM_CXSCREEN: i32 = 0;
const SM_CYSCREEN: i32 = 1;
const IDC_ARROW: usize = 32512;
const COLOR_WINDOW: usize = 5;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.c) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, Handle, Handle, Handle, ?*anyopaque) callconv(.c) Handle;
extern "user32" fn DefWindowProcW(Handle, u32, usize, isize) callconv(.c) isize;
extern "user32" fn ShowWindow(Handle, i32) callconv(.c) i32;
extern "user32" fn SetForegroundWindow(Handle) callconv(.c) i32;
extern "user32" fn GetMessageW(*MSG, Handle, u32, u32) callconv(.c) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.c) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.c) isize;
extern "user32" fn PostQuitMessage(i32) callconv(.c) void;
extern "user32" fn PostMessageW(Handle, u32, usize, isize) callconv(.c) i32;
extern "user32" fn GetClientRect(Handle, *RECT) callconv(.c) i32;
extern "user32" fn SetWindowLongPtrW(Handle, i32, isize) callconv(.c) isize;
extern "user32" fn GetWindowLongPtrW(Handle, i32) callconv(.c) isize;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, i32, u32) callconv(.c) i32;
extern "user32" fn GetSystemMetrics(i32) callconv(.c) i32;
extern "user32" fn LoadCursorW(Handle, ?[*:0]const u16) callconv(.c) Handle;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.c) i32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.c) Handle;

const window_class_name = std.unicode.utf8ToUtf16LeStringLiteral("NimloWindow");

var window_class_registered = false;
var open_window_count: usize = 0;

// Per-window state reachable from the wndproc via GWLP_USERDATA. The webview
// registers its resize hook here so WM_SIZE can forward the new client size.
const WindowState = struct {
    resize_context: ?*anyopaque = null,
    on_resize: ?*const fn (context: *anyopaque, width: i32, height: i32) void = null,
};

pub const Win32Window = struct {
    title: [:0]const u8,
    width: u32,
    height: u32,
    top_left: ?window.ScreenPoint,
    handle: Handle,

    pub fn create(options: window.WindowOptions) !Win32Window {
        ensureWindowClass();

        const title = try std.heap.page_allocator.dupeZ(u8, options.title);
        const title_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, options.title);
        defer std.heap.page_allocator.free(title_utf16);

        const outer = outerSizeForClientSize(options.width, options.height);
        const position = windowPosition(options.top_left, outer.width, outer.height);

        const handle = CreateWindowExW(
            0,
            window_class_name,
            title_utf16,
            WS_OVERLAPPEDWINDOW,
            position.x,
            position.y,
            outer.width,
            outer.height,
            null,
            null,
            GetModuleHandleW(null),
            null,
        );
        if (handle == null) return error.Win32WindowUnavailable;

        const state = try std.heap.page_allocator.create(WindowState);
        state.* = .{};
        _ = SetWindowLongPtrW(handle, GWLP_USERDATA, @bitCast(@intFromPtr(state)));
        open_window_count += 1;

        return .{
            .title = title,
            .width = options.width,
            .height = options.height,
            .top_left = options.top_left,
            .handle = handle,
        };
    }

    pub fn show(self: *Win32Window) !void {
        try self.present();
        try self.runEventLoop();
    }

    pub fn present(self: *Win32Window) !void {
        try self.focus();

        std.debug.print("win32 window ready: {s} ({d}x{d})\n", .{
            self.title,
            self.width,
            self.height,
        });
    }

    pub fn focus(self: *Win32Window) !void {
        _ = ShowWindow(self.handle, SW_SHOW);
        _ = SetForegroundWindow(self.handle);
    }

    pub fn close(self: *Win32Window) void {
        // Post rather than destroy directly: callers may be inside message
        // dispatch, the same hazard as the macOS mid-dispatch close bug.
        _ = PostMessageW(self.handle, WM_CLOSE, 0, 0);
    }

    pub fn runEventLoop(self: *Win32Window) !void {
        _ = self;

        // No chrome yet, so the 0.1 "load a typed URL" checkbox is exercised
        // through the same env-hook pattern as the macOS self-tests.
        if (readEnvAlloc("NIMLO_START_URL")) |url| {
            defer std.heap.page_allocator.free(url);
            webview_events.emitUrlOpenRequested(url);
        }

        var message: MSG = undefined;
        while (GetMessageW(&message, null, 0, 0) > 0) {
            _ = TranslateMessage(&message);
            _ = DispatchMessageW(&message);
        }
    }

    pub fn nativeHandle(self: *Win32Window) ?*anyopaque {
        return self.handle;
    }
};

/// Registers the webview's resize hook for a window created by this module.
pub fn setResizeCallback(
    window_handle: ?*anyopaque,
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, width: i32, height: i32) void,
) void {
    const state = stateForWindow(window_handle) orelse return;
    state.resize_context = context;
    state.on_resize = callback;
}

pub fn clientSize(window_handle: ?*anyopaque) ?struct { width: i32, height: i32 } {
    var rect: RECT = undefined;
    if (GetClientRect(window_handle, &rect) == 0) return null;
    return .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top };
}

fn ensureWindowClass() void {
    if (window_class_registered) return;

    // Per-monitor-v2 keeps WebView2 rendering crisp on mixed-DPI setups;
    // best effort, the export exists on the Windows 10 1703+ baseline.
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const class = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW)),
        .hbrBackground = @ptrFromInt(COLOR_WINDOW + 1),
        .lpszMenuName = null,
        .lpszClassName = window_class_name,
        .hIconSm = null,
    };
    _ = RegisterClassExW(&class);
    window_class_registered = true;
}

fn wndProc(hwnd: Handle, message: u32, wparam: usize, lparam: isize) callconv(.c) isize {
    switch (message) {
        WM_SIZE => {
            if (stateForWindow(hwnd)) |state| {
                if (state.on_resize) |callback| {
                    const packed_size: usize = @bitCast(lparam);
                    const width: i32 = @intCast(packed_size & 0xFFFF);
                    const height: i32 = @intCast((packed_size >> 16) & 0xFFFF);
                    callback(state.resize_context.?, width, height);
                }
            }
        },
        WM_ACTIVATE => {
            // Focus changes must re-activate the per-window sinks or menu and
            // accelerator commands act on the wrong window's browser (hard-won
            // macOS lesson, same contract here).
            if ((wparam & 0xFFFF) != WA_INACTIVE) {
                webview_events.activateSinkForOwner(hwnd);
                webview_events.activateChromeSinkForOwner(hwnd);
            }
        },
        WM_DESTROY => {
            webview_events.emitWindowClosed(hwnd);
            open_window_count -= 1;
            if (open_window_count == 0) PostQuitMessage(0);
        },
        WM_NCDESTROY => {
            if (stateForWindow(hwnd)) |state| {
                _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                std.heap.page_allocator.destroy(state);
            }
        },
        else => {},
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

fn stateForWindow(window_handle: Handle) ?*WindowState {
    const raw = GetWindowLongPtrW(window_handle, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn outerSizeForClientSize(client_width: u32, client_height: u32) struct { width: i32, height: i32 } {
    var rect = RECT{
        .left = 0,
        .top = 0,
        .right = @intCast(client_width),
        .bottom = @intCast(client_height),
    };
    if (AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, 0, 0) == 0) {
        return .{ .width = @intCast(client_width), .height = @intCast(client_height) };
    }
    return .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top };
}

fn windowPosition(top_left: ?window.ScreenPoint, outer_width: i32, outer_height: i32) struct { x: i32, y: i32 } {
    if (top_left) |point| {
        return .{
            .x = @intFromFloat(@round(point.x)),
            .y = @intFromFloat(@round(point.y)),
        };
    }

    const screen_width = GetSystemMetrics(SM_CXSCREEN);
    const screen_height = GetSystemMetrics(SM_CYSCREEN);
    if (screen_width <= 0 or screen_height <= 0) {
        return .{ .x = CW_USEDEFAULT, .y = CW_USEDEFAULT };
    }
    return .{
        .x = @max(0, @divTrunc(screen_width - outer_width, 2)),
        .y = @max(0, @divTrunc(screen_height - outer_height, 2)),
    };
}

fn readEnvAlloc(key: []const u8) ?[]u8 {
    const environ: std.process.Environ = .{ .block = .global };
    return environ.getAlloc(std.heap.page_allocator, key) catch null;
}
