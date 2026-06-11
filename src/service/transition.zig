const std = @import("std");
const db = @import("../db/connection.zig");
const Service = @import("root.zig").Service;
const lifecycle = @import("../domain/lifecycle.zig");
const entities = @import("../domain/entities.zig");
const queries_epic = @import("../db/queries/epics.zig");
const queries_story = @import("../db/queries/stories.zig");
const queries_task = @import("../db/queries/tasks.zig");
const queries_subtask = @import("../db/queries/subtasks.zig");
const queries_bug = @import("../db/queries/bug.zig");
const workflow = @import("workflow.zig");

/// Transition an entity to a new status, wrapped in a transaction.
/// When a custom workflow exists, the transition is validated against it and
/// role-based permissions are enforced if `agent_id` is provided (MCP-driven).
/// Pass `null` for agent_id to skip the permission check (dashboard/human
/// transitions). The transition definition itself is still validated.
/// Cross-entity gating (parent terminal state, blocker bugs) is always enforced.
/// Returns `error.InvalidTransition` on invalid transitions,
/// `error.PermissionDenied` if role lacks permission,
/// `error.ParentInTerminalState` if the parent is Done/Cancelled,
/// `error.BlockerBugsExist` if open critical/high bugs exist on parent,
/// `error.NotFound` if the entity doesn't exist,
/// or a database error on failure.
pub fn transitionStatus(srv: *Service, allocator: std.mem.Allocator, entity_type: []const u8, entity_id: i64, new_status: []const u8, agent_id: ?i64) !void {
    const conn = srv.conn;

    // Parse entity type
    const etype = blk: {
        if (std.mem.eql(u8, entity_type, "epic")) break :blk lifecycle.EntityType.epic;
        if (std.mem.eql(u8, entity_type, "story")) break :blk lifecycle.EntityType.story;
        if (std.mem.eql(u8, entity_type, "task")) break :blk lifecycle.EntityType.task;
        if (std.mem.eql(u8, entity_type, "subtask")) break :blk lifecycle.EntityType.subtask;
        if (std.mem.eql(u8, entity_type, "bug")) break :blk lifecycle.EntityType.bug;
        return error.InvalidEntityType;
    };

    // Begin transaction
    conn.begin() catch |err| {
        conn.rollback();
        return err;
    };
    errdefer conn.rollback();

    // Get current status
    const current_status = try getCurrentStatus(conn, allocator, etype, entity_id);
    defer allocator.free(current_status);

    // Get project_id for workflow check
    const project_id = (try workflow.getEntityProjectId(conn, entity_type, entity_id)) orelse return error.NotFound;

    // Check custom workflow — if it exists, validate transition is defined.
    // When agent_id is provided (MCP/agent), also enforce role permissions.
    // When agent_id is null (dashboard/human), skip permission check.
    const has_workflow = try workflow.hasCustomWorkflow(conn, project_id, entity_type);
    if (has_workflow) {
        const from_id = (try workflow.resolveStateId(conn, project_id, entity_type, current_status)) orelse return error.InvalidTransition;
        const to_id = (try workflow.resolveStateId(conn, project_id, entity_type, new_status)) orelse return error.InvalidTransition;
        const transition_id = (try workflow.findTransitionId(conn, project_id, entity_type, from_id, to_id)) orelse return error.InvalidTransition;
        // Enforce role permissions only for agent-driven transitions (MCP).
        if (agent_id) |aid| {
            const role_id = (try workflow.getAgentRoleId(conn, aid, project_id)) orelse return error.PermissionDenied;
            if (!try workflow.isRolePermitted(conn, role_id, transition_id)) return error.PermissionDenied;
        }
    } else {
        // Fall back to hardcoded lifecycle validation
        try lifecycle.validateTransition(etype, current_status, new_status);
    }

    // Cross-entity gating: check parent state (story → epic, task → story, subtask → task)
    if (!try workflow.validateParentState(conn, allocator, entity_type, entity_id)) {
        return error.ParentInTerminalState;
    }

    // Cross-entity gating: check for open blocker bugs
    if (!try workflow.validateNoBlockerBugs(conn, entity_type, entity_id)) {
        return error.BlockerBugsExist;
    }

    // Apply transition
    switch (etype) {
        .epic => {
            const parsed = lifecycle.epicStatusFromDb(new_status) orelse return error.InvalidTransition;
            try queries_epic.updateStatus(conn, entity_id, parsed);
        },
        .story => {
            const parsed = lifecycle.storyStatusFromDb(new_status) orelse return error.InvalidTransition;
            try queries_story.updateStatus(conn, entity_id, parsed);
        },
        .task => {
            const parsed = lifecycle.taskStatusFromDb(new_status) orelse return error.InvalidTransition;
            try queries_task.updateStatus(conn, entity_id, parsed);
        },
        .subtask => {
            const parsed = lifecycle.subTaskStatusFromDb(new_status) orelse return error.InvalidTransition;
            try queries_subtask.updateStatus(conn, entity_id, parsed);
        },
        .bug => {
            const parsed = lifecycle.bugStatusFromDb(new_status) orelse return error.InvalidTransition;
            try queries_bug.updateStatus(conn, entity_id, parsed);
        },
    }

    // Commit
    conn.commit() catch |err| {
        conn.rollback();
        return err;
    };
}

/// Fetch the current status string for an entity and dupe it for the caller.
/// Caller owns the returned `[]u8`.
fn getCurrentStatus(conn: *db.Connection, allocator: std.mem.Allocator, etype: lifecycle.EntityType, entity_id: i64) ![]u8 {
    switch (etype) {
        .epic => {
            const epic = try queries_epic.getById(conn, allocator, entity_id);
            if (epic) |e| {
                const status = try allocator.dupe(u8, lifecycle.epicStatusToDb(e.status));
                entities.freeEpic(allocator, e);
                return status;
            }
        },
        .story => {
            const story = try queries_story.getById(conn, allocator, entity_id);
            if (story) |s| {
                const status = try allocator.dupe(u8, lifecycle.storyStatusToDb(s.status));
                entities.freeStory(allocator, s);
                return status;
            }
        },
        .task => {
            const task = try queries_task.getById(conn, allocator, entity_id);
            if (task) |t| {
                const status = try allocator.dupe(u8, lifecycle.taskStatusToDb(t.status));
                entities.freeTask(allocator, t);
                return status;
            }
        },
        .subtask => {
            const subtask = try queries_subtask.getById(conn, allocator, entity_id);
            if (subtask) |st| {
                const status = try allocator.dupe(u8, lifecycle.subTaskStatusToDb(st.status));
                entities.freeSubTask(allocator, st);
                return status;
            }
        },
        .bug => {
            const bug = try queries_bug.getById(conn, allocator, entity_id);
            if (bug) |b| {
                const status = try allocator.dupe(u8, lifecycle.bugStatusToDb(b.status));
                entities.freeBug(allocator, b);
                return status;
            }
        },
    }
    return error.NotFound;
}
