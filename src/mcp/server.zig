const std = @import("std");
const db = @import("../db/connection.zig");
const svc = @import("../service/root.zig");
const Server = @import("types.zig").Server;
const json = @import("json.zig");

/// Run the MCP server over stdio.
///
/// Uses raw `std.c.read` / `std.c.write` syscalls instead of Zig's I/O
/// abstraction layer to avoid a buffered-reader mode-detection bug that
/// hangs when stdin is a pipe that stays open (subprocess mode).
pub fn run(conn: *db.Connection, io: std.Io) !void {
    _ = io; // Unused — raw syscalls below.
    var service = svc.init(conn);
    var server = Server{ .conn = conn, .service = &service, .allocator = std.heap.page_allocator };

    var buf: [65536]u8 = undefined;
    var buf_len: usize = 0;

    const stdin_fd: std.c.fd_t = 0;
    const stdout_fd: std.c.fd_t = 1;

    while (true) {
        // Read raw bytes from stdin. Blocks until data available,
        // then returns whatever the kernel has available (short read).
        const raw_n = std.c.read(stdin_fd, buf[buf_len..].ptr, buf.len - buf_len);
        if (raw_n <= 0) break; // EOF or error
        buf_len += @as(usize, @intCast(raw_n));

        // Find complete JSON messages by tracking brace depth across the
        // buffer. This handles messages whose string values contain newlines
        // (e.g. multi-line acceptance_criteria), which line-splitting would
        // break into fragments.
        var consumed: usize = 0;
        while (consumed < buf_len) {
            const msg_end = findCompleteJson(buf[consumed..buf_len]) orelse break;
            const line = buf[consumed .. consumed + msg_end];
            consumed += msg_end;

            // Skip trailing newlines / whitespace after the message.
            while (consumed < buf_len and (buf[consumed] == '\n' or buf[consumed] == '\r')) {
                consumed += 1;
            }

            if (line.len == 0) continue;

            const response = server.handleMessage(line) catch |err| {
                std.log.err("Error: {s}\n", .{@errorName(err)});
                // Send a JSON-RPC error response so the client doesn't timeout
                const id_str = extractRequestId(line);
                const err_msg = std.fmt.allocPrint(server.allocator, "Internal error: {s}", .{@errorName(err)}) catch "Internal error";
                const err_resp = makeErrorResponse(server.allocator, id_str, -32603, err_msg) catch null;
                server.allocator.free(err_msg);
                if (err_resp) |resp| {
                    _ = std.c.write(stdout_fd, resp.ptr, resp.len);
                    _ = std.c.write(stdout_fd, "\n", 1);
                    server.allocator.free(resp);
                }
                continue;
            };
            if (response) |resp| {
                _ = std.c.write(stdout_fd, resp.ptr, resp.len);
                _ = std.c.write(stdout_fd, "\n", 1);
                server.allocator.free(resp);
            }
        }

        // Shift any remaining partial data to the front of the buffer.
        const remaining = buf_len - consumed;
        if (remaining > 0) {
            @memcpy(buf[0..remaining], buf[consumed..buf_len]);
        }
        buf_len = remaining;

        // Guard against buffer overflow on very large messages.
        if (buf_len >= buf.len) {
            std.log.warn("MCP message too large (>{d} bytes), discarding partial data\n", .{buf.len});
            buf_len = 0;
        }
    }
}

/// Extract the "id" field from a JSON-RPC request string.
fn extractRequestId(raw: []const u8) ?[]const u8 {
    const key = "\"id\"";
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return null;
    const after_key = raw[key_pos + key.len..];
    const colon_pos = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var start = colon_pos + 1;
    while (start < after_key.len and (after_key[start] == ' ' or after_key[start] == '\t')) {
        start += 1;
    }
    if (start >= after_key.len) return null;
    const first = after_key[start];
    if (first == '"') {
        var i = start + 1;
        while (i < after_key.len) {
            if (after_key[i] == '\\') { if (i + 1 < after_key.len) i += 1; i += 1; continue; }
            if (after_key[i] == '"') return after_key[start .. i + 1];
            i += 1;
        }
        return null;
    }
    if (first == 'n') {
        if (start + 4 <= after_key.len and std.mem.eql(u8, after_key[start..start+4], "null")) {
            return after_key[start..start+4];
        }
        return null;
    }
    if (first == '-' or (first >= '0' and first <= '9')) {
        var i = start;
        while (i < after_key.len) {
            const c = after_key[i];
            if (c == ',' or c == '}' or c == ' ' or c == '\n' or c == '\t' or c == '\r') break;
            i += 1;
        }
        return after_key[start..i];
    }
    return null;
}

/// Create a JSON-RPC error response.
fn makeErrorResponse(alloc: std.mem.Allocator, id: ?[]const u8, code: i32, message: []const u8) ![]u8 {
    const id_str = id orelse "null";
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id_str, code, message });
}

/// Find the first complete JSON object in `data` by tracking brace depth,
/// skipping over string contents and escape sequences.
/// Returns the byte length of the complete JSON object, or `null` if none found.
fn findCompleteJson(data: []const u8) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var escaped = false;
    var started = false;

    for (data, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and in_str) {
            escaped = true;
            continue;
        }
        if (c == '"' and !escaped) {
            in_str = !in_str;
            continue;
        }
        if (!in_str) {
            if (c == '{') {
                depth += 1;
                started = true;
            } else if (c == '}') {
                depth -= 1;
                if (started and depth == 0) {
                    return i + 1; // length of complete JSON
                }
            }
        }
    }
    return null;
}
