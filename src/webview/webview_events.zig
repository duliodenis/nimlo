pub const LoadingState = enum {
    idle,
    loading,
    failed,
};

pub const NavigationEvent = struct {
    source_handle: ?*anyopaque = null,
    url: []const u8,
    title: []const u8 = "",
    favicon_url: []const u8 = "",
    loading_state: LoadingState,
    can_go_back: bool = false,
    can_go_forward: bool = false,
};

pub const TabSnapshot = struct {
    id: u64,
    title: []const u8,
    url: []const u8,
    favicon_url: []const u8 = "",
    is_active: bool,
};

pub const EventSink = struct {
    context: *anyopaque,
    on_navigation: *const fn (context: *anyopaque, event: NavigationEvent) void,
    on_new_tab_requested: ?*const fn (context: *anyopaque) void = null,
    on_url_open_requested: ?*const fn (context: *anyopaque, url: []const u8) void = null,
    on_tab_activated_requested: ?*const fn (context: *anyopaque, tab_id: u64) void = null,
    on_tab_closed_requested: ?*const fn (context: *anyopaque, tab_id: u64) void = null,
};

pub const ChromeSink = struct {
    context: *anyopaque,
    on_tabs_changed: *const fn (context: *anyopaque, tabs: []const TabSnapshot) void,
};

var current_sink: ?EventSink = null;
var current_chrome_sink: ?ChromeSink = null;

pub fn setSink(sink: EventSink) void {
    current_sink = sink;
}

pub fn clearSink() void {
    current_sink = null;
}

pub fn setChromeSink(sink: ChromeSink) void {
    current_chrome_sink = sink;
}

pub fn clearChromeSink() void {
    current_chrome_sink = null;
}

pub fn emitNavigation(event: NavigationEvent) void {
    if (current_sink) |sink| {
        sink.on_navigation(sink.context, event);
    }
}

pub fn emitTabActivatedRequested(tab_id: u64) void {
    if (current_sink) |sink| {
        if (sink.on_tab_activated_requested) |callback| {
            callback(sink.context, tab_id);
        }
    }
}

pub fn emitTabClosedRequested(tab_id: u64) void {
    if (current_sink) |sink| {
        if (sink.on_tab_closed_requested) |callback| {
            callback(sink.context, tab_id);
        }
    }
}

pub fn emitTabsChanged(tabs: []const TabSnapshot) void {
    if (current_chrome_sink) |sink| {
        sink.on_tabs_changed(sink.context, tabs);
    }
}

pub fn emitNewTabRequested() void {
    if (current_sink) |sink| {
        if (sink.on_new_tab_requested) |callback| {
            callback(sink.context);
        }
    }
}

pub fn emitUrlOpenRequested(url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_url_open_requested) |callback| {
            callback(sink.context, url);
        }
    }
}
