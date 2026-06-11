/// Shared test fixtures and helpers for prozig tests.
/// Used by both unit tests in the queries layer and any future integration tests.
/// Pattern: tiny functions that create minimal valid records in an in-memory
/// SQLite database. Each helper inserts a single row and returns the new id.
const std = @import("std");
const db = @import("connection.zig");

/// Insert a project with the given name. Returns the new project id.
pub fn seedSimpleProject(conn: *db.Connection) !i64 {
    var stmt = try conn.prepare("INSERT INTO projects (name, root_path) VALUES ('Test Project', '/tmp/test') RETURNING id");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Insert an epic with valid title/description. Returns the new epic id.
pub fn seedSimpleEpic(conn: *db.Connection, project_id: i64) !i64 {
    var stmt = try conn.prepare("INSERT INTO epics (project_id, title, description) VALUES (?, 'Sample Epic', 'Sample description with enough content') RETURNING id");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

/// Insert a story with valid title/description/AC. Returns the new story id.
pub fn seedSimpleStory(conn: *db.Connection, project_id: i64, epic_id: i64) !i64 {
    var stmt = try conn.prepare("INSERT INTO stories (project_id, epic_id, title, description, acceptance_criteria) VALUES (?, ?, 'Sample Story', 'Sample description with enough content', 'Sample AC with enough content') RETURNING id");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindInt64(2, epic_id);
    _ = try stmt.step();
    return stmt.columnInt64(0);
}
