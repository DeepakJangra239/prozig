const std = @import("std");
const Service = @import("root.zig").Service;
const queries_epic = @import("../db/queries/epics.zig");
const queries_story = @import("../db/queries/stories.zig");
const queries_task = @import("../db/queries/tasks.zig");
const queries_subtask = @import("../db/queries/subtasks.zig");
const queries_bug = @import("../db/queries/bug.zig");
const queries_wiki = @import("../db/queries/wiki.zig");
const queries_agents = @import("../db/queries/agents.zig");
const validation = @import("../domain/validation.zig");

// ─── Update Operations ───

pub fn updateEpic(srv: *Service, allocator: std.mem.Allocator, epic_id: i64, title: ?[]const u8, description: ?[]const u8) !void {
    if (title == null and description == null) {
        return error.NoFieldsToUpdate;
    }
    validation.validateEpicOpt(title, description) catch return error.InvalidField;
    try queries_epic.updatePartial(srv.conn, allocator, epic_id, title, description);
}

pub fn updateStory(srv: *Service, allocator: std.mem.Allocator, story_id: i64, title: ?[]const u8, description: ?[]const u8, acceptance_criteria: ?[]const u8) !void {
    if (title == null and description == null and acceptance_criteria == null) {
        return error.NoFieldsToUpdate;
    }
    validation.validateStoryOpt(title, description, acceptance_criteria) catch return error.InvalidField;
    try queries_story.updatePartial(srv.conn, allocator, story_id, title, description, acceptance_criteria);
}

pub fn updateTask(srv: *Service, allocator: std.mem.Allocator, task_id: i64, title: ?[]const u8, description: ?[]const u8) !void {
    if (title == null and description == null) {
        return error.NoFieldsToUpdate;
    }
    validation.validateTaskOpt(title, description) catch return error.InvalidField;
    try queries_task.updatePartial(srv.conn, allocator, task_id, title, description);
}

pub fn updateSubtask(srv: *Service, allocator: std.mem.Allocator, subtask_id: i64, title: ?[]const u8, description: ?[]const u8) !void {
    if (title == null and description == null) {
        return error.NoFieldsToUpdate;
    }
    validation.validateSubTaskOpt(title, description) catch return error.InvalidField;
    try queries_subtask.updatePartial(srv.conn, allocator, subtask_id, title, description);
}

pub fn updateBug(srv: *Service, allocator: std.mem.Allocator, bug_id: i64, title: ?[]const u8, description: ?[]const u8, severity: ?[]const u8) !void {
    if (title == null and description == null and severity == null) {
        return error.NoFieldsToUpdate;
    }
    validation.validateBugOpt(title, description, severity) catch return error.InvalidField;
    try queries_bug.updatePartial(srv.conn, allocator, bug_id, title, description, severity);
}

// ─── Cascade Delete Operations ───

pub fn deleteEpicWithChildren(srv: *Service, epic_id: i64) !void {
    srv.conn.begin() catch |err| return err;
    errdefer srv.conn.rollback();
    try queries_epic.deleteWithChildren(srv.conn, epic_id);
    try srv.conn.commit();
}

pub fn deleteStoryWithChildren(srv: *Service, story_id: i64) !void {
    srv.conn.begin() catch |err| return err;
    errdefer srv.conn.rollback();
    try queries_story.deleteWithChildren(srv.conn, story_id);
    try srv.conn.commit();
}

pub fn deleteTaskWithChildren(srv: *Service, task_id: i64) !void {
    srv.conn.begin() catch |err| return err;
    errdefer srv.conn.rollback();
    try queries_task.deleteWithChildren(srv.conn, task_id);
    try srv.conn.commit();
}

// ─── Simple Delete Operations ───

pub fn deleteWiki(srv: *Service, page_id: i64) !void {
    try queries_wiki.delete(srv.conn, page_id);
}

pub fn deleteAgent(srv: *Service, agent_id: i64) !void {
    try queries_agents.delete(srv.conn, agent_id);
}
