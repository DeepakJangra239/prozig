const std = @import("std");
const db = @import("db/connection.zig");
const mcp_types = @import("mcp/types.zig");
const mcp_json = @import("mcp/json.zig");
const svc = @import("service/root.zig");
const entities = @import("domain/entities.zig");

fn setupServer(allocator: std.mem.Allocator) !struct { conn: db.Connection, server: mcp_types.Server, service: svc.Service } {
    var conn = try db.Connection.init(":memory:");
    try conn.migrate();
    var service = svc.init(&conn);
    var server = mcp_types.Server{
        .conn = &conn,
        .service = &service,
        .allocator = allocator,
    };
    // Initialize
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    return .{ .conn = conn, .server = server, .service = service };
}

fn setupProject(server: *mcp_types.Server) !void {
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"project_init\",\"arguments\":{\"name\":\"Test\",\"root_path\":\"/tmp\",\"description\":\"test\"}}}");
}

fn setupEpic(server: *mcp_types.Server) !void {
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"epic_create\",\"arguments\":{\"project_id\":\"1\",\"title\":\"Test Epic\",\"description\":\"test\"}}}");
}

fn setupStory(server: *mcp_types.Server) !void {
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"story_create\",\"arguments\":{\"project_id\":\"1\",\"epic_id\":\"1\",\"title\":\"Test Story\",\"description\":\"test\",\"acceptance_criteria\":\"test\"}}}");
}

fn setupTask(server: *mcp_types.Server) !void {
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"task_create\",\"arguments\":{\"project_id\":\"1\",\"story_id\":\"1\",\"title\":\"Test Task\",\"description\":\"test\"}}}");
}

fn setupSubtask(server: *mcp_types.Server) !void {
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"subtask_create\",\"arguments\":{\"project_id\":\"1\",\"task_id\":\"1\",\"title\":\"Test Subtask\",\"description\":\"test\"}}}");
}

fn setupAgent(server: *mcp_types.Server) !void {
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"agent_profile_create\",\"arguments\":{\"name\":\"Test Agent\",\"capabilities\":\"test\",\"description\":\"test\"}}}");
}

fn setupWiki(server: *mcp_types.Server) !void {
    _ = try server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"wiki_create\",\"arguments\":{\"project_id\":\"1\",\"category\":\"General\",\"title\":\"Test Page\",\"content\":\"test content\"}}}");
}

// BUG-001: All _get by-ID operations should return responses
test "BUG-001: project_get returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"project_get\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Project:") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-001: epic_get returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"epic_get\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Epic:") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-001: story_get returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"story_get\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Story:") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-001: task_get returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);
    try setupTask(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"task_get\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Task:") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-001: subtask_get returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);
    try setupTask(&s.server);
    try setupSubtask(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"subtask_get\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "SubTask:") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-001: agent_profile_get returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupAgent(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"agent_profile_get\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Agent:") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-001: wiki_get returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupWiki(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"wiki_get\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "test content") != null);
        std.testing.allocator.free(r);
    }
}

// BUG-002: All _update operations should return responses
test "BUG-002: epic_update returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"epic_update\",\"arguments\":{\"entity_id\":\"1\",\"title\":\"Updated Epic\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Epic updated") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-002: story_update returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"story_update\",\"arguments\":{\"entity_id\":\"1\",\"title\":\"Updated Story\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Story updated") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-002: task_update returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);
    try setupTask(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"task_update\",\"arguments\":{\"entity_id\":\"1\",\"title\":\"Updated Task\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Task updated") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-002: subtask_update returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);
    try setupTask(&s.server);
    try setupSubtask(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"tools/call\",\"params\":{\"name\":\"subtask_update\",\"arguments\":{\"entity_id\":\"1\",\"title\":\"Updated Subtask\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "SubTask updated") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-002: wiki_update returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupWiki(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tools/call\",\"params\":{\"name\":\"wiki_update\",\"arguments\":{\"entity_id\":\"1\",\"content\":\"updated content\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Wiki page updated") != null);
        std.testing.allocator.free(r);
    }
}

// BUG-003: All _delete operations should return responses
test "BUG-003: epic_delete returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"epic_delete\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Epic deleted") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-003: story_delete returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/call\",\"params\":{\"name\":\"story_delete\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Story deleted") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-003: task_delete returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);
    try setupTask(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/call\",\"params\":{\"name\":\"task_delete\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Task deleted") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-003: subtask_delete returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupEpic(&s.server);
    try setupStory(&s.server);
    try setupTask(&s.server);
    try setupSubtask(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"subtask_delete\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "SubTask deleted") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-003: bug_delete returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    _ = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"tools/call\",\"params\":{\"name\":\"bug_create\",\"arguments\":{\"project_id\":\"1\",\"title\":\"Test Bug\",\"description\":\"test\",\"severity\":\"high\"}}}");

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"tools/call\",\"params\":{\"name\":\"bug_delete\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Bug deleted") != null);
        std.testing.allocator.free(r);
    }
}

// BUG-004: wiki_versions should return version history
test "BUG-004: wiki_versions returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupWiki(&s.server);
    // Update to create a version
    _ = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"tools/call\",\"params\":{\"name\":\"wiki_update\",\"arguments\":{\"entity_id\":\"1\",\"content\":\"updated\"}}}");

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/call\",\"params\":{\"name\":\"wiki_versions\",\"arguments\":{\"entity_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Version history") != null);
        std.testing.allocator.free(r);
    }
}

// BUG-005: wiki_search should return search results
test "BUG-005: wiki_search returns response" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupProject(&s.server);
    try setupWiki(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":50,\"method\":\"tools/call\",\"params\":{\"name\":\"wiki_search\",\"arguments\":{\"project_id\":\"1\",\"query\":\"test\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Found") != null);
        std.testing.allocator.free(r);
    }
}

// BUG-006: get_my_work formatting bugs
test "BUG-006: get_my_work includes agent id" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupAgent(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":60,\"method\":\"tools/call\",\"params\":{\"name\":\"get_my_work\",\"arguments\":{\"agent_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r, "Work for agent 1") != null);
        std.testing.allocator.free(r);
    }
}

test "BUG-006: get_my_work uses correct plural 'stories'" {
    var s = try setupServer(std.testing.allocator);
    defer s.conn.deinit();
    try setupAgent(&s.server);

    const resp = try s.server.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":61,\"method\":\"tools/call\",\"params\":{\"name\":\"get_my_work\",\"arguments\":{\"agent_id\":\"1\"}}}");
    try std.testing.expect(resp != null);
    if (resp) |r| {
        // Should contain "stories:" not "storys:"
        try std.testing.expect(std.mem.indexOf(u8, r, "storys") == null);
        std.testing.allocator.free(r);
    }
}
