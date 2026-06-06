const std = @import("std");

pub const default_search_prefix = "https://duckduckgo.com/?q=";

pub fn normalize(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return normalizeWithSearchPrefix(allocator, input, default_search_prefix);
}

pub fn normalizeWithSearchPrefix(
    allocator: std.mem.Allocator,
    input: []const u8,
    search_prefix: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyInput;

    if (hasKnownScheme(trimmed)) {
        return allocator.dupe(u8, trimmed);
    }

    if (looksLikeDomain(trimmed)) {
        return std.mem.concat(allocator, u8, &.{ "https://", trimmed });
    }

    return buildSearchUrl(allocator, search_prefix, trimmed);
}

fn hasKnownScheme(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "http://") or
        std.mem.startsWith(u8, input, "https://") or
        std.mem.startsWith(u8, input, "file://") or
        std.mem.startsWith(u8, input, "nimlo://");
}

fn looksLikeDomain(input: []const u8) bool {
    if (containsWhitespace(input) or std.mem.indexOf(u8, input, "://") != null) {
        return false;
    }

    const host_end = std.mem.indexOfAny(u8, input, "/?#") orelse input.len;
    const host = input[0..host_end];

    return host.len > 0 and
        std.mem.indexOfScalar(u8, host, '.') != null and
        !std.mem.startsWith(u8, host, ".") and
        !std.mem.endsWith(u8, host, ".");
}

fn containsWhitespace(input: []const u8) bool {
    for (input) |byte| {
        switch (byte) {
            ' ', '\t', '\r', '\n' => return true,
            else => {},
        }
    }

    return false;
}

fn buildSearchUrl(
    allocator: std.mem.Allocator,
    search_prefix: []const u8,
    query: []const u8,
) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, search_prefix);
    try appendEncodedQuery(&result, allocator, query);

    return result.toOwnedSlice(allocator);
}

fn appendEncodedQuery(
    result: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    query: []const u8,
) !void {
    const hex = "0123456789ABCDEF";

    for (query) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try result.append(allocator, byte);
        } else if (byte == ' ') {
            try result.append(allocator, '+');
        } else {
            try result.append(allocator, '%');
            try result.append(allocator, hex[byte >> 4]);
            try result.append(allocator, hex[byte & 0x0f]);
        }
    }
}

test "preserves explicit web URLs" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, " https://example.com/path ");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("https://example.com/path", normalized);
}

test "preserves Nimlo internal URLs" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, "nimlo://start");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("nimlo://start", normalized);
}

test "preserves file URLs" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, " file:///Users/dd/dev/github/nimlo/docs/index.html ");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("file:///Users/dd/dev/github/nimlo/docs/index.html", normalized);
}

test "preserves file directory URLs" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, "file:///Users/dd/dev/github/nimlo/");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("file:///Users/dd/dev/github/nimlo/", normalized);
}

test "normalizes domain-like input to https" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, "example.com/docs");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("https://example.com/docs", normalized);
}

test "routes plain text to search" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, "hello world");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("https://duckduckgo.com/?q=hello+world", normalized);
}

test "percent-encodes search punctuation" {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, "zig + webview");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("https://duckduckgo.com/?q=zig+%2B+webview", normalized);
}

test "rejects empty input" {
    try std.testing.expectError(error.EmptyInput, normalize(std.testing.allocator, " \n\t "));
}
