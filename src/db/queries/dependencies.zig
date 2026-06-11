const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");

pub fn add(conn: *db.Connection, project_id: i64, blocker_type: []const u8, blocker_id: i64, blocked_type: []const u8, blocked_id: i64) !void {
    var stmt = try conn.prepare("INSERT INTO dependencies (project_id, blocker_type, blocker_id, blocked_type, blocked_id) VALUES (?, ?, ?, ?, ?)");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, blocker_type);
    stmt.bindInt64(3, blocker_id);
    stmt.bindText(4, blocked_type);
    stmt.bindInt64(5, blocked_id);
    _ = try stmt.step();
}

pub fn remove(conn: *db.Connection, dep_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM dependencies WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, dep_id);
    _ = try stmt.step();
}

pub fn getBlockers(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, entity_type: []const u8, entity_id: i64) !std.ArrayList(entities.Dependency) {
    var results = std.ArrayList(entities.Dependency).empty;
    var stmt = try conn.prepare("SELECT id, project_id, blocker_type, blocker_id, blocked_type, blocked_id FROM dependencies WHERE project_id = ? AND blocked_type = ? AND blocked_id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, entity_type);
    stmt.bindInt64(3, entity_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        try results.append(allocator, entities.Dependency{
            .id = id_opt.?,
            .project_id = stmt.columnInt64(1),
            .blocker_type = try allocator.dupe(u8, stmt.columnText(2).?),
            .blocker_id = stmt.columnInt64(3),
            .blocked_type = try allocator.dupe(u8, stmt.columnText(4).?),
            .blocked_id = stmt.columnInt64(5),
        });
    }
    return results;
}
