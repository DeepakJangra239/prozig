const std = @import("std");
const Service = @import("root.zig").Service;
const queries = @import("../db/queries/projects.zig");

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
