/// Memory service — transactional boundaries, cap enforcement, retrieval with filters.
const std = @import("std");
const db = @import("../db/connection.zig");
const queries = @import("../db/queries/memory.zig");
const entities = @import("../domain/entities.zig");
const lifecycle = @import("../domain/lifecycle.zig");
const validation = @import("../domain/validation.zig");

/// Save a memory entry with transactional boundary (DAT-02).
/// Wraps memory insert + usage tracking in one transaction.
pub fn saveMemory(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, role_name: ?[]const u8, scope: lifecycle.MemoryScope, entity_id: ?i64, category: lifecycle.MemoryCategory, title: []const u8, content: []const u8, summary: ?[]const u8, tags: ?[]const u8, importance: lifecycle.MemoryImportance) !entities.MemoryEntry {
    // 1. Validate input (COD-03)
    try validation.validateMemorySave(project_id, scope, category, title, content, summary, tags, importance);

    // 2. Check cap enforcement (for role-siloed entries)
    if (role_name) |rn| {
        if (std.mem.eql(u8, rn, "shared")) {
            // Shared entries don't count against role cap
        } else {
            const usage = try queries.getUsage(conn, project_id, rn);
            if (usage) |u| {
                const cap = validation.DEFAULT_MEMORY_CAP_BYTES;
                if (u.total_chars + @as(i64, @intCast(content.len)) > @as(i64, @intCast(cap))) {
                    return error.MemoryCapExceeded;
                }
            }
        }
    }

    // 2b. Check for duplicate (title + scope + entity_id)
    if (try isDuplicate(conn, project_id, scope, entity_id, title)) {
        return error.MemoryDuplicate;
    }

    // 3. Begin transaction (conn.begin())
    conn.begin() catch |err| {
        conn.rollback();
        return err;
    };
    errdefer conn.rollback();

    // 4. Insert memory entry
    const entry = try queries.insert(conn, allocator, project_id, role_name, scope, entity_id, category, title, content, summary, tags, importance);

    // 5. Update memory_usage
    if (role_name) |rn| {
        if (!std.mem.eql(u8, rn, "shared")) {
            const usage = try queries.getUsage(conn, project_id, rn);
            const cur_total = if (usage) |u| u.total_chars else 0;
            const cur_count = if (usage) |u| u.entry_count else 0;
            const new_total = cur_total + @as(i64, @intCast(content.len));
            const new_count = cur_count + 1;
            try queries.upsertUsage(conn, project_id, rn, new_total, new_count);
        }
    }

    // 6. Commit transaction (conn.commit())
    conn.commit() catch |err| {
        conn.rollback();
        return err;
    };

    // 7. Return memory entry
    return entry;
}

/// Retrieve memories with composable filters (DAT-01).
/// Applies time-decay re-ranking and updates access counts.
pub fn retrieveMemories(conn: *db.Connection, allocator: std.mem.Allocator, filter: queries.MemoryFilter) !std.ArrayList(entities.MemoryEntry) {
    var results: std.ArrayList(entities.MemoryEntry) = .empty;

    // 1. Build query with composable filters
    if (filter.query) |_| {
        // BM25 search
        results = try queries.search(conn, allocator, filter);
    } else if (filter.entity_id) |eid| {
        // Exact match on scope + entity
        const scope_str = if (filter.scope) |s| lifecycle.memoryScopeToDb(s) else "project";
        results = try queries.listByEntity(conn, allocator, scope_str, eid);
    } else {
        // Fallback: most recent entries by importance desc
        results = try queries.listByProject(conn, allocator, filter.project_id);
        // Trim to limit
        if (results.items.len > filter.limit) {
            results.items = results.items[0..filter.limit];
        }
    }

    // 2. Update access_count (transactional)
    if (results.items.len > 0) {
        conn.begin() catch {};
        errdefer conn.rollback();
        for (results.items) |m| {
            queries.incrementAccessCount(conn, m.id) catch {};
        }
        conn.commit() catch {};
    }

    // 3. Return results
    return results;
}

/// Update project summary.
pub fn updateProjectSummary(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, narrative: ?[]const u8, bullets: ?[]const u8) !entities.ProjectSummary {
    return queries.upsertProjectSummary(conn, allocator, project_id, narrative, bullets);
}

/// Get memory usage for a role.
pub fn getMemoryUsage(conn: *db.Connection, project_id: i64, role_name: []const u8) !?struct {
    total_chars: i64,
    entry_count: i64,
    last_consolidated_at: ?[]const u8,
} {
    return queries.getUsage(conn, project_id, role_name);
}

/// Check if cap exceeded for a role.
pub fn checkCap(conn: *db.Connection, project_id: i64, role_name: []const u8, new_content_len: usize) !bool {
    if (std.mem.eql(u8, role_name, "shared")) return false;
    const usage = try queries.getUsage(conn, project_id, role_name);
    if (usage == null) return false;
    const u = usage.?;
    const cap = validation.DEFAULT_MEMORY_CAP_BYTES;
    return u.total_chars + @as(i64, @intCast(new_content_len)) > @as(i64, @intCast(cap));
}

/// Delete a memory entry and update usage tracking.
pub fn deleteMemory(conn: *db.Connection, allocator: std.mem.Allocator, memory_id: i64) !void {
    // Get the entry before deleting to update usage
    const entry = try queries.getById(conn, allocator, memory_id);
    if (entry == null) return error.NotFound;
    const e = entry.?;
    defer entities.freeMemoryEntry(allocator, e);

    conn.begin() catch |err| {
        conn.rollback();
        return err;
    };
    errdefer conn.rollback();

    try queries.delete(conn, memory_id);

    // Update usage tracking
    if (e.role_name) |rn| {
        if (!std.mem.eql(u8, rn, "shared")) {
            const usage = try queries.getUsage(conn, e.project_id, rn);
            if (usage) |u| {
                const new_total = if (u.total_chars > @as(i64, @intCast(e.content.len))) u.total_chars - @as(i64, @intCast(e.content.len)) else 0;
                const new_count = if (u.entry_count > 1) u.entry_count - 1 else 0;
                try queries.upsertUsage(conn, e.project_id, rn, new_total, new_count);
            }
        }
    }

    conn.commit() catch |err| {
        conn.rollback();
        return err;
    };
}

/// Check if a memory with the same title + scope + entity_id already exists.
fn isDuplicate(conn: *db.Connection, project_id: i64, scope: lifecycle.MemoryScope, entity_id: ?i64, title: []const u8) !bool {
    var stmt = try conn.prepare("SELECT COUNT(*) FROM agent_memory WHERE project_id = ? AND scope = ? AND entity_id = ? AND title = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, lifecycle.memoryScopeToDb(scope));
    if (entity_id) |eid| stmt.bindInt64(3, eid) else stmt.bindNull(3);
    stmt.bindText(4, title);
    _ = try stmt.step();
    return stmt.columnInt64(0) > 0;
}

const testing = std.testing;
const test_helpers = @import("../db/test_helpers.zig");

test "memory service: save with transaction" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    const entry = try saveMemory(&conn, allocator, project_id, null, .project, null, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", null, null, .high);
    defer entities.freeMemoryEntry(allocator, entry);

    try testing.expect(entry.id > 0);
    try testing.expectEqualStrings("project", entry.scope);
}

test "memory service: retrieve with filters" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    _ = try saveMemory(&conn, allocator, project_id, null, .project, null, .decision, "Auth library choice decision", "This is valid memory content about authentication and JWT tokens for testing", null, null, .high);

    const filter = queries.MemoryFilter{ .project_id = project_id, .query = "auth", .limit = 5 };
    var results = try retrieveMemories(&conn, allocator, filter);
    defer {
        for (results.items) |m| entities.freeMemoryEntry(allocator, m);
        results.deinit(allocator);
    }

    try testing.expect(results.items.len >= 1);
}

test "memory service: cap enforcement" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    // Set usage near cap
    try queries.upsertUsage(&conn, project_id, "developer", @as(i64, @intCast(validation.DEFAULT_MEMORY_CAP_BYTES - 100)), 100);

    // Try to save content that exceeds cap
    var long_content: [200]u8 = undefined;
    @memset(&long_content, 'x');
    const result = saveMemory(&conn, allocator, project_id, "developer", .project, null, .note, "This is a valid memory title", &long_content, null, null, .low);
    try testing.expectError(error.MemoryCapExceeded, result);
}

test "memory service: deduplication check" {
    const allocator = testing.allocator;
    var conn = try db.Connection.init(":memory:");
    defer conn.close();
    try db.migrate(&conn);
    const project_id = try test_helpers.seedSimpleProject(&conn);

    const title = "This is a unique memory title";
    const content = "This is valid memory content that meets the minimum length requirement for testing";

    // First save should succeed
    _ = try saveMemory(&conn, allocator, project_id, null, .project, null, .decision, title, content, null, null, .high);

    // Second save with same title + scope + entity_id should fail
    const result = saveMemory(&conn, allocator, project_id, null, .project, null, .decision, title, content, null, null, .high);
    try testing.expectError(error.MemoryDuplicate, result);
}
