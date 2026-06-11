const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/tasks.zig");
const queries_comments = @import("../../db/queries/comments.zig");
const entities = @import("../../domain/entities.zig");
const errorz = @import("../../error.zig");
const lifecycle = @import("../../domain/lifecycle.zig");
const validation = @import("../../domain/validation.zig");
const workflow = @import("../../service/workflow.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "task_create")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const story_id_str = args.getRequiredString("story_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "story_id");
        const story_id = std.fmt.parseInt(i64, story_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "story_id must be an integer");
        const title = args.getRequiredString("title") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title");
        const description = args.getRequiredString("description") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "description");

        validation.validateTask(project_id, story_id, title, description) catch |err| return switch (err) {
            error.MissingField => json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title, description are required"),
            error.InvalidField => json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id, story_id must be > 0"),
        };

        // Create-time guard: parent story must not be in terminal state
        if (!try workflow.validateCreateParentState(s.conn, "story", story_id)) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, "parent story is in a terminal state");
        }

        const task = try queries.insert(s.conn, alloc, project_id, story_id, title, description);
        defer {
            s.allocator.free(task.title);
            if (task.description) |d| s.allocator.free(d);
            s.allocator.free(task.created_at);
            s.allocator.free(task.updated_at);
        }
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Task '{s}' created", .{title}) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "task_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const task = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (task) |t| {
            defer {
                s.allocator.free(t.title);
                if (t.description) |d| s.allocator.free(d);
                s.allocator.free(t.created_at);
                s.allocator.free(t.updated_at);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(try std.fmt.allocPrint(alloc, "Task: {s} (id: {d}, status: {s})", .{ t.title, t.id, lifecycle.taskStatusToDb(t.status) }));
            if (try queries_comments.formatCommentsForResponse(alloc, s.conn, "task", id)) |comments_str| {
                defer alloc.free(comments_str);
                try buf.appendSlice(comments_str);
            }
            return json.stringifyTextResponse(alloc, buf.items);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Task");
    }

    if (std.mem.eql(u8, tool_name, "task_list")) {
        const story_id_str = args.getRequiredString("story_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "story_id");
        const story_id = std.fmt.parseInt(i64, story_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "story_id must be an integer");
        var tasks = try queries.listByStory(s.conn, alloc, story_id);
        defer {
            for (tasks.items) |t| entities.freeTask(alloc, t);
            tasks.deinit(alloc);
        }
        {
            var list_buf = std.array_list.Managed(u8).init(alloc);
            try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} tasks:", .{tasks.items.len}));
            for (tasks.items) |t| {
                const piece = try std.fmt.allocPrint(alloc, " {d} ({s})", .{ t.id, t.title });
                try list_buf.appendSlice(piece);
                alloc.free(piece);
            }
            const result = try json.stringifyTextResponse(alloc, list_buf.items);
            list_buf.deinit();
            return result;
        }
    }

    if (std.mem.eql(u8, tool_name, "task_delete")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        queries.delete(s.conn, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        return json.stringifyTextResponse(alloc, "Task deleted");
    }

    if (std.mem.eql(u8, tool_name, "task_update")) {
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
        return json.stringifyTextResponse(alloc, "Task updated");
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}
