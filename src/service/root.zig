const std = @import("std");
const db = @import("../db/connection.zig");

/// Central service struct holding the database connection.
/// Sub-service modules (transition, project, dashboard, assignment)
/// take a pointer to this struct as their first parameter.
pub const Service = struct {
    conn: *db.Connection,
};

/// Initialize a Service from a database connection.
pub fn init(conn: *db.Connection) Service {
    return Service{ .conn = conn };
}
