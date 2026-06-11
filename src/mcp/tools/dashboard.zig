const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const errorz = @import("../../error.zig");
const dashboard_svc = @import("../../service/dashboard.zig");

pub fn handle(s: *Server, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;
    _ = args;

    const counts = dashboard_svc.getDashboardCounts(s.service, alloc) catch |err| {
        return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
    };

    return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Dashboard: {d} projects, {d} epics, {d} stories, {d} tasks", .{ counts.projects, counts.epics, counts.stories, counts.tasks }) catch "alloc error");
}
