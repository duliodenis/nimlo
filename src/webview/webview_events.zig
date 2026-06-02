pub const LoadingState = enum {
    idle,
    loading,
    failed,
};

pub const NavigationEvent = struct {
    url: []const u8,
    title: []const u8 = "",
    favicon_url: []const u8 = "",
    loading_state: LoadingState,
    can_go_back: bool = false,
    can_go_forward: bool = false,
};

pub const EventSink = struct {
    context: *anyopaque,
    on_navigation: *const fn (context: *anyopaque, event: NavigationEvent) void,
    on_new_tab_requested: ?*const fn (context: *anyopaque) void = null,
};

var current_sink: ?EventSink = null;

pub fn setSink(sink: EventSink) void {
    current_sink = sink;
}

pub fn clearSink() void {
    current_sink = null;
}

pub fn emitNavigation(event: NavigationEvent) void {
    if (current_sink) |sink| {
        sink.on_navigation(sink.context, event);
    }
}

pub fn emitNewTabRequested() void {
    if (current_sink) |sink| {
        if (sink.on_new_tab_requested) |callback| {
            callback(sink.context);
        }
    }
}
