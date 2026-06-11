const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const errorz = @import("../../error.zig");
const transition_svc = @import("../../service/transition.zig");

pub fn handle(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    const entity_type = args.getRequiredString("entity_type") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_type");
    const entity_id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
    const entity_id = std.fmt.parseInt(i64, entity_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
    const new_status = args.getRequiredString("new_status") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "new_status");
    const agent_id_str = args.getRequiredString("agent_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "agent_id");
    const agent_id = std.fmt.parseInt(i64, agent_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "agent_id must be an integer");

    // Delegate to service layer (handles validation, transaction, persistence)
    transition_svc.transitionStatus(s.service, alloc, entity_type, entity_id, new_status, agent_id) catch |err| {
        if (err == error.InvalidTransition) {
            const detail = try std.fmt.allocPrint(alloc, "{s} {d} -> {s}", .{ entity_type, entity_id, new_status });
            defer alloc.free(detail);
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, detail);
        }
        if (err == error.ParentInTerminalState) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, "parent is in a terminal state");
        }
        if (err == error.BlockerBugsExist) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, "open blocker bugs exist");
        }
        if (err == error.NotFound) {
            const detail = try std.fmt.allocPrint(alloc, "{s} {d}", .{ entity_type, entity_id });
            defer alloc.free(detail);
            return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, detail);
        }
        if (err == error.PermissionDenied) {
            return json.stringifyCatalogError(alloc, errorz.Errors.PERMISSION_DENIED.code, errorz.Errors.PERMISSION_DENIED.message, @errorName(err));
        }
        if (err == error.InvalidEntityType) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, entity_type);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    };

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Transitioned to {s}", .{new_status}) catch "transitioned");
}
