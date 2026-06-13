const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/subtasks.zig");
const queries_tasks = @import("../../db/queries/tasks.zig");
const queries_comments = @import("../../db/queries/comments.zig");
const entities = @import("../../domain/entities.zig");
const errorz = @import("../../error.zig");
const lifecycle = @import("../../domain/lifecycle.zig");
const validation = @import("../../domain/validation.zig");
const workflow = @import("../../service/workflow.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "subtask_create")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const task_id_str = args.getRequiredString("task_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "task_id");
        const task_id = std.fmt.parseInt(i64, task_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "task_id must be an integer");
        const title = args.getRequiredString("title") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title");
        const description = args.getRequiredString("description") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "description");

        validation.validateSubTask(project_id, task_id, title, description) catch |err| return switch (err) {
            error.MissingField => json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title, description are required"),
            error.InvalidField => json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id, task_id must be > 0"),
        };

        // Verify task belongs to the specified project
        const parent_task_check = queries_tasks.getById(s.conn, alloc, task_id) catch null;
        if (parent_task_check) |ptc| {
            defer entities.freeTask(alloc, ptc);
            if (ptc.project_id != project_id) {
                return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "task_id does not belong to the specified project_id");
            }
        } else {
            return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Task not found");
        }

        // Create-time guard: parent task must not be in terminal state
        if (!try workflow.validateCreateParentState(s.conn, "task", task_id)) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, "parent task is in a terminal state");
        }

        const subtask = try queries.insert(s.conn, alloc, project_id, task_id, title, description);
        defer {
            s.allocator.free(subtask.title);
            if (subtask.description) |d| s.allocator.free(d);
            s.allocator.free(subtask.created_at);
            s.allocator.free(subtask.updated_at);
        }
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "SubTask '{s}' created", .{title}) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "subtask_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const subtask = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (subtask) |st| {
            defer {
                s.allocator.free(st.title);
                if (st.description) |d| s.allocator.free(d);
                s.allocator.free(st.created_at);
                s.allocator.free(st.updated_at);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(try std.fmt.allocPrint(alloc, "SubTask: {s} (id: {d}, status: {s})", .{ st.title, st.id, lifecycle.subTaskStatusToDb(st.status) }));
            // Parent task context
            const parent_task = queries_tasks.getById(s.conn, alloc, st.task_id) catch null;
            if (parent_task) |pt| {
                defer entities.freeTask(alloc, pt);
                try buf.appendSlice(try std.fmt.allocPrint(alloc, "\nParent Task: {s} (id: {d})", .{ pt.title, pt.id }));
            }
            if (try queries_comments.formatCommentsForResponse(alloc, s.conn, "subtask", id)) |comments_str| {
                defer alloc.free(comments_str);
                try buf.appendSlice(comments_str);
            }
            return json.stringifyTextResponse(alloc, buf.items);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "SubTask");
    }

    if (std.mem.eql(u8, tool_name, "subtask_list")) {
        const task_id_str = args.getRequiredString("task_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "task_id");
        const task_id = std.fmt.parseInt(i64, task_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "task_id must be an integer");
        // Optional project_id for cross-validation
        const project_id_str = args.getOptionalString("project_id");
        if (project_id_str) |pid_str| {
            const pid = std.fmt.parseInt(i64, pid_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
            const task_check = queries_tasks.getById(s.conn, alloc, task_id) catch null;
            if (task_check) |tc| {
                defer entities.freeTask(alloc, tc);
                if (tc.project_id != pid) {
                    return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "task_id does not belong to the specified project_id");
                }
            }
        }
        var subtasks = try queries.listByTask(s.conn, alloc, task_id);
        defer {
            for (subtasks.items) |st| entities.freeSubTask(alloc, st);
            subtasks.deinit(alloc);
        }
        {
            var list_buf = std.array_list.Managed(u8).init(alloc);
            try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} subtasks:", .{subtasks.items.len}));
            for (subtasks.items) |st| {
                const piece = try std.fmt.allocPrint(alloc, " {d} ({s})", .{ st.id, st.title });
                try list_buf.appendSlice(piece);
                alloc.free(piece);
            }
            const result = try json.stringifyTextResponse(alloc, list_buf.items);
            list_buf.deinit();
            return result;
        }
    }

    if (std.mem.eql(u8, tool_name, "subtask_delete")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        queries.delete(s.conn, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        return json.stringifyTextResponse(alloc, "SubTask deleted");
    }

    if (std.mem.eql(u8, tool_name, "subtask_update")) {
        // PATCH semantics: only the fields explicitly provided are written.
        // Any field that IS provided must meet the same min-length standard
        // as a create call (no blanking-out of existing content).
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const title = args.getOptionalString("title");
        const description = args.getOptionalString("description");

        if (title == null and description == null) {
            return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "at least one of title, description must be provided");
        }
        validation.validateTitleOpt(title) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title is too short (min 3 chars)");
        validation.validateDescriptionOpt(description) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "description is too short (min 20 chars)");

        queries.updatePartial(s.conn, alloc, id, title, description) catch |err| switch (err) {
            error.NoFieldsToUpdate => return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "no fields to update"),
            else => return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err)),
        };
        return json.stringifyTextResponse(alloc, "SubTask updated");
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}
