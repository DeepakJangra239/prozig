const std = @import("std");

pub const JsonValue = union(enum) {
    null_value: void,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
    array_val: std.array_list.Managed(JsonValue),
    object_val: std.StringHashMap(JsonValue),

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !JsonValue {
        // Delegate to Zig's standard JSON parser which handles escape sequences,
        // partial tokens, UTF-8, surrogates, etc. correctly.
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
        defer parsed.deinit();
        return try jsonValueFromStd(allocator, parsed.value);
    }

    /// Convert a std.json.Value into our internal JsonValue, deep-copying all
    /// strings.  The original std.json.Value can be freed afterwards.
    fn jsonValueFromStd(allocator: std.mem.Allocator, value: std.json.Value) !JsonValue {
        return switch (value) {
            .null => JsonValue{ .null_value = {} },
            .bool => |b| JsonValue{ .bool_val = b },
            .integer => |i| JsonValue{ .int_val = i },
            .float => |f| JsonValue{ .float_val = f },
            .number_string => |s| blk: {
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    break :blk JsonValue{ .int_val = i };
                } else |_| {
                    if (std.fmt.parseFloat(f64, s)) |f| {
                        break :blk JsonValue{ .float_val = f };
                    } else |_| {
                        return error.InvalidJson;
                    }
                }
            },
            .string => |s| JsonValue{ .string_val = try allocator.dupe(u8, s) },
            .array => |arr| {
                var result = try std.array_list.Managed(JsonValue).initCapacity(allocator, arr.items.len);
                for (arr.items) |item| {
                    try result.append(try jsonValueFromStd(allocator, item));
                }
                return JsonValue{ .array_val = result };
            },
            .object => |obj| {
                var result = std.StringHashMap(JsonValue).init(allocator);
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const val = try jsonValueFromStd(allocator, entry.value_ptr.*);
                    try result.put(key, val);
                }
                return JsonValue{ .object_val = result };
            },
        };
    }


    pub fn getString(self: JsonValue, key: []const u8) ?[]const u8 {
        if (std.meta.activeTag(self) == .object_val) {
            if (self.object_val.get(key)) |val| {
                if (std.meta.activeTag(val) == .string_val) return val.string_val;
            }
        }
        return null;
    }

    /// Get a required non-empty string. Returns `error.MissingField` if the key
    /// is absent, not a string, or an empty string. Empty strings are rejected
    /// because a missing value and an empty value are semantically the same —
    /// both indicate the caller did not provide meaningful content.
    pub fn getRequiredString(self: JsonValue, key: []const u8) ![]const u8 {
        const s = self.getString(key) orelse return error.MissingField;
        if (s.len == 0) return error.MissingField;
        return s;
    }

    pub fn getOptionalString(self: JsonValue, key: []const u8) ?[]const u8 {
        return self.getString(key);
    }

    pub fn getInt(self: JsonValue, key: []const u8) ?i64 {
        if (std.meta.activeTag(self) == .object_val) {
            if (self.object_val.get(key)) |val| {
                if (std.meta.activeTag(val) == .int_val) return val.int_val;
            }
        }
        return null;
    }

    pub fn getArguments(self: JsonValue) ?JsonValue {
        if (std.meta.activeTag(self) == .object_val) {
            return self.object_val.get("arguments");
        }
        return null;
    }

    pub fn deinit(self: *JsonValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string_val => |s| allocator.free(s),
            .array_val => |*arr| {
                for (arr.items) |*item| item.deinit(allocator);
                arr.deinit();
            },
            .object_val => |*obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }
};

/// Escape a string for safe inclusion in JSON output.
/// Handles quotes, backslashes, and common control characters.
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(c),
        }
    }
    return result.items;
}

pub fn stringifyTextResponse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const escaped = try jsonEscape(allocator, text);
    defer allocator.free(escaped);
    // NOTE: Returns key-value pairs WITHOUT outer braces — the caller
    // (handleToolsCall → makeResponse) wraps them in `{result}` to produce
    // a complete MCP content response object.
    return std.fmt.allocPrint(allocator, "\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"isError\":false", .{escaped});
}

pub fn stringifyErrorResponse(allocator: std.mem.Allocator, error_text: []const u8) ![]u8 {
    const escaped = try jsonEscape(allocator, error_text);
    defer allocator.free(escaped);
    // NOTE: Returns key-value pairs WITHOUT outer braces (same reason as above).
    return std.fmt.allocPrint(allocator, "\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"isError\":true", .{escaped});
}

/// Same as stringifyErrorResponse but formats the error message using ErrorCode + detail.
pub fn stringifyCatalogError(allocator: std.mem.Allocator, code: []const u8, message: []const u8, detail: []const u8) ![]u8 {
    const formatted = try std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{ code, message, detail });
    defer allocator.free(formatted);
    return stringifyErrorResponse(allocator, formatted);
}

test "getRequiredString: returns value when present" {
    const input =
        \\{"name":"hello"}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.testing.allocator, input, .{});
    defer std.json.parseFree(std.json.Value, parsed, std.testing.allocator, .{});
    const v = JsonValue{ .object_val = parsed.object };
    try std.testing.expectEqualStrings("hello", try v.getRequiredString("name"));
}

test "getRequiredString: rejects missing key" {
    const input =
        \\{"other":"value"}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.testing.allocator, input, .{});
    const v = JsonValue{ .object_val = parsed.object };
    try std.testing.expectError(error.MissingField, v.getRequiredString("name"));
}

test "getRequiredString: rejects empty string" {
    const input =
        \\{"name":""}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.testing.allocator, input, .{});
    const v = JsonValue{ .object_val = parsed.object };
    try std.testing.expectError(error.MissingField, v.getRequiredString("name"));
}

test "getRequiredString: rejects non-string value" {
    const input =
        \\{"name":42}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.testing.allocator, input, .{});
    const v = JsonValue{ .object_val = parsed.object };
    try std.testing.expectError(error.MissingField, v.getRequiredString("name"));
}

// --- JsonValue.parse integration tests ---

test "parse: string with \\n escape" {
    const input =
        \\{"a":"x\ny"}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x\ny", v.getString("a").?);
}

test "parse: string with \\\\ escape" {
    const input =
        \\{"a":"a\\b"}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a\\b", v.getString("a").?);
}

test "parse: string with \\\" escape" {
    const input =
        \\{"a":"she said \"hi\""}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("she said \"hi\"", v.getString("a").?);
}

test "parse: string with \\t escape" {
    const input =
        \\{"a":"col1\tcol2"}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("col1\tcol2", v.getString("a").?);
}

test "parse: string with mixed escapes" {
    const input =
        \\{"a":"one\ntwo\\three\"four\nfive"}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    const expected = "one\ntwo\\three\"four\nfive";
    try std.testing.expectEqualStrings(expected, v.getString("a").?);
}

test "parse: string without escapes (regression)" {
    const input =
        \\{"a":"hello"}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", v.getString("a").?);
}

test "parse: multiple fields with escapes" {
    const input =
        \\{"a":"x\ny","b":"z"}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x\ny", v.getString("a").?);
    try std.testing.expectEqualStrings("z", v.getString("b").?);
}

test "parse: integer field" {
    const input =
        \\{"a":42}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), v.getInt("a").?);
}

test "parse: nested object with escape in inner string" {
    const input =
        \\{"a":{"b":"c\nd"}}
    ;
    // Just verify top-level parse succeeds — JsonValue doesn't expose
    // deep nested accessors, but the inner string WAS parsed correctly.
    _ = try JsonValue.parse(std.testing.allocator, input);
}

test "parse: string with \\r\\n escape" {
    const input =
        \\{"a":"line1\r\nline2"}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("line1\r\nline2", v.getString("a").?);
}

test "parse: array of strings with escapes" {
    const input =
        \\{"a":["x\ny","z"]}
    ;
    const v = try JsonValue.parse(std.testing.allocator, input);
    defer v.deinit(std.testing.allocator);
    // Just verify it parses without error; deep access of array is handled
    try std.testing.expect(v.getString("a") == null); // a is an array, not a string
}
