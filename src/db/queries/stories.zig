const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");
const lifecycle = @import("../../domain/lifecycle.zig");

pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, epic_id: i64, title: []const u8, description: ?[]const u8, acceptance_criteria: ?[]const u8) !entities.Story {
    var stmt = try conn.prepare("INSERT INTO stories (project_id, epic_id, title, description, acceptance_criteria) VALUES (?, ?, ?, ?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();

    stmt.bindInt64(1, project_id);
    stmt.bindInt64(2, epic_id);
    stmt.bindText(3, title);
    if (description) |d| stmt.bindText(4, d) else stmt.bindNull(4);
    if (acceptance_criteria) |a| stmt.bindText(5, a) else stmt.bindNull(5);
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.Story{
        .id = id,
        .project_id = project_id,
        .epic_id = epic_id,
        .title = try allocator.dupe(u8, title),
        .description = if (description) |d| try allocator.dupe(u8, d) else null,
        .acceptance_criteria = if (acceptance_criteria) |a| try allocator.dupe(u8, a) else null,
        .status = .backlog,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, story_id: i64) !?entities.Story {
    var stmt = try conn.prepare("SELECT id, project_id, epic_id, title, description, acceptance_criteria, status, priority, assignee_agent_id, created_at, updated_at FROM stories WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, story_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;

    return entities.Story{
        .id = id_opt.?,
        .project_id = stmt.columnInt64(1),
        .epic_id = stmt.columnInt64(2),
        .title = try allocator.dupe(u8, stmt.columnText(3).?),
        .description = if (stmt.columnText(4)) |d| try allocator.dupe(u8, d) else null,
        .acceptance_criteria = if (stmt.columnText(5)) |a| try allocator.dupe(u8, a) else null,
        .status = lifecycle.storyStatusFromDb(stmt.columnText(6).?) orelse .backlog,
        .priority = switch (stmt.columnInt64(7)) { 1 => .critical, 2 => .high, 3 => .medium, 4 => .low, else => .medium },
        .assignee_agent_id = stmt.columnInt64Safe(8),
        .created_at = try allocator.dupe(u8, stmt.columnText(9).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(10).?),
    };
}

pub fn listByEpic(conn: *db.Connection, allocator: std.mem.Allocator, epic_id: i64) !std.ArrayList(entities.Story) {
    var results = std.ArrayList(entities.Story).empty;
    var stmt = try conn.prepare("SELECT id, project_id, epic_id, title, description, acceptance_criteria, status, priority, assignee_agent_id, created_at, updated_at FROM stories WHERE epic_id = ? ORDER BY priority, created_at");
    defer stmt.finalize();
    stmt.bindInt64(1, epic_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        try results.append(allocator, entities.Story{
            .id = id_opt.?,
            .project_id = stmt.columnInt64(1),
            .epic_id = stmt.columnInt64(2),
            .title = try allocator.dupe(u8, stmt.columnText(3).?),
            .description = if (stmt.columnText(4)) |d| try allocator.dupe(u8, d) else null,
            .acceptance_criteria = if (stmt.columnText(5)) |a| try allocator.dupe(u8, a) else null,
            .status = lifecycle.storyStatusFromDb(stmt.columnText(6).?) orelse .backlog,
            .priority = switch (stmt.columnInt64(7)) { 1 => .critical, 2 => .high, 3 => .medium, 4 => .low, else => .medium },
            .assignee_agent_id = stmt.columnInt64Safe(8),
            .created_at = try allocator.dupe(u8, stmt.columnText(9).?),
            .updated_at = try allocator.dupe(u8, stmt.columnText(10).?),
        });
    }
    return results;
}

pub fn updateStatus(conn: *db.Connection, story_id: i64, status: lifecycle.StoryStatus) !void {
    var stmt = try conn.prepare("UPDATE stories SET status = ?, updated_at = datetime('now') WHERE id = ?");
    defer stmt.finalize();
    stmt.bindText(1, lifecycle.storyStatusToDb(status));
    stmt.bindInt64(2, story_id);
    _ = try stmt.step();
}

pub fn delete(conn: *db.Connection, story_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM stories WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, story_id);
    _ = try stmt.step();
}

/// PATCH update for stories — only the provided fields are written. A null
/// argument means "leave unchanged". Empty strings are NOT allowed: callers
/// must validate content (validation.validate*Opt) before calling this.
/// Always bumps `updated_at` to now so consumers can detect any change.
pub fn updatePartial(conn: *db.Connection, allocator: std.mem.Allocator, story_id: i64, title: ?[]const u8, description: ?[]const u8, acceptance_criteria: ?[]const u8) !void {
    if (title == null and description == null and acceptance_criteria == null) {
        return error.NoFieldsToUpdate;
    }
    var sql_buf = std.array_list.Managed(u8).init(allocator);
    defer sql_buf.deinit();
    try sql_buf.appendSlice("UPDATE stories SET updated_at = datetime('now')");
    if (title != null) try sql_buf.appendSlice(", title = ?");
    if (description != null) try sql_buf.appendSlice(", description = ?");
    if (acceptance_criteria != null) try sql_buf.appendSlice(", acceptance_criteria = ?");
    try sql_buf.appendSlice(" WHERE id = ?");

    var stmt = try conn.prepare(sql_buf.items);
    defer stmt.finalize();
    var idx: usize = 1;
    if (title) |t| {
        stmt.bindText(@intCast(idx), t);
        idx += 1;
    }
    if (description) |d| {
        stmt.bindText(@intCast(idx), d);
        idx += 1;
    }
    if (acceptance_criteria) |a| {
        stmt.bindText(@intCast(idx), a);
        idx += 1;
    }
    stmt.bindInt64(@intCast(idx), story_id);
    _ = try stmt.step();
}

const testing = std.testing;
const test_helpers = @import("../test_helpers.zig");

test "updatePartial: rejects when all fields are null" {
    const allocator = testing.allocator;
    const db_path = ":memory:";
    var conn = try db.Connection.init(db_path);
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);
    const epic_id = try test_helpers.seedSimpleEpic(&conn, project_id);
    const story_id = try test_helpers.seedSimpleStory(&conn, project_id, epic_id);

    try testing.expectError(error.NoFieldsToUpdate, updatePartial(&conn, allocator, story_id, null, null, null));
}

test "updatePartial: only updates the provided fields" {
    const allocator = testing.allocator;
    const db_path = ":memory:";
    var conn = try db.Connection.init(db_path);
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);
    const epic_id = try test_helpers.seedSimpleEpic(&conn, project_id);
    const story_id = try test_helpers.seedSimpleStory(&conn, project_id, epic_id);

    // Update only the title — description and AC should be preserved.
    try updatePartial(&conn, allocator, story_id, "new title with content", null, null);

    var stmt = try conn.prepare("SELECT title, description, acceptance_criteria FROM stories WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, story_id);
    _ = try stmt.step();
    try testing.expectEqualStrings("new title with content", stmt.columnText(0).?);
    try testing.expectEqualStrings("Sample description with enough content", stmt.columnText(1).?);
    try testing.expectEqualStrings("Sample AC with enough content", stmt.columnText(2).?);
}

test "updatePartial: updates all three fields when provided" {
    const allocator = testing.allocator;
    const db_path = ":memory:";
    var conn = try db.Connection.init(db_path);
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);
    const epic_id = try test_helpers.seedSimpleEpic(&conn, project_id);
    const story_id = try test_helpers.seedSimpleStory(&conn, project_id, epic_id);

    try updatePartial(&conn, allocator, story_id, "new title for story", "brand new description text", "brand new AC content");

    var stmt = try conn.prepare("SELECT title, description, acceptance_criteria FROM stories WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, story_id);
    _ = try stmt.step();
    try testing.expectEqualStrings("new title for story", stmt.columnText(0).?);
    try testing.expectEqualStrings("brand new description text", stmt.columnText(1).?);
    try testing.expectEqualStrings("brand new AC content", stmt.columnText(2).?);
}
