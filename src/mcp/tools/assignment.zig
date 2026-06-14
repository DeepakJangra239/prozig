const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const errorz = @import("../../error.zig");
const entities = @import("../../domain/entities.zig");
const assignment_svc = @import("../../service/assignment.zig");
const queries_memory = @import("../../db/queries/memory.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "assign_work")) {
        const entity_type = args.getRequiredString("entity_type") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_type");
        const entity_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
        const entity_id = std.fmt.parseInt(i64, entity_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const agent_id_str = args.getRequiredString("agent_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "agent_id");
        const agent_id = std.fmt.parseInt(i64, agent_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "agent_id must be an integer");

        assignment_svc.assignWork(s.service, alloc, entity_type, entity_id, agent_id) catch |err| {
            if (err == error.NotFound) {
                return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "agent or entity");
            }
            if (err == error.InvalidEntityType) {
                return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, entity_type);
            }
            return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        };

        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Assigned {s} ({d}) to agent {d}", .{ entity_type, entity_id, agent_id }) catch "assigned");
    }

    if (std.mem.eql(u8, tool_name, "get_my_work")) {
        const agent_id_str = args.getRequiredString("agent_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "agent_id");
        const agent_id = std.fmt.parseInt(i64, agent_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "agent_id must be an integer");

        const work = assignment_svc.getMyWork(s.service, alloc, agent_id) catch |err| {
            return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        };
        defer alloc.free(work);

        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(work);

        // Memory injection: project summaries for projects with assigned work
        var project_ids = try getDistinctProjectIds(s.conn, alloc, agent_id);
        defer {
            for (project_ids.items) |pid| alloc.free(pid);
            project_ids.deinit(alloc);
        }
        for (project_ids.items) |pid_str| {
            const pid = std.fmt.parseInt(i64, pid_str, 10) catch continue;
            if (try queries_memory.formatProjectSummaryForResponse(alloc, s.conn, pid)) |summary_str| {
                defer alloc.free(summary_str);
                try buf.appendSlice(summary_str);
            }
        }

        return json.stringifyTextResponse(alloc, buf.items);
    }

    if (std.mem.eql(u8, tool_name, "suggest_assignment")) {
        const entity_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
        const entity_id = std.fmt.parseInt(i64, entity_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const entity_type_str = args.getRequiredString("entity_type") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_type");

        var suggestions = assignment_svc.suggestAssignment(s.service, alloc, entity_id, entity_type_str) catch |err| {
            return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        };
        defer {
            for (suggestions.items) |id| alloc.free(id);
            suggestions.deinit(alloc);
        }

        if (suggestions.items.len == 0) {
            return json.stringifyTextResponse(alloc, "No suitable agents found");
        }
        var result = std.array_list.Managed(u8).init(alloc);
        try result.appendSlice("Suggested agents: ");
        for (suggestions.items, 0..) |id, i| {
            if (i > 0) try result.appendSlice(", ");
            try result.appendSlice(id);
        }
        return json.stringifyTextResponse(alloc, result.items);
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}

/// Get distinct project IDs from all entities assigned to an agent.
fn getDistinctProjectIds(conn: *db.Connection, allocator: std.mem.Allocator, agent_id: i64) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).empty;
    // Query distinct project_ids from all entity types
    const query =
        \\SELECT DISTINCT project_id FROM epics WHERE assignee_agent_id = ?
        \\UNION SELECT DISTINCT project_id FROM stories WHERE assignee_agent_id = ?
        \\UNION SELECT DISTINCT project_id FROM tasks WHERE assignee_agent_id = ?
        \\UNION SELECT DISTINCT project_id FROM subtasks WHERE assignee_agent_id = ?
        \\UNION SELECT DISTINCT project_id FROM bugs WHERE assignee_agent_id = ?
    ;
    var stmt = try conn.prepare(query);
    defer stmt.finalize();
    stmt.bindInt64(1, agent_id);
    stmt.bindInt64(2, agent_id);
    stmt.bindInt64(3, agent_id);
    stmt.bindInt64(4, agent_id);
    stmt.bindInt64(5, agent_id);

    while (true) {
        const step_result = stmt.step() catch break;
        if (step_result != .row) break;
        const pid = stmt.columnInt64(0);
        const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{pid});
        try result.append(allocator, pid_str);
    }
    return result;
}
