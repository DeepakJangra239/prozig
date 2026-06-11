const std = @import("std");
const entities = @import("entities.zig");

/// Suggest agent profiles for a task based on its type/title
/// Returns a list of matching agent IDs
pub fn suggestAgents(allocator: std.mem.Allocator, agents: []const entities.AgentProfile, task_title: []const u8, task_type: []const u8) !std.ArrayList([]const u8) {
    var suggestions = std.ArrayList([]const u8).empty;

    // Simple keyword matching
    const capability_map = [_]struct { []const u8, []const u8 }{
        .{ "architect", "design" },
        .{ "coder", "implement" },
        .{ "reviewer", "review" },
        .{ "qa", "test" },
    };

    for (agents) |agent| {
        var matched = false;

        // Check if any capability keyword appears in task title or type
        for (capability_map) |mapping| {
            if (std.mem.indexOf(u8, agent.capabilities, mapping[0]) != null) {
                if (std.ascii.indexOfIgnoreCase(task_title, mapping[1]) != null or
                    std.ascii.indexOfIgnoreCase(task_type, mapping[1]) != null)
                {
                    matched = true;
                    break;
                }
            }
        }

        // If no specific match, suggest all agents as fallback
        if (!matched and suggestions.items.len == 0) {
            matched = true;
        }

        if (matched) {
            const id_copy = try std.fmt.allocPrint(allocator, "{d}", .{agent.id});
            try suggestions.append(allocator, id_copy);
        }
    }

    return suggestions;
}

/// Check if an agent has a specific capability
pub fn hasCapability(agent: *const entities.AgentProfile, capability: []const u8) bool {
    return std.mem.indexOf(u8, agent.capabilities, capability) != null;
}
