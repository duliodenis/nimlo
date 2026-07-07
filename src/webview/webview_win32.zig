//! WebView2-backed webview for Windows. Bootstraps through the vendored
//! WebView2Loader.dll (LoadLibrary + GetProcAddress, no import library) and
//! then talks to the runtime through the raw COM vtables in webview2.zig.
//!
//! WebView2 creation is asynchronous: the environment and controller arrive
//! via COM completion callbacks dispatched by the window's message pump, but
//! the browser core issues its first load before the pump starts (see
//! createWindowWithInitialTab in app.zig). Loads that arrive before the
//! controller exists are queued and flushed from the controller callback.

const std = @import("std");
const webview_events = @import("webview_events.zig");
const webview2 = @import("webview2.zig");
const window_win32 = @import("../app/window_win32.zig");

const COINIT_APARTMENTTHREADED: u32 = 0x2;

extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.c) webview2.HRESULT;
extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;

const loader_dll_name = std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll");

pub const Win32WebView = struct {
    window_handle: ?*anyopaque = null,
    environment: ?*webview2.ICoreWebView2Environment = null,
    controller: ?*webview2.ICoreWebView2Controller = null,
    core: ?*webview2.ICoreWebView2 = null,
    pending_load: ?PendingLoad = null,

    const PendingLoad = union(enum) {
        url: [:0]u16,
        html: [:0]u16,

        fn deinit(self: PendingLoad) void {
            switch (self) {
                .url, .html => |content| std.heap.page_allocator.free(content),
            }
        }
    };

    pub fn init() Win32WebView {
        return .{};
    }

    pub fn attachToWindow(self: *Win32WebView, window_handle: ?*anyopaque) !void {
        self.window_handle = window_handle;
        if (window_handle == null) return error.Win32WindowHandleUnavailable;

        // S_FALSE (already initialized) is fine; the thread must be STA for
        // WebView2's completion callbacks to arrive on the message pump.
        _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED);

        window_win32.setResizeCallback(window_handle, self, onWindowResized);

        const loader = LoadLibraryW(loader_dll_name) orelse return error.WebView2LoaderUnavailable;
        const create_environment_raw = GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions") orelse
            return error.WebView2LoaderEntryPointUnavailable;
        const create_environment: webview2.CreateCoreWebView2EnvironmentWithOptionsFn =
            @ptrCast(@alignCast(create_environment_raw));

        const user_data_folder = try userDataFolderUtf16();
        defer std.heap.page_allocator.free(user_data_folder);

        // TODO(privacy): match the macOS non-persistent data store by moving
        // to CreateCoreWebView2ControllerWithOptions + IsInPrivateModeEnabled
        // once Nimlo has explicit storage policy.
        const handler = try webview2.EnvironmentCompletedHandler.create(self, onEnvironmentCreated);
        const hr = create_environment(null, user_data_folder, null, handler);
        handler.releaseOwnership();
        if (!webview2.succeeded(hr)) {
            std.debug.print("WebView2 environment request failed: 0x{x:0>8}. Is the WebView2 runtime installed?\n", .{@as(u32, @bitCast(hr))});
            return error.WebView2EnvironmentUnavailable;
        }

        std.debug.print("win32 WebView2 environment requested.\n", .{});
    }

    pub fn load(self: *Win32WebView, url: []const u8) !void {
        const url_utf16 = try webview2.utf16ZFromUtf8(std.heap.page_allocator, url);

        if (self.core) |core| {
            defer std.heap.page_allocator.free(url_utf16);
            const hr = core.navigate(url_utf16);
            if (!webview2.succeeded(hr)) return error.WebView2NavigateFailed;
            std.debug.print("win32 WebView2 loading: {s}\n", .{url});
            return;
        }

        self.setPendingLoad(.{ .url = url_utf16 });
        std.debug.print("win32 WebView2 queued load: {s}\n", .{url});
    }

    pub fn loadHtml(self: *Win32WebView, html: []const u8, base_url: []const u8) !void {
        const html_utf16 = try webview2.utf16ZFromUtf8(std.heap.page_allocator, html);

        if (self.core) |core| {
            defer std.heap.page_allocator.free(html_utf16);
            const hr = core.navigateToString(html_utf16);
            if (!webview2.succeeded(hr)) return error.WebView2NavigateFailed;
            std.debug.print("win32 WebView2 loading internal page: {s}\n", .{base_url});
            return;
        }

        self.setPendingLoad(.{ .html = html_utf16 });
        std.debug.print("win32 WebView2 queued internal page: {s}\n", .{base_url});
    }

    pub fn createWebView(self: *Win32WebView) !?*anyopaque {
        _ = self;
        // TODO(0.3 tabs): per-tab WebView2 controllers, mirroring the
        // one-WKWebView-per-tab model on macOS.
        return error.Win32MultiWebViewUnsupported;
    }

    pub fn showWebView(self: *Win32WebView, handle: ?*anyopaque) void {
        _ = self;
        _ = handle;
    }

    pub fn destroyWebView(self: *Win32WebView, handle: ?*anyopaque) void {
        _ = self;
        _ = handle;
    }

    pub fn activeHandle(self: *Win32WebView) ?*anyopaque {
        return @ptrCast(self.core);
    }

    pub fn setEventSink(self: *Win32WebView, sink: webview_events.EventSink) void {
        webview_events.setSinkForOwner(self.window_handle, sink);
    }

    pub fn clearEventSink(self: *Win32WebView) void {
        webview_events.clearSinkForOwner(self.window_handle);
    }

    pub fn clearChromeSink(self: *Win32WebView) void {
        if (self.window_handle) |owner| {
            webview_events.clearChromeSinkForOwner(owner);
        } else {
            webview_events.clearChromeSink();
        }
    }

    fn setPendingLoad(self: *Win32WebView, pending: PendingLoad) void {
        if (self.pending_load) |previous| previous.deinit();
        self.pending_load = pending;
    }

    fn flushPendingLoad(self: *Win32WebView) void {
        const pending = self.pending_load orelse return;
        self.pending_load = null;
        defer pending.deinit();

        const core = self.core orelse return;
        const hr = switch (pending) {
            .url => |url| core.navigate(url),
            .html => |html| core.navigateToString(html),
        };
        if (!webview2.succeeded(hr)) {
            std.debug.print("win32 WebView2 pending load failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        }
    }

    fn applyClientBounds(self: *Win32WebView) void {
        const controller = self.controller orelse return;
        const size = window_win32.clientSize(self.window_handle) orelse return;
        _ = controller.setBounds(.{
            .left = 0,
            .top = 0,
            .right = size.width,
            .bottom = size.height,
        });
    }

    fn onWindowResized(context: *anyopaque, width: i32, height: i32) void {
        const self: *Win32WebView = @ptrCast(@alignCast(context));
        const controller = self.controller orelse return;
        _ = controller.setBounds(.{ .left = 0, .top = 0, .right = width, .bottom = height });
    }

    fn onEnvironmentCreated(
        context: *anyopaque,
        error_code: webview2.HRESULT,
        environment: ?*webview2.ICoreWebView2Environment,
    ) callconv(.c) void {
        const self: *Win32WebView = @ptrCast(@alignCast(context));
        const created = environment orelse {
            std.debug.print("WebView2 environment creation failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(error_code))});
            return;
        };

        _ = created.addRef();
        self.environment = created;

        const handler = webview2.ControllerCompletedHandler.create(self, onControllerCreated) catch return;
        const hr = created.createController(self.window_handle, handler);
        handler.releaseOwnership();
        if (!webview2.succeeded(hr)) {
            std.debug.print("WebView2 controller request failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        }
    }

    fn onControllerCreated(
        context: *anyopaque,
        error_code: webview2.HRESULT,
        controller: ?*webview2.ICoreWebView2Controller,
    ) callconv(.c) void {
        const self: *Win32WebView = @ptrCast(@alignCast(context));
        const created = controller orelse {
            std.debug.print("WebView2 controller creation failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(error_code))});
            return;
        };

        _ = created.addRef();
        self.controller = created;
        self.core = created.coreWebView2();
        self.applyClientBounds();
        _ = created.setVisible(true);

        std.debug.print("win32 WebView2 controller ready.\n", .{});
        // TODO(webview adapter): report page load, title, URL, and navigation
        // state events (add_NavigationStarting and friends), matching macOS.
        self.flushPendingLoad();
    }
};

fn userDataFolderUtf16() ![:0]u16 {
    const allocator = std.heap.page_allocator;

    // Keep browser profile data under the same root as the JSONL stores
    // (%APPDATA%\.nimlo, resolved the same way as app.zig).
    const environ: std.process.Environ = .{ .block = .global };
    const app_data = environ.getAlloc(allocator, "APPDATA") catch null;
    defer if (app_data) |value| allocator.free(value);

    const folder = if (app_data) |base|
        try std.fmt.allocPrint(allocator, "{s}\\.nimlo\\webview2", .{base})
    else
        try allocator.dupe(u8, ".nimlo\\webview2");
    defer allocator.free(folder);

    return webview2.utf16ZFromUtf8(allocator, folder);
}
