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
    can_bookmark: bool = false,
    is_bookmarked: bool = false,
};

pub const DetachedTab = struct {
    title: []const u8,
    url: []const u8,
    favicon_url: []const u8 = "",
    is_private: bool = false,
};

pub const EventSink = struct {
    context: *anyopaque,
    on_navigation: *const fn (context: *anyopaque, event: NavigationEvent) void,
    on_new_tab_requested: ?*const fn (context: *anyopaque) void = null,
    on_url_open_requested: ?*const fn (context: *anyopaque, url: []const u8) void = null,
    on_active_tab_url_requested: ?*const fn (context: *anyopaque, url: []const u8) void = null,
    on_bookmark_current_page_toggle_requested: ?*const fn (context: *anyopaque) void = null,
    on_internal_page_reload_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, url: []const u8) void = null,
    on_history_clear_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque) void = null,
    on_history_clear_confirmed_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque) void = null,
    on_history_urls_delete_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void = null,
    on_history_urls_open_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void = null,
    on_bookmark_urls_delete_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void = null,
    on_bookmark_tag_add_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void = null,
    on_bookmark_tag_remove_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque, request_url: []const u8) void = null,
    on_tab_activated_requested: ?*const fn (context: *anyopaque, tab_id: u64) void = null,
    on_tab_closed_requested: ?*const fn (context: *anyopaque, tab_id: u64) void = null,
    on_tab_reordered_requested: ?*const fn (context: *anyopaque, from_index: usize, to_index: usize) void = null,
    on_active_tab_detach_requested: ?*const fn (context: *anyopaque) void = null,
};

pub const ChromeSink = struct {
    context: *anyopaque,
    on_tabs_changed: *const fn (context: *anyopaque, tabs: []const TabSnapshot) void,
    on_address_bar_focus_requested: ?*const fn (context: *anyopaque) void = null,
    on_app_close_requested: ?*const fn (context: *anyopaque) void = null,
    on_history_empty_requested: ?*const fn (context: *anyopaque) void = null,
    on_history_clear_confirmation_requested: ?*const fn (context: *anyopaque, source_handle: ?*anyopaque) void = null,
};

pub const AppSink = struct {
    context: *anyopaque,
    on_new_window_requested: ?*const fn (context: *anyopaque) void = null,
    on_window_closed: ?*const fn (context: *anyopaque, window_handle: ?*anyopaque) void = null,
    on_tab_detached: ?*const fn (context: *anyopaque, tab: DetachedTab) void = null,
};

var current_sink: ?EventSink = null;
var current_chrome_sink: ?ChromeSink = null;
var current_app_sink: ?AppSink = null;
var event_sinks: std.ArrayList(OwnedEventSink) = .empty;
var chrome_sinks: std.ArrayList(OwnedChromeSink) = .empty;

const std = @import("std");

const OwnedEventSink = struct {
    owner: ?*anyopaque,
    sink: EventSink,
};

const OwnedChromeSink = struct {
    owner: ?*anyopaque,
    sink: ChromeSink,
};

pub fn setSink(sink: EventSink) void {
    current_sink = sink;
}

pub fn clearSink() void {
    current_sink = null;
    event_sinks.clearRetainingCapacity();
}

pub fn clearSinkForOwner(owner: ?*anyopaque) void {
    var index: usize = 0;
    while (index < event_sinks.items.len) {
        if (event_sinks.items[index].owner == owner) {
            _ = event_sinks.orderedRemove(index);
            continue;
        }
        index += 1;
    }

    if (current_sink) |sink| {
        for (event_sinks.items) |entry| {
            if (entry.sink.context == sink.context) return;
        }
        current_sink = if (event_sinks.items.len > 0) event_sinks.items[event_sinks.items.len - 1].sink else null;
    }
}

pub fn setSinkForOwner(owner: ?*anyopaque, sink: EventSink) void {
    for (event_sinks.items) |*entry| {
        if (entry.owner == owner) {
            entry.sink = sink;
            current_sink = sink;
            return;
        }
    }

    event_sinks.append(std.heap.page_allocator, .{
        .owner = owner,
        .sink = sink,
    }) catch {
        current_sink = sink;
        return;
    };
    current_sink = sink;
}

pub fn activateSinkForOwner(owner: ?*anyopaque) void {
    for (event_sinks.items) |entry| {
        if (entry.owner == owner) {
            current_sink = entry.sink;
            return;
        }
    }
}

pub fn setChromeSink(sink: ChromeSink) void {
    current_chrome_sink = sink;
}

pub fn clearChromeSink() void {
    current_chrome_sink = null;
    chrome_sinks.clearRetainingCapacity();
}

pub fn clearChromeSinkForOwner(owner: ?*anyopaque) void {
    var index: usize = 0;
    while (index < chrome_sinks.items.len) {
        if (chrome_sinks.items[index].owner == owner) {
            _ = chrome_sinks.orderedRemove(index);
            continue;
        }
        index += 1;
    }

    if (current_chrome_sink) |sink| {
        for (chrome_sinks.items) |entry| {
            if (entry.sink.context == sink.context) return;
        }
        current_chrome_sink = if (chrome_sinks.items.len > 0) chrome_sinks.items[chrome_sinks.items.len - 1].sink else null;
    }
}

pub fn setChromeSinkForOwner(owner: ?*anyopaque, sink: ChromeSink) void {
    for (chrome_sinks.items) |*entry| {
        if (entry.owner == owner) {
            entry.sink = sink;
            current_chrome_sink = sink;
            return;
        }
    }

    chrome_sinks.append(std.heap.page_allocator, .{
        .owner = owner,
        .sink = sink,
    }) catch {
        current_chrome_sink = sink;
        return;
    };
    current_chrome_sink = sink;
}

pub fn activateChromeSinkForOwner(owner: ?*anyopaque) void {
    for (chrome_sinks.items) |entry| {
        if (entry.owner == owner) {
            current_chrome_sink = entry.sink;
            return;
        }
    }
}

pub fn setAppSink(sink: AppSink) void {
    current_app_sink = sink;
}

pub fn clearAppSink() void {
    current_app_sink = null;
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

pub fn emitTabReorderedRequested(from_index: usize, to_index: usize) void {
    if (current_sink) |sink| {
        if (sink.on_tab_reordered_requested) |callback| {
            callback(sink.context, from_index, to_index);
        }
    }
}

pub fn emitActiveTabDetachRequested() void {
    if (current_sink) |sink| {
        if (sink.on_active_tab_detach_requested) |callback| {
            callback(sink.context);
        }
    }
}

pub fn emitTabsChanged(tabs: []const TabSnapshot) void {
    if (current_chrome_sink) |sink| {
        sink.on_tabs_changed(sink.context, tabs);
    }
}

pub fn emitAddressBarFocusRequested() void {
    if (current_chrome_sink) |sink| {
        if (sink.on_address_bar_focus_requested) |callback| {
            callback(sink.context);
        }
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

pub fn emitNewWindowRequested() void {
    if (current_app_sink) |sink| {
        if (sink.on_new_window_requested) |callback| {
            callback(sink.context);
        }
    }
}

pub fn emitWindowClosed(window_handle: ?*anyopaque) void {
    if (current_app_sink) |sink| {
        if (sink.on_window_closed) |callback| {
            callback(sink.context, window_handle);
        }
    }
}

pub fn emitTabDetached(tab: DetachedTab) void {
    if (current_app_sink) |sink| {
        if (sink.on_tab_detached) |callback| {
            callback(sink.context, tab);
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

pub fn emitActiveTabUrlRequested(url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_active_tab_url_requested) |callback| {
            callback(sink.context, url);
        }
    }
}

pub fn emitBookmarkCurrentPageToggleRequested() void {
    if (current_sink) |sink| {
        if (sink.on_bookmark_current_page_toggle_requested) |callback| {
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

pub fn emitBookmarkUrlsDeleteRequested(source_handle: ?*anyopaque, request_url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_bookmark_urls_delete_requested) |callback| {
            callback(sink.context, source_handle, request_url);
        }
    }
}

pub fn emitBookmarkTagAddRequested(source_handle: ?*anyopaque, request_url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_bookmark_tag_add_requested) |callback| {
            callback(sink.context, source_handle, request_url);
        }
    }
}

pub fn emitBookmarkTagRemoveRequested(source_handle: ?*anyopaque, request_url: []const u8) void {
    if (current_sink) |sink| {
        if (sink.on_bookmark_tag_remove_requested) |callback| {
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
