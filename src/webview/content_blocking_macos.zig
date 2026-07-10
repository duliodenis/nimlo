//! macOS content-blocking enforcement: compiles WebKit content-blocker JSON
//! through WKContentRuleListStore and attaches the compiled lists to every
//! registered WKUserContentController (docs/CONTENT_BLOCKING.md, Phase F).
//!
//! WKContentRuleListStore's API is async with ObjC completion blocks. The
//! blocks are built here in raw C ABI, marked BLOCK_IS_GLOBAL so the ObjC
//! runtime never tries to copy, retain, or dispose them; each is
//! heap-allocated and fires exactly once on the main thread. The blocks are
//! deliberately never freed: the runtime still reads the block's flags in
//! _Block_release *after* invoke returns, so freeing inside invoke is a
//! use-after-free (page_allocator unmaps the page → segfault). A few dozen
//! leaked bytes per rule list per launch is the price of not owning the
//! release point.

const std = @import("std");
const content_blocking = @import("content_blocking.zig");

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Class = ?*anyopaque;

extern "c" fn objc_msgSend() void;
extern "c" var _NSConcreteGlobalBlock: anyopaque;

const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const BlockDescriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
};

// void (^)(WKContentRuleList *ruleList, NSError *error) — the completion
// shape shared by lookUp… and compile….
const RuleListCompletionBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*RuleListCompletionBlock, Id, Id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    pending: *PendingList,
};

var rule_list_block_descriptor = BlockDescriptor{
    .reserved = 0,
    .size = @sizeOf(RuleListCompletionBlock),
};

const PendingList = struct {
    identifier: [:0]u8,
    json: ?[:0]u8,
};

var install_started = false;
var store: Id = null;
var compiled_lists: std.ArrayList(Id) = .empty;
var registered_controllers: std.ArrayList(Id) = .empty;
var pending_count: usize = 0;

pub fn installRuleLists(compiled_store_path: []const u8, sources: []const content_blocking.RuleListSource) void {
    if (install_started) return;
    install_started = true;

    const allocator = std.heap.page_allocator;
    const path_z = allocator.dupeZ(u8, compiled_store_path) catch return;
    defer allocator.free(path_z);

    const store_url = msg2(
        Id,
        cls("NSURL"),
        sel("fileURLWithPath:isDirectory:"),
        nsString(path_z),
        true,
    );
    // Compiled artifacts cache separately from browsing data on purpose:
    // the browsing store is non-persistent, the compile cache must persist.
    store = msg1(Id, cls("WKContentRuleListStore"), sel("storeWithURL:"), store_url);
    if (store == null) {
        std.debug.print("content blocking: WKContentRuleListStore unavailable.\n", .{});
        return;
    }
    _ = msg0(Id, store, sel("retain"));

    for (sources) |source| {
        lookUpOrCompile(source) catch |err| {
            std.debug.print("content blocking: install failed for {s}: {s}\n", .{ source.identifier, @errorName(err) });
        };
    }
}

pub fn wantsRuleListPayloads() bool {
    return true;
}

pub fn pendingListCount() usize {
    return pending_count;
}

pub fn activeListCount() usize {
    return compiled_lists.items.len;
}

/// Registers a webview's user content controller so it receives every
/// compiled list, now and as later compilations finish. Called by
/// webview_macos at webview creation.
pub fn attachToController(controller: Id) void {
    if (controller == null) return;

    for (registered_controllers.items) |existing| {
        if (existing == controller) return;
    }
    _ = msg0(Id, controller, sel("retain"));
    registered_controllers.append(std.heap.page_allocator, controller) catch {
        _ = msg0(Id, controller, sel("release"));
        return;
    };

    for (compiled_lists.items) |rule_list| {
        msg1(void, controller, sel("addContentRuleList:"), rule_list);
    }
}

/// Forgets a controller when its webview is destroyed.
pub fn forgetController(controller: Id) void {
    if (controller == null) return;
    for (registered_controllers.items, 0..) |existing, index| {
        if (existing != controller) continue;
        _ = registered_controllers.orderedRemove(index);
        _ = msg0(Id, controller, sel("release"));
        return;
    }
}

fn lookUpOrCompile(source: content_blocking.RuleListSource) !void {
    const allocator = std.heap.page_allocator;

    const pending = try allocator.create(PendingList);
    errdefer allocator.destroy(pending);
    pending.* = .{
        .identifier = try allocator.dupeZ(u8, source.identifier),
        .json = try allocator.dupeZ(u8, source.json),
    };

    pending_count += 1;
    const block = makeCompletionBlock(onLookUpCompleted, pending) catch |err| {
        pending_count -= 1;
        finishPending(pending);
        return err;
    };
    msg2(
        void,
        store,
        sel("lookUpContentRuleListForIdentifier:completionHandler:"),
        nsString(pending.identifier),
        block,
    );
}

fn onLookUpCompleted(block: *RuleListCompletionBlock, rule_list: Id, lookup_error: Id) callconv(.c) void {
    const pending = block.pending;
    _ = lookup_error;

    if (rule_list != null) {
        adoptCompiledList(rule_list);
        std.debug.print("content blocking: {s} loaded from compile cache.\n", .{pending.identifier});
        completePending(pending);
        return;
    }

    // Cache miss: compile from the JSON payload.
    const json = pending.json orelse {
        completePending(pending);
        return;
    };
    const compile_block = makeCompletionBlock(onCompileCompleted, pending) catch {
        completePending(pending);
        return;
    };
    msg3(
        void,
        store,
        sel("compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:"),
        nsString(pending.identifier),
        nsString(json),
        compile_block,
    );
}

fn onCompileCompleted(block: *RuleListCompletionBlock, rule_list: Id, compile_error: Id) callconv(.c) void {
    const pending = block.pending;

    if (rule_list != null) {
        adoptCompiledList(rule_list);
        std.debug.print("content blocking: {s} compiled.\n", .{pending.identifier});
    } else {
        // WebKit's compiler is the ground truth for the Phase D emitter;
        // surface its verdict verbatim.
        std.debug.print("content blocking: {s} failed to compile: {s}\n", .{
            pending.identifier,
            errorDescription(compile_error),
        });
    }
    completePending(pending);
}

fn adoptCompiledList(rule_list: Id) void {
    _ = msg0(Id, rule_list, sel("retain"));
    compiled_lists.append(std.heap.page_allocator, rule_list) catch {
        _ = msg0(Id, rule_list, sel("release"));
        return;
    };

    for (registered_controllers.items) |controller| {
        msg1(void, controller, sel("addContentRuleList:"), rule_list);
    }
}

fn completePending(pending: *PendingList) void {
    pending_count -= 1;
    finishPending(pending);
    if (pending_count == 0) {
        std.debug.print("content blocking: {d} rule lists active.\n", .{compiled_lists.items.len});
    }
}

fn finishPending(pending: *PendingList) void {
    const allocator = std.heap.page_allocator;
    allocator.free(pending.identifier);
    if (pending.json) |json| allocator.free(json);
    allocator.destroy(pending);
}

fn makeCompletionBlock(
    invoke: *const fn (*RuleListCompletionBlock, Id, Id) callconv(.c) void,
    pending: *PendingList,
) !*RuleListCompletionBlock {
    const block = try std.heap.page_allocator.create(RuleListCompletionBlock);
    block.* = .{
        .isa = &_NSConcreteGlobalBlock,
        .flags = BLOCK_IS_GLOBAL,
        .reserved = 0,
        .invoke = invoke,
        .descriptor = &rule_list_block_descriptor,
        .pending = pending,
    };
    return block;
}

fn errorDescription(error_id: Id) [:0]const u8 {
    if (error_id == null) return "unknown error";
    const description = msg0(Id, error_id, sel("localizedDescription"));
    if (description == null) return "unknown error";
    const utf8 = msg0(?[*:0]const u8, description, sel("UTF8String")) orelse return "unknown error";
    return std.mem.span(utf8);
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
