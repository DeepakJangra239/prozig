const std = @import("std");
const errors = @import("errors.zig");
const lifecycle = @import("lifecycle.zig");

/// Dependency edge in the graph
const Edge = struct {
    from: []const u8, // blocker
    to: []const u8,   // blocked
};

/// Detect cycles in a dependency graph using DFS
/// Returns true if a cycle is detected
pub fn detectCycle(allocator: std.mem.Allocator, edges: []const Edge) !bool {
    var visited = std.AutoHashMap([]const u8, bool).init(allocator);
    var rec_stack = std.AutoHashMap([]const u8, bool).init(allocator);
    defer {
        var it = visited.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        visited.deinit(allocator);
        it = rec_stack.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        rec_stack.deinit(allocator);
    }

    // Build adjacency list
    var adj = std.AutoHashMap([]const u8, std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        adj.deinit(allocator);
    }

    for (edges) |edge| {
        const from_copy = try allocator.dupe(u8, edge.from);
        const to_copy = try allocator.dupe(u8, edge.to);
        var list = (try adj.getOrValue(from_copy)).value;
        try list.append(to_copy);
    }

    // DFS from each node
    var adj_it = adj.iterator();
    while (adj_it.next()) |entry| {
        if (try hasCycle(entry.key_ptr.*, &adj, &visited, &rec_stack)) {
            return true;
        }
    }

    return false;
}

fn hasCycle(
    node: []const u8,
    adj: *std.AutoHashMap([]const u8, std.ArrayList([]const u8)),
    visited: *std.AutoHashMap([]const u8, bool),
    rec_stack: *std.AutoHashMap([]const u8, bool),
) !bool {
    try visited.put(node, true);
    try rec_stack.put(node, true);

    if (adj.get(node)) |neighbors| {
        for (neighbors) |neighbor| {
            if (visited.get(neighbor) == null) {
                if (try hasCycle(neighbor, adj, visited, rec_stack)) return true;
            } else if (rec_stack.get(neighbor) orelse false) {
                return true;
            }
        }
    }

    _ = rec_stack.remove(node);
    return false;
}

/// Check if all blockers for an entity are resolved (Done or Cancelled)
pub fn areBlockersResolved(blocker_statuses: []const []const u8) bool {
    for (blocker_statuses) |status| {
        if (!lifecycle.isTerminal(status)) return false;
    }
    return true;
}
