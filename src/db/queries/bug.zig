const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");
const lifecycle = @import("../../domain/lifecycle.zig");

pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, title: []const u8, description: ?[]const u8, severity: []const u8, epic_id: ?i64, story_id: ?i64, task_id: ?i64) !entities.Bug {
    var stmt = try conn.prepare("INSERT INTO bugs (project_id, title, description, severity, epic_id, story_id, task_id) VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();

    stmt.bindInt64(1, project_id);
    stmt.bindText(2, title);
    if (description) |d| stmt.bindText(3, d) else stmt.bindNull(3);
    stmt.bindText(4, severity);
    if (epic_id) |e| stmt.bindInt64(5, e) else stmt.bindNull(5);
    if (story_id) |s| stmt.bindInt64(6, s) else stmt.bindNull(6);
    if (task_id) |t| stmt.bindInt64(7, t) else stmt.bindNull(7);
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.Bug{
        .id = id,
        .project_id = project_id,
        .title = try allocator.dupe(u8, title),
        .description = if (description) |d| try allocator.dupe(u8, d) else null,
        .severity = try allocator.dupe(u8, severity),
        .status = .new,
        .epic_id = epic_id,
        .story_id = story_id,
        .task_id = task_id,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, bug_id: i64) !?entities.Bug {
    var stmt = try conn.prepare("SELECT id, project_id, title, description, severity, status, assignee_agent_id, epic_id, story_id, task_id, created_at, updated_at FROM bugs WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, bug_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;

    return entities.Bug{
        .id = id_opt.?,
        .project_id = stmt.columnInt64(1),
        .title = try allocator.dupe(u8, stmt.columnText(2).?),
        .description = if (stmt.columnText(3)) |d| try allocator.dupe(u8, d) else null,
        .severity = try allocator.dupe(u8, stmt.columnText(4).?),
        .status = lifecycle.bugStatusFromDb(stmt.columnText(5).?) orelse .new,
        .assignee_agent_id = stmt.columnInt64Safe(6),
        .epic_id = stmt.columnInt64Safe(7),
        .story_id = stmt.columnInt64Safe(8),
        .task_id = stmt.columnInt64Safe(9),
        .created_at = try allocator.dupe(u8, stmt.columnText(10).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(11).?),
    };
}

pub fn listByProject(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64) !std.ArrayList(entities.Bug) {
    var results = std.ArrayList(entities.Bug).empty;
    var stmt = try conn.prepare("SELECT id, project_id, title, description, severity, status, assignee_agent_id, epic_id, story_id, task_id, created_at, updated_at FROM bugs WHERE project_id = ? ORDER BY created_at DESC");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        try results.append(allocator, entities.Bug{
            .id = id_opt.?,
            .project_id = stmt.columnInt64(1),
            .title = try allocator.dupe(u8, stmt.columnText(2).?),
            .description = if (stmt.columnText(3)) |d| try allocator.dupe(u8, d) else null,
            .severity = try allocator.dupe(u8, stmt.columnText(4).?),
            .status = lifecycle.bugStatusFromDb(stmt.columnText(5).?) orelse .new,
            .assignee_agent_id = stmt.columnInt64Safe(6),
            .epic_id = stmt.columnInt64Safe(7),
            .story_id = stmt.columnInt64Safe(8),
            .task_id = stmt.columnInt64Safe(9),
            .created_at = try allocator.dupe(u8, stmt.columnText(10).?),
            .updated_at = try allocator.dupe(u8, stmt.columnText(11).?),
        });
    }
    return results;
}

pub fn updateStatus(conn: *db.Connection, bug_id: i64, status: lifecycle.BugStatus) !void {
    var stmt = try conn.prepare("UPDATE bugs SET status = ?, updated_at = datetime('now') WHERE id = ?");
    defer stmt.finalize();
    stmt.bindText(1, lifecycle.bugStatusToDb(status));
    stmt.bindInt64(2, bug_id);
    _ = try stmt.step();
}

pub fn setAssignee(conn: *db.Connection, bug_id: i64, agent_id: i64) !void {
    var stmt = try conn.prepare("UPDATE bugs SET assignee_agent_id = ?, updated_at = datetime('now') WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    stmt.bindInt64(2, bug_id);
    _ = try stmt.step();
}

pub fn delete(conn: *db.Connection, bug_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM bugs WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, bug_id);
    _ = try stmt.step();
}

/// PATCH update for bugs — only the provided fields are written. A null
/// argument means "leave unchanged". Empty strings are NOT allowed: callers
/// must validate content (validation.validate*Opt) before calling this.
/// Always bumps `updated_at` to now so consumers can detect any change.
pub fn updatePartial(conn: *db.Connection, allocator: std.mem.Allocator, bug_id: i64, title: ?[]const u8, description: ?[]const u8, severity: ?[]const u8) !void {
    if (title == null and description == null and severity == null) {
        return error.NoFieldsToUpdate;
    }
    var sql_buf = std.array_list.Managed(u8).init(allocator);
    defer sql_buf.deinit();
    try sql_buf.appendSlice("UPDATE bugs SET updated_at = datetime('now')");
    if (title != null) try sql_buf.appendSlice(", title = ?");
    if (description != null) try sql_buf.appendSlice(", description = ?");
    if (severity != null) try sql_buf.appendSlice(", severity = ?");
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
    if (severity) |s| {
        stmt.bindText(@intCast(idx), s);
        idx += 1;
    }
    stmt.bindInt64(@intCast(idx), bug_id);
    _ = try stmt.step();
}
