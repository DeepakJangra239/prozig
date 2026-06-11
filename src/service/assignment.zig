const std = @import("std");
const db = @import("../db/connection.zig");
const Service = @import("root.zig").Service;
const entities = @import("../domain/entities.zig");
const domain_assignment = @import("../domain/assignment.zig");
const queries_agents = @import("../db/queries/agents.zig");
const queries_project = @import("../db/queries/projects.zig");
const queries_epic = @import("../db/queries/epics.zig");
const queries_story = @import("../db/queries/stories.zig");
const queries_task = @import("../db/queries/tasks.zig");
const queries_subtask = @import("../db/queries/subtasks.zig");
const queries_bug = @import("../db/queries/bug.zig");

/// Assign an agent to an entity by updating the entity's assignee_agent_id field.
/// Returns `error.NotFound` if the entity or agent doesn't exist.
pub fn assignWork(srv: *Service, allocator: std.mem.Allocator, entity_type: []const u8, entity_id: i64, agent_id: i64) !void {
    const conn = srv.conn;

    // Verify agent exists
    const agent = try queries_agents.getById(conn, allocator, agent_id);
    if (agent) |a| entities.freeAgentProfile(allocator, a) else return error.NotFound;

    conn.begin() catch |err| {
        conn.rollback();
        return err;
    };
    errdefer conn.rollback();

    if (std.mem.eql(u8, entity_type, "project")) {
        _ = try queries_project.update(conn, entity_id, null, null);
    } else if (std.mem.eql(u8, entity_type, "epic")) {
        try setEpicAssignee(conn, entity_id, agent_id);
    } else if (std.mem.eql(u8, entity_type, "story")) {
        try setStoryAssignee(conn, entity_id, agent_id);
    } else if (std.mem.eql(u8, entity_type, "task")) {
        try setTaskAssignee(conn, entity_id, agent_id);
    } else if (std.mem.eql(u8, entity_type, "subtask")) {
        try setSubTaskAssignee(conn, entity_id, agent_id);
    } else if (std.mem.eql(u8, entity_type, "bug")) {
        try queries_bug.setAssignee(conn, entity_id, agent_id);
    } else {
        return error.InvalidEntityType;
    }

    conn.commit() catch |err| {
        conn.rollback();
        return err;
    };
}

/// Suggest agents for a piece of work based on capability matching.
/// Uses domain/assignment.zig's `suggestAgents` function.
pub fn suggestAssignment(srv: *Service, allocator: std.mem.Allocator, entity_id: i64, entity_type: []const u8) !std.ArrayList([]const u8) {
    const conn = srv.conn;

    // Get all agents
    var agents = try queries_agents.listAll(conn, allocator);
    defer {
        for (agents.items) |a| entities.freeAgentProfile(allocator, a);
        agents.deinit(allocator);
    }

    // Get the entity's title/type for matching
    const title = try getEntityTitle(conn, allocator, entity_type, entity_id);
    defer allocator.free(title);

    return domain_assignment.suggestAgents(allocator, agents.items, title, entity_type);
}

/// Get work items assigned to a specific agent.
/// Returns formatted text describing the work.
pub fn getMyWork(srv: *Service, allocator: std.mem.Allocator, agent_id: i64) ![]u8 {
    const conn = srv.conn;

    var result = std.array_list.Managed(u8).init(allocator);
    try result.appendSlice("Work for agent ");
    try result.appendSlice(try std.fmt.allocPrint(allocator, "{d}", .{agent_id}));

    // Query each entity type for items assigned to this agent
    inline for (.{ "epic", "story", "task", "subtask", "bug" }) |etype| {
        try appendWorkForEntityType(conn, allocator, &result, etype, agent_id);
    }

    return result.toOwnedSlice() catch return error.OutOfMemory;
}

// --- Private helpers ---

fn setEpicAssignee(conn: *db.Connection, epic_id: i64, agent_id: i64) !void {
    var stmt = try conn.prepare("UPDATE epics SET assignee_agent_id = ? WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    stmt.bindInt64(2, epic_id);
    _ = try stmt.step();
}

fn setStoryAssignee(conn: *db.Connection, story_id: i64, agent_id: i64) !void {
    var stmt = try conn.prepare("UPDATE stories SET assignee_agent_id = ? WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    stmt.bindInt64(2, story_id);
    _ = try stmt.step();
}

fn setTaskAssignee(conn: *db.Connection, task_id: i64, agent_id: i64) !void {
    var stmt = try conn.prepare("UPDATE tasks SET assignee_agent_id = ? WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    stmt.bindInt64(2, task_id);
    _ = try stmt.step();
}

fn setSubTaskAssignee(conn: *db.Connection, subtask_id: i64, agent_id: i64) !void {
    var stmt = try conn.prepare("UPDATE subtasks SET assignee_agent_id = ? WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    stmt.bindInt64(2, subtask_id);
    _ = try stmt.step();
}

fn getEntityTitle(conn: *db.Connection, allocator: std.mem.Allocator, entity_type: []const u8, entity_id: i64) ![]u8 {
    if (std.mem.eql(u8, entity_type, "epic")) {
        const epic = try queries_epic.getById(conn, allocator, entity_id);
        if (epic) |e| {
            defer entities.freeEpic(allocator, e);
            return allocator.dupe(u8, e.title);
        }
    } else if (std.mem.eql(u8, entity_type, "story")) {
        const story = try queries_story.getById(conn, allocator, entity_id);
        if (story) |s| {
            defer entities.freeStory(allocator, s);
            return allocator.dupe(u8, s.title);
        }
    } else if (std.mem.eql(u8, entity_type, "task")) {
        const task = try queries_task.getById(conn, allocator, entity_id);
        if (task) |t| {
            defer entities.freeTask(allocator, t);
            return allocator.dupe(u8, t.title);
        }
    } else if (std.mem.eql(u8, entity_type, "subtask")) {
        const subtask = try queries_subtask.getById(conn, allocator, entity_id);
        if (subtask) |st| {
            defer entities.freeSubTask(allocator, st);
            return allocator.dupe(u8, st.title);
        }
    } else if (std.mem.eql(u8, entity_type, "bug")) {
        const bug = try queries_bug.getById(conn, allocator, entity_id);
        if (bug) |b| {
            defer entities.freeBug(allocator, b);
            return allocator.dupe(u8, b.title);
        }
    }
    return error.NotFound;
}

fn appendWorkForEntityType(conn: *db.Connection, allocator: std.mem.Allocator, result: *std.array_list.Managed(u8), entity_type: []const u8, agent_id: i64) !void {
    const type_label = blk: {
        if (std.mem.eql(u8, entity_type, "epic")) break :blk "epic";
        if (std.mem.eql(u8, entity_type, "story")) break :blk "story";
        if (std.mem.eql(u8, entity_type, "task")) break :blk "task";
        if (std.mem.eql(u8, entity_type, "subtask")) break :blk "subtask";
        if (std.mem.eql(u8, entity_type, "bug")) break :blk "bug";
        return;
    };

    const query_str = if (std.mem.eql(u8, type_label, "epic"))
        "SELECT id, title FROM epics WHERE assignee_agent_id = ?"
    else if (std.mem.eql(u8, type_label, "story"))
        "SELECT id, title FROM stories WHERE assignee_agent_id = ?"
    else if (std.mem.eql(u8, type_label, "task"))
        "SELECT id, title FROM tasks WHERE assignee_agent_id = ?"
    else if (std.mem.eql(u8, type_label, "subtask"))
        "SELECT id, title FROM subtasks WHERE assignee_agent_id = ?"
    else if (std.mem.eql(u8, type_label, "bug"))
        "SELECT id, title FROM bugs WHERE assignee_agent_id = ?"
    else
        "SELECT id, title FROM subtasks WHERE assignee_agent_id = ?";

    var stmt = try conn.prepare(query_str);
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);

    var count: usize = 0;
    while (true) {
        const step_result = stmt.step() catch break;
        if (step_result != .row) break;
        const id_opt = stmt.columnInt64Safe(0) orelse break;
        const title_val = stmt.columnText(1) orelse break;

        if (count == 0) {
            try result.appendSlice(": ");
            if (std.mem.eql(u8, type_label, "story")) {
                try result.appendSlice("stories: ");
            } else {
                try result.appendSlice(type_label);
                try result.appendSlice("s: ");
            }
        } else {
            try result.appendSlice(", ");
        }
        try result.appendSlice(std.fmt.allocPrint(allocator, "{d}", .{id_opt}) catch return);
        try result.appendSlice(" (");
        try result.appendSlice(title_val);
        try result.appendSlice(")");
        count += 1;
        stmt.reset();
    }

    if (count == 0) {
        try result.appendSlice(": no ");
        if (std.mem.eql(u8, type_label, "story")) {
            try result.appendSlice("stories assigned\n");
        } else {
            try result.appendSlice(type_label);
            try result.appendSlice("s assigned\n");
        }
    } else {
        try result.appendSlice("\n");
    }
}
