const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/epics.zig");
const queries_comments = @import("../../db/queries/comments.zig");
const queries_memory = @import("../../db/queries/memory.zig");
const entities = @import("../../domain/entities.zig");
const errorz = @import("../../error.zig");
const lifecycle = @import("../../domain/lifecycle.zig");
const validation = @import("../../domain/validation.zig");

fn parseInt64(s: ?[]const u8) ?i64 {
    const val = s orelse return null;
    return std.fmt.parseInt(i64, val, 10) catch return null;
}

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "epic_create")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const title = args.getRequiredString("title") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title");
        const description = args.getRequiredString("description") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "description");
        const parent_epic_id = parseInt64(args.getOptionalString("parent_epic_id"));

        validation.validateEpic(project_id, title, description) catch |err| return switch (err) {
            error.MissingField => json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title, description are required"),
            error.InvalidField => json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be > 0"),
        };

        const epic = try queries.insert(s.conn, alloc, project_id, title, description, parent_epic_id);
        defer {
            s.allocator.free(epic.title);
            if (epic.description) |d| s.allocator.free(d);
            s.allocator.free(epic.created_at);
            s.allocator.free(epic.updated_at);
        }
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Epic '{s}' created (status: Backlog)", .{title}) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "epic_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const epic = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (epic) |e| {
            defer {
                s.allocator.free(e.title);
                if (e.description) |d| s.allocator.free(d);
                s.allocator.free(e.created_at);
                s.allocator.free(e.updated_at);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(try std.fmt.allocPrint(alloc, "Epic: {s} (id: {d}, status: {s})", .{ e.title, e.id, lifecycle.epicStatusToDb(e.status) }));
            if (try queries_comments.formatCommentsForResponse(alloc, s.conn, "epic", id)) |comments_str| {
                defer alloc.free(comments_str);
                try buf.appendSlice(comments_str);
            }
            // Memory injection: project summary + related memories
            if (try queries_memory.formatProjectSummaryForResponse(alloc, s.conn, e.project_id)) |summary_str| {
                defer alloc.free(summary_str);
                try buf.appendSlice(summary_str);
            }
            if (try queries_memory.formatMemoriesForResponse(alloc, s.conn, "epic", e.id)) |mem_str| {
                defer alloc.free(mem_str);
                try buf.appendSlice(mem_str);
            }
            return json.stringifyTextResponse(alloc, buf.items);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Epic");
    }

    if (std.mem.eql(u8, tool_name, "epic_list")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        var epics = try queries.listByProject(s.conn, alloc, project_id);
        defer {
            for (epics.items) |e| entities.freeEpic(s.allocator, e);
            epics.deinit(s.allocator);
        }
        {
            var list_buf = std.array_list.Managed(u8).init(alloc);
            try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} epics:", .{epics.items.len}));
            for (epics.items) |e| {
                const piece = try std.fmt.allocPrint(alloc, " {d} ({s})", .{ e.id, e.title });
                try list_buf.appendSlice(piece);
                alloc.free(piece);
            }
            const result = try json.stringifyTextResponse(alloc, list_buf.items);
            list_buf.deinit();
            return result;
        }
    }

    if (std.mem.eql(u8, tool_name, "epic_delete")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        queries.delete(s.conn, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        return json.stringifyTextResponse(alloc, "Epic deleted");
    }

    if (std.mem.eql(u8, tool_name, "epic_update")) {
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
        return json.stringifyTextResponse(alloc, "Epic updated");
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}
