const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const errorz = @import("../../error.zig");
const transition_svc = @import("../../service/transition.zig");
const workflow = @import("../../service/workflow.zig");
const lifecycle = @import("../../domain/lifecycle.zig");
const db = @import("../../db/connection.zig");

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
            return invalidTransitionError(s, alloc, entity_type, entity_id, new_status);
        }
        if (err == error.ParentInTerminalState) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, "parent is in a terminal state (Done/Cancelled). Complete or un-cancel the parent before transitioning this entity.");
        }
        if (err == error.BlockerBugsExist) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, "open blocker bugs exist. Resolve or close all critical/high/medium bugs before transitioning.");
        }
        if (err == error.NotFound) {
            const detail = try std.fmt.allocPrint(alloc, "{s} {d}", .{ entity_type, entity_id });
            defer alloc.free(detail);
            return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, detail);
        }
        if (err == error.PermissionDenied) {
            return permissionDeniedError(s, alloc, entity_type, entity_id, new_status, agent_id);
        }
        if (err == error.InvalidEntityType) {
            return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, entity_type);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    };

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Transitioned to {s}", .{new_status}) catch "transitioned");
}

fn invalidTransitionError(s: *Server, alloc: std.mem.Allocator, entity_type: []const u8, entity_id: i64, new_status: []const u8) ![]const u8 {
    // Get current status and valid transitions
    const project_id = workflow.getEntityProjectId(s.conn, entity_type, entity_id) catch null;

    var valid_transitions = std.ArrayList([]const u8).empty;
    defer {
        for (valid_transitions.items) |vt| alloc.free(vt);
        valid_transitions.deinit(alloc);
    }

    if (project_id) |pid| {
        const has_wf = workflow.hasCustomWorkflow(s.conn, pid, entity_type) catch false;
        if (has_wf) {
            // Get current status for workflow query
            const current_status = getCurrentStatusText(s.conn, alloc, entity_type, entity_id) catch null;
            if (current_status) |cs| {
                defer alloc.free(cs);
                var wf_valid = workflow.getValidWorkflowTransitions(s.conn, pid, entity_type, cs, alloc) catch null;
                if (wf_valid) |*wfv| {
                    for (wfv.items) |vt| {
                        valid_transitions.append(alloc, vt) catch {};
                    }
                    wfv.deinit(alloc);
                }
            }
        }
    }

    // Fallback to hardcoded lifecycle if no workflow transitions found
    if (valid_transitions.items.len == 0) {
        const etype = parseEntityType(entity_type);
        if (etype) |et| {
            const current_status = getCurrentStatusText(s.conn, alloc, entity_type, entity_id) catch null;
            if (current_status) |cs| {
                const hardcoded_valid = lifecycle.getValidTransitions(et, cs);
                for (hardcoded_valid) |vt| {
                    valid_transitions.append(alloc, alloc.dupe(u8, vt) catch "") catch {};
                }
            }
        }
    }

    // Build valid transitions string
    var valid_str = std.array_list.Managed(u8).init(alloc);
    defer valid_str.deinit();
    for (valid_transitions.items, 0..) |vt, i| {
        if (i > 0) try valid_str.appendSlice(", ");
        try valid_str.appendSlice(vt);
    }

    const detail = try std.fmt.allocPrint(alloc, "{s} {d} cannot transition to '{s}'. Valid transitions from current status: [{s}].", .{ entity_type, entity_id, new_status, valid_str.items });
    defer alloc.free(detail);
    return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_STATE.code, errorz.Errors.INVALID_STATE.message, detail);
}

fn permissionDeniedError(s: *Server, alloc: std.mem.Allocator, entity_type: []const u8, entity_id: i64, new_status: []const u8, agent_id: i64) ![]const u8 {
    _ = s;
    _ = agent_id;
    const detail = try std.fmt.allocPrint(alloc, "Permission denied: your role does not allow transitioning {s} {d} to '{s}'. Check with a product manager or admin for permitted transitions.", .{ entity_type, entity_id, new_status });
    defer alloc.free(detail);
    return json.stringifyCatalogError(alloc, errorz.Errors.PERMISSION_DENIED.code, errorz.Errors.PERMISSION_DENIED.message, detail);
}

fn parseEntityType(s: []const u8) ?lifecycle.EntityType {
    if (std.mem.eql(u8, s, "epic")) return lifecycle.EntityType.epic;
    if (std.mem.eql(u8, s, "story")) return lifecycle.EntityType.story;
    if (std.mem.eql(u8, s, "task")) return lifecycle.EntityType.task;
    if (std.mem.eql(u8, s, "subtask")) return lifecycle.EntityType.subtask;
    if (std.mem.eql(u8, s, "bug")) return lifecycle.EntityType.bug;
    return null;
}

fn getCurrentStatusText(conn: *db.Connection, alloc: std.mem.Allocator, entity_type: []const u8, entity_id: i64) ![]u8 {
    const table = if (std.mem.eql(u8, entity_type, "epic")) "epics"
    else if (std.mem.eql(u8, entity_type, "story")) "stories"
    else if (std.mem.eql(u8, entity_type, "task")) "tasks"
    else if (std.mem.eql(u8, entity_type, "subtask")) "subtasks"
    else if (std.mem.eql(u8, entity_type, "bug")) "bugs"
    else return error.InvalidEntityType;

    const sql = try std.fmt.allocPrint(alloc, "SELECT status FROM {s} WHERE id = ?", .{table});
    defer alloc.free(sql);

    var stmt = try conn.prepare(sql);
    defer stmt.finalize();
    stmt.bindInt64(1, entity_id);
    if (try stmt.step() == .row) {
        const status = stmt.columnText(0) orelse return error.NotFound;
        return try alloc.dupe(u8, status);
    }
    return error.NotFound;
}
