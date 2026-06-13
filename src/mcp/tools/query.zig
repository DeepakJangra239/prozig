const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const errorz = @import("../../error.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "search")) {
        return handleSearch(s, args);
    }

    if (std.mem.eql(u8, tool_name, "filter")) {
        return handleFilter(s, args);
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}

fn handleSearch(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const query = args.getRequiredString("query") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "query");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");

    // Build LIKE pattern: %query%
    var like_pattern = std.array_list.Managed(u8).init(alloc);
    defer like_pattern.deinit();
    try like_pattern.append('%');
    try like_pattern.appendSlice(query);
    try like_pattern.append('%');

    var results = std.array_list.Managed(u8).init(alloc);
    defer results.deinit();
    var total: usize = 0;

    // Search each entity type
    const searchTables = [_]struct {
        table: []const u8,
        label: []const u8,
    }{
        .{ .table = "epics", .label = "EPIC" },
        .{ .table = "stories", .label = "STORY" },
        .{ .table = "tasks", .label = "TASK" },
        .{ .table = "subtasks", .label = "SUBTASK" },
        .{ .table = "bugs", .label = "BUG" },
    };

    for (searchTables) |st| {
        try searchTable(s.conn, alloc, st.table, st.label, project_id, like_pattern.items, &results, &total);
    }

    if (total == 0) {
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "No results found for '{s}'", .{query}) catch "alloc error");
    }

    const header = std.fmt.allocPrint(alloc, "Search results for '{s}' ({d} found):\n", .{ query, total }) catch "alloc error";
    defer alloc.free(header);
    var full = std.array_list.Managed(u8).init(alloc);
    try full.appendSlice(header);
    try full.appendSlice(results.items);
    const content = try full.toOwnedSlice();
    return json.stringifyTextResponse(alloc, content);
}

fn searchTable(conn: *db.Connection, alloc: std.mem.Allocator, table: []const u8, label: []const u8, project_id: i64, like_pattern: []const u8, results: *std.array_list.Managed(u8), total: *usize) !void {
    const sql = try std.fmt.allocPrint(alloc, "SELECT id, title, status FROM {s} WHERE project_id = ? AND (title LIKE ? OR description LIKE ?) ORDER BY created_at DESC", .{table});
    defer alloc.free(sql);

    var stmt = conn.prepare(sql) catch return;
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, like_pattern);
    stmt.bindText(3, like_pattern);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        const title = stmt.columnText(1) orelse "";
        const status = stmt.columnText(2) orelse "";
        const line = std.fmt.allocPrint(alloc, "  [{s}] #{d} {s} (status: {s})\n", .{ label, id_opt.?, title, status }) catch continue;
        try results.appendSlice(line);
        alloc.free(line);
        total.* += 1;
    }
}

fn handleFilter(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
    const entity_type = args.getOptionalString("entity_type");
    const status = args.getOptionalString("status");

    // Validate entity_type if provided
    if (entity_type) |et| {
        const valid = std.mem.eql(u8, et, "epic") or std.mem.eql(u8, et, "story") or
            std.mem.eql(u8, et, "task") or std.mem.eql(u8, et, "subtask") or
            std.mem.eql(u8, et, "bug");
        if (!valid) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_type must be epic, story, task, subtask, or bug");
        }
    }

    var results = std.array_list.Managed(u8).init(alloc);
    defer results.deinit();
    var total: usize = 0;

    // Determine which tables to query
    if (entity_type) |et| {
        const tbl = tableName(et);
        try filterTable(s.conn, alloc, tbl, et, project_id, status, &results, &total);
    } else {
        const allTables = [_]struct {
            table: []const u8,
            label: []const u8,
        }{
            .{ .table = "epics", .label = "epic" },
            .{ .table = "stories", .label = "story" },
            .{ .table = "tasks", .label = "task" },
            .{ .table = "subtasks", .label = "subtask" },
            .{ .table = "bugs", .label = "bug" },
        };
        for (allTables) |st| {
            try filterTable(s.conn, alloc, st.table, st.label, project_id, status, &results, &total);
        }
    }

    if (total == 0) {
        if (status) |st| {
            return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "No entities found with status '{s}'", .{st}) catch "alloc error");
        }
        return json.stringifyTextResponse(alloc, "No entities found");
    }

    const header = std.fmt.allocPrint(alloc, "Filtered results ({d} found):\n", .{total}) catch "alloc error";
    defer alloc.free(header);
    var full = std.array_list.Managed(u8).init(alloc);
    try full.appendSlice(header);
    try full.appendSlice(results.items);
    const content = try full.toOwnedSlice();
    return json.stringifyTextResponse(alloc, content);
}

fn filterTable(conn: *db.Connection, alloc: std.mem.Allocator, table: []const u8, label: []const u8, project_id: i64, status: ?[]const u8, results: *std.array_list.Managed(u8), total: *usize) !void {
    const has_status = status != null;
    const sql = if (has_status) std.fmt.allocPrint(alloc, "SELECT id, title, status FROM {s} WHERE project_id = ? AND status = ?", .{table}) catch return
    else std.fmt.allocPrint(alloc, "SELECT id, title, status FROM {s} WHERE project_id = ?", .{table}) catch return;
    defer alloc.free(sql);

    var stmt = conn.prepare(sql) catch return;
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    if (status) |st| stmt.bindText(2, st);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        const title = stmt.columnText(1) orelse "";
        const row_status = stmt.columnText(2) orelse "";
        const line = std.fmt.allocPrint(alloc, "  [{s}] #{d} {s} (status: {s})\n", .{ label, id_opt.?, title, row_status }) catch continue;
        try results.appendSlice(line);
        alloc.free(line);
        total.* += 1;
    }
}

fn tableName(entity_type: []const u8) []const u8 {
    return if (std.mem.eql(u8, entity_type, "epic")) "epics"
    else if (std.mem.eql(u8, entity_type, "story")) "stories"
    else if (std.mem.eql(u8, entity_type, "task")) "tasks"
    else if (std.mem.eql(u8, entity_type, "subtask")) "subtasks"
    else if (std.mem.eql(u8, entity_type, "bug")) "bugs"
    else entity_type;
}
