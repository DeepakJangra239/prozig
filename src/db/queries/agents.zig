const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");

pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, name: []const u8, capabilities: []const u8, description: ?[]const u8) !entities.AgentProfile {
    var stmt = try conn.prepare("INSERT INTO agent_profiles (name, capabilities, description) VALUES (?, ?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();

    stmt.bindText(1, name);
    stmt.bindText(2, capabilities);
    if (description) |d| stmt.bindText(3, d) else stmt.bindNull(3);
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.AgentProfile{
        .id = id,
        .name = try allocator.dupe(u8, name),
        .capabilities = try allocator.dupe(u8, capabilities),
        .description = if (description) |d| try allocator.dupe(u8, d) else null,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, agent_id: i64) !?entities.AgentProfile {
    var stmt = try conn.prepare("SELECT id, name, capabilities, description, metadata, created_at, updated_at FROM agent_profiles WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;

    return entities.AgentProfile{
        .id = id_opt.?,
        .name = try allocator.dupe(u8, stmt.columnText(1).?),
        .capabilities = try allocator.dupe(u8, stmt.columnText(2).?),
        .description = if (stmt.columnText(3)) |d| try allocator.dupe(u8, d) else null,
        .metadata = if (stmt.columnText(4)) |m| try allocator.dupe(u8, m) else null,
        .created_at = try allocator.dupe(u8, stmt.columnText(5).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(6).?),
    };
}

pub fn getByName(conn: *db.Connection, allocator: std.mem.Allocator, name: []const u8) !?entities.AgentProfile {
    var stmt = try conn.prepare("SELECT id, name, capabilities, description, metadata, created_at, updated_at FROM agent_profiles WHERE name = ?");
    defer stmt.finalize();
    stmt.bindText(1, name);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;

    return entities.AgentProfile{
        .id = id_opt.?,
        .name = try allocator.dupe(u8, stmt.columnText(1).?),
        .capabilities = try allocator.dupe(u8, stmt.columnText(2).?),
        .description = if (stmt.columnText(3)) |d| try allocator.dupe(u8, d) else null,
        .metadata = if (stmt.columnText(4)) |m| try allocator.dupe(u8, m) else null,
        .created_at = try allocator.dupe(u8, stmt.columnText(5).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(6).?),
    };
}

pub fn listAll(conn: *db.Connection, allocator: std.mem.Allocator) !std.ArrayList(entities.AgentProfile) {
    var results = std.ArrayList(entities.AgentProfile).empty;
    var stmt = try conn.prepare("SELECT id, name, capabilities, description, metadata, created_at, updated_at FROM agent_profiles ORDER BY name");
    defer stmt.finalize();

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        try results.append(allocator, entities.AgentProfile{
            .id = id_opt.?,
            .name = try allocator.dupe(u8, stmt.columnText(1).?),
            .capabilities = try allocator.dupe(u8, stmt.columnText(2).?),
            .description = if (stmt.columnText(3)) |d| try allocator.dupe(u8, d) else null,
            .metadata = if (stmt.columnText(4)) |m| try allocator.dupe(u8, m) else null,
            .created_at = try allocator.dupe(u8, stmt.columnText(5).?),
            .updated_at = try allocator.dupe(u8, stmt.columnText(6).?),
        });
    }
    return results;
}

/// Delete an agent profile by ID.
pub fn delete(conn: *db.Connection, agent_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM agent_profiles WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    _ = try stmt.step();
}
