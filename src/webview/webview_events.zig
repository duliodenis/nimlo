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
    on_bookmark_current_page_requested: ?*const fn (context: *anyopaque) void = null,
    on_internal_page_reload_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, url: []const u8) void = null,
    on_history_clear_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque) void = null,
    on_history_clear_confirmed_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque) void = null,
    on_history_urls_delete_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void = null,
    on_history_urls_open_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void = null,
    on_tab_activated_requested: ?*const fn (context: *anyopaque, tab_id: u64) void = null,
    on_tab_closed_requested: ?*const fn (context: *anyopaque, tab_id: u64) void = null,
};

pub const ChromeSink = struct {
    context: *anyopaque,
    on_tabs_changed: *const fn (context: *anyopaque, tabs: []const TabSnapshot) void,
    on_app_close_requested: ?*const fn (context: *anyopaque) void = null,
    on_history_empty_requested: ?*const fn (context: *anyopaque) void = null,
    on_history_clear_confirmation_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque) void = null,
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

pub fn emitAppCloseRequested() void {
    if (current_chrome_sink) |sink| {
        if (sink.on_app_close_requested) |callback| {
            callback(sink.context);
        }
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

pub fn emitBookmarkCurrentPageRequested() void {
    if (current_sink) |sink| {
        if (sink.on_bookmark_current_page_requested) |callback| {
            callback(sink.context);
        }
    }
}

pub fn emitInternalPageReloadRequested(source_handle: ?*anyopaque, url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_internal_page_reload_requested) |callback| {
            callback(sink.context, source_handle, url);
        }
    }
}

pub fn emitHistoryClearRequested(source_handle: ?*anyopaque) void {
    if (current_sink) |sink| {
        if (sink.on_history_clear_requested) |callback| {
            callback(sink.context, source_handle);
        }
    }
}

pub fn emitHistoryClearConfirmedRequested(source_handle: ?*anyopaque) void {
    if (current_sink) |sink| {
        if (sink.on_history_clear_confirmed_requested) |callback| {
            callback(sink.context, source_handle);
        }
    }
}

pub fn emitHistoryUrlsDeleteRequested(source_handle: ?*anyopaque, request_url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_history_urls_delete_requested) |callback| {
            callback(sink.context, source_handle, request_url);
        }
    }
}

pub fn emitHistoryUrlsOpenRequested(source_handle: ?*anyopaque, request_url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_history_urls_open_requested) |callback| {
            callback(sink.context, source_handle, request_url);
        }
    }
}

pub fn emitHistoryEmptyRequested() void {
    if (current_chrome_sink) |sink| {
        if (sink.on_history_empty_requested) |callback| {
            callback(sink.context);
        }
    }
}

pub fn emitHistoryClearConfirmationRequested(source_handle: ?*anyopaque) void {
    if (current_chrome_sink) |sink| {
        if (sink.on_history_clear_confirmation_requested) |callback| {
            callback(sink.context, source_handle);
        }
    }
}
