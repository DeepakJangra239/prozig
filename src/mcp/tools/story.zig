const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/stories.zig");
const queries_epics = @import("../../db/queries/epics.zig");
const queries_comments = @import("../../db/queries/comments.zig");
const queries_memory = @import("../../db/queries/memory.zig");
const entities = @import("../../domain/entities.zig");
const errorz = @import("../../error.zig");
const lifecycle = @import("../../domain/lifecycle.zig");
const validation = @import("../../domain/validation.zig");
const workflow = @import("../../service/workflow.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "story_create")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const epic_id_str = args.getRequiredString("epic_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "epic_id");
        const epic_id = std.fmt.parseInt(i64, epic_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "epic_id must be an integer");
        const title = args.getRequiredString("title") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title");
        const description = args.getRequiredString("description") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "description");
        const acceptance_criteria = args.getRequiredString("acceptance_criteria") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "acceptance_criteria");

        validation.validateStory(project_id, epic_id, title, description, acceptance_criteria) catch |err| return switch (err) {
            error.MissingField => json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title, description, acceptance_criteria are required"),
            error.InvalidField => json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id, epic_id must be > 0"),
        };

        // Create-time guard: parent epic must not be in terminal state
        if (!try workflow.validateCreateParentState(s.conn, "epic", epic_id)) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, "parent epic is in a terminal state");
        }

        const story = try queries.insert(s.conn, alloc, project_id, epic_id, title, description, acceptance_criteria);
        defer {
            s.allocator.free(story.title);
            if (story.description) |d| s.allocator.free(d);
            if (story.acceptance_criteria) |a| s.allocator.free(a);
            s.allocator.free(story.created_at);
            s.allocator.free(story.updated_at);
        }
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Story '{s}' created", .{title}) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "story_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const story = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (story) |s2| {
            defer {
                s.allocator.free(s2.title);
                if (s2.description) |d| s.allocator.free(d);
                if (s2.acceptance_criteria) |a| s.allocator.free(a);
                s.allocator.free(s2.created_at);
                s.allocator.free(s2.updated_at);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(try std.fmt.allocPrint(alloc, "Story: {s} (id: {d}, status: {s})", .{ s2.title, s2.id, lifecycle.storyStatusToDb(s2.status) }));
            // Parent epic context
            const parent_epic = queries_epics.getById(s.conn, alloc, s2.epic_id) catch null;
            if (parent_epic) |pe| {
                defer entities.freeEpic(alloc, pe);
                try buf.appendSlice(try std.fmt.allocPrint(alloc, "\nParent Epic: {s} (id: {d})", .{ pe.title, pe.id }));
            }
            if (try queries_comments.formatCommentsForResponse(alloc, s.conn, "story", id)) |comments_str| {
                defer alloc.free(comments_str);
                try buf.appendSlice(comments_str);
            }
            // Memory injection: project summary + related memories
            if (try queries_memory.formatProjectSummaryForResponse(alloc, s.conn, s2.project_id)) |summary_str| {
                defer alloc.free(summary_str);
                try buf.appendSlice(summary_str);
            }
            if (try queries_memory.formatMemoriesForResponse(alloc, s.conn, "story", s2.id)) |mem_str| {
                defer alloc.free(mem_str);
                try buf.appendSlice(mem_str);
            }
            return json.stringifyTextResponse(alloc, buf.items);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Story");
    }

    if (std.mem.eql(u8, tool_name, "story_list")) {
        const epic_id_str = args.getRequiredString("epic_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "epic_id");
        const epic_id = std.fmt.parseInt(i64, epic_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "epic_id must be an integer");
        var stories = try queries.listByEpic(s.conn, alloc, epic_id);
        defer {
            for (stories.items) |st| entities.freeStory(alloc, st);
            stories.deinit(alloc);
        }
        {
            var list_buf = std.array_list.Managed(u8).init(alloc);
            try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} stories:", .{stories.items.len}));
            for (stories.items) |st| {
                const piece = try std.fmt.allocPrint(alloc, " {d} ({s})", .{ st.id, st.title });
                try list_buf.appendSlice(piece);
                alloc.free(piece);
            }
            const result = try json.stringifyTextResponse(alloc, list_buf.items);
            list_buf.deinit();
            return result;
        }
    }

    if (std.mem.eql(u8, tool_name, "story_delete")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        queries.delete(s.conn, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        return json.stringifyTextResponse(alloc, "Story deleted");
    }

    if (std.mem.eql(u8, tool_name, "story_update")) {
        // PATCH semantics: only the fields explicitly provided are written.
        // Any field that IS provided must meet the same min-length standard
        // as a create call (no blanking-out of existing content).
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const title = args.getOptionalString("title");
        const description = args.getOptionalString("description");
        const acceptance_criteria = args.getOptionalString("acceptance_criteria");

        if (title == null and description == null and acceptance_criteria == null) {
            return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "at least one of title, description, acceptance_criteria must be provided");
        }
        validation.validateTitleOpt(title) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title is too short (min 3 chars)");
        validation.validateDescriptionOpt(description) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "description is too short (min 20 chars)");
        validation.validateAcceptanceCriteriaOpt(acceptance_criteria) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "acceptance_criteria is too short (min 20 chars)");

        queries.updatePartial(s.conn, alloc, id, title, description, acceptance_criteria) catch |err| switch (err) {
            error.NoFieldsToUpdate => return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "no fields to update"),
            else => return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err)),
        };
        return json.stringifyTextResponse(alloc, "Story updated");
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}
