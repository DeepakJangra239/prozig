const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/bug.zig");
const queries_comments = @import("../../db/queries/comments.zig");
const entities = @import("../../domain/entities.zig");
const errorz = @import("../../error.zig");
const lifecycle = @import("../../domain/lifecycle.zig");
const validation = @import("../../domain/validation.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "bug_create")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const title = args.getRequiredString("title") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title");
        const description = args.getRequiredString("description") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "description");
        const severity = args.getRequiredString("severity") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "severity");
        const epic_id_str = args.getOptionalString("epic_id");
        const story_id_str = args.getOptionalString("story_id");
        const task_id_str = args.getOptionalString("task_id");

        validation.validateBug(project_id, title, description, severity) catch |err| return switch (err) {
            error.MissingField => json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title, description, severity are required"),
            error.InvalidField => json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "severity must be one of: critical, high, medium, low"),
        };

        const epic_id = if (epic_id_str) |eid| std.fmt.parseInt(i64, eid, 10) catch null else null;
        const story_id = if (story_id_str) |sid| std.fmt.parseInt(i64, sid, 10) catch null else null;
        const task_id = if (task_id_str) |tid| std.fmt.parseInt(i64, tid, 10) catch null else null;

        const bug = try queries.insert(s.conn, alloc, project_id, title, description, severity, epic_id, story_id, task_id);
        defer {
            s.allocator.free(bug.title);
            if (bug.description) |d| s.allocator.free(d);
            s.allocator.free(bug.severity);
            s.allocator.free(bug.created_at);
            s.allocator.free(bug.updated_at);
        }
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Bug '{s}' created (id: {d}, severity: {s})", .{ title, bug.id, severity }) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "bug_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const bug = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (bug) |b| {
            defer {
                s.allocator.free(b.title);
                if (b.description) |d| s.allocator.free(d);
                s.allocator.free(b.severity);
                s.allocator.free(b.created_at);
                s.allocator.free(b.updated_at);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(try std.fmt.allocPrint(alloc, "Bug: {s} (id: {d}, severity: {s}, status: {s})", .{ b.title, b.id, b.severity, lifecycle.bugStatusToDb(b.status) }));
            if (try queries_comments.formatCommentsForResponse(alloc, s.conn, "bug", id)) |comments_str| {
                defer alloc.free(comments_str);
                try buf.appendSlice(comments_str);
            }
            return json.stringifyTextResponse(alloc, buf.items);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Bug");
    }

    if (std.mem.eql(u8, tool_name, "bug_list")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        var bugs = try queries.listByProject(s.conn, alloc, project_id);
        defer {
            for (bugs.items) |b| entities.freeBug(alloc, b);
            bugs.deinit(alloc);
        }
        {
            var list_buf = std.array_list.Managed(u8).init(alloc);
            try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} bugs:", .{bugs.items.len}));
            for (bugs.items) |b| {
                const piece = try std.fmt.allocPrint(alloc, " {d} ({s}) [{s}]", .{ b.id, b.title, b.severity });
                try list_buf.appendSlice(piece);
                alloc.free(piece);
            }
            const result = try json.stringifyTextResponse(alloc, list_buf.items);
            list_buf.deinit();
            return result;
        }
    }

    if (std.mem.eql(u8, tool_name, "bug_delete")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        queries.delete(s.conn, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        return json.stringifyTextResponse(alloc, "Bug deleted");
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}
