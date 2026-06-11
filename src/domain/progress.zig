const std = @import("std");
const lifecycle = @import("lifecycle.zig");

/// Calculate progress percentage (0-100) for a parent entity based on children
/// children_statuses: slice of child status strings
pub fn calculateProgress(children_statuses: []const []const u8) u8 {
    if (children_statuses.len == 0) return 0;

    var completed: usize = 0;
    for (children_statuses) |status| {
        if (lifecycle.isTerminal(status) and !std.mem.eql(u8, status, "Cancelled")) {
            completed += 1;
        }
    }

    return @as(u8, @intCast(@divTrunc(completed * 100, children_statuses.len)));
}

/// Check if all children are done (for auto-advancing parent)
pub fn allChildrenDone(children_statuses: []const []const u8) bool {
    for (children_statuses) |status| {
        if (!std.mem.eql(u8, status, "Done")) return false;
    }
    return children_statuses.len > 0;
}

/// Check if any child is in a given status
pub fn anyChildInStatus(children_statuses: []const []const u8, target: []const u8) bool {
    for (children_statuses) |status| {
        if (std.mem.eql(u8, status, target)) return true;
    }
    return false;
}
