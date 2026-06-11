/// MCP handler for comment tools: comment_create, comment_list, comment_update, comment_delete.
/// Agents can comment on any entity (epic, story, task, subtask, bug, wiki).
/// Comments are returned when reading an entity via the entity's *_get tool.
/// Author-based authorization: only the author can update/delete their own comment.
const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/comments.zig");
const entities = @import("../../domain/entities.zig");
const errorz = @import("../../error.zig");
const validation = @import("../../domain/validation.zig");
const workflow = @import("../../service/workflow.zig");
const agent_queries = @import("../../db/queries/agents.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "comment_create")) {
        return handleCreate(s, args);
    }
    if (std.mem.eql(u8, tool_name, "comment_list")) {
        return handleList(s, args);
    }
    if (std.mem.eql(u8, tool_name, "comment_update")) {
        return handleUpdate(s, args);
    }
    if (std.mem.eql(u8, tool_name, "comment_delete")) {
        return handleDelete(s, args);
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}

fn handleCreate(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const entity_type = args.getRequiredString("entity_type") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_type");
    const entity_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
    const entity_id = std.fmt.parseInt(i64, entity_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
    const content = args.getRequiredString("content") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "content");
    const agent_id_str = args.getRequiredString("agent_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "agent_id");
    const agent_id = std.fmt.parseInt(i64, agent_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "agent_id must be an integer");

    validation.validateComment(content) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "comment content is too short (min 5 chars)");

    // Look up agent name
    const agent = agent_queries.getById(s.conn, alloc, agent_id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    if (agent == null) return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Agent not found");
    const agent_name = agent.?.name;
    defer {
        alloc.free(agent.?.name);
        if (agent.?.description) |d| alloc.free(d);
        alloc.free(agent.?.capabilities);
        if (agent.?.metadata) |m| alloc.free(m);
        alloc.free(agent.?.created_at);
        alloc.free(agent.?.updated_at);
    }

    // Resolve project_id from the entity
    const project_id = workflow.getEntityProjectId(s.conn, entity_type, entity_id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    if (project_id == null) return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Entity not found");

    const comment = queries.insert(s.conn, alloc, project_id.?, entity_type, entity_id, "agent", agent_id, agent_name, content) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    defer entities.freeComment(alloc, comment);

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Comment added (id: {d}) on {s} #{d}", .{ comment.id, entity_type, entity_id }) catch "comment added");
}

fn handleList(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const entity_type = args.getRequiredString("entity_type") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_type");
    const entity_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
    const entity_id = std.fmt.parseInt(i64, entity_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");

    var comments = try queries.listByEntity(s.conn, alloc, entity_type, entity_id);
    defer {
        for (comments.items) |c| entities.freeComment(alloc, c);
        comments.deinit(alloc);
    }

    if (comments.items.len == 0) {
        return json.stringifyTextResponse(alloc, "No comments on this entity");
    }

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(try std.fmt.allocPrint(alloc, "Comments ({d}):", .{comments.items.len}));
    for (comments.items) |c| {
        const line = try std.fmt.allocPrint(alloc, "  [{s}] {s} @ {s}: {s}", .{ c.author_type, c.author_name, c.created_at, c.content });
        try buf.appendSlice(line);
        alloc.free(line);
    }
    return json.stringifyTextResponse(alloc, buf.items);
}

fn handleUpdate(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const comment_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id (comment id)");
    const comment_id = std.fmt.parseInt(i64, comment_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
    const content = args.getRequiredString("content") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "content");
    const agent_id_str = args.getRequiredString("agent_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "agent_id");
    const agent_id = std.fmt.parseInt(i64, agent_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "agent_id must be an integer");

    validation.validateComment(content) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "comment content is too short (min 5 chars)");

    // Authorization: only the author can update
    const comment = queries.getById(s.conn, alloc, comment_id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    if (comment == null) return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Comment not found");
    const c = comment.?;
    defer entities.freeComment(alloc, c);

    if (c.author_type[0] == 'a' and c.author_id != agent_id) {
        return json.stringifyCatalogError(alloc, errorz.Errors.PERMISSION_DENIED.code, errorz.Errors.PERMISSION_DENIED.message, "only the author can update this comment");
    }

    queries.updateContent(s.conn, comment_id, content) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    return json.stringifyTextResponse(alloc, "Comment updated");
}

fn handleDelete(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const comment_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id (comment id)");
    const comment_id = std.fmt.parseInt(i64, comment_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
    const agent_id_str = args.getRequiredString("agent_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "agent_id");
    const agent_id = std.fmt.parseInt(i64, agent_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "agent_id must be an integer");

    // Authorization: only the author can delete
    const comment = queries.getById(s.conn, alloc, comment_id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    if (comment == null) return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Comment not found");
    const c = comment.?;
    defer entities.freeComment(alloc, c);

    if (c.author_type[0] == 'a' and c.author_id != agent_id) {
        return json.stringifyCatalogError(alloc, errorz.Errors.PERMISSION_DENIED.code, errorz.Errors.PERMISSION_DENIED.message, "only the author can delete this comment");
    }

    queries.delete(s.conn, comment_id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    return json.stringifyTextResponse(alloc, "Comment deleted");
}
