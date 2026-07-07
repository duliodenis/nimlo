//! Minimal COM bridge for Microsoft's WebView2 — the Windows analog of the
//! raw objc_msgSend bridge on macOS: no SDK headers, no import libraries.
//! Vtable layouts and IIDs are transcribed from WebView2.idl (NuGet package
//! Microsoft.Web.WebView2 1.0.2903.40, vendored under windows/webview2/).
//!
//! Everything here is platform-neutral declarations plus small helpers, so
//! the GUID and COM-object logic stays unit-testable on any host. COM's
//! stdcall calling convention equals the C ABI on the 64-bit targets Nimlo
//! supports (x86_64, aarch64); 32-bit x86 Windows is unsupported.

const std = @import("std");

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x8000_4002));

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    /// Parses the canonical "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" form.
    pub fn parse(text: []const u8) error{InvalidGuid}!GUID {
        if (text.len != 36) return error.InvalidGuid;
        if (text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') {
            return error.InvalidGuid;
        }

        var data4: [8]u8 = undefined;
        data4[0] = parseHexByte(text[19..21]) catch return error.InvalidGuid;
        data4[1] = parseHexByte(text[21..23]) catch return error.InvalidGuid;
        for (0..6) |index| {
            const offset = 24 + index * 2;
            data4[2 + index] = parseHexByte(text[offset..][0..2]) catch return error.InvalidGuid;
        }

        return .{
            .Data1 = std.fmt.parseInt(u32, text[0..8], 16) catch return error.InvalidGuid,
            .Data2 = std.fmt.parseInt(u16, text[9..13], 16) catch return error.InvalidGuid,
            .Data3 = std.fmt.parseInt(u16, text[14..18], 16) catch return error.InvalidGuid,
            .Data4 = data4,
        };
    }

    pub fn eql(self: *const GUID, other: *const GUID) bool {
        return self.Data1 == other.Data1 and
            self.Data2 == other.Data2 and
            self.Data3 == other.Data3 and
            std.mem.eql(u8, &self.Data4, &other.Data4);
    }

    fn parseHexByte(text: *const [2]u8) !u8 {
        return std.fmt.parseInt(u8, text, 16);
    }
};

pub const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046") catch unreachable;
pub const IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler =
    GUID.parse("4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d") catch unreachable;
pub const IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler =
    GUID.parse("6c4819f3-c9b7-4260-8127-c9f5bde7f68c") catch unreachable;

/// Signature of the entry point resolved from WebView2Loader.dll with
/// GetProcAddress; the DLL is never linked, only loaded at runtime.
pub const CreateCoreWebView2EnvironmentWithOptionsFn = *const fn (
    browser_executable_folder: ?[*:0]const u16,
    user_data_folder: ?[*:0]const u16,
    environment_options: ?*anyopaque,
    environment_created_handler: *EnvironmentCompletedHandler,
) callconv(.c) HRESULT;

// The interface vtables below declare only the leading slots Nimlo calls
// (in exact IDL order); they are always received from COM, never
// instantiated, so a prefix is safe. Unused slots are untyped.

pub const ICoreWebView2Environment = extern struct {
    vtable: *const Vtable,

    pub const Vtable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*ICoreWebView2Environment) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2Environment) callconv(.c) u32,
        CreateCoreWebView2Controller: *const fn (
            *ICoreWebView2Environment,
            parent_window: ?*anyopaque,
            handler: *ControllerCompletedHandler,
        ) callconv(.c) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Environment) u32 {
        return self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2Environment) u32 {
        return self.vtable.Release(self);
    }

    pub fn createController(
        self: *ICoreWebView2Environment,
        parent_window: ?*anyopaque,
        handler: *ControllerCompletedHandler,
    ) HRESULT {
        return self.vtable.CreateCoreWebView2Controller(self, parent_window, handler);
    }
};

pub const ICoreWebView2Controller = extern struct {
    vtable: *const Vtable,

    pub const Vtable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*ICoreWebView2Controller) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2Controller) callconv(.c) u32,
        get_IsVisible: *const anyopaque,
        put_IsVisible: *const fn (*ICoreWebView2Controller, i32) callconv(.c) HRESULT,
        get_Bounds: *const anyopaque,
        put_Bounds: *const fn (*ICoreWebView2Controller, RECT) callconv(.c) HRESULT,
        get_ZoomFactor: *const anyopaque,
        put_ZoomFactor: *const anyopaque,
        add_ZoomFactorChanged: *const anyopaque,
        remove_ZoomFactorChanged: *const anyopaque,
        SetBoundsAndZoomFactor: *const anyopaque,
        MoveFocus: *const anyopaque,
        add_MoveFocusRequested: *const anyopaque,
        remove_MoveFocusRequested: *const anyopaque,
        add_GotFocus: *const anyopaque,
        remove_GotFocus: *const anyopaque,
        add_LostFocus: *const anyopaque,
        remove_LostFocus: *const anyopaque,
        add_AcceleratorKeyPressed: *const anyopaque,
        remove_AcceleratorKeyPressed: *const anyopaque,
        get_ParentWindow: *const anyopaque,
        put_ParentWindow: *const anyopaque,
        NotifyParentWindowPositionChanged: *const anyopaque,
        Close: *const fn (*ICoreWebView2Controller) callconv(.c) HRESULT,
        get_CoreWebView2: *const fn (*ICoreWebView2Controller, *?*ICoreWebView2) callconv(.c) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2Controller) u32 {
        return self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2Controller) u32 {
        return self.vtable.Release(self);
    }

    pub fn setVisible(self: *ICoreWebView2Controller, visible: bool) HRESULT {
        return self.vtable.put_IsVisible(self, @intFromBool(visible));
    }

    pub fn setBounds(self: *ICoreWebView2Controller, bounds: RECT) HRESULT {
        return self.vtable.put_Bounds(self, bounds);
    }

    pub fn close(self: *ICoreWebView2Controller) HRESULT {
        return self.vtable.Close(self);
    }

    pub fn coreWebView2(self: *ICoreWebView2Controller) ?*ICoreWebView2 {
        var core: ?*ICoreWebView2 = null;
        if (!succeeded(self.vtable.get_CoreWebView2(self, &core))) return null;
        return core;
    }
};

pub const ICoreWebView2 = extern struct {
    vtable: *const Vtable,

    pub const Vtable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*ICoreWebView2) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2) callconv(.c) u32,
        get_Settings: *const anyopaque,
        get_Source: *const anyopaque,
        Navigate: *const fn (*ICoreWebView2, [*:0]const u16) callconv(.c) HRESULT,
        NavigateToString: *const fn (*ICoreWebView2, [*:0]const u16) callconv(.c) HRESULT,
    };

    pub fn addRef(self: *ICoreWebView2) u32 {
        return self.vtable.AddRef(self);
    }

    pub fn release(self: *ICoreWebView2) u32 {
        return self.vtable.Release(self);
    }

    pub fn navigate(self: *ICoreWebView2, url_utf16: [*:0]const u16) HRESULT {
        return self.vtable.Navigate(self, url_utf16);
    }

    pub fn navigateToString(self: *ICoreWebView2, html_utf16: [*:0]const u16) HRESULT {
        return self.vtable.NavigateToString(self, html_utf16);
    }
};

/// A COM object implemented in Zig for WebView2's async completion
/// callbacks: IUnknown plus Invoke(HRESULT, *Result). Created with one
/// reference owned by the caller; COM add-refs while it holds the handler,
/// so callers release their reference right after handing it off.
pub fn CompletedHandler(comptime Result: type, comptime interface_iid: GUID) type {
    return extern struct {
        vtable: *const Vtable,
        ref_count: u32,
        context: *anyopaque,
        on_completed: Callback,

        const Self = @This();
        const own_iid: GUID = interface_iid;

        // The extern layout forces the C calling convention onto this
        // Zig-to-Zig callback as well; it is otherwise an ordinary function.
        pub const Callback = *const fn (context: *anyopaque, error_code: HRESULT, result: ?*Result) callconv(.c) void;

        pub const Vtable = extern struct {
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
            AddRef: *const fn (*Self) callconv(.c) u32,
            Release: *const fn (*Self) callconv(.c) u32,
            Invoke: *const fn (*Self, HRESULT, ?*Result) callconv(.c) HRESULT,
        };

        const vtable_instance = Vtable{
            .QueryInterface = queryInterface,
            .AddRef = addRef,
            .Release = release,
            .Invoke = invoke,
        };

        pub fn create(context: *anyopaque, on_completed: Callback) !*Self {
            const self = try std.heap.page_allocator.create(Self);
            self.* = .{
                .vtable = &vtable_instance,
                .ref_count = 1,
                .context = context,
                .on_completed = on_completed,
            };
            return self;
        }

        pub fn releaseOwnership(self: *Self) void {
            _ = release(self);
        }

        fn queryInterface(self: *Self, riid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
            if (riid.eql(&own_iid) or riid.eql(&IID_IUnknown)) {
                out.* = self;
                _ = addRef(self);
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }

        // WebView2 completion callbacks arrive on the single UI thread that
        // pumps messages, so the reference count needs no atomics.
        fn addRef(self: *Self) callconv(.c) u32 {
            self.ref_count += 1;
            return self.ref_count;
        }

        fn release(self: *Self) callconv(.c) u32 {
            self.ref_count -= 1;
            const remaining = self.ref_count;
            if (remaining == 0) std.heap.page_allocator.destroy(self);
            return remaining;
        }

        fn invoke(self: *Self, error_code: HRESULT, result: ?*Result) callconv(.c) HRESULT {
            self.on_completed(self.context, error_code, result);
            return S_OK;
        }
    };
}

pub const EnvironmentCompletedHandler = CompletedHandler(
    ICoreWebView2Environment,
    IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
);

pub const ControllerCompletedHandler = CompletedHandler(
    ICoreWebView2Controller,
    IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
);

pub fn utf16ZFromUtf8(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

test "GUID.parse decodes the canonical form" {
    const guid = try GUID.parse("4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d");
    try std.testing.expectEqual(@as(u32, 0x4e8a3389), guid.Data1);
    try std.testing.expectEqual(@as(u16, 0xc9d8), guid.Data2);
    try std.testing.expectEqual(@as(u16, 0x4bd2), guid.Data3);
    try std.testing.expectEqualSlices(u8, &.{ 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d }, &guid.Data4);
}

test "GUID.parse rejects malformed input" {
    try std.testing.expectError(error.InvalidGuid, GUID.parse("4e8a3389"));
    try std.testing.expectError(error.InvalidGuid, GUID.parse("4e8a3389+c9d8-4bd2-b6b5-124fee6cc14d"));
    try std.testing.expectError(error.InvalidGuid, GUID.parse("4e8a3389-c9d8-4bd2-b6b5-124fee6cc14g"));
}

test "GUID.eql distinguishes interface ids" {
    const env_iid = IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
    const controller_iid = IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;
    try std.testing.expect(env_iid.eql(&env_iid));
    try std.testing.expect(!env_iid.eql(&controller_iid));
}

const TestCompletionRecorder = struct {
    invoked: usize = 0,
    last_error_code: HRESULT = 0,
    last_result: ?*ICoreWebView2Environment = null,

    fn onCompleted(context: *anyopaque, error_code: HRESULT, result: ?*ICoreWebView2Environment) callconv(.c) void {
        const recorder: *TestCompletionRecorder = @ptrCast(@alignCast(context));
        recorder.invoked += 1;
        recorder.last_error_code = error_code;
        recorder.last_result = result;
    }
};

test "CompletedHandler invokes its callback and manages references" {
    var recorder = TestCompletionRecorder{};
    const handler = try EnvironmentCompletedHandler.create(&recorder, TestCompletionRecorder.onCompleted);

    try std.testing.expectEqual(@as(u32, 2), handler.vtable.AddRef(handler));
    _ = handler.vtable.Invoke(handler, S_OK, null);
    try std.testing.expectEqual(@as(usize, 1), recorder.invoked);
    try std.testing.expectEqual(S_OK, recorder.last_error_code);
    try std.testing.expectEqual(@as(?*ICoreWebView2Environment, null), recorder.last_result);

    try std.testing.expectEqual(@as(u32, 1), handler.vtable.Release(handler));
    try std.testing.expectEqual(@as(u32, 0), handler.vtable.Release(handler));
}

test "CompletedHandler answers QueryInterface for its IID and IUnknown only" {
    var recorder = TestCompletionRecorder{};
    const handler = try EnvironmentCompletedHandler.create(&recorder, TestCompletionRecorder.onCompleted);
    defer handler.releaseOwnership();

    var out: ?*anyopaque = null;
    try std.testing.expectEqual(S_OK, handler.vtable.QueryInterface(
        handler,
        &IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
        &out,
    ));
    try std.testing.expectEqual(@as(?*anyopaque, handler), out);
    try std.testing.expectEqual(@as(u32, 1), handler.vtable.Release(handler));

    try std.testing.expectEqual(S_OK, handler.vtable.QueryInterface(handler, &IID_IUnknown, &out));
    try std.testing.expectEqual(@as(u32, 1), handler.vtable.Release(handler));

    const unrelated = IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;
    try std.testing.expectEqual(E_NOINTERFACE, handler.vtable.QueryInterface(handler, &unrelated, &out));
    try std.testing.expectEqual(@as(?*anyopaque, null), out);
}

test "utf16ZFromUtf8 round-trips URLs" {
    const utf16 = try utf16ZFromUtf8(std.testing.allocator, "https://ziglang.org/päge");
    defer std.testing.allocator.free(utf16);

    const back = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, utf16);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings("https://ziglang.org/päge", back);
}
