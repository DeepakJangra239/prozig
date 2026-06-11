const std = @import("std");
const db = @import("../db/connection.zig");
const Connection = db.Connection;
const lifecycle = @import("../domain/lifecycle.zig");

/// Resolve a state name to its workflow_states ID for a given project + entity_type.
/// Returns null if no such state exists.
pub fn resolveStateId(conn: *Connection, project_id: i64, entity_type: []const u8, state_name: []const u8) !?i64 {
    const sql = "SELECT id FROM workflow_states WHERE project_id = ? AND entity_type = ? AND name = ?";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, entity_type);
    stmt.bindText(3, state_name);
    if (try stmt.step() == .row) return stmt.columnInt64(0);
    return null;
}

/// Check if a project has a custom workflow defined for an entity type.
pub fn hasCustomWorkflow(conn: *Connection, project_id: i64, entity_type: []const u8) !bool {
    const sql = "SELECT COUNT(*) FROM workflow_states WHERE project_id = ? AND entity_type = ?";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, entity_type);
    _ = try stmt.step();
    return stmt.columnInt64(0) > 0;
}

/// Check if a specific transition (from_state → to_state) is defined in workflow_transitions.
/// Returns the transition ID if found, null if not defined.
pub fn findTransitionId(conn: *Connection, project_id: i64, entity_type: []const u8, from_state_id: i64, to_state_id: i64) !?i64 {
    const sql = "SELECT id FROM workflow_transitions WHERE project_id = ? AND entity_type = ? AND from_state_id = ? AND to_state_id = ?";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, entity_type);
    stmt.bindInt64(3, from_state_id);
    stmt.bindInt64(4, to_state_id);
    if (try stmt.step() == .row) return stmt.columnInt64(0);
    return null;
}

/// Get the project_id for an entity by type and id.
pub fn getEntityProjectId(conn: *Connection, entity_type: []const u8, entity_id: i64) !?i64 {
        const table = if (std.mem.eql(u8, entity_type, "epic")) "epics"
        else if (std.mem.eql(u8, entity_type, "story")) "stories"
        else if (std.mem.eql(u8, entity_type, "task")) "tasks"
        else if (std.mem.eql(u8, entity_type, "subtask")) "subtasks"
        else if (std.mem.eql(u8, entity_type, "bug")) "bugs"
        else if (std.mem.eql(u8, entity_type, "wiki")) "wiki_pages"
        else return null;
    const sql = std.fmt.allocPrint(std.heap.page_allocator, "SELECT project_id FROM {s} WHERE id = ?", .{table}) catch return null;
    defer std.heap.page_allocator.free(sql);

    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, entity_id);
    if (try stmt.step() == .row) return stmt.columnInt64(0);
    return null;
}

/// Get the state category for a given state ID.
pub fn getStateCategory(conn: *Connection, state_id: i64) !?[]const u8 {
    const sql = "SELECT category FROM workflow_states WHERE id = ?";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, state_id);
    if (try stmt.step() == .row) {
        if (stmt.columnText(0)) |cat| return cat;
    }
    return null;
}

/// Check if a role is permitted to use a specific transition.
pub fn isRolePermitted(conn: *Connection, role_id: i64, transition_id: i64) !bool {
    const sql = "SELECT COUNT(*) FROM role_permissions WHERE role_id = ? AND transition_id = ?";
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, role_id);
    stmt.bindInt64(2, transition_id);
    _ = try stmt.step();
    return stmt.columnInt64(0) > 0;
}

/// Get the role_id for an agent in a specific project.
/// Resolves by role NAME (same names across all projects) so agents work
/// in any project regardless of which project's role they were registered with.
/// Returns null if the agent has no role, or the role name doesn't exist in the target project.
pub fn getAgentRoleId(conn: *Connection, agent_id: i64, project_id: i64) !?i64 {
    const sql =
        \\SELECT target_role.id FROM agent_profiles ap
        \\JOIN agent_roles source_role ON ap.role_id = source_role.id
        \\JOIN agent_roles target_role ON target_role.name = source_role.name AND target_role.project_id = ?
        \\WHERE ap.id = ?
    ;
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindInt64(2, agent_id);
    if (try stmt.step() == .row) {
        const raw = stmt.columnInt64Safe(0);
        if (raw) |r| return r;
    }
    return null;
}

const ParentInfo = struct {
    parent_type: []const u8, // "epic", "story", or "task"
    parent_id: i64,
    parent_status: []const u8, // owned by the allocator passed to getParentInfo
};

/// Get the parent entity info for a given entity.
/// Returns null if entity type has no parent, or parent doesn't exist.
/// Caller is responsible for freeing `parent_status` (via the allocator).
fn getParentInfo(conn: *Connection, allocator: std.mem.Allocator, entity_type: []const u8, entity_id: i64) !?ParentInfo {
    if (std.mem.eql(u8, entity_type, "subtask")) {
        const sql = "SELECT t.id, t.status, s.id, s.status, e.id, e.status FROM subtasks st JOIN tasks t ON st.task_id = t.id JOIN stories s ON t.story_id = s.id JOIN epics e ON s.epic_id = e.id WHERE st.id = ?";
        var stmt = try conn.prepare(sql);
        defer stmt.finalize();
        stmt.bindInt64(1, entity_id);
        if (try stmt.step() == .row) {
            const task_status_raw = stmt.columnText(1) orelse return null;
            const task_status = try allocator.dupe(u8, task_status_raw);
            errdefer allocator.free(task_status);
            return ParentInfo{ .parent_type = "task", .parent_id = stmt.columnInt64(0), .parent_status = task_status };
        }
        return null;
    }
    if (std.mem.eql(u8, entity_type, "task")) {
        const sql = "SELECT s.id, s.status, e.id, e.status FROM tasks t JOIN stories s ON t.story_id = s.id JOIN epics e ON s.epic_id = e.id WHERE t.id = ?";
        var stmt = try conn.prepare(sql);
        defer stmt.finalize();
        stmt.bindInt64(1, entity_id);
        if (try stmt.step() == .row) {
            const story_status_raw = stmt.columnText(1) orelse return null;
            const story_status = try allocator.dupe(u8, story_status_raw);
            errdefer allocator.free(story_status);
            return ParentInfo{ .parent_type = "story", .parent_id = stmt.columnInt64(0), .parent_status = story_status };
        }
        return null;
    }
    if (std.mem.eql(u8, entity_type, "story")) {
        const sql = "SELECT e.id, e.status FROM stories s JOIN epics e ON s.epic_id = e.id WHERE s.id = ?";
        var stmt = try conn.prepare(sql);
        defer stmt.finalize();
        stmt.bindInt64(1, entity_id);
        if (try stmt.step() == .row) {
            const epic_status_raw = stmt.columnText(1) orelse return null;
            const epic_status = try allocator.dupe(u8, epic_status_raw);
            errdefer allocator.free(epic_status);
            return ParentInfo{ .parent_type = "epic", .parent_id = stmt.columnInt64(0), .parent_status = epic_status };
        }
        return null;
    }
    return null; // epics and bugs have no parent for gating purposes
}

/// Validate that an entity's parent is not in a terminal state.
/// Returns `error.ParentInTerminalState` if the parent is Done or Cancelled.
/// Returns `true` if entity has no parent or parent is not terminal.
pub fn validateParentState(conn: *Connection, allocator: std.mem.Allocator, entity_type: []const u8, entity_id: i64) !bool {
    const parent = (try getParentInfo(conn, allocator, entity_type, entity_id)) orelse return true;
    defer allocator.free(parent.parent_status);
    if (lifecycle.isTerminal(parent.parent_status)) {
        std.log.err("Parent {s} {d} is in terminal state '{s}', blocking child {s} {d}\n", .{ parent.parent_type, parent.parent_id, parent.parent_status, entity_type, entity_id });
        return false;
    }
    return true;
}

/// Check if an entity has open blocker bugs blocking it.
/// A bug is considered blocking if:
///   - It is in an open status (New, In Progress, In Review)
///   - Its severity is critical, high, or medium (low is non-blocking)
/// Returns true if there are open blocker bugs, false otherwise.
pub fn hasOpenBlockerBugs(conn: *Connection, entity_type: []const u8, entity_id: i64) !bool {
    const col = if (std.mem.eql(u8, entity_type, "epic")) "epic_id"
        else if (std.mem.eql(u8, entity_type, "story")) "story_id"
        else if (std.mem.eql(u8, entity_type, "task")) "task_id"
        else return false;
    const sql = std.fmt.allocPrint(std.heap.page_allocator, "SELECT COUNT(*) FROM bugs WHERE {s} = ? AND status IN ('New', 'In Progress', 'In Review') AND severity IN ('critical', 'high', 'medium')", .{col}) catch return false;
    defer std.heap.page_allocator.free(sql);
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, entity_id);
    _ = try stmt.step();
    return stmt.columnInt64(0) > 0;
}

/// Validate that an entity doesn't have open blocker bugs for transition.
/// Returns false if there are open bugs blocking the entity.
pub fn validateNoBlockerBugs(conn: *Connection, entity_type: []const u8, entity_id: i64) !bool {
    if (try hasOpenBlockerBugs(conn, entity_type, entity_id)) {
        std.log.err("Entity {s} {d} has open blocker bugs\n", .{ entity_type, entity_id });
        return false;
    }
    return true;
}

/// Get the parent entity type from an entity type.
pub fn getParentEntityType(entity_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, entity_type, "subtask")) return "task";
    if (std.mem.eql(u8, entity_type, "task")) return "story";
    if (std.mem.eql(u8, entity_type, "story")) return "epic";
    return null;
}

/// Validate that a parent entity is not in a terminal state (for create-time guards).
/// Returns true if parent is valid or entity has no parent.
pub fn validateCreateParentState(conn: *Connection, parent_type: []const u8, parent_id: i64) !bool {
    const table = switch (parent_type[0]) {
        'e' => if (std.mem.eql(u8, parent_type, "epic")) "epics" else return true,
        's' => if (std.mem.eql(u8, parent_type, "story")) "stories" else return true,
        't' => if (std.mem.eql(u8, parent_type, "task")) "tasks" else return true,
        else => return true,
    };
    const sql = std.fmt.allocPrint(std.heap.page_allocator, "SELECT status FROM {s} WHERE id = ?", .{table}) catch return true;
    defer std.heap.page_allocator.free(sql);
    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, parent_id);
    if (try stmt.step() == .row) {
        const status = stmt.columnText(0) orelse return true;
        return !lifecycle.isTerminal(status);
    }
    return false; // parent doesn't exist
}

/// Validate a transition against the custom workflow for a project.
/// Returns `error.InvalidTransition` if the transition is not in the workflow.
/// Returns `error.PermissionDenied` if the agent's role doesn't have permission.
/// Returns `true` if custom workflow doesn't exist (caller should use hardcoded validation).
pub fn validateWorkflowTransition(conn: *Connection, project_id: i64, entity_type: []const u8, from_status: []const u8, to_status: []const u8, agent_id: ?i64) !bool {
    // Check if custom workflow exists for this project + entity_type
    if (!try hasCustomWorkflow(conn, project_id, entity_type)) {
        return true; // No custom workflow — caller should use hardcoded validation
    }

    // Resolve state IDs
    const from_id = (try resolveStateId(conn, project_id, entity_type, from_status)) orelse {
        std.log.err("Workflow: unknown from-state '{s}' for {s}\n", .{ from_status, entity_type });
        return false;
    };
    const to_id = (try resolveStateId(conn, project_id, entity_type, to_status)) orelse {
        std.log.err("Workflow: unknown to-state '{s}' for {s}\n", .{ to_status, entity_type });
        return false;
    };

    // Find the transition
    const transition_id = (try findTransitionId(conn, project_id, entity_type, from_id, to_id)) orelse {
        std.log.err("Workflow: transition '{s} -> {s}' not defined for {s}\n", .{ from_status, to_status, entity_type });
        return false;
    };

    // If agent_id provided, check role permissions
    if (agent_id) |aid| {
        const role_id = (try getAgentRoleId(conn, aid, project_id)) orelse {
            std.log.err("Workflow: agent {d} has no role assigned in project {d}\n", .{ aid, project_id });
            return false;
        };
        if (!try isRolePermitted(conn, role_id, transition_id)) {
            std.log.err("Workflow: role {d} not permitted for transition {d}\n", .{ role_id, transition_id });
            return false;
        }
    }

    return true; // Transition is valid per workflow
}

test "workflow validation with seeded project" {
    const testing = std.testing;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    // Create a project and seed
    try conn.exec("INSERT INTO projects (name, root_path) VALUES ('Test', '/tmp')");
    const seed = @import("../db/seed.zig");
    try seed.seedProjectWorkflow(&conn, 1);

    // Test custom workflow exists
    try testing.expect(try hasCustomWorkflow(&conn, 1, "epic"));
    try testing.expect(try hasCustomWorkflow(&conn, 1, "story"));
    try testing.expect(!try hasCustomWorkflow(&conn, 1, "nonexistent"));

    // Test state resolution
    const state_id = (try resolveStateId(&conn, 1, "epic", "Backlog")) orelse return error.TestFailed;
    try testing.expect(state_id > 0);

    // Test transition lookup — valid forward
    const backlog_id = (try resolveStateId(&conn, 1, "epic", "Backlog")) orelse return error.TestFailed;
    const planned_id = (try resolveStateId(&conn, 1, "epic", "Planned")) orelse return error.TestFailed;
    const transition = try findTransitionId(&conn, 1, "epic", backlog_id, planned_id);
    try testing.expect(transition != null);

    // Test invalid transition — backlog to done (skip)
    const done_id = (try resolveStateId(&conn, 1, "epic", "Done")) orelse return error.TestFailed;
    const bad_transition = try findTransitionId(&conn, 1, "epic", backlog_id, done_id);
    try testing.expect(bad_transition == null);

    // Test validation with no custom workflow (should return true = fallback)
    try conn.exec("INSERT INTO projects (name, root_path) VALUES ('Empty', '/tmp')");
    try testing.expect(try validateWorkflowTransition(&conn, 2, "epic", "Backlog", "Planned", null));
}

test "workflow validation with role check" {
    const testing = std.testing;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    // Create project and seed
    try conn.exec("INSERT INTO projects (name, root_path) VALUES ('Test', '/tmp')");
    const seed = @import("../db/seed.zig");
    try seed.seedProjectWorkflow(&conn, 1);

    // Create an agent with a role
    try conn.exec("INSERT INTO agent_profiles (name, capabilities, role_id) VALUES ('dev', 'coding', (SELECT id FROM agent_roles WHERE project_id = 1 AND name = 'developer'))");
    try conn.exec("INSERT INTO agent_profiles (name, capabilities, role_id) VALUES ('pm', 'management', (SELECT id FROM agent_roles WHERE project_id = 1 AND name = 'product-manager'))");

    // Developer should be able to transition task: Todo → In Progress
    const dev_id: i64 = 1; // first agent inserted
    try testing.expect(try validateWorkflowTransition(&conn, 1, "task", "Todo", "In Progress", dev_id));

    // Developer should NOT be able to transition epic: Backlog → Planned
    // (developer role has no epic permissions)
    try testing.expect(!try validateWorkflowTransition(&conn, 1, "epic", "Backlog", "Planned", dev_id));

    // Product-manager should be able to transition epic: Backlog → Planned
    const pm_id: i64 = 2;
    try testing.expect(try validateWorkflowTransition(&conn, 1, "epic", "Backlog", "Planned", pm_id));
}

test "cross-entity parent gating" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    try conn.exec("INSERT INTO projects (name, root_path) VALUES ('Test', '/tmp')");
    try conn.exec("INSERT INTO epics (project_id, title, status) VALUES (1, 'Epic 1', 'Done')");
    try conn.exec("INSERT INTO stories (project_id, epic_id, title, status) VALUES (1, 1, 'Story 1', 'Backlog')");
    try conn.exec("INSERT INTO tasks (project_id, story_id, title, status) VALUES (1, 1, 'Task 1', 'Todo')");
    try conn.exec("INSERT INTO subtasks (project_id, task_id, title, status) VALUES (1, 1, 'Subtask 1', 'Todo')");

    // Story under Done epic should be blocked
    try testing.expect(!try validateParentState(&conn, allocator, "story", 1));

    // Task under Done epic (via Done story) should be blocked
    try testing.expect(!try validateParentState(&conn, allocator, "task", 1));

    // Subtask under Done hierarchy should be blocked
    try testing.expect(!try validateParentState(&conn, allocator, "subtask", 1));

    // Epic has no parent — should pass
    try testing.expect(try validateParentState(&conn, allocator, "epic", 1));

    // Now create an epic that is not Done
    try conn.exec("INSERT INTO epics (project_id, title, status) VALUES (1, 'Epic 2', 'In Progress')");
    try conn.exec("INSERT INTO stories (project_id, epic_id, title, status) VALUES (1, 2, 'Story 2', 'In Review')");
    try conn.exec("INSERT INTO tasks (project_id, story_id, title, status) VALUES (1, 2, 'Task 2', 'In Progress')");

    // Active parent should pass
    try testing.expect(try validateParentState(&conn, allocator, "story", 2));
    try testing.expect(try validateParentState(&conn, allocator, "task", 2));
}

test "cross-entity create-time guard" {
    const testing = std.testing;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    try conn.exec("INSERT INTO projects (name, root_path) VALUES ('Test', '/tmp')");

    // Terminal parent — create should be blocked
    try conn.exec("INSERT INTO epics (project_id, title, status) VALUES (1, 'Done Epic', 'Done')");
    try testing.expect(!try validateCreateParentState(&conn, "epic", 1));

    // Non-terminal parent — create should pass
    try conn.exec("INSERT INTO epics (project_id, title, status) VALUES (1, 'Active Epic', 'In Progress')");
    try testing.expect(try validateCreateParentState(&conn, "epic", 2));

    // Nonexistent parent — should fail (parent doesn't exist)
    try testing.expect(!try validateCreateParentState(&conn, "epic", 999));
}

test "blocker bug detection" {
    const testing = std.testing;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    try conn.exec("INSERT INTO projects (name, root_path) VALUES ('Test', '/tmp')");
    try conn.exec("INSERT INTO epics (project_id, title, status) VALUES (1, 'Epic 1', 'In Progress')");
    try conn.exec("INSERT INTO bugs (project_id, epic_id, title, severity, status) VALUES (1, 1, 'Bug 1', 'high', 'New')");
    try conn.exec("INSERT INTO bugs (project_id, epic_id, title, severity, status) VALUES (1, 1, 'Bug 2', 'medium', 'Closed')");

    // Epic 1 has 1 open bug (Bug 1 is New)
    try testing.expect(try hasOpenBlockerBugs(&conn, "epic", 1));

    // Close the open bug
    try conn.exec("UPDATE bugs SET status = 'Closed' WHERE id = 1");
    try testing.expect(!try hasOpenBlockerBugs(&conn, "epic", 1));
}

test "blocker bug severity filtering" {
    const testing = std.testing;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();

    try conn.exec("INSERT INTO projects (name, root_path) VALUES ('Test', '/tmp')");
    try conn.exec("INSERT INTO epics (project_id, title, status) VALUES (1, 'Epic 1', 'In Progress')");

    // Critical bug blocks
    try conn.exec("INSERT INTO bugs (project_id, epic_id, title, severity, status) VALUES (1, 1, 'Critical Bug', 'critical', 'New')");
    try testing.expect(try hasOpenBlockerBugs(&conn, "epic", 1));
    try conn.exec("DELETE FROM bugs WHERE id = 1");

    // High bug blocks
    try conn.exec("INSERT INTO bugs (project_id, epic_id, title, severity, status) VALUES (1, 1, 'High Bug', 'high', 'In Progress')");
    try testing.expect(try hasOpenBlockerBugs(&conn, "epic", 1));
    try conn.exec("DELETE FROM bugs WHERE id = 1");

    // Medium bug blocks
    try conn.exec("INSERT INTO bugs (project_id, epic_id, title, severity, status) VALUES (1, 1, 'Medium Bug', 'medium', 'In Review')");
    try testing.expect(try hasOpenBlockerBugs(&conn, "epic", 1));
    try conn.exec("DELETE FROM bugs WHERE id = 1");

    // Low bug does NOT block
    try conn.exec("INSERT INTO bugs (project_id, epic_id, title, severity, status) VALUES (1, 1, 'Low Bug', 'low', 'New')");
    try testing.expect(!try hasOpenBlockerBugs(&conn, "epic", 1));
}
