/// MCP handler for memory tools: memory_save, memory_get, memory_list, memory_delete, memory_update, update_project_summary.
const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const json_value = json.JsonValue;
const service = @import("../../service/memory.zig");
const queries = @import("../../db/queries/memory.zig");
const entities = @import("../../domain/entities.zig");
const lifecycle = @import("../../domain/lifecycle.zig");
const errorz = @import("../../error.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json_value) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "memory_save")) {
        return handleSave(s, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_get")) {
        return handleGet(s, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_list")) {
        return handleList(s, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_delete")) {
        return handleDelete(s, args);
    }
    if (std.mem.eql(u8, tool_name, "memory_update")) {
        return handleUpdate(s, args);
    }
    if (std.mem.eql(u8, tool_name, "update_project_summary")) {
        return handleUpdateSummary(s, args);
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}

fn handleSave(s: *Server, args: json_value) ![]const u8 {
    const alloc = s.allocator;

    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");

    const scope_str = args.getRequiredString("scope") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "scope");
    const scope = lifecycle.memoryScopeFromDb(scope_str) orelse return json.stringifyCatalogError(alloc, errorz.Errors.MEMORY_INVALID_SCOPE.code, errorz.Errors.MEMORY_INVALID_SCOPE.message, scope_str);

    const category_str = args.getRequiredString("category") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "category");
    const category = lifecycle.memoryCategoryFromDb(category_str) orelse return json.stringifyCatalogError(alloc, errorz.Errors.MEMORY_INVALID_CATEGORY.code, errorz.Errors.MEMORY_INVALID_CATEGORY.message, category_str);

    const title = args.getRequiredString("title") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title");
    const content = args.getRequiredString("content") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "content");

    const role_name = args.getOptionalString("role_name");
    const summary = args.getOptionalString("summary");
    const tags = args.getOptionalString("tags");

    var importance: lifecycle.MemoryImportance = .high;
    if (args.getString("importance")) |imp_str| {
        importance = switch (imp_str[0]) {
            '1' => .low,
            '2' => .medium,
            '3' => .high,
            '4' => .critical,
            else => .high,
        };
    }

    var entity_id: ?i64 = null;
    if (args.getString("entity_id")) |eid_str| {
        entity_id = std.fmt.parseInt(i64, eid_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
    }

    const entry = service.saveMemory(s.conn, alloc, project_id, role_name, scope, entity_id, category, title, content, summary, tags, importance) catch |err| {
        if (err == error.MemoryCapExceeded) {
            return json.stringifyCatalogError(alloc, errorz.Errors.MEMORY_CAP_EXCEEDED.code, errorz.Errors.MEMORY_CAP_EXCEEDED.message, "");
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    };
    defer entities.freeMemoryEntry(alloc, entry);

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Memory saved (id: {d}): {s}", .{ entry.id, entry.title }) catch "memory saved");
}

fn handleGet(s: *Server, args: json_value) ![]const u8 {
    const alloc = s.allocator;

    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");

    var filter = queries.MemoryFilter{ .project_id = project_id };

    if (args.getString("scope")) |scope_str| {
        filter.scope = lifecycle.memoryScopeFromDb(scope_str) orelse return json.stringifyCatalogError(alloc, errorz.Errors.MEMORY_INVALID_SCOPE.code, errorz.Errors.MEMORY_INVALID_SCOPE.message, scope_str);
    }
    if (args.getString("entity_id")) |eid_str| {
        filter.entity_id = std.fmt.parseInt(i64, eid_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
    }
    if (args.getString("category")) |cat_str| {
        filter.category = lifecycle.memoryCategoryFromDb(cat_str) orelse return json.stringifyCatalogError(alloc, errorz.Errors.MEMORY_INVALID_CATEGORY.code, errorz.Errors.MEMORY_INVALID_CATEGORY.message, cat_str);
    }
    if (args.getString("query")) |q| {
        filter.query = q;
    }
    if (args.getString("limit")) |lim_str| {
        filter.limit = std.fmt.parseInt(usize, lim_str, 10) catch 5;
    }

    var results = service.retrieveMemories(s.conn, alloc, filter) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    defer {
        for (results.items) |m| entities.freeMemoryEntry(alloc, m);
        results.deinit(alloc);
    }

    if (results.items.len == 0) {
        return json.stringifyTextResponse(alloc, "No memories found matching the criteria");
    }

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(try std.fmt.allocPrint(alloc, "Memories ({d}):", .{results.items.len}));
    for (results.items) |m| {
        const line = try std.fmt.allocPrint(alloc, "\n[{s}] {s} (importance: {d}, {s})", .{ m.category, m.title, m.importance, m.created_at });
        try buf.appendSlice(line);
        alloc.free(line);
        const content_line = try std.fmt.allocPrint(alloc, "{s}", .{m.content});
        try buf.appendSlice(content_line);
        alloc.free(content_line);
    }
    return json.stringifyTextResponse(alloc, buf.items);
}

fn handleList(s: *Server, args: json_value) ![]const u8 {
    const alloc = s.allocator;

    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");

    var results = queries.listByProject(s.conn, alloc, project_id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    defer {
        for (results.items) |m| entities.freeMemoryEntry(alloc, m);
        results.deinit(alloc);
    }

    if (results.items.len == 0) {
        return json.stringifyTextResponse(alloc, "No memories found for this project");
    }

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(try std.fmt.allocPrint(alloc, "Memories ({d}):", .{results.items.len}));
    for (results.items) |m| {
        const line = try std.fmt.allocPrint(alloc, "\n#{d} [{s}] {s} (scope: {s}, importance: {d})", .{ m.id, m.category, m.title, m.scope, m.importance });
        try buf.appendSlice(line);
        alloc.free(line);
    }
    return json.stringifyTextResponse(alloc, buf.items);
}

fn handleDelete(s: *Server, args: json_value) ![]const u8 {
    const alloc = s.allocator;

    const entity_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
    const memory_id = std.fmt.parseInt(i64, entity_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");

    service.deleteMemory(s.conn, alloc, memory_id) catch |err| {
        if (err == error.NotFound) {
            return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Memory not found");
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    };

    return json.stringifyTextResponse(alloc, "Memory deleted");
}

fn handleUpdate(s: *Server, args: json_value) ![]const u8 {
    const alloc = s.allocator;

    const entity_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
    const memory_id = std.fmt.parseInt(i64, entity_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");

    const title = args.getOptionalString("title");
    const content = args.getOptionalString("content");
    const summary = args.getOptionalString("summary");
    const tags = args.getOptionalString("tags");

    var importance: ?lifecycle.MemoryImportance = null;
    if (args.getString("importance")) |imp_str| {
        importance = switch (imp_str[0]) {
            '1' => .low,
            '2' => .medium,
            '3' => .high,
            '4' => .critical,
            else => null,
        };
    }

    queries.update(s.conn, alloc, memory_id, title, content, summary, tags, importance) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));

    return json.stringifyTextResponse(alloc, "Memory updated");
}

fn handleUpdateSummary(s: *Server, args: json_value) ![]const u8 {
    const alloc = s.allocator;

    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");

    const narrative = args.getOptionalString("narrative");
    const bullets = args.getOptionalString("bullets");

    const summary = service.updateProjectSummary(s.conn, alloc, project_id, narrative, bullets) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    defer entities.freeProjectSummary(alloc, summary);

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Project summary updated (version: {d})", .{summary.version}) catch "summary updated");
}
