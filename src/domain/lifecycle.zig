const std = @import("std");
const errors = @import("errors.zig");

/// Entity types that have lifecycles
pub const EntityType = enum {
    epic,
    story,
    task,
    subtask,
    bug,
};

/// Valid statuses per entity type
pub const EpicStatus = enum {
    backlog,
    planned,
    in_progress,
    in_review,
    done,
    cancelled,
};

/// Story has its own lifecycle with UAT state between in_review and done
pub const StoryStatus = enum {
    backlog,
    planned,
    in_progress,
    in_review,
    uat,
    done,
    cancelled,
};

pub const TaskStatus = enum {
    todo,
    in_progress,
    in_review,
    in_qa,
    done,
    cancelled,
};

pub const SubTaskStatus = enum {
    todo,
    in_progress,
    ut,
    done,
    cancelled,
};

pub const BugStatus = enum {
    new,
    in_progress,
    in_review,
    resolved,
    closed,
    cancelled,
};

// ── Serialization: enum → DB string ──

pub fn epicStatusToDb(s: EpicStatus) []const u8 {
    return switch (s) {
        .backlog => "Backlog",
        .planned => "Planned",
        .in_progress => "In Progress",
        .in_review => "In Review",
        .done => "Done",
        .cancelled => "Cancelled",
    };
}

pub fn storyStatusToDb(s: StoryStatus) []const u8 {
    return switch (s) {
        .backlog => "Backlog",
        .planned => "Planned",
        .in_progress => "In Progress",
        .in_review => "In Review",
        .uat => "UAT",
        .done => "Done",
        .cancelled => "Cancelled",
    };
}

pub fn taskStatusToDb(s: TaskStatus) []const u8 {
    return switch (s) {
        .todo => "Todo",
        .in_progress => "In Progress",
        .in_review => "In Review",
        .in_qa => "In QA",
        .done => "Done",
        .cancelled => "Cancelled",
    };
}

pub fn subTaskStatusToDb(s: SubTaskStatus) []const u8 {
    return switch (s) {
        .todo => "Todo",
        .in_progress => "In Progress",
        .ut => "UT",
        .done => "Done",
        .cancelled => "Cancelled",
    };
}

pub fn bugStatusToDb(s: BugStatus) []const u8 {
    return switch (s) {
        .new => "New",
        .in_progress => "In Progress",
        .in_review => "In Review",
        .resolved => "Resolved",
        .closed => "Closed",
        .cancelled => "Cancelled",
    };
}

/// Convert a status enum to its DB string representation
/// based on the entity type.
pub fn statusToDb(entity_type: EntityType, status: anytype) []const u8 {
    return switch (entity_type) {
        .epic => epicStatusToDb(@as(EpicStatus, status)),
        .story => storyStatusToDb(@as(StoryStatus, status)),
        .task => taskStatusToDb(@as(TaskStatus, status)),
        .subtask => subTaskStatusToDb(@as(SubTaskStatus, status)),
        .bug => bugStatusToDb(@as(BugStatus, status)),
    };
}

// ── Serialization: DB string → enum ──

pub fn epicStatusFromDb(s: []const u8) ?EpicStatus {
    if (std.mem.eql(u8, s, "Backlog")) return .backlog;
    if (std.mem.eql(u8, s, "Planned")) return .planned;
    if (std.mem.eql(u8, s, "In Progress")) return .in_progress;
    if (std.mem.eql(u8, s, "In Review")) return .in_review;
    if (std.mem.eql(u8, s, "Done")) return .done;
    if (std.mem.eql(u8, s, "Cancelled")) return .cancelled;
    return null;
}

pub fn storyStatusFromDb(s: []const u8) ?StoryStatus {
    if (std.mem.eql(u8, s, "Backlog")) return .backlog;
    if (std.mem.eql(u8, s, "Planned")) return .planned;
    if (std.mem.eql(u8, s, "In Progress")) return .in_progress;
    if (std.mem.eql(u8, s, "In Review")) return .in_review;
    if (std.mem.eql(u8, s, "UAT")) return .uat;
    if (std.mem.eql(u8, s, "Done")) return .done;
    if (std.mem.eql(u8, s, "Cancelled")) return .cancelled;
    return null;
}

pub fn taskStatusFromDb(s: []const u8) ?TaskStatus {
    if (std.mem.eql(u8, s, "Todo")) return .todo;
    if (std.mem.eql(u8, s, "In Progress")) return .in_progress;
    if (std.mem.eql(u8, s, "In Review")) return .in_review;
    if (std.mem.eql(u8, s, "In QA")) return .in_qa;
    if (std.mem.eql(u8, s, "Done")) return .done;
    if (std.mem.eql(u8, s, "Cancelled")) return .cancelled;
    return null;
}

pub fn subTaskStatusFromDb(s: []const u8) ?SubTaskStatus {
    if (std.mem.eql(u8, s, "Todo")) return .todo;
    if (std.mem.eql(u8, s, "In Progress")) return .in_progress;
    if (std.mem.eql(u8, s, "UT")) return .ut;
    if (std.mem.eql(u8, s, "Done")) return .done;
    if (std.mem.eql(u8, s, "Cancelled")) return .cancelled;
    return null;
}

pub fn bugStatusFromDb(s: []const u8) ?BugStatus {
    if (std.mem.eql(u8, s, "New")) return .new;
    if (std.mem.eql(u8, s, "In Progress")) return .in_progress;
    if (std.mem.eql(u8, s, "In Review")) return .in_review;
    if (std.mem.eql(u8, s, "Resolved")) return .resolved;
    if (std.mem.eql(u8, s, "Closed")) return .closed;
    if (std.mem.eql(u8, s, "Cancelled")) return .cancelled;
    return null;
}

/// Get the default (initial) status for an entity type.
pub fn defaultStatus(entity_type: EntityType) []const u8 {
    return switch (entity_type) {
        .epic => "Backlog",
        .story => "Backlog",
        .task, .subtask => "Todo",
        .bug => "New",
    };
}

// ── Enum-based validation ──

/// Check if a transition is valid for Epic (enum-based)
pub fn isValidEpicTransitionEnum(from: EpicStatus, to: EpicStatus) bool {
    if (to == .cancelled) return true;
    if (from == .cancelled) return false;

    const stage_index = comptime blk: {
        var map: [6]usize = undefined;
        for ([_]EpicStatus{ .backlog, .planned, .in_progress, .in_review, .done, .cancelled }, 0..) |st, i| {
            map[@intFromEnum(st)] = i;
        }
        break :blk map;
    };

    const fi = stage_index[@intFromEnum(from)];
    const ti = stage_index[@intFromEnum(to)];

    // Forward: stay or advance one step
    if (ti == fi or ti == fi + 1) return true;
    // Backward: retreat one step (but not from Done, and fi must be > 0)
    if (from != .done and fi > 0 and ti == fi - 1) return true;

    return false;
}

/// Check if a transition is valid for Story (enum-based)
/// Story has UAT between in_review and done — can't skip directly
pub fn isValidStoryTransitionEnum(from: StoryStatus, to: StoryStatus) bool {
    if (to == .cancelled) return true;
    if (from == .cancelled) return false;

    // Cannot skip from in_review directly to done — must go through UAT
    if (from == .in_review and to == .done) return false;

    const stage_index = comptime blk: {
        var map: [7]usize = undefined;
        for ([_]StoryStatus{ .backlog, .planned, .in_progress, .in_review, .uat, .done, .cancelled }, 0..) |st, i| {
            map[@intFromEnum(st)] = i;
        }
        break :blk map;
    };

    const fi = stage_index[@intFromEnum(from)];
    const ti = stage_index[@intFromEnum(to)];

    // Forward: stay or advance one step
    if (ti == fi or ti == fi + 1) return true;
    // Backward: retreat one step (but not from Done, and fi must be > 0)
    if (from != .done and fi > 0 and ti == fi - 1) return true;

    return false;
}

/// Check if a transition is valid for Task (enum-based)
pub fn isValidTaskTransitionEnum(from: TaskStatus, to: TaskStatus) bool {
    if (to == .cancelled) return true;
    if (from == .cancelled) return false;

    const stage_index = comptime blk: {
        var map: [6]usize = undefined;
        for ([_]TaskStatus{ .todo, .in_progress, .in_review, .in_qa, .done, .cancelled }, 0..) |st, i| {
            map[@intFromEnum(st)] = i;
        }
        break :blk map;
    };

    const fi = stage_index[@intFromEnum(from)];
    const ti = stage_index[@intFromEnum(to)];

    // Forward: stay or advance one step
    if (ti == fi or ti == fi + 1) return true;
    // Backward: retreat one step (but not from Done, and fi must be > 0)
    if (from != .done and fi > 0 and ti == fi - 1) return true;

    return false;
}


/// Check if a transition is valid for SubTask (enum-based)
pub fn isValidSubTaskTransitionEnum(from: SubTaskStatus, to: SubTaskStatus) bool {
    if (to == .cancelled) return true;
    if (from == .cancelled) return false;

    const stage_index = comptime blk: {
        var map: [5]usize = undefined;
        for ([_]SubTaskStatus{ .todo, .in_progress, .ut, .done, .cancelled }, 0..) |st, i| {
            map[@intFromEnum(st)] = i;
        }
        break :blk map;
    };

    const fi = stage_index[@intFromEnum(from)];
    const ti = stage_index[@intFromEnum(to)];

    // Forward: stay or advance one step
    if (ti == fi or ti == fi + 1) return true;
    // Backward: retreat one step (but not from Done, and fi must be > 0)
    if (from != .done and fi > 0 and ti == fi - 1) return true;

    return false;
}

/// Check if a transition is valid for Bug (enum-based)
pub fn isValidBugTransitionEnum(from: BugStatus, to: BugStatus) bool {
    if (to == .cancelled) return true;
    if (from == .cancelled) return false;

    const stage_index = comptime blk: {
        var map: [6]usize = undefined;
        for ([_]BugStatus{ .new, .in_progress, .in_review, .resolved, .closed, .cancelled }, 0..) |st, i| {
            map[@intFromEnum(st)] = i;
        }
        break :blk map;
    };

    const fi = stage_index[@intFromEnum(from)];
    const ti = stage_index[@intFromEnum(to)];

    // Forward: stay or advance one step
    if (ti == fi or ti == fi + 1) return true;
    // Backward: retreat one step (but not from terminal Closed, and fi must be > 0)
    if (from != .closed and fi > 0 and ti == fi - 1) return true;

    return false;
}

// ── String-based validation (keep for backwards compat, delegate to enums) ──

pub fn isValidEpicTransition(from: []const u8, to: []const u8) bool {
    const from_e = epicStatusFromDb(from) orelse return false;
    const to_e = epicStatusFromDb(to) orelse return false;
    return isValidEpicTransitionEnum(from_e, to_e);
}

pub fn isValidStoryTransition(from: []const u8, to: []const u8) bool {
    const from_e = storyStatusFromDb(from) orelse return false;
    const to_e = storyStatusFromDb(to) orelse return false;
    return isValidStoryTransitionEnum(from_e, to_e);
}

pub fn isValidTaskTransition(from: []const u8, to: []const u8) bool {
    const from_e = taskStatusFromDb(from) orelse return false;
    const to_e = taskStatusFromDb(to) orelse return false;
    return isValidTaskTransitionEnum(from_e, to_e);
}

pub fn isValidSubTaskTransition(from: []const u8, to: []const u8) bool {
    const from_e = subTaskStatusFromDb(from) orelse return false;
    const to_e = subTaskStatusFromDb(to) orelse return false;
    return isValidSubTaskTransitionEnum(from_e, to_e);
}

pub fn isValidBugTransition(from: []const u8, to: []const u8) bool {
    const from_e = bugStatusFromDb(from) orelse return false;
    const to_e = bugStatusFromDb(to) orelse return false;
    return isValidBugTransitionEnum(from_e, to_e);
}

/// Validate a transition for any entity type (string API, delegates to enums)
pub fn validateTransition(entity_type: EntityType, from: []const u8, to: []const u8) errors.Error!void {
    const valid = switch (entity_type) {
        .epic => isValidEpicTransition(from, to),
        .story => isValidStoryTransition(from, to),
        .task => isValidTaskTransition(from, to),
        .subtask => isValidSubTaskTransition(from, to),
        .bug => isValidBugTransition(from, to),
    };

    if (!valid) {
        std.log.err("Invalid transition: {s} -> {s}\n", .{ from, to });
        return errors.Error.InvalidTransition;
    }
}

/// Get the next valid status for an entity (string API)
pub fn getNextStatus(entity_type: EntityType, current: []const u8) ?[]const u8 {
    const all_statuses = switch (entity_type) {
        .epic => [_][]const u8{ "Backlog", "Planned", "In Progress", "In Review", "Done" },
        .story => [_][]const u8{ "Backlog", "Planned", "In Progress", "In Review", "UAT", "Done" },
        .task => [_][]const u8{ "Todo", "In Progress", "In Review", "In QA", "Done" },
        .subtask => [_][]const u8{ "Todo", "In Progress", "UT", "Done" },
        .bug => [_][]const u8{ "New", "In Progress", "In Review", "Resolved", "Closed" },
    };

    for (all_statuses) |status| {
        if (!std.mem.eql(u8, current, status)) {
            const valid = switch (entity_type) {
                .epic => isValidEpicTransition(current, status),
                .story => isValidStoryTransition(current, status),
                .task => isValidTaskTransition(current, status),
                .subtask => isValidSubTaskTransition(current, status),
                .bug => isValidBugTransition(current, status),
            };
            if (valid) return status;
        }
    }
    return null;
}

/// Return all valid target statuses from a given current status.
/// Returns a static slice of valid status strings.
pub fn getValidTransitions(entity_type: EntityType, current: []const u8) []const []const u8 {
    // Collect valid transitions into a static array (max 7 for story)
    var valid: [7][]const u8 = undefined;
    var count: usize = 0;

    switch (entity_type) {
        .epic => {
            const all = [_][]const u8{ "Backlog", "Planned", "In Progress", "In Review", "Done", "Cancelled" };
            for (all) |status| {
                if (std.mem.eql(u8, current, status)) continue;
                if (isValidEpicTransition(current, status) and count < valid.len) {
                    valid[count] = status;
                    count += 1;
                }
            }
        },
        .story => {
            const all = [_][]const u8{ "Backlog", "Planned", "In Progress", "In Review", "UAT", "Done", "Cancelled" };
            for (all) |status| {
                if (std.mem.eql(u8, current, status)) continue;
                if (isValidStoryTransition(current, status) and count < valid.len) {
                    valid[count] = status;
                    count += 1;
                }
            }
        },
        .task => {
            const all = [_][]const u8{ "Todo", "In Progress", "In Review", "In QA", "Done", "Cancelled" };
            for (all) |status| {
                if (std.mem.eql(u8, current, status)) continue;
                if (isValidTaskTransition(current, status) and count < valid.len) {
                    valid[count] = status;
                    count += 1;
                }
            }
        },
        .subtask => {
            const all = [_][]const u8{ "Todo", "In Progress", "UT", "Done", "Cancelled" };
            for (all) |status| {
                if (std.mem.eql(u8, current, status)) continue;
                if (isValidSubTaskTransition(current, status) and count < valid.len) {
                    valid[count] = status;
                    count += 1;
                }
            }
        },
        .bug => {
            const all = [_][]const u8{ "New", "In Progress", "In Review", "Resolved", "Closed", "Cancelled" };
            for (all) |status| {
                if (std.mem.eql(u8, current, status)) continue;
                if (isValidBugTransition(current, status) and count < valid.len) {
                    valid[count] = status;
                    count += 1;
                }
            }
        },
    }

    return valid[0..count];
}

/// Check if a status is terminal (Done or Cancelled)
pub fn isTerminal(status: []const u8) bool {
    return std.mem.eql(u8, status, "Done") or std.mem.eql(u8, status, "Cancelled");
}

/// Get the numeric stage index for comparison (for parent-child integrity)
pub fn getStageIndex(entity_type: EntityType, status: []const u8) usize {
    if (std.mem.eql(u8, status, "Cancelled")) return 0;

    const stages = switch (entity_type) {
        .epic => [_][]const u8{ "Backlog", "Planned", "In Progress", "In Review", "Done" },
        .story => [_][]const u8{ "Backlog", "Planned", "In Progress", "In Review", "UAT", "Done" },
        .task => [_][]const u8{ "Todo", "In Progress", "In Review", "In QA", "Done" },
        .subtask => [_][]const u8{ "Todo", "In Progress", "UT", "Done" },
        .bug => [_][]const u8{ "New", "In Progress", "In Review", "Resolved", "Closed" },
    };

    for (stages, 0..) |stage, i| {
        if (std.mem.eql(u8, stage, status)) return i;
    }
    return 0;
}

// ── Tests ──

test "isValidEpicTransition: valid backward steps" {
    try std.testing.expect(isValidEpicTransition("In Review", "In Progress"));
    try std.testing.expect(isValidEpicTransition("In Progress", "Planned"));
    try std.testing.expect(isValidEpicTransition("Planned", "Backlog"));
}

test "isValidEpicTransition: cannot go backward from Done" {
    try std.testing.expect(!isValidEpicTransition("Done", "In Review"));
}

test "isValidEpicTransition: valid forward steps" {
    try std.testing.expect(isValidEpicTransition("Backlog", "Backlog"));
    try std.testing.expect(isValidEpicTransition("Backlog", "Planned"));
    try std.testing.expect(isValidEpicTransition("Planned", "In Progress"));
    try std.testing.expect(isValidEpicTransition("In Progress", "In Review"));
    try std.testing.expect(isValidEpicTransition("In Review", "Done"));
}

test "isValidEpicTransition: invalid skips" {
    try std.testing.expect(!isValidEpicTransition("Backlog", "Done"));
    try std.testing.expect(!isValidEpicTransition("Planned", "In Review"));
    try std.testing.expect(!isValidEpicTransition("Backlog", "In Progress"));
}

test "isValidEpicTransition: cancellation from any state" {
    try std.testing.expect(isValidEpicTransition("Backlog", "Cancelled"));
    try std.testing.expect(isValidEpicTransition("Planned", "Cancelled"));
    try std.testing.expect(isValidEpicTransition("In Progress", "Cancelled"));
    try std.testing.expect(isValidEpicTransition("In Review", "Cancelled"));
    try std.testing.expect(isValidEpicTransition("Done", "Cancelled"));
}

test "isValidEpicTransition: cannot leave cancelled" {
    try std.testing.expect(!isValidEpicTransition("Cancelled", "Backlog"));
    try std.testing.expect(!isValidEpicTransition("Cancelled", "Planned"));
    try std.testing.expect(!isValidEpicTransition("Cancelled", "Done"));
}

// ── Story Transition Tests (with UAT) ──

test "isValidStoryTransition: valid forward steps with UAT" {
    try std.testing.expect(isValidStoryTransition("Backlog", "Backlog"));
    try std.testing.expect(isValidStoryTransition("Backlog", "Planned"));
    try std.testing.expect(isValidStoryTransition("Planned", "In Progress"));
    try std.testing.expect(isValidStoryTransition("In Progress", "In Review"));
    try std.testing.expect(isValidStoryTransition("In Review", "UAT"));
    try std.testing.expect(isValidStoryTransition("UAT", "Done"));
}

test "isValidStoryTransition: cannot skip from in_review to done" {
    try std.testing.expect(!isValidStoryTransition("In Review", "Done"));
}

test "isValidStoryTransition: invalid forward skips" {
    try std.testing.expect(!isValidStoryTransition("Backlog", "Done"));
    try std.testing.expect(!isValidStoryTransition("Backlog", "In Progress"));
    try std.testing.expect(!isValidStoryTransition("Planned", "In Review"));
    try std.testing.expect(!isValidStoryTransition("Backlog", "UAT"));
}

test "isValidStoryTransition: valid backward steps with UAT" {
    try std.testing.expect(isValidStoryTransition("UAT", "In Review"));
    try std.testing.expect(isValidStoryTransition("In Review", "In Progress"));
    try std.testing.expect(isValidStoryTransition("In Progress", "Planned"));
    try std.testing.expect(isValidStoryTransition("Planned", "Backlog"));
}

test "isValidStoryTransition: cannot go backward from Done" {
    try std.testing.expect(!isValidStoryTransition("Done", "UAT"));
}

test "isValidStoryTransition: cancellation from any state" {
    try std.testing.expect(isValidStoryTransition("Backlog", "Cancelled"));
    try std.testing.expect(isValidStoryTransition("In Progress", "Cancelled"));
    try std.testing.expect(isValidStoryTransition("In Review", "Cancelled"));
    try std.testing.expect(isValidStoryTransition("UAT", "Cancelled"));
    try std.testing.expect(isValidStoryTransition("Done", "Cancelled"));
}

test "isValidStoryTransition: cannot leave cancelled" {
    try std.testing.expect(!isValidStoryTransition("Cancelled", "Backlog"));
    try std.testing.expect(!isValidStoryTransition("Cancelled", "UAT"));
    try std.testing.expect(!isValidStoryTransition("Cancelled", "Done"));
}

test "isValidTaskTransition: valid forward steps" {
    try std.testing.expect(isValidTaskTransition("Todo", "Todo"));
    try std.testing.expect(isValidTaskTransition("Todo", "In Progress"));
    try std.testing.expect(isValidTaskTransition("In Progress", "In Review"));
    try std.testing.expect(isValidTaskTransition("In Review", "In QA"));
    try std.testing.expect(isValidTaskTransition("In QA", "Done"));
}

test "isValidTaskTransition: invalid skips" {
    try std.testing.expect(!isValidTaskTransition("Todo", "Done"));
    try std.testing.expect(!isValidTaskTransition("In Progress", "In QA"));
    try std.testing.expect(!isValidTaskTransition("Todo", "In Review"));
}

test "isValidTaskTransition: valid backward steps" {
    try std.testing.expect(isValidTaskTransition("In QA", "In Review"));
    try std.testing.expect(isValidTaskTransition("In Review", "In Progress"));
    try std.testing.expect(isValidTaskTransition("In Progress", "Todo"));
}

test "isValidTaskTransition: cannot go backward from Done" {
    try std.testing.expect(!isValidTaskTransition("Done", "In QA"));
}

test "isValidSubTaskTransition: valid forward steps" {
    try std.testing.expect(isValidSubTaskTransition("Todo", "Todo"));
    try std.testing.expect(isValidSubTaskTransition("Todo", "In Progress"));
    try std.testing.expect(isValidSubTaskTransition("In Progress", "UT"));
    try std.testing.expect(isValidSubTaskTransition("UT", "Done"));
}

test "isValidSubTaskTransition: invalid skips" {
    try std.testing.expect(!isValidSubTaskTransition("Todo", "Done"));
    try std.testing.expect(!isValidSubTaskTransition("In Progress", "Done"));
}

test "isValidSubTaskTransition: valid backward steps" {
    try std.testing.expect(isValidSubTaskTransition("UT", "In Progress"));
    try std.testing.expect(isValidSubTaskTransition("In Progress", "Todo"));
}

test "isValidSubTaskTransition: cannot go backward from Done" {
    try std.testing.expect(!isValidSubTaskTransition("Done", "UT"));
}

test "isTerminal" {
    try std.testing.expect(isTerminal("Done"));
    try std.testing.expect(isTerminal("Cancelled"));
    try std.testing.expect(!isTerminal("Backlog"));
    try std.testing.expect(!isTerminal("In Progress"));
    try std.testing.expect(!isTerminal("Todo"));
}

test "getStageIndex: epic stages" {
    try std.testing.expectEqual(@as(usize, 0), getStageIndex(.epic, "Backlog"));
    try std.testing.expectEqual(@as(usize, 1), getStageIndex(.epic, "Planned"));
    try std.testing.expectEqual(@as(usize, 2), getStageIndex(.epic, "In Progress"));
    try std.testing.expectEqual(@as(usize, 3), getStageIndex(.epic, "In Review"));
    try std.testing.expectEqual(@as(usize, 4), getStageIndex(.epic, "Done"));
    try std.testing.expectEqual(@as(usize, 0), getStageIndex(.epic, "Cancelled"));
}

test "getStageIndex: story stages with UAT" {
    try std.testing.expectEqual(@as(usize, 0), getStageIndex(.story, "Backlog"));
    try std.testing.expectEqual(@as(usize, 1), getStageIndex(.story, "Planned"));
    try std.testing.expectEqual(@as(usize, 2), getStageIndex(.story, "In Progress"));
    try std.testing.expectEqual(@as(usize, 3), getStageIndex(.story, "In Review"));
    try std.testing.expectEqual(@as(usize, 4), getStageIndex(.story, "UAT"));
    try std.testing.expectEqual(@as(usize, 5), getStageIndex(.story, "Done"));
    try std.testing.expectEqual(@as(usize, 0), getStageIndex(.story, "Cancelled"));
}

test "validateTransition: accepts valid epic transition" {
    try validateTransition(.epic, "Backlog", "Planned");
}

test "validateTransition: rejects invalid epic transition" {
    const result = validateTransition(.epic, "Backlog", "Done");
    try std.testing.expectError(error.InvalidTransition, result);
}

test "validateTransition: accepts valid story transition with UAT" {
    try validateTransition(.story, "In Review", "UAT");
    try validateTransition(.story, "UAT", "Done");
}

test "validateTransition: rejects story skipping UAT" {
    const result = validateTransition(.story, "In Review", "Done");
    try std.testing.expectError(error.InvalidTransition, result);
}

test "serialization: epicStatusToDb roundtrip" {
    const statuses = [_]EpicStatus{ .backlog, .planned, .in_progress, .in_review, .done, .cancelled };
    for (statuses) |s| {
        const db_str = epicStatusToDb(s);
        const parsed = epicStatusFromDb(db_str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(s, parsed.?);
    }
}

test "serialization: storyStatusToDb roundtrip" {
    const statuses = [_]StoryStatus{ .backlog, .planned, .in_progress, .in_review, .uat, .done, .cancelled };
    for (statuses) |s| {
        const db_str = storyStatusToDb(s);
        const parsed = storyStatusFromDb(db_str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(s, parsed.?);
    }
}

test "serialization: taskStatusToDb roundtrip" {
    const statuses = [_]TaskStatus{ .todo, .in_progress, .in_review, .in_qa, .done, .cancelled };
    for (statuses) |s| {
        const db_str = taskStatusToDb(s);
        const parsed = taskStatusFromDb(db_str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(s, parsed.?);
    }
}

test "serialization: subTaskStatusToDb roundtrip" {
    const statuses = [_]SubTaskStatus{ .todo, .in_progress, .ut, .done, .cancelled };
    for (statuses) |s| {
        const db_str = subTaskStatusToDb(s);
        const parsed = subTaskStatusFromDb(db_str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(s, parsed.?);
    }
}

test "serialization: null for invalid db string" {
    try std.testing.expect(epicStatusFromDb("InvalidStatus") == null);
    try std.testing.expect(storyStatusFromDb("InvalidStatus") == null);
    try std.testing.expect(taskStatusFromDb("InvalidStatus") == null);
    try std.testing.expect(subTaskStatusFromDb("InvalidStatus") == null);
    try std.testing.expect(bugStatusFromDb("InvalidStatus") == null);
}

// ── Bug Lifecycle Tests ──

test "isValidBugTransition: valid forward steps" {
    try std.testing.expect(isValidBugTransition("New", "New"));
    try std.testing.expect(isValidBugTransition("New", "In Progress"));
    try std.testing.expect(isValidBugTransition("In Progress", "In Review"));
    try std.testing.expect(isValidBugTransition("In Review", "Resolved"));
    try std.testing.expect(isValidBugTransition("Resolved", "Closed"));
}

test "isValidBugTransition: invalid skip forward" {
    try std.testing.expect(!isValidBugTransition("New", "Resolved"));
    try std.testing.expect(!isValidBugTransition("In Progress", "Closed"));
    try std.testing.expect(!isValidBugTransition("New", "In Review"));
}

test "isValidBugTransition: valid backward steps" {
    try std.testing.expect(isValidBugTransition("In Review", "In Progress"));
    try std.testing.expect(isValidBugTransition("In Progress", "New"));
    try std.testing.expect(isValidBugTransition("Resolved", "In Review"));
}

test "isValidBugTransition: cannot go backward from Closed" {
    try std.testing.expect(!isValidBugTransition("Closed", "Resolved"));
    try std.testing.expect(!isValidBugTransition("Closed", "New"));
}

test "isValidBugTransition: cancellation from any state" {
    try std.testing.expect(isValidBugTransition("New", "Cancelled"));
    try std.testing.expect(isValidBugTransition("In Progress", "Cancelled"));
    try std.testing.expect(isValidBugTransition("In Review", "Cancelled"));
    try std.testing.expect(isValidBugTransition("Resolved", "Cancelled"));
    try std.testing.expect(isValidBugTransition("Closed", "Cancelled"));
}

test "isValidBugTransition: cannot leave cancelled" {
    try std.testing.expect(!isValidBugTransition("Cancelled", "New"));
    try std.testing.expect(!isValidBugTransition("Cancelled", "In Progress"));
    try std.testing.expect(!isValidBugTransition("Cancelled", "Closed"));
}

test "serialization: bugStatusToDb roundtrip" {
    const statuses = [_]BugStatus{ .new, .in_progress, .in_review, .resolved, .closed, .cancelled };
    for (statuses) |s| {
        const db_str = bugStatusToDb(s);
        const parsed = bugStatusFromDb(db_str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(s, parsed.?);
    }
}

test "validateTransition: accepts valid bug transition" {
    try validateTransition(.bug, "New", "In Progress");
}

test "validateTransition: rejects invalid bug transition" {
    const result = validateTransition(.bug, "New", "Closed");
    try std.testing.expectError(error.InvalidTransition, result);
}
