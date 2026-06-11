const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/agents.zig");
const errorz = @import("../../error.zig");
const entities = @import("../../domain/entities.zig");
const validation = @import("../../domain/validation.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "agent_profile_create")) {
        const name = args.getRequiredString("name") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "name");
        const capabilities = args.getRequiredString("capabilities") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "capabilities");
        const description = args.getOptionalString("description");

        validation.validateAgent(name, capabilities) catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "name, capabilities are required");

        const agent = try queries.insert(s.conn, alloc, name, capabilities, description);
        defer {
            s.allocator.free(agent.name);
            s.allocator.free(agent.capabilities);
            if (agent.description) |d| s.allocator.free(d);
            s.allocator.free(agent.created_at);
            s.allocator.free(agent.updated_at);
        }
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Agent profile '{s}' created", .{name}) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "agent_profile_list")) {
        var agents = try queries.listAll(s.conn, alloc);
        defer {
            for (agents.items) |a| entities.freeAgentProfile(alloc, a);
            agents.deinit(alloc);
        }
        {
            var list_buf = std.array_list.Managed(u8).init(alloc);
            try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} agent profiles:", .{agents.items.len}));
            for (agents.items) |a| {
                const piece = try std.fmt.allocPrint(alloc, " {d} ({s})", .{ a.id, a.name });
                try list_buf.appendSlice(piece);
                alloc.free(piece);
            }
            const result = try json.stringifyTextResponse(alloc, list_buf.items);
            list_buf.deinit();
            return result;
        }
    }

    if (std.mem.eql(u8, tool_name, "agent_profile_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const agent = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (agent) |a| {
            defer {
                s.allocator.free(a.name);
                s.allocator.free(a.capabilities);
                if (a.description) |d| s.allocator.free(d);
                s.allocator.free(a.created_at);
                s.allocator.free(a.updated_at);
            }
            return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Agent: {s} (id: {d}, capabilities: {s})", .{ a.name, a.id, a.capabilities }) catch "alloc error");
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Agent profile");
    }

    if (std.mem.eql(u8, tool_name, "config_get")) {
        return handleConfigGet(s, args);
    }

    if (std.mem.eql(u8, tool_name, "config_set")) {
        return handleConfigSet(s, args);
    }

    if (std.mem.startsWith(u8, tool_name, "config_")) {
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_IMPLEMENTED.code, errorz.Errors.NOT_IMPLEMENTED.message, "project configuration");
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}

fn handleConfigGet(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");

    var stmt = try s.conn.prepare("SELECT key, value FROM project_configs WHERE project_id = ? ORDER BY key");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var count: usize = 0;

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const key_opt = stmt.columnText(0);
        if (key_opt == null) break;
        const key = key_opt.?;
        const value = stmt.columnText(1) orelse "";
        if (count > 0) try buf.append('\n');
        const kv = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ key, value });
        try buf.appendSlice(kv);
        alloc.free(kv);
        count += 1;
    }

    if (count == 0) {
        return json.stringifyTextResponse(alloc, "No configuration found for this project");
    }
    const content = buf.toOwnedSlice() catch "alloc error";
    return json.stringifyTextResponse(alloc, content);
}

fn handleConfigSet(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
    const key = args.getRequiredString("key") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "key");
    const value = args.getRequiredString("value") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "value");
    const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");

    var stmt = try s.conn.prepare("INSERT INTO project_configs (project_id, key, value) VALUES (?, ?, ?) ON CONFLICT(project_id, key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, key);
    stmt.bindText(3, value);
    _ = try stmt.step();

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Config '{s}' set for project {d}", .{ key, project_id }) catch "alloc error");
}
