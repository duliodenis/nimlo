//! Platform-neutral URL/string helpers shared by the platform chrome
//! implementations. No AppKit/ObjC dependencies allowed here.

const std = @import("std");

pub fn hexValue(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

// Percent-decoding for path-like input: '+' is kept literal.
pub fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try appendPercentDecoded(&output, allocator, input, false);
    return output.toOwnedSlice(allocator);
}

// Percent-decoding for query-component values: '+' becomes a space and the
// result is zero-terminated for direct use with C/ObjC string APIs.
pub fn percentDecodeQueryAlloc(allocator: std.mem.Allocator, input: []const u8) ![:0]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try appendPercentDecoded(&output, allocator, input, true);
    return allocator.dupeZ(u8, output.items);
}

fn appendPercentDecoded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    plus_as_space: bool,
) !void {
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '%' and index + 2 < input.len) {
            if (hexValue(input[index + 1])) |high| {
                if (hexValue(input[index + 2])) |low| {
                    try output.append(allocator, (high << 4) | low);
                    index += 3;
                    continue;
                }
            }
        }

        try output.append(allocator, if (plus_as_space and byte == '+') ' ' else byte);
        index += 1;
    }
}

pub fn appendPercentEncodedPath(output: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.append(allocator, '%');
            try output.append(allocator, hex[byte >> 4]);
            try output.append(allocator, hex[byte & 0x0f]);
        }
    }
}

pub fn appendFileUrl(output: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8, is_directory: bool) !void {
    try output.appendSlice(allocator, "file://");
    try appendPercentEncodedPath(output, allocator, path);
    if (is_directory and !std.mem.endsWith(u8, path, "/")) {
        try output.append(allocator, '/');
    }
}

pub fn fileUrlStringAlloc(allocator: std.mem.Allocator, path: []const u8, is_directory: bool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try appendFileUrl(&output, allocator, path, is_directory);
    return output.toOwnedSlice(allocator);
}

pub fn filePathFromUrlAlloc(allocator: std.mem.Allocator, file_url: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, file_url, prefix)) return error.NotFileUrl;

    var path_text = file_url[prefix.len..];
    if (std.mem.startsWith(u8, path_text, "localhost/")) {
        path_text = path_text["localhost".len..];
    }
    if (!std.mem.startsWith(u8, path_text, "/")) return error.UnsupportedFileUrl;

    return percentDecodeAlloc(allocator, path_text);
}

pub fn appendEscapedHtml(output: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            else => try output.append(allocator, byte),
        }
    }
}

pub fn isExternalWebUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

test "hex digits parse and reject" {
    try std.testing.expectEqual(@as(?u8, 0), hexValue('0'));
    try std.testing.expectEqual(@as(?u8, 10), hexValue('a'));
    try std.testing.expectEqual(@as(?u8, 15), hexValue('F'));
    try std.testing.expectEqual(@as(?u8, null), hexValue('g'));
}

test "percent decode keeps plus literal for paths" {
    const decoded = try percentDecodeAlloc(std.testing.allocator, "/Users/dd/a%20b+c%2Fd");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("/Users/dd/a b+c/d", decoded);
}

test "percent decode leaves malformed escapes untouched" {
    const decoded = try percentDecodeAlloc(std.testing.allocator, "a%zz%4");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a%zz%4", decoded);
}

test "query decode converts plus and terminates" {
    const decoded = try percentDecodeQueryAlloc(std.testing.allocator, "annual+report%20final.pdf");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("annual report final.pdf", decoded);
    try std.testing.expectEqual(@as(u8, 0), decoded.ptr[decoded.len]);
}

test "file url round trip with encoding" {
    const url = try fileUrlStringAlloc(std.testing.allocator, "/Users/dd/My Files", true);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///Users/dd/My%20Files/", url);

    const path = try filePathFromUrlAlloc(std.testing.allocator, url);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/Users/dd/My Files/", path);
}

test "file path from localhost url" {
    const path = try filePathFromUrlAlloc(std.testing.allocator, "file://localhost/tmp/x");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/x", path);
}

test "file path rejects non-file urls" {
    try std.testing.expectError(error.NotFileUrl, filePathFromUrlAlloc(std.testing.allocator, "https://example.com"));
    try std.testing.expectError(error.UnsupportedFileUrl, filePathFromUrlAlloc(std.testing.allocator, "file://host/x"));
}

test "html escaping" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendEscapedHtml(&output, std.testing.allocator, "<a href=\"x\">&</a>");
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;", output.items);
}

test "external web url detection" {
    try std.testing.expect(isExternalWebUrl("https://example.com"));
    try std.testing.expect(isExternalWebUrl("http://example.com"));
    try std.testing.expect(!isExternalWebUrl("nimlo://start"));
    try std.testing.expect(!isExternalWebUrl("file:///tmp"));
}
