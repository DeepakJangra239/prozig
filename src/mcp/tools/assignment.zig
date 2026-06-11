const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const errorz = @import("../../error.zig");
const entities = @import("../../domain/entities.zig");
const assignment_svc = @import("../../service/assignment.zig");

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

        return json.stringifyTextResponse(alloc, work);
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
