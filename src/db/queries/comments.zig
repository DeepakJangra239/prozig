/// Comments query module — stores user/agent comments on any trackable entity.
/// Comments are scoped to an entity (epic, story, task, subtask, bug, wiki)
/// and include a denormalized author_name so reads don't require a JOIN.
const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");

/// Insert a new comment. Returns the inserted comment with id/timestamps populated.
pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, entity_type: []const u8, entity_id: i64, author_type: []const u8, author_id: ?i64, author_name: []const u8, content: []const u8) !entities.Comment {
    var stmt = try conn.prepare("INSERT INTO comments (project_id, entity_type, entity_id, author_type, author_id, author_name, content) VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();

    stmt.bindInt64(1, project_id);
    stmt.bindText(2, entity_type);
    stmt.bindInt64(3, entity_id);
    stmt.bindText(4, author_type);
    if (author_id) |aid| stmt.bindInt64(5, aid) else stmt.bindNull(5);
    stmt.bindText(6, author_name);
    stmt.bindText(7, content);
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.Comment{
        .id = id,
        .project_id = project_id,
        .entity_type = try allocator.dupe(u8, entity_type),
        .entity_id = entity_id,
        .author_type = try allocator.dupe(u8, author_type),
        .author_id = author_id,
        .author_name = try allocator.dupe(u8, author_name),
        .content = try allocator.dupe(u8, content),
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

/// Get a single comment by id. Returns null if not found.
pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, comment_id: i64) !?entities.Comment {
    var stmt = try conn.prepare("SELECT id, project_id, entity_type, entity_id, author_type, author_id, author_name, content, created_at, updated_at FROM comments WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, comment_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;
    return try rowToComment(allocator, &stmt, id_opt.?);
}

/// List all comments for a specific entity, ordered by created_at ascending (chronological).
/// This is the read path used by both MCP `entity_get` and the dashboard detail view.
pub fn listByEntity(conn: *db.Connection, allocator: std.mem.Allocator, entity_type: []const u8, entity_id: i64) !std.ArrayList(entities.Comment) {
    var results = std.ArrayList(entities.Comment).empty;
    var stmt = try conn.prepare("SELECT id, project_id, entity_type, entity_id, author_type, author_id, author_name, content, created_at, updated_at FROM comments WHERE entity_type = ? AND entity_id = ? ORDER BY created_at ASC");
    defer stmt.finalize();
    stmt.bindText(1, entity_type);
    stmt.bindInt64(2, entity_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        const c = try rowToComment(allocator, &stmt, id_opt.?);
        try results.append(allocator, c);
    }
    return results;
}

/// Update a comment's content. Always bumps `updated_at`. Caller is responsible
/// for authorization (e.g., verifying the caller is the author of the comment).
pub fn updateContent(conn: *db.Connection, comment_id: i64, content: []const u8) !void {
    var stmt = try conn.prepare("UPDATE comments SET content = ?, updated_at = datetime('now') WHERE id = ?");
    defer stmt.finalize();
    stmt.bindText(1, content);
    stmt.bindInt64(2, comment_id);
    _ = try stmt.step();
}

/// Hard-delete a comment. Authorization is the caller's responsibility.
pub fn delete(conn: *db.Connection, comment_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM comments WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, comment_id);
    _ = try stmt.step();
}

/// Format comments for a given entity as a human-readable string suitable for
/// appending to an MCP tool response. Returns null if there are no comments.
/// The caller must free the returned string.
/// Format: "\n\nComments (N):\n  [agent] Name @ time: content\n  ..."
pub fn formatCommentsForResponse(allocator: std.mem.Allocator, conn: *db.Connection, entity_type: []const u8, entity_id: i64) !?[]u8 {
    var comments = try listByEntity(conn, allocator, entity_type, entity_id);
    defer {
        for (comments.items) |c| entities.freeComment(allocator, c);
        comments.deinit(allocator);
    }
    if (comments.items.len == 0) return null;

    var buf = std.array_list.Managed(u8).init(allocator);
    try buf.appendSlice("\n\nComments (");
    try buf.appendSlice(try std.fmt.allocPrint(allocator, "{d}", .{comments.items.len}));
    try buf.appendSlice("):");
    for (comments.items) |c| {
        const line = try std.fmt.allocPrint(allocator, "\n  [{s}] {s} @ {s}: {s}", .{ c.author_type, c.author_name, c.created_at, c.content });
        try buf.appendSlice(line);
        allocator.free(line);
    }
    return buf.toOwnedSlice() catch return error.OutOfMemory;
}

fn rowToComment(allocator: std.mem.Allocator, stmt: *db.PreparedStmt, id: i64) !entities.Comment {
    const author_id_val = stmt.columnInt64Safe(5);
    const author_name_str = stmt.columnText(6) orelse "";
    return entities.Comment{
        .id = id,
        .project_id = stmt.columnInt64(1),
        .entity_type = try allocator.dupe(u8, stmt.columnText(2).?),
        .entity_id = stmt.columnInt64(3),
        .author_type = try allocator.dupe(u8, stmt.columnText(4).?),
        .author_id = author_id_val,
        .author_name = try allocator.dupe(u8, author_name_str),
        .content = try allocator.dupe(u8, stmt.columnText(7).?),
        .created_at = try allocator.dupe(u8, stmt.columnText(8).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(9).?),
    };
}

const testing = std.testing;
const test_helpers = @import("../test_helpers.zig");

test "comments: insert and getById round-trip" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);
    const epic_id = try test_helpers.seedSimpleEpic(&conn, project_id);

    const inserted = try insert(&conn, allocator, project_id, "epic", epic_id, "agent", null, "Test Agent", "This is a useful comment about the epic");
    defer entities.freeComment(allocator, inserted);

    const fetched = (try getById(&conn, allocator, inserted.id)).?;
    defer entities.freeComment(allocator, fetched);

    try testing.expectEqual(inserted.id, fetched.id);
    try testing.expectEqualStrings("epic", fetched.entity_type);
    try testing.expectEqualStrings("agent", fetched.author_type);
    try testing.expectEqualStrings("Test Agent", fetched.author_name);
    try testing.expectEqualStrings("This is a useful comment about the epic", fetched.content);
}

test "comments: listByEntity returns in chronological order" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);
    const epic_id = try test_helpers.seedSimpleEpic(&conn, project_id);

    const c1 = try insert(&conn, allocator, project_id, "epic", epic_id, "agent", null, "Agent A", "First comment in the thread");
    defer entities.freeComment(allocator, c1);
    const c2 = try insert(&conn, allocator, project_id, "epic", epic_id, "human", null, "Admin", "Second comment as a human");
    defer entities.freeComment(allocator, c2);

    var list = try listByEntity(&conn, allocator, "epic", epic_id);
    defer {
        for (list.items) |c| entities.freeComment(allocator, c);
        list.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("First comment in the thread", list.items[0].content);
    try testing.expectEqualStrings("Second comment as a human", list.items[1].content);
    try testing.expectEqualStrings("human", list.items[1].author_type);
}

test "comments: updateContent and delete" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);
    const epic_id = try test_helpers.seedSimpleEpic(&conn, project_id);

    const c = try insert(&conn, allocator, project_id, "epic", epic_id, "agent", null, "Agent A", "Original content of comment");
    defer entities.freeComment(allocator, c);

    try updateContent(&conn, c.id, "Edited content of comment");

    const fetched = (try getById(&conn, allocator, c.id)).?;
    defer entities.freeComment(allocator, fetched);
    try testing.expectEqualStrings("Edited content of comment", fetched.content);

    try delete(&conn, c.id);
    try testing.expect(try getById(&conn, allocator, c.id) == null);
}
