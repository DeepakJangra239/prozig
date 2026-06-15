const std = @import("std");
const Service = @import("root.zig").Service;
const queries = @import("../db/queries/projects.zig");

/// Config entry from project_configs table.
pub const ConfigEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Delete a project and all its child data, wrapped in a transaction.
/// Rolls back on any failure so the DB is never left in a partially-deleted state.
pub fn deleteProject(srv: *Service, project_id: []const u8) !void {
    const conn = srv.conn;

    conn.begin() catch |err| {
        conn.rollback();
        return err;
    };
    errdefer conn.rollback();

    try queries.delete(conn, project_id);

    conn.commit() catch |err| {
        conn.rollback();
        return err;
    };
}

/// Get all config key-value pairs for a project.
pub fn getConfig(srv: *Service, allocator: std.mem.Allocator, project_id: i64) !std.ArrayList(ConfigEntry) {
    var results = std.ArrayList(ConfigEntry).empty;
    var stmt = try srv.conn.prepare("SELECT key, value FROM project_configs WHERE project_id = ? ORDER BY key");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const key = stmt.columnText(0) orelse continue;
        const value = stmt.columnText(1) orelse "";
        try results.append(allocator, ConfigEntry{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        });
    }
    return results;
}

/// Set a config value for a project (upsert).
pub fn setConfig(srv: *Service, project_id: i64, key: []const u8, value: []const u8) !void {
    var stmt = try srv.conn.prepare(
        \\INSERT INTO project_configs (project_id, key, value) VALUES (?, ?, ?)
        \\ON CONFLICT(project_id, key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
    );
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, key);
    stmt.bindText(3, value);
    _ = try stmt.step();
}
