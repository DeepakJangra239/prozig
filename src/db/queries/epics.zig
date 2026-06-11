const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");
const lifecycle = @import("../../domain/lifecycle.zig");

pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, title: []const u8, description: ?[]const u8, parent_epic_id: ?i64) !entities.Epic {
    var stmt = try conn.prepare("INSERT INTO epics (project_id, title, description, parent_epic_id) VALUES (?, ?, ?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();

    stmt.bindInt64(1, project_id);
    stmt.bindText(2, title);
    if (description) |d| stmt.bindText(3, d) else stmt.bindNull(3);
    if (parent_epic_id) |p| stmt.bindInt64(4, p) else stmt.bindNull(4);
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.Epic{
        .id = id,
        .project_id = project_id,
        .title = try allocator.dupe(u8, title),
        .description = if (description) |d| try allocator.dupe(u8, d) else null,
        .status = .backlog,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, epic_id: i64) !?entities.Epic {
    var stmt = try conn.prepare("SELECT id, project_id, title, description, status, priority, assignee_agent_id, parent_epic_id, created_at, updated_at FROM epics WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, epic_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;

    return entities.Epic{
        .id = id_opt.?,
        .project_id = stmt.columnInt64(1),
        .title = try allocator.dupe(u8, stmt.columnText(2).?),
        .description = if (stmt.columnText(3)) |d| try allocator.dupe(u8, d) else null,
        .status = lifecycle.epicStatusFromDb(stmt.columnText(4).?) orelse .backlog,
        .priority = switch (stmt.columnInt64(5)) { 1 => .critical, 2 => .high, 3 => .medium, 4 => .low, else => .medium },
        .assignee_agent_id = stmt.columnInt64Safe(6),
        .parent_epic_id = stmt.columnInt64Safe(7),
        .created_at = try allocator.dupe(u8, stmt.columnText(8).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(9).?),
    };
}

pub fn listByProject(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64) !std.ArrayList(entities.Epic) {
    var results = std.ArrayList(entities.Epic).empty;
    var stmt = try conn.prepare("SELECT id, project_id, title, description, status, priority, assignee_agent_id, parent_epic_id, created_at, updated_at FROM epics WHERE project_id = ? ORDER BY priority, created_at");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        try results.append(allocator, entities.Epic{
            .id = id_opt.?,
            .project_id = stmt.columnInt64(1),
            .title = try allocator.dupe(u8, stmt.columnText(2).?),
            .description = if (stmt.columnText(3)) |d| try allocator.dupe(u8, d) else null,
            .status = lifecycle.epicStatusFromDb(stmt.columnText(4).?) orelse .backlog,
            .priority = switch (stmt.columnInt64(5)) { 1 => .critical, 2 => .high, 3 => .medium, 4 => .low, else => .medium },
            .assignee_agent_id = stmt.columnInt64Safe(6),
            .parent_epic_id = stmt.columnInt64Safe(7),
            .created_at = try allocator.dupe(u8, stmt.columnText(8).?),
            .updated_at = try allocator.dupe(u8, stmt.columnText(9).?),
        });
    }
    return results;
}

pub fn updateStatus(conn: *db.Connection, epic_id: i64, status: lifecycle.EpicStatus) !void {
    var stmt = try conn.prepare("UPDATE epics SET status = ?, updated_at = datetime('now') WHERE id = ?");
    defer stmt.finalize();
    stmt.bindText(1, lifecycle.epicStatusToDb(status));
    stmt.bindInt64(2, epic_id);
    _ = try stmt.step();
}

pub fn delete(conn: *db.Connection, epic_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM epics WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, epic_id);
    _ = try stmt.step();
}

/// PATCH update for epics — only the provided fields are written. A null
/// argument means "leave unchanged". Empty strings are NOT allowed: callers
/// must validate content (validation.validate*Opt) before calling this.
/// Always bumps `updated_at` to now so consumers can detect any change.
pub fn updatePartial(conn: *db.Connection, allocator: std.mem.Allocator, epic_id: i64, title: ?[]const u8, description: ?[]const u8) !void {
    if (title == null and description == null) {
        return error.NoFieldsToUpdate;
    }
    var sql_buf = std.array_list.Managed(u8).init(allocator);
    defer sql_buf.deinit();
    try sql_buf.appendSlice("UPDATE epics SET updated_at = datetime('now')");
    if (title != null) try sql_buf.appendSlice(", title = ?");
    if (description != null) try sql_buf.appendSlice(", description = ?");
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
    stmt.bindInt64(@intCast(idx), epic_id);
    _ = try stmt.step();
}
