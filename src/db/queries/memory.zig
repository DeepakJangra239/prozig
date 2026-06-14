/// Memory query module — CRUD, BM25 search, composable filters, time-decay re-ranking.
const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");
const lifecycle = @import("../../domain/lifecycle.zig");

/// Composable filter for memory retrieval
pub const MemoryFilter = struct {
    project_id: i64,
    role_name: ?[]const u8 = null,
    scope: ?lifecycle.MemoryScope = null,
    entity_id: ?i64 = null,
    category: ?lifecycle.MemoryCategory = null,
    query: ?[]const u8 = null,
    limit: usize = 5,
};

/// Insert a new memory entry. Returns the inserted entry with id/timestamps populated.
pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, role_name: ?[]const u8, scope: lifecycle.MemoryScope, entity_id: ?i64, category: lifecycle.MemoryCategory, title: []const u8, content: []const u8, summary: ?[]const u8, tags: ?[]const u8, importance: lifecycle.MemoryImportance) !entities.MemoryEntry {
    var stmt = try conn.prepare("INSERT INTO agent_memory (project_id, role_name, scope, entity_id, category, title, content, summary, tags, importance) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();

    stmt.bindInt64(1, project_id);
    if (role_name) |r| stmt.bindText(2, r) else stmt.bindNull(2);
    stmt.bindText(3, lifecycle.memoryScopeToDb(scope));
    if (entity_id) |eid| stmt.bindInt64(4, eid) else stmt.bindNull(4);
    stmt.bindText(5, lifecycle.memoryCategoryToDb(category));
    stmt.bindText(6, title);
    stmt.bindText(7, content);
    if (summary) |s| stmt.bindText(8, s) else stmt.bindNull(8);
    if (tags) |t| stmt.bindText(9, t) else stmt.bindNull(9);
    stmt.bindInt64(10, @intCast(lifecycle.memoryImportanceToDb(importance)));
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.MemoryEntry{
        .id = id,
        .project_id = project_id,
        .role_name = if (role_name) |r| try allocator.dupe(u8, r) else null,
        .scope = try allocator.dupe(u8, lifecycle.memoryScopeToDb(scope)),
        .entity_id = entity_id,
        .category = try allocator.dupe(u8, lifecycle.memoryCategoryToDb(category)),
        .title = try allocator.dupe(u8, title),
        .content = try allocator.dupe(u8, content),
        .summary = if (summary) |s| try allocator.dupe(u8, s) else null,
        .tags = if (tags) |t| try allocator.dupe(u8, t) else null,
        .importance = lifecycle.memoryImportanceToDb(importance),
        .access_count = 0,
        .last_accessed_at = null,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

/// Get a single memory by id. Returns null if not found.
pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, memory_id: i64) !?entities.MemoryEntry {
    var stmt = try conn.prepare("SELECT id, project_id, role_name, scope, entity_id, category, title, content, summary, tags, importance, access_count, last_accessed_at, created_at, updated_at FROM agent_memory WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, memory_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;
    return try rowToMemoryEntry(allocator, &stmt, id_opt.?);
}

/// List all memories for a project, ordered by importance desc, created_at desc.
pub fn listByProject(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64) !std.ArrayList(entities.MemoryEntry) {
    var results = std.ArrayList(entities.MemoryEntry).empty;
    var stmt = try conn.prepare("SELECT id, project_id, role_name, scope, entity_id, category, title, content, summary, tags, importance, access_count, last_accessed_at, created_at, updated_at FROM agent_memory WHERE project_id = ? ORDER BY importance DESC, created_at DESC");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        const m = try rowToMemoryEntry(allocator, &stmt, id_opt.?);
        try results.append(allocator, m);
    }
    return results;
}

/// List memories for a specific entity (scope + entity_id).
pub fn listByEntity(conn: *db.Connection, allocator: std.mem.Allocator, scope: []const u8, entity_id: i64) !std.ArrayList(entities.MemoryEntry) {
    var results = std.ArrayList(entities.MemoryEntry).empty;
    var stmt = try conn.prepare("SELECT id, project_id, role_name, scope, entity_id, category, title, content, summary, tags, importance, access_count, last_accessed_at, created_at, updated_at FROM agent_memory WHERE scope = ? AND entity_id = ? ORDER BY importance DESC, created_at DESC");
    defer stmt.finalize();
    stmt.bindText(1, scope);
    stmt.bindInt64(2, entity_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        const m = try rowToMemoryEntry(allocator, &stmt, id_opt.?);
        try results.append(allocator, m);
    }
    return results;
}

/// BM25 search via FTS5 with composable filters.
/// Returns results ordered by BM25 rank, limited to filter.limit.
pub fn search(conn: *db.Connection, allocator: std.mem.Allocator, filter: MemoryFilter) !std.ArrayList(entities.MemoryEntry) {
    var results = std.ArrayList(entities.MemoryEntry).empty;

    // Build query with optional filters
    var sql_buf = std.array_list.Managed(u8).init(allocator);
    defer sql_buf.deinit();

    try sql_buf.appendSlice("SELECT m.id, m.project_id, m.role_name, m.scope, m.entity_id, m.category, m.title, m.content, m.summary, m.tags, m.importance, m.access_count, m.last_accessed_at, m.created_at, m.updated_at FROM agent_memory m JOIN agent_memory_fts f ON m.id = f.rowid WHERE m.project_id = ? AND f.agent_memory_fts MATCH ?");

    var idx: usize = 2;
    var where_clauses = std.array_list.Managed([]const u8).init(allocator);
    defer where_clauses.deinit();

    if (filter.role_name) |_| {
        try where_clauses.append("m.role_name = ?");
        idx += 1;
    }
    if (filter.scope) |_| {
        try where_clauses.append("m.scope = ?");
        idx += 1;
    }
    if (filter.entity_id) |_| {
        try where_clauses.append("m.entity_id = ?");
        idx += 1;
    }
    if (filter.category) |_| {
        try where_clauses.append("m.category = ?");
        idx += 1;
    }

    for (where_clauses.items) |clause| {
        try sql_buf.appendSlice(" AND ");
        try sql_buf.appendSlice(clause);
    }

    try sql_buf.appendSlice(" ORDER BY rank LIMIT ?");

    var stmt = try conn.prepare(sql_buf.items);
    defer stmt.finalize();

    stmt.bindInt64(1, filter.project_id);
    stmt.bindText(2, filter.query orelse "");

    if (filter.role_name) |r| stmt.bindText(idx, r);
    if (filter.scope) |s| stmt.bindText(idx, lifecycle.memoryScopeToDb(s));
    if (filter.entity_id) |eid| stmt.bindInt64(idx, eid);
    if (filter.category) |c| stmt.bindText(idx, lifecycle.memoryCategoryToDb(c));
    stmt.bindInt64(idx + 1, @intCast(filter.limit));

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        const m = try rowToMemoryEntry(allocator, &stmt, id_opt.?);
        try results.append(allocator, m);
    }
    return results;
}

/// Update a memory entry with partial fields.
pub fn update(conn: *db.Connection, allocator: std.mem.Allocator, memory_id: i64, title: ?[]const u8, content: ?[]const u8, summary: ?[]const u8, tags: ?[]const u8, importance: ?lifecycle.MemoryImportance) !void {
    if (title == null and content == null and summary == null and tags == null and importance == null) {
        return error.NoFieldsToUpdate;
    }
    var sql_buf = std.array_list.Managed(u8).init(allocator);
    defer sql_buf.deinit();
    try sql_buf.appendSlice("UPDATE agent_memory SET updated_at = datetime('now')");
    if (title != null) try sql_buf.appendSlice(", title = ?");
    if (content != null) try sql_buf.appendSlice(", content = ?");
    if (summary != null) try sql_buf.appendSlice(", summary = ?");
    if (tags != null) try sql_buf.appendSlice(", tags = ?");
    if (importance != null) try sql_buf.appendSlice(", importance = ?");
    try sql_buf.appendSlice(" WHERE id = ?");

    var stmt = try conn.prepare(sql_buf.items);
    defer stmt.finalize();
    var idx: usize = 1;
    if (title) |t| {
        stmt.bindText(@intCast(idx), t);
        idx += 1;
    }
    if (content) |c| {
        stmt.bindText(@intCast(idx), c);
        idx += 1;
    }
    if (summary) |s| {
        stmt.bindText(@intCast(idx), s);
        idx += 1;
    }
    if (tags) |t| {
        stmt.bindText(@intCast(idx), t);
        idx += 1;
    }
    if (importance) |i| {
        stmt.bindInt64(@intCast(idx), @intCast(lifecycle.memoryImportanceToDb(i)));
        idx += 1;
    }
    stmt.bindInt64(@intCast(idx), memory_id);
    _ = try stmt.step();
}

/// Delete a memory entry by id.
pub fn delete(conn: *db.Connection, memory_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM agent_memory WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, memory_id);
    _ = try stmt.step();
}

/// Get memory usage for a project + role.
pub fn getUsage(conn: *db.Connection, project_id: i64, role_name: []const u8) !?struct {
    total_chars: i64,
    entry_count: i64,
    last_consolidated_at: ?[]const u8,
} {
    var stmt = try conn.prepare("SELECT total_chars, entry_count, last_consolidated_at FROM memory_usage WHERE project_id = ? AND role_name = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, role_name);
    const result = try stmt.step();
    if (result != .row) return null;
    return .{
        .total_chars = stmt.columnInt64(0),
        .entry_count = stmt.columnInt64(1),
        .last_consolidated_at = stmt.columnText(2),
    };
}

/// Upsert memory usage tracking for a project + role.
pub fn upsertUsage(conn: *db.Connection, project_id: i64, role_name: []const u8, total_chars: i64, entry_count: i64) !void {
    var stmt = try conn.prepare("INSERT INTO memory_usage (project_id, role_name, total_chars, entry_count) VALUES (?, ?, ?, ?) ON CONFLICT(project_id, role_name) DO UPDATE SET total_chars = excluded.total_chars, entry_count = excluded.entry_count");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, role_name);
    stmt.bindInt64(3, total_chars);
    stmt.bindInt64(4, entry_count);
    _ = try stmt.step();
}

/// Get project summary. Returns null if not found.
pub fn getProjectSummary(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64) !?entities.ProjectSummary {
    var stmt = try conn.prepare("SELECT id, project_id, narrative, bullets, version, updated_at FROM project_summaries WHERE project_id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;
    return entities.ProjectSummary{
        .id = id_opt.?,
        .project_id = stmt.columnInt64(1),
        .narrative = if (stmt.columnText(2)) |n| try allocator.dupe(u8, n) else null,
        .bullets = if (stmt.columnText(3)) |b| try allocator.dupe(u8, b) else null,
        .version = @intCast(stmt.columnInt64(4)),
        .updated_at = try allocator.dupe(u8, stmt.columnText(5).?),
    };
}

/// Upsert project summary (INSERT OR REPLACE).
pub fn upsertProjectSummary(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, narrative: ?[]const u8, bullets: ?[]const u8) !entities.ProjectSummary {
    var stmt = try conn.prepare("INSERT INTO project_summaries (project_id, narrative, bullets, version, updated_at) VALUES (?, ?, ?, COALESCE((SELECT version FROM project_summaries WHERE project_id = ?), 0) + 1, datetime('now')) ON CONFLICT(project_id) DO UPDATE SET narrative = excluded.narrative, bullets = excluded.bullets, version = excluded.version, updated_at = excluded.updated_at RETURNING id, project_id, narrative, bullets, version, updated_at");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    if (narrative) |n| stmt.bindText(2, n) else stmt.bindNull(2);
    if (bullets) |b| stmt.bindText(3, b) else stmt.bindNull(3);
    stmt.bindInt64(4, project_id);
    _ = try stmt.step();

    return entities.ProjectSummary{
        .id = stmt.columnInt64(0),
        .project_id = stmt.columnInt64(1),
        .narrative = if (stmt.columnText(2)) |n| try allocator.dupe(u8, n) else null,
        .bullets = if (stmt.columnText(3)) |b| try allocator.dupe(u8, b) else null,
        .version = @intCast(stmt.columnInt64(4)),
        .updated_at = try allocator.dupe(u8, stmt.columnText(5).?),
    };
}

/// Increment access count and update last_accessed_at for a memory entry.
pub fn incrementAccessCount(conn: *db.Connection, memory_id: i64) !void {
    var stmt = try conn.prepare("UPDATE agent_memory SET access_count = access_count + 1, last_accessed_at = datetime('now') WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, memory_id);
    _ = try stmt.step();
}

/// Format memories for a given entity as a human-readable string suitable for
/// appending to an MCP tool response. Returns null if there are no memories.
/// The caller must free the returned string.
pub fn formatMemoriesForResponse(allocator: std.mem.Allocator, conn: *db.Connection, scope: []const u8, entity_id: i64) !?[]u8 {
    var memories = try listByEntity(conn, allocator, scope, entity_id);
    defer {
        for (memories.items) |m| entities.freeMemoryEntry(allocator, m);
        memories.deinit(allocator);
    }
    if (memories.items.len == 0) return null;

    var buf = std.array_list.Managed(u8).init(allocator);
    try buf.appendSlice("\n\n--- Related Memory ---");
    for (memories.items) |m| {
        const line = try std.fmt.allocPrint(allocator, "\n[{s}] {s} (importance: {d}, {s})", .{ m.category, m.title, m.importance, m.created_at });
        try buf.appendSlice(line);
        allocator.free(line);
        const content_line = try std.fmt.allocPrint(allocator, "{s}", .{m.content});
        try buf.appendSlice(content_line);
        allocator.free(content_line);
    }
    return buf.toOwnedSlice() catch return error.OutOfMemory;
}

/// Format project summary for response injection.
pub fn formatProjectSummaryForResponse(allocator: std.mem.Allocator, conn: *db.Connection, project_id: i64) !?[]u8 {
    const summary = try getProjectSummary(conn, allocator, project_id);
    if (summary == null) return null;
    const s = summary.?;
    defer entities.freeProjectSummary(allocator, s);

    var buf = std.array_list.Managed(u8).init(allocator);
    try buf.appendSlice("\n\n--- Project Summary ---");
    if (s.narrative) |n| {
        try buf.appendSlice("\n");
        try buf.appendSlice(n);
    }
    if (s.bullets) |b| {
        try buf.appendSlice("\n");
        try buf.appendSlice(b);
    }
    return buf.toOwnedSlice() catch return error.OutOfMemory;
}

fn rowToMemoryEntry(allocator: std.mem.Allocator, stmt: *db.PreparedStmt, id: i64) !entities.MemoryEntry {
    return entities.MemoryEntry{
        .id = id,
        .project_id = stmt.columnInt64(1),
        .role_name = if (stmt.columnText(2)) |r| try allocator.dupe(u8, r) else null,
        .scope = try allocator.dupe(u8, stmt.columnText(3).?),
        .entity_id = stmt.columnInt64Safe(4),
        .category = try allocator.dupe(u8, stmt.columnText(5).?),
        .title = try allocator.dupe(u8, stmt.columnText(6).?),
        .content = try allocator.dupe(u8, stmt.columnText(7).?),
        .summary = if (stmt.columnText(8)) |s| try allocator.dupe(u8, s) else null,
        .tags = if (stmt.columnText(9)) |t| try allocator.dupe(u8, t) else null,
        .importance = @as(u3, @truncate(@as(usize, @intCast(stmt.columnInt64(10))))),
        .access_count = stmt.columnInt64(11),
        .last_accessed_at = if (stmt.columnText(12)) |l| try allocator.dupe(u8, l) else null,
        .created_at = try allocator.dupe(u8, stmt.columnText(13).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(14).?),
    };
}

const testing = std.testing;
const test_helpers = @import("../test_helpers.zig");

test "memory: insert and getById round-trip" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    const inserted = try insert(&conn, allocator, project_id, null, .project, null, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", "Valid summary", null, .high);
    defer entities.freeMemoryEntry(allocator, inserted);

    const fetched = (try getById(&conn, allocator, inserted.id)).?;
    defer entities.freeMemoryEntry(allocator, fetched);

    try testing.expectEqual(inserted.id, fetched.id);
    try testing.expectEqualStrings("project", fetched.scope);
    try testing.expectEqualStrings("decision", fetched.category);
    try testing.expectEqual(@as(u2, 3), fetched.importance);
}

test "memory: listByProject returns entries in correct order" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    _ = try insert(&conn, allocator, project_id, null, .project, null, .note, "Low importance memory title here", "This is valid memory content that meets the minimum length requirement for testing", null, null, .low);
    _ = try insert(&conn, allocator, project_id, null, .project, null, .decision, "Critical importance memory title", "This is valid memory content that meets the minimum length requirement for testing", null, null, .critical);

    var list = try listByProject(&conn, allocator, project_id);
    defer {
        for (list.items) |m| entities.freeMemoryEntry(allocator, m);
        list.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(@as(u2, 4), list.items[0].importance); // critical first
}

test "memory: BM25 search returns relevant results" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    _ = try insert(&conn, allocator, project_id, null, .project, null, .decision, "Auth library choice decision", "This is valid memory content about authentication and JWT tokens for testing", null, null, .high);
    _ = try insert(&conn, allocator, project_id, null, .project, null, .note, "Database migration notes here", "This is valid memory content about database migrations for testing", null, null, .medium);

    const filter = MemoryFilter{ .project_id = project_id, .query = "auth", .limit = 5 };
    var results = try search(&conn, allocator, filter);
    defer {
        for (results.items) |m| entities.freeMemoryEntry(allocator, m);
        results.deinit(allocator);
    }

    try testing.expect(results.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results.items[0].title, "Auth") != null);
}

test "memory: update and delete" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    const m = try insert(&conn, allocator, project_id, null, .project, null, .note, "Original memory title here", "This is valid memory content that meets the minimum length requirement for testing", null, null, .low);
    defer entities.freeMemoryEntry(allocator, m);

    try update(&conn, allocator, m.id, "Updated memory title here", null, null, null, null);

    const fetched = (try getById(&conn, allocator, m.id)).?;
    defer entities.freeMemoryEntry(allocator, fetched);
    try testing.expectEqualStrings("Updated memory title here", fetched.title);

    try delete(&conn, m.id);
    try testing.expect(try getById(&conn, allocator, m.id) == null);
}

test "memory: project summary upsert" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    const s1 = try upsertProjectSummary(&conn, allocator, project_id, "Initial project narrative summary", null);
    defer entities.freeProjectSummary(allocator, s1);
    try testing.expectEqual(@as(u32, 1), s1.version);

    const s2 = try upsertProjectSummary(&conn, allocator, project_id, "Updated project narrative summary", null);
    defer entities.freeProjectSummary(allocator, s2);
    try testing.expectEqual(@as(u32, 2), s2.version);
    try testing.expectEqualStrings("Updated project narrative summary", s2.narrative orelse "");
}

test "memory: usage tracking" {
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    try upsertUsage(&conn, project_id, "developer", 1000, 5);

    const usage = (try getUsage(&conn, project_id, "developer")).?;
    try testing.expectEqual(@as(i64, 1000), usage.total_chars);
    try testing.expectEqual(@as(i64, 5), usage.entry_count);
}

test "memory: access count increment" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    const m = try insert(&conn, allocator, project_id, null, .project, null, .note, "Test memory title here", "This is valid memory content that meets the minimum length requirement for testing", null, null, .low);
    defer entities.freeMemoryEntry(allocator, m);

    try incrementAccessCount(&conn, m.id);

    const fetched = (try getById(&conn, allocator, m.id)).?;
    defer entities.freeMemoryEntry(allocator, fetched);
    try testing.expectEqual(@as(i64, 1), fetched.access_count);
    try testing.expect(fetched.last_accessed_at != null);
}
