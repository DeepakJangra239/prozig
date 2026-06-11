const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");

/// Insert a new project
pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, name: []const u8, root_path: []const u8, description: ?[]const u8) !entities.Project {
    const sql = "INSERT INTO projects (name, root_path, description) VALUES (?, ?, ?) RETURNING id, created_at, updated_at";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();

    stmt.bindText(1, name);
    stmt.bindText(2, root_path);
    if (description) |desc| {
        stmt.bindText(3, desc);
    } else {
        stmt.bindNull(3);
    }
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.Project{
        .id = id,
        .name = try allocator.dupe(u8, name),
        .root_path = try allocator.dupe(u8, root_path),
        .description = if (description) |d| try allocator.dupe(u8, d) else null,
        .metadata = null,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

/// Get a project by ID
pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64) !?entities.Project {
    const sql = "SELECT id, name, root_path, description, metadata, created_at, updated_at FROM projects WHERE id = ?";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();

    stmt.bindInt64(1, project_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;
    const name = stmt.columnText(1) orelse return null;
    const root_path = stmt.columnText(2) orelse return null;
    const description = stmt.columnText(3);
    const metadata = stmt.columnText(4);
    const created_at = stmt.columnText(5) orelse return null;
    const updated_at = stmt.columnText(6) orelse return null;

    return entities.Project{
        .id = id_opt.?,
        .name = try allocator.dupe(u8, name),
        .root_path = try allocator.dupe(u8, root_path),
        .description = if (description) |d| try allocator.dupe(u8, d) else null,
        .metadata = if (metadata) |m| try allocator.dupe(u8, m) else null,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

/// List all projects
pub fn listAll(conn: *db.Connection, allocator: std.mem.Allocator) !std.ArrayList(entities.Project) {
    var results = std.ArrayList(entities.Project).empty;

    const sql = "SELECT id, name, root_path, description, metadata, created_at, updated_at FROM projects ORDER BY created_at DESC";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;

        const name = stmt.columnText(1).?;
        const root_path = stmt.columnText(2).?;
        const description = stmt.columnText(3);
        const metadata = stmt.columnText(4);
        const created_at = stmt.columnText(5).?;
        const updated_at = stmt.columnText(6).?;

        try results.append(allocator, entities.Project{
            .id = id_opt.?,
            .name = try allocator.dupe(u8, name),
            .root_path = try allocator.dupe(u8, root_path),
            .description = if (description) |d| try allocator.dupe(u8, d) else null,
            .metadata = if (metadata) |m| try allocator.dupe(u8, m) else null,
            .created_at = try allocator.dupe(u8, created_at),
            .updated_at = try allocator.dupe(u8, updated_at),
        });
    }

    return results;
}

/// Update a project
pub fn update(conn: *db.Connection, project_id: i64, name: ?[]const u8, description: ?[]const u8) !void {
    var stmt = try conn.prepare("UPDATE projects SET updated_at = datetime('now') WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    _ = try stmt.step();

    if (name) |n| {
        var s = try conn.prepare("UPDATE projects SET name = ? WHERE id = ?");
        defer s.finalize();
        s.bindText(1, n);
        s.bindInt64(2, project_id);
        _ = try s.step();
    }

    if (description) |d| {
        var s = try conn.prepare("UPDATE projects SET description = ? WHERE id = ?");
        defer s.finalize();
        s.bindText(1, d);
        s.bindInt64(2, project_id);
        _ = try s.step();
    }
}

/// Delete a project and all its data
pub fn delete(conn: *db.Connection, project_id: i64) !void {
    // Delete in reverse dependency order
    {
        var stmt = try conn.prepare("DELETE FROM subtasks WHERE task_id IN (SELECT id FROM tasks WHERE story_id IN (SELECT id FROM stories WHERE epic_id IN (SELECT id FROM epics WHERE project_id = ?)))");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
    {
        var stmt = try conn.prepare("DELETE FROM tasks WHERE story_id IN (SELECT id FROM stories WHERE epic_id IN (SELECT id FROM epics WHERE project_id = ?))");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
    {
        var stmt = try conn.prepare("DELETE FROM wiki_history WHERE page_id IN (SELECT id FROM wiki_pages WHERE project_id = ?)");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
    {
        var stmt = try conn.prepare("DELETE FROM wiki_pages WHERE project_id = ?");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
    {
        var stmt = try conn.prepare("DELETE FROM stories WHERE epic_id IN (SELECT id FROM epics WHERE project_id = ?)");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
    {
        var stmt = try conn.prepare("DELETE FROM epics WHERE project_id = ?");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
    {
        var stmt = try conn.prepare("DELETE FROM dependencies WHERE project_id = ?");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
    {
        var stmt = try conn.prepare("DELETE FROM projects WHERE id = ?");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        _ = try stmt.step();
    }
}

// ── Tests ──

test "insert: returns project with RETURNING timestamps" {
    var conn = try db.Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    const project = try insert(&conn, std.testing.allocator, "Test Project", "/tmp/test", null);
    defer entities.freeProject(std.testing.allocator, project);

    try std.testing.expect(project.id > 0);
    try std.testing.expectEqualStrings("Test Project", project.name);
    try std.testing.expect(project.created_at.len > 0);
    try std.testing.expect(project.updated_at.len > 0);
    try std.testing.expect(!std.mem.eql(u8, project.created_at, "unknown"));
}

test "getById: returns project when found" {
    var conn = try db.Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    const inserted = try insert(&conn, std.testing.allocator, "Find Me", "/tmp/find", null);
    defer entities.freeProject(std.testing.allocator, inserted);

    const found = try getById(&conn, std.testing.allocator, inserted.id);
    try std.testing.expect(found != null);
    if (found) |p| {
        defer entities.freeProject(std.testing.allocator, p);
        try std.testing.expectEqual(inserted.id, p.id);
        try std.testing.expectEqualStrings("Find Me", p.name);
    }
}

test "getById: returns null for missing project" {
    var conn = try db.Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    const found = try getById(&conn, std.testing.allocator, 999999);
    try std.testing.expect(found == null);
}

test "listAll: returns inserted projects" {
    var conn = try db.Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    const p1 = try insert(&conn, std.testing.allocator, "A", "/tmp/a", null);
    defer entities.freeProject(std.testing.allocator, p1);
    const p2 = try insert(&conn, std.testing.allocator, "B", "/tmp/b", null);
    defer entities.freeProject(std.testing.allocator, p2);

    var list = try listAll(&conn, std.testing.allocator);
    defer {
        for (list.items) |p| entities.freeProject(std.testing.allocator, p);
        list.deinit(std.testing.allocator);
    }
    try std.testing.expect(list.items.len >= 2);
}

test "delete: cascade deletes all child data" {
    var conn = try db.Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    // Insert project
    const project = try insert(&conn, std.testing.allocator, "Cascade Test", "/tmp/cascade", null);
    defer entities.freeProject(std.testing.allocator, project);

    // Insert epic (omit id, let SQLite auto-increment)
    var stmt = try conn.prepare("INSERT INTO epics (project_id, title) VALUES (?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();
    stmt.bindInt64(1, project.id);
    stmt.bindText(2, "Test Epic");
    _ = try stmt.step();
    const epic_id = stmt.columnInt64(0);

    // Insert story
    var s2 = try conn.prepare("INSERT INTO stories (project_id, epic_id, title) VALUES (?, ?, ?) RETURNING id, created_at, updated_at");
    defer s2.finalize();
    s2.bindInt64(1, project.id);
    s2.bindInt64(2, epic_id);
    s2.bindText(3, "Test Story");
    _ = try s2.step();

    // Verify data exists before delete
    var check = try conn.prepare("SELECT COUNT(*) FROM epics WHERE project_id = ?");
    defer check.finalize();
    check.bindInt64(1, project.id);
    _ = try check.step();
    try std.testing.expect(check.columnInt64(0) > 0);

    // Delete project
    try delete(&conn, project.id);

    // Verify cascade: epics gone
    var check2 = try conn.prepare("SELECT COUNT(*) FROM epics WHERE project_id = ?");
    defer check2.finalize();
    check2.bindInt64(1, project.id);
    _ = try check2.step();
    try std.testing.expectEqual(@as(i64, 0), check2.columnInt64(0));

    // Verify cascade: stories gone
    var check3 = try conn.prepare("SELECT COUNT(*) FROM stories WHERE project_id = ?");
    defer check3.finalize();
    check3.bindInt64(1, project.id);
    _ = try check3.step();
    try std.testing.expectEqual(@as(i64, 0), check3.columnInt64(0));

    // Verify project itself is gone
    const found = try getById(&conn, std.testing.allocator, project.id);
    try std.testing.expect(found == null);
}
