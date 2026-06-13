const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const errorz = @import("../../error.zig");
const dashboard_svc = @import("../../service/dashboard.zig");

pub fn handle(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    // Check if project_id is provided
    const project_id_str = args.getOptionalString("project_id");
    if (project_id_str) |pid_str| {
        const project_id = std.fmt.parseInt(i64, pid_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const counts = dashboard_svc.getProjectDashboardCounts(s.service, alloc, project_id) catch |err| {
            return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        };
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Dashboard (project {d}): {d} epics, {d} stories, {d} tasks, {d} bugs", .{ project_id, counts.epics, counts.stories, counts.tasks, counts.bugs }) catch "alloc error");
    }

    // No project_id — return global counts
    const counts = dashboard_svc.getDashboardCounts(s.service, alloc) catch |err| {
        return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    };

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Dashboard: {d} projects, {d} epics, {d} stories, {d} tasks", .{ counts.projects, counts.epics, counts.stories, counts.tasks }) catch "alloc error");
}
