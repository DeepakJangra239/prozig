const std = @import("std");
const sqlite = @import("sqlite.zig");
const Connection = @import("connection.zig").Connection;

/// Entity types that have workflow states
const entity_types = [_][]const u8{ "epic", "story", "task", "subtask", "bug" };

/// State definitions per entity type: {name, category, color}
const StateDef = struct { name: []const u8, category: []const u8, color: []const u8 };

const default_states = struct {
    fn epic() []const StateDef {
        return &[_]StateDef{
            .{ .name = "Backlog", .category = "initial", .color = "#94a3b8" },
            .{ .name = "Planned", .category = "active", .color = "#6366f1" },
            .{ .name = "In Progress", .category = "active", .color = "#3b82f6" },
            .{ .name = "In Review", .category = "active", .color = "#f59e0b" },
            .{ .name = "Done", .category = "terminal", .color = "#22c55e" },
            .{ .name = "Cancelled", .category = "cancellation", .color = "#ef4444" },
        };
    }
    fn story() []const StateDef {
        return &[_]StateDef{
            .{ .name = "Backlog", .category = "initial", .color = "#94a3b8" },
            .{ .name = "Planned", .category = "active", .color = "#6366f1" },
            .{ .name = "In Progress", .category = "active", .color = "#3b82f6" },
            .{ .name = "In Review", .category = "active", .color = "#f59e0b" },
            .{ .name = "UAT", .category = "active", .color = "#8b5cf6" },
            .{ .name = "Done", .category = "terminal", .color = "#22c55e" },
            .{ .name = "Cancelled", .category = "cancellation", .color = "#ef4444" },
        };
    }
    fn task() []const StateDef {
        return &[_]StateDef{
            .{ .name = "Todo", .category = "initial", .color = "#94a3b8" },
            .{ .name = "In Progress", .category = "active", .color = "#3b82f6" },
            .{ .name = "In Review", .category = "active", .color = "#f59e0b" },
            .{ .name = "In QA", .category = "active", .color = "#06b6d4" },
            .{ .name = "Done", .category = "terminal", .color = "#22c55e" },
            .{ .name = "Cancelled", .category = "cancellation", .color = "#ef4444" },
        };
    }
    fn subtask() []const StateDef {
        return &[_]StateDef{
            .{ .name = "Todo", .category = "initial", .color = "#94a3b8" },
            .{ .name = "In Progress", .category = "active", .color = "#3b82f6" },
            .{ .name = "UT", .category = "active", .color = "#06b6d4" },
            .{ .name = "Done", .category = "terminal", .color = "#22c55e" },
            .{ .name = "Cancelled", .category = "cancellation", .color = "#ef4444" },
        };
    }
    fn bug() []const StateDef {
        return &[_]StateDef{
            .{ .name = "New", .category = "initial", .color = "#94a3b8" },
            .{ .name = "In Progress", .category = "active", .color = "#3b82f6" },
            .{ .name = "In Review", .category = "active", .color = "#f59e0b" },
            .{ .name = "Resolved", .category = "terminal", .color = "#22c55e" },
            .{ .name = "Closed", .category = "terminal", .color = "#16a34a" },
            .{ .name = "Cancelled", .category = "cancellation", .color = "#ef4444" },
        };
    }
};

fn getStatesForType(entity_type: []const u8) []const StateDef {
    if (std.mem.eql(u8, entity_type, "epic")) return default_states.epic();
    if (std.mem.eql(u8, entity_type, "story")) return default_states.story();
    if (std.mem.eql(u8, entity_type, "task")) return default_states.task();
    if (std.mem.eql(u8, entity_type, "subtask")) return default_states.subtask();
    if (std.mem.eql(u8, entity_type, "bug")) return default_states.bug();
    return &[_]StateDef{};
}

/// Role definitions: {name, description}
const RoleDef = struct { name: []const u8, description: []const u8 };

const default_roles = [_]RoleDef{
    .{ .name = "admin", .description = "Full access to all transitions" },
    .{ .name = "product-manager", .description = "Manages epics and stories, UAT gate" },
    .{ .name = "architect", .description = "Technical lead, in_review to done gate" },
    .{ .name = "developer", .description = "Implements tasks and subtasks" },
    .{ .name = "qa", .description = "Quality assurance, testing flow" },
};

/// A permission rule: role_name can perform this entity_type transition from→to
const PermissionRule = struct {
    role_name: []const u8,
    entity_type: []const u8,
    from_name: []const u8,
    to_name: []const u8,
};

fn allPermissions() []const PermissionRule {
    return &[_]PermissionRule{
        // Admin: all transitions (handled as wildcard at enforcement time)
        .{ .role_name = "admin", .entity_type = "*", .from_name = "*", .to_name = "*" },

        // Product-manager: epic and story transitions
        .{ .role_name = "product-manager", .entity_type = "epic", .from_name = "*", .to_name = "*" },
        .{ .role_name = "product-manager", .entity_type = "story", .from_name = "*", .to_name = "*" },

        // Architect: all transitions for all entities
        .{ .role_name = "architect", .entity_type = "*", .from_name = "*", .to_name = "*" },

        // Developer: task/subtask up to in_review; bug up to in_review
        .{ .role_name = "developer", .entity_type = "task", .from_name = "*", .to_name = "In Review" },
        .{ .role_name = "developer", .entity_type = "subtask", .from_name = "*", .to_name = "Done" },
        .{ .role_name = "developer", .entity_type = "bug", .from_name = "*", .to_name = "In Review" },

        // QA: task from in_review onward; bug from in_review onward
        .{ .role_name = "qa", .entity_type = "task", .from_name = "In Review", .to_name = "*" },
        .{ .role_name = "qa", .entity_type = "bug", .from_name = "In Review", .to_name = "*" },
    };
}

/// Seed default workflow data for a project.
/// Inserts states, transitions, roles, and permissions.
/// Safe to call multiple times — checks if already seeded.
pub fn seedProjectWorkflow(conn: *Connection, project_id: i64) !void {
    // Check if already seeded for this project
    {
        const check_sql = "SELECT COUNT(*) FROM workflow_states WHERE project_id = ?";
        var stmt = try conn.prepare(check_sql);
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        if (try stmt.step() == .row) {
            if (stmt.columnInt64(0) > 0) return; // Already seeded
        }
    }

    // For each entity type, insert states and transitions
    for (entity_types) |entity_type| {
        const states = getStatesForType(entity_type);
        if (states.len == 0) continue;

        // Insert states
        var state_ids: [16]i64 = undefined;
        var state_count: usize = 0;

        for (states, 0..) |state, pos| {
            const pos_i: i64 = @intCast(pos);
            const sql =
                \\INSERT INTO workflow_states (project_id, entity_type, name, position, category, color)
                \\VALUES (?, ?, ?, ?, ?, ?)
            ;
            var stmt = try conn.prepare(sql);
            defer stmt.finalize();
            stmt.bindInt64(1, project_id);
            stmt.bindText(2, entity_type);
            stmt.bindText(3, state.name);
            stmt.bindInt64(4, pos_i);
            stmt.bindText(5, state.category);
            stmt.bindText(6, state.color);
            _ = try stmt.step();

            // Get the inserted ID
            state_ids[state_count] = sqliteLastInsertRowId(conn);
            state_count += 1;
        }

        // Find cancellation state index
        var cancel_idx: ?usize = null;
        for (states, 0..) |state, i| {
            if (std.mem.eql(u8, state.category, "cancellation")) {
                cancel_idx = i;
                break;
            }
        }

        for (0..state_count) |i| {
            // Forward transition: i → i+1 (unless i+1 is cancellation)
            if (i + 1 < state_count and cancel_idx != i + 1) {
                const sql =
                    \\INSERT OR IGNORE INTO workflow_transitions (project_id, entity_type, from_state_id, to_state_id)
                    \\VALUES (?, ?, ?, ?)
                ;
                var stmt = try conn.prepare(sql);
                defer stmt.finalize();
                stmt.bindInt64(1, project_id);
                stmt.bindText(2, entity_type);
                stmt.bindInt64(3, state_ids[i]);
                stmt.bindInt64(4, state_ids[i + 1]);
                _ = try stmt.step();
            }

            // Backward transition: i → i-1, only if state i is 'active' category
            // (not terminal, not initial, not cancellation)
            if (i > 0 and i < states.len) {
                const is_active = std.mem.eql(u8, states[i].category, "active");
                if (is_active) {
                    const sql =
                        \\INSERT OR IGNORE INTO workflow_transitions (project_id, entity_type, from_state_id, to_state_id)
                        \\VALUES (?, ?, ?, ?)
                    ;
                    var stmt = try conn.prepare(sql);
                    defer stmt.finalize();
                    stmt.bindInt64(1, project_id);
                    stmt.bindText(2, entity_type);
                    stmt.bindInt64(3, state_ids[i]);
                    stmt.bindInt64(4, state_ids[i - 1]);
                    _ = try stmt.step();
                }
            }

            // Cancellation transition: every state → cancellation state
            if (cancel_idx) |ci| {
                if (i != ci) {
                    const sql =
                        \\INSERT OR IGNORE INTO workflow_transitions (project_id, entity_type, from_state_id, to_state_id)
                        \\VALUES (?, ?, ?, ?)
                    ;
                    var stmt = try conn.prepare(sql);
                    defer stmt.finalize();
                    stmt.bindInt64(1, project_id);
                    stmt.bindText(2, entity_type);
                    stmt.bindInt64(3, state_ids[i]);
                    stmt.bindInt64(4, state_ids[ci]);
                    _ = try stmt.step();
                }
            }
        }
    }

    // Create default roles
    var role_ids: [default_roles.len]i64 = undefined;
    for (default_roles, 0..) |role, i| {
        const sql =
            \\INSERT INTO agent_roles (project_id, name, description)
            \\VALUES (?, ?, ?)
        ;
        var stmt = try conn.prepare(sql);
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        stmt.bindText(2, role.name);
        stmt.bindText(3, role.description);
        _ = try stmt.step();

        role_ids[i] = sqliteLastInsertRowId(conn);
    }

    // Grant permissions: for each permission rule, find matching transitions
    const permissions = allPermissions();
    for (permissions) |perm| {
        const role_name = perm.role_name;
        const entity_type = perm.entity_type;
        const from_name = perm.from_name;
        const to_name = perm.to_name;

        // Find role ID
        var role_id: ?i64 = null;
        for (default_roles, 0..) |r, i| {
            if (std.mem.eql(u8, r.name, role_name)) {
                role_id = role_ids[i];
                break;
            }
        }
        if (role_id == null) continue;

        // For wildcard permissions, grant all transitions for the entity type (or all types)
        if (std.mem.eql(u8, entity_type, "*")) {
            // Grant this role all transitions for all entity types
            const sql =
                \\INSERT OR IGNORE INTO role_permissions (role_id, transition_id)
                \\SELECT ?, wt.id FROM workflow_transitions wt WHERE wt.project_id = ?
            ;
            var stmt = try conn.prepare(sql);
            defer stmt.finalize();
            stmt.bindInt64(1, role_id.?);
            stmt.bindInt64(2, project_id);
            _ = try stmt.step();
        } else if (std.mem.eql(u8, from_name, "*") and std.mem.eql(u8, to_name, "*")) {
            // Grant all transitions for a specific entity type
            const sql =
                \\INSERT OR IGNORE INTO role_permissions (role_id, transition_id)
                \\SELECT ?, wt.id FROM workflow_transitions wt
                \\JOIN workflow_states ws ON wt.from_state_id = ws.id
                \\WHERE ws.project_id = ? AND ws.entity_type = ?
            ;
            var stmt = try conn.prepare(sql);
            defer stmt.finalize();
            stmt.bindInt64(1, role_id.?);
            stmt.bindInt64(2, project_id);
            stmt.bindText(3, entity_type);
            _ = try stmt.step();
        } else if (std.mem.eql(u8, from_name, "*")) {
            // Grant transitions TO a specific state for a specific entity type
            const sql =
                \\INSERT OR IGNORE INTO role_permissions (role_id, transition_id)
                \\SELECT ?, wt.id FROM workflow_transitions wt
                \\JOIN workflow_states ws_from ON wt.from_state_id = ws_from.id
                \\JOIN workflow_states ws_to ON wt.to_state_id = ws_to.id
                \\WHERE ws_from.project_id = ? AND ws_from.entity_type = ?
                \\  AND ws_to.name = ?
            ;
            var stmt = try conn.prepare(sql);
            defer stmt.finalize();
            stmt.bindInt64(1, role_id.?);
            stmt.bindInt64(2, project_id);
            stmt.bindText(3, entity_type);
            stmt.bindText(4, to_name);
            _ = try stmt.step();
        } else if (std.mem.eql(u8, to_name, "*")) {
            // Grant transitions FROM a specific state for a specific entity type
            const sql =
                \\INSERT OR IGNORE INTO role_permissions (role_id, transition_id)
                \\SELECT ?, wt.id FROM workflow_transitions wt
                \\JOIN workflow_states ws_from ON wt.from_state_id = ws_from.id
                \\JOIN workflow_states ws_to ON wt.to_state_id = ws_to.id
                \\WHERE ws_from.project_id = ? AND ws_from.entity_type = ?
                \\  AND ws_from.name = ?
            ;
            var stmt = try conn.prepare(sql);
            defer stmt.finalize();
            stmt.bindInt64(1, role_id.?);
            stmt.bindInt64(2, project_id);
            stmt.bindText(3, entity_type);
            stmt.bindText(4, from_name);
            _ = try stmt.step();
        }
    }
}

/// Seed all projects that don't have workflow data yet.
/// Called after migration.
pub fn seedAllProjects(conn: *Connection) !void {
    // Get all project IDs
    const sql = "SELECT id FROM projects";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();

    while (true) {
        const step = try stmt.step();
        if (step != .row) break;
        const project_id = stmt.columnInt64(0);
        seedProjectWorkflow(conn, project_id) catch |err| {
            std.log.err("Failed to seed project {d}: {any}\n", .{ project_id, err });
        };
    }
}

/// Get the last inserted row ID from SQLite
fn sqliteLastInsertRowId(conn: *Connection) i64 {
    const db = conn.db orelse return 0;
    return @intCast(sqlite.c.sqlite3_last_insert_rowid(db));
}

test "seed workflow for in-memory project" {
    const testing = std.testing;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    // Create a project
    const create_sql = "INSERT INTO projects (name, root_path) VALUES ('Test', '/tmp')";
    try conn.exec(create_sql);

    // Seed
    try seedProjectWorkflow(&conn, 1);
    try seedProjectWorkflow(&conn, 1); // Should be idempotent

    // Verify states
    var stmt = try conn.prepare("SELECT COUNT(*) FROM workflow_states WHERE project_id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, 1);
    _ = try stmt.step();
    try testing.expect(stmt.columnInt64(0) > 0);

    // Verify transitions
    var stmt2 = try conn.prepare("SELECT COUNT(*) FROM workflow_transitions WHERE project_id = ?");
    defer stmt2.finalize();
    stmt2.bindInt64(1, 1);
    _ = try stmt2.step();
    try testing.expect(stmt2.columnInt64(0) > 0);

    // Verify roles
    var stmt3 = try conn.prepare("SELECT COUNT(*) FROM agent_roles WHERE project_id = ?");
    defer stmt3.finalize();
    stmt3.bindInt64(1, 1);
    _ = try stmt3.step();
    try testing.expect(stmt3.columnInt64(0) > 0);

    // Verify permissions
    var stmt4 = try conn.prepare("SELECT COUNT(*) FROM role_permissions WHERE role_id IN (SELECT id FROM agent_roles WHERE project_id = ?)");
    defer stmt4.finalize();
    stmt4.bindInt64(1, 1);
    _ = try stmt4.step();
    try testing.expect(stmt4.columnInt64(0) > 0);
}
