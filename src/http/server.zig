const std = @import("std");
const db = @import("../db/connection.zig");
const svc = @import("../service/root.zig");
const transition_svc = @import("../service/transition.zig");
const dashboard_svc = @import("../service/dashboard.zig");
const entities_svc = @import("../service/entities.zig");
const project_svc = @import("../service/project.zig");
const queries_project = @import("../db/queries/projects.zig");
const queries_epic = @import("../db/queries/epics.zig");
const queries_story = @import("../db/queries/stories.zig");
const queries_task = @import("../db/queries/tasks.zig");
const queries_subtask = @import("../db/queries/subtasks.zig");
const queries_bug = @import("../db/queries/bug.zig");
const queries_wiki = @import("../db/queries/wiki.zig");
const queries_agents = @import("../db/queries/agents.zig");
const queries_comments = @import("../db/queries/comments.zig");
const queries_memory = @import("../db/queries/memory.zig");
const entities = @import("../domain/entities.zig");
const lifecycle = @import("../domain/lifecycle.zig");
const validation = @import("../domain/validation.zig");

const ui_index_html = @embedFile("../ui/index.html");
const ui_app_js = @embedFile("../ui/app.js");
const ui_styles_css = @embedFile("../ui/styles.css");

pub fn run(conn: *db.Connection, io: std.Io, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.log.info("Prozig dashboard listening on http://127.0.0.1:{d}\n", .{port});
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.warn("Accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        std.log.info("Connection from client\n", .{});
        handleOneRequest(conn, io, stream) catch |err| {
            std.log.warn("Connection error: {s}\n", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn handleOneRequest(conn: *db.Connection, io: std.Io, stream: std.Io.net.Stream) !void {
    var recv_buf: [8192]u8 = undefined;
    var send_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch |err| {
        std.log.warn("Receive head failed: {s}\n", .{@errorName(err)});
        return;
    };
    handleRequest(conn, &request) catch |err| {
        std.log.warn("Request error: {s}\n", .{@errorName(err)});
    };
}

fn handleRequest(conn: *db.Connection, request: *std.http.Server.Request) !void {
    const alloc = std.heap.page_allocator;
    const path = request.head.target;
    const method = request.head.method;

    if (method == .OPTIONS) {
        try request.respond("", .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
            },
        });
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/")) {
        const body = if (method.requestHasBody()) try readRequestBody(request) else null;
        defer if (body) |b| alloc.free(b);
        const response = handleApi(conn, alloc, method, path, body) catch |err| {
            std.log.err("API error: {s}\n", .{@errorName(err)});
            return request.respond("Internal server error", .{ .status = .internal_server_error, .keep_alive = false });
        };
        defer alloc.free(response);
        try request.respond(response, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "Connection", .value = "close" },
            },
        });
        return;
    }

    if (method == .GET) {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            try request.respond(ui_index_html, .{ .keep_alive = false, .extra_headers = &.{ .{ .name = "Content-Type", .value = "text/html; charset=utf-8" }, .{ .name = "Connection", .value = "close" } } });
        } else if (std.mem.eql(u8, path, "/app.js")) {
            try request.respond(ui_app_js, .{ .keep_alive = false, .extra_headers = &.{ .{ .name = "Content-Type", .value = "application/javascript" }, .{ .name = "Connection", .value = "close" } } });
        } else if (std.mem.eql(u8, path, "/styles.css")) {
            try request.respond(ui_styles_css, .{ .keep_alive = false, .extra_headers = &.{ .{ .name = "Content-Type", .value = "text/css" }, .{ .name = "Connection", .value = "close" } } });
        } else if (std.mem.eql(u8, path, "/favicon.ico")) {
            try request.respond("", .{ .status = .no_content, .keep_alive = false });
        } else {
            try request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
        }
        return;
    }
    try request.respond("Method not allowed", .{ .status = .method_not_allowed, .keep_alive = false });
}

fn readRequestBody(request: *std.http.Server.Request) !?[]u8 {
    if (request.head.content_length orelse 0 == 0) return null;
    const len = request.head.content_length.?;
    if (len > 65536) return null;
    var buf: [65536]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    return std.Io.Reader.readAlloc(reader, std.heap.page_allocator, len) catch |err| {
        std.log.warn("Body read error: {s}\n", .{@errorName(err)});
        return null;
    };
}

fn parseId(s: []const u8) !i64 {
    return std.fmt.parseInt(i64, s, 10);
}

fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, s, '"') == null and
        std.mem.indexOfScalar(u8, s, '\\') == null and
        std.mem.indexOfScalar(u8, s, '\n') == null and
        std.mem.indexOfScalar(u8, s, '\r') == null and
        std.mem.indexOfScalar(u8, s, '\t') == null)
    {
        return alloc.dupe(u8, s);
    }
    var result = std.array_list.Managed(u8).init(alloc);
    try result.ensureTotalCapacity(s.len + 16);
    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(c),
        }
    }
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn jsonFieldIf(alloc: std.mem.Allocator, field: []const u8, value: ?[]const u8) ![]u8 {
    if (value) |v| {
        const escaped = try jsonEscape(alloc, v);
        defer alloc.free(escaped);
        return std.fmt.allocPrint(alloc, ",\"{s}\":\"{s}\"", .{ field, escaped });
    }
    return alloc.dupe(u8, "");
}

fn jsonTimestamps(alloc: std.mem.Allocator, created: []const u8, updated: []const u8) ![]u8 {
    const esc_created = try jsonEscape(alloc, created);
    defer alloc.free(esc_created);
    const esc_updated = try jsonEscape(alloc, updated);
    defer alloc.free(esc_updated);
    return std.fmt.allocPrint(alloc, ",\"created_at\":\"{s}\",\"updated_at\":\"{s}\"", .{ esc_created, esc_updated });
}

fn jsonOptInt(alloc: std.mem.Allocator, field: []const u8, value: ?i64) ![]u8 {
    if (value) |v| {
        return std.fmt.allocPrint(alloc, ",\"{s}\":{d}", .{ field, v });
    }
    return alloc.dupe(u8, "");
}

/// Fetch comments for an entity and serialize as a JSON array string.
/// Returns a string like `,"comments":[...]` that can be appended to the
/// entity's JSON response. The caller must free the returned string.
fn jsonComments(alloc: std.mem.Allocator, conn: *db.Connection, entity_type: []const u8, entity_id: i64) ![]u8 {
    var comments = try queries_comments.listByEntity(conn, alloc, entity_type, entity_id);
    defer {
        for (comments.items) |c| entities.freeComment(alloc, c);
        comments.deinit(alloc);
    }

    var buf = std.array_list.Managed(u8).init(alloc);
    try buf.appendSlice(",\"comments\":[");
    for (comments.items, 0..) |c, i| {
        if (i > 0) try buf.append(',');
        const esc_content = try jsonEscape(alloc, c.content);
        defer alloc.free(esc_content);
        const esc_name = try jsonEscape(alloc, c.author_name);
        defer alloc.free(esc_name);
        const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"author_type\":\"{s}\",\"author_name\":\"{s}\",\"content\":\"{s}\",\"created_at\":\"{s}\"}}", .{ c.id, c.author_type, esc_name, esc_content, c.created_at });
        try buf.appendSlice(entry);
        alloc.free(entry);
    }
    try buf.append(']');
    return buf.toOwnedSlice() catch return error.OutOfMemory;
}

fn errJson(alloc: std.mem.Allocator, msg: []const u8) []u8 {
    return std.fmt.allocPrint(alloc, "{{\"error\":\"{s}\"}}", .{msg}) catch alloc.dupe(u8, "{{\"error\":\"internal\"}}") catch unreachable;
}

fn errFk(alloc: std.mem.Allocator, parent: []const u8) []u8 {
    return std.fmt.allocPrint(alloc, "{{\"error\":\"parent_not_found\",\"detail\":\"{s} does not exist\"}}", .{parent}) catch unreachable;
}

const TransitionBody = struct { status: []const u8 };

fn handleTransition(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, entity_type: []const u8, entity_id: i64, body: ?[]u8) ![]u8 {
    if (method != .POST) return errJson(alloc, "method_not_allowed");
    const body_str = body orelse return errJson(alloc, "missing_body");
    const parsed = std.json.parseFromSliceLeaky(TransitionBody, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
    var service = svc.init(conn);
    transition_svc.transitionStatus(&service, alloc, entity_type, entity_id, parsed.status, null) catch |err| {
        if (err == error.InvalidTransition) return errJson(alloc, "invalid_transition");
        if (err == error.NotFound) return errJson(alloc, "not_found");
        return errJson(alloc, @errorName(err));
    };
    return alloc.dupe(u8, "{\"success\":true}");
}

fn handleApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, path: []const u8, body: ?[]u8) ![]u8 {
    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next();
    _ = it.next();
    var resource = it.next() orelse return error.BadRequest;
    // Strip query string from resource name (e.g., "dashboard?project_id=1" -> "dashboard")
    const qmark = std.mem.indexOfScalar(u8, resource, '?');
    if (qmark) |q| {
        resource = resource[0..q];
    }

    if (std.mem.eql(u8, resource, "projects")) {
        const project_id = it.next();
        if (project_id) |pid| {
            const sub = it.next();
            if (sub) |subresource| {
                if (std.mem.eql(u8, subresource, "epics")) return handleEpicsByProject(conn, alloc, method, pid, body);
                if (std.mem.eql(u8, subresource, "stories")) return handleStoriesByProject(conn, alloc, method, pid, body);
                if (std.mem.eql(u8, subresource, "tasks")) return handleTasksByProject(conn, alloc, method, pid, body);
                if (std.mem.eql(u8, subresource, "subtasks")) return handleSubtasksByProject(conn, alloc, method, pid, body);
                if (std.mem.eql(u8, subresource, "bugs")) return handleBugsByProject(conn, alloc, method, pid, body);
                if (std.mem.eql(u8, subresource, "wiki")) return handleWikiByProject(conn, alloc, method, pid, body);
                if (std.mem.eql(u8, subresource, "roles")) return handleRolesByProject(conn, alloc, method, pid, &it, body);
                if (std.mem.eql(u8, subresource, "workflow")) return handleWorkflowByProject(conn, alloc, method, pid, &it, body);
            }
            return handleProjectById(conn, alloc, method, pid, body);
        }
        return handleProjectsList(conn, alloc, method, body);
    }
    if (std.mem.eql(u8, resource, "epics")) return handleEpicsApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "stories")) return handleStoriesApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "tasks")) return handleTasksApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "subtasks")) return handleSubtasksApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "bugs")) return handleBugsApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "wiki")) return handleWikiApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "agents")) return handleAgentsApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "comments")) return handleCommentsApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "dashboard")) return handleDashboardApi(conn, alloc, method, path, body);
    if (std.mem.eql(u8, resource, "memories")) return handleMemoriesApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "config")) return handleConfigApi(conn, alloc, method, &it, body);
    if (std.mem.eql(u8, resource, "health")) return alloc.dupe(u8, "{\"status\":\"ok\"}");
    return error.NotFound;
}

fn handleProjectsList(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, body: ?[]u8) ![]u8 {
    if (method == .POST) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(AllocatedProject, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        const project = queries_project.insert(conn, alloc, parsed.name, parsed.root_path, parsed.description) catch |err| return errJson(alloc, @errorName(err));
        defer freeProject(alloc, project);
        return std.fmt.allocPrint(alloc, \\{{"id":{d},"name":"{s}","root_path":"{s}"}}
        , .{ project.id, project.name, project.root_path });
    }
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    var projects = try queries_project.listAll(conn, alloc);
    defer projects.deinit(alloc);
    var result = std.array_list.Managed(u8).init(alloc);
    try result.appendSlice("[");
    for (projects.items, 0..) |p, i| {
        if (i > 0) try result.append(',');
        const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"name\":\"{s}\",\"root_path\":\"{s}\"}}", .{ p.id, p.name, p.root_path });
        try result.appendSlice(entry);
        alloc.free(entry);
        freeProject(alloc, p);
    }
    try result.appendSlice("]");
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn handleProjectById(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    if (method == .GET) {
        const project = queries_project.getById(conn, alloc, project_id) catch |err| return errJson(alloc, @errorName(err));
        if (project) |p| {
            defer freeProject(alloc, p);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"name":"{s}","root_path":"{s}","description":{s}}}
            , .{ p.id, p.name, p.root_path, if (p.description) |d| try std.fmt.allocPrint(alloc, "\"{s}\"", .{d}) else "null" });
        }
        return errJson(alloc, "not_found");
    }
    if (method == .DELETE) {
        conn.begin() catch |err| return errJson(alloc, @errorName(err));
        errdefer conn.rollback();
        queries_project.delete(conn, project_id) catch |err| {
            conn.rollback();
            return errJson(alloc, @errorName(err));
        };
        conn.commit() catch |err| {
            conn.rollback();
            return errJson(alloc, @errorName(err));
        };
        return alloc.dupe(u8, "{\"success\":true}");
    }
    return errJson(alloc, "method_not_allowed");
}

const AllocatedProject = struct { name: []const u8, root_path: []const u8, description: ?[]const u8 = null };

fn freeProject(alloc: std.mem.Allocator, p: entities.Project) void {
    alloc.free(p.name); alloc.free(p.root_path);
    if (p.description) |d| alloc.free(d);
    if (p.metadata) |m| alloc.free(m);
    alloc.free(p.created_at); alloc.free(p.updated_at);
}

// ─── Role Manager API ───

fn handleRolesByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    const role_id_str = it.next();
    const role_id = if (role_id_str) |s| parseId(s) catch null else null;
    const sub = if (role_id != null) it.next() else null;

    // GET/PUT /api/projects/{pid}/roles/{rid}/permissions
    if (sub != null and std.mem.eql(u8, sub.?, "permissions")) {
        if (method == .GET) {
            var stmt = try conn.prepare(
                \\SELECT t.id, t.from_state_id, t.to_state_id, ws_from.name, ws_to.name, ws_from.entity_type,
                \\CASE WHEN rp.id IS NOT NULL THEN 1 ELSE 0 END
                \\FROM workflow_transitions t
                \\JOIN workflow_states ws_from ON t.from_state_id = ws_from.id
                \\JOIN workflow_states ws_to ON t.to_state_id = ws_to.id
                \\LEFT JOIN role_permissions rp ON rp.transition_id = t.id AND rp.role_id = ?
                \\WHERE t.project_id = ? ORDER BY ws_from.entity_type, ws_from.position, ws_to.position
            );
            defer stmt.finalize();
            stmt.bindInt64(1, role_id.?);
            stmt.bindInt64(2, project_id);
            var result = std.array_list.Managed(u8).init(alloc);
            try result.appendSlice("[");
            var first = true;
            while (true) {
                const row = stmt.step() catch break;
                if (row != .row) break;
                if (!first) try result.append(',');
                first = false;
                const tid = stmt.columnInt64(0);
                const from_name = stmt.columnText(3) orelse "";
                const to_name = stmt.columnText(4) orelse "";
                const entity_type = stmt.columnText(5) orelse "";
                const permitted = stmt.columnInt64(6);
                const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"entity_type\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"permitted\":{d}}}", .{ tid, entity_type, from_name, to_name, permitted });
                try result.appendSlice(entry);
                alloc.free(entry);
            }
            try result.appendSlice("]");
            return result.toOwnedSlice() catch return error.OutOfMemory;
        }
        if (method == .PUT) {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(RolePermissionPayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            var del = try conn.prepare("DELETE FROM role_permissions WHERE role_id = ? AND transition_id = ?");
            defer del.finalize();
            del.bindInt64(1, role_id.?);
            del.bindInt64(2, parsed.transition_id);
            _ = try del.step();
            if (parsed.permitted) {
                var ins = try conn.prepare("INSERT INTO role_permissions (role_id, transition_id) VALUES (?, ?)");
                defer ins.finalize();
                ins.bindInt64(1, role_id.?);
                ins.bindInt64(2, parsed.transition_id);
                _ = try ins.step();
            }
            return alloc.dupe(u8, "{\"success\":true}");
        }
    return errJson(alloc, "method_not_allowed");
}

    // GET list / POST create / DELETE / PUT single role
    if (role_id == null and method == .GET) {
        var stmt = try conn.prepare(
            \\SELECT r.id, r.name, r.description, (
            \\  SELECT COUNT(*) FROM agent_profiles ap
            \\  JOIN agent_roles ar ON ap.role_id = ar.id
            \\  WHERE ar.name = r.name
            \\) FROM agent_roles r WHERE r.project_id = ? ORDER BY r.name
        );
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        var result = std.array_list.Managed(u8).init(alloc);
        try result.appendSlice("[");
        var first = true;
        while (true) {
            const row = stmt.step() catch break;
            if (row != .row) break;
            if (!first) try result.append(',');
            first = false;
            const rid = stmt.columnInt64(0);
            const name = stmt.columnText(1) orelse "";
            const desc = stmt.columnText(2) orelse "";
            const agent_count = stmt.columnInt64(3);
            const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"name\":\"{s}\",\"description\":\"{s}\",\"agent_count\":{d}}}", .{ rid, name, desc, agent_count });
            try result.appendSlice(entry);
            alloc.free(entry);
        }
        try result.appendSlice("]");
        return result.toOwnedSlice() catch return error.OutOfMemory;
    }
    if (role_id == null and method == .POST) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(RoleCreatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        var stmt = try conn.prepare("INSERT INTO agent_roles (project_id, name, description) VALUES (?, ?, ?) RETURNING id");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        stmt.bindText(2, parsed.name);
        if (parsed.description) |d| stmt.bindText(3, d) else stmt.bindNull(3);
        _ = try stmt.step();
        return std.fmt.allocPrint(alloc, "{{\"id\":{d},\"name\":\"{s}\"}}", .{ stmt.columnInt64(0), parsed.name });
    }
    if (role_id != null and method == .DELETE) {
        var stmt = try conn.prepare("DELETE FROM agent_roles WHERE id = ? AND project_id = ?");
        defer stmt.finalize();
        stmt.bindInt64(1, role_id.?);
        stmt.bindInt64(2, project_id);
        _ = try stmt.step();
        return alloc.dupe(u8, "{\"success\":true}");
    }
    if (role_id != null and method == .PUT) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(RoleUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        var stmt = try conn.prepare("UPDATE agent_roles SET name = ?, description = ? WHERE id = ? AND project_id = ?");
        defer stmt.finalize();
        stmt.bindText(1, parsed.name);
        stmt.bindText(2, parsed.description orelse "");
        stmt.bindInt64(3, role_id.?);
        stmt.bindInt64(4, project_id);
        _ = try stmt.step();
        return alloc.dupe(u8, "{\"success\":true}");
    }
    return errJson(alloc, "method_not_allowed");
}

const RoleCreatePayload = struct { name: []const u8, description: ?[]const u8 = null };
const RoleUpdatePayload = struct { name: []const u8, description: ?[]const u8 = null };
const RolePermissionPayload = struct { transition_id: i64, permitted: bool };

// ─── Workflow Designer API ───

fn handleWorkflowByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    const subresource = it.next() orelse return errJson(alloc, "not_found");

    if (std.mem.eql(u8, subresource, "states")) {
        return handleWorkflowStates(conn, alloc, method, project_id, it, body);
    }
    if (std.mem.eql(u8, subresource, "transitions")) {
        return handleWorkflowTransitions(conn, alloc, method, project_id, it, body);
    }
    return errJson(alloc, "not_found");
}

fn handleWorkflowStates(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id: i64, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const segment = it.next() orelse return errJson(alloc, "not_found");
    const state_id = parseId(segment) catch null;

    if (state_id == null and method == .GET) {
        const entity_type = segment;
        var stmt = try conn.prepare("SELECT id, name, position, category, color FROM workflow_states WHERE project_id = ? AND entity_type = ? ORDER BY position");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        stmt.bindText(2, entity_type);
        var result = std.array_list.Managed(u8).init(alloc);
        try result.appendSlice("[");
        var first = true;
        while (true) {
            const row = stmt.step() catch break;
            if (row != .row) break;
            if (!first) try result.append(',');
            first = false;
            const sid = stmt.columnInt64(0);
            const name = stmt.columnText(1) orelse "";
            const pos = stmt.columnInt64(2);
            const cat = stmt.columnText(3) orelse "active";
            const color = stmt.columnText(4) orelse "";
            const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"name\":\"{s}\",\"position\":{d},\"category\":\"{s}\",\"color\":\"{s}\"}}", .{ sid, name, pos, cat, color });
            try result.appendSlice(entry);
            alloc.free(entry);
        }
        try result.appendSlice("]");
        return result.toOwnedSlice() catch return error.OutOfMemory;
    }
    if (state_id == null and method == .POST) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(StateCreatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        var stmt = try conn.prepare("INSERT INTO workflow_states (project_id, entity_type, name, position, category, color) VALUES (?, ?, ?, ?, ?, ?) RETURNING id");
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        stmt.bindText(2, parsed.entity_type);
        stmt.bindText(3, parsed.name);
        stmt.bindInt64(4, parsed.position);
        stmt.bindText(5, parsed.category orelse "active");
        if (parsed.color) |c| stmt.bindText(6, c) else stmt.bindNull(6);
        _ = try stmt.step();
        return std.fmt.allocPrint(alloc, "{{\"id\":{d},\"name\":\"{s}\"}}", .{ stmt.columnInt64(0), parsed.name });
    }
    if (state_id != null and method == .DELETE) {
        var stmt = try conn.prepare("DELETE FROM workflow_states WHERE id = ? AND project_id = ?");
        defer stmt.finalize();
        stmt.bindInt64(1, state_id.?);
        stmt.bindInt64(2, project_id);
        _ = try stmt.step();
        return alloc.dupe(u8, "{\"success\":true}");
    }
    if (state_id != null and method == .PUT) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(StateUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        var stmt = try conn.prepare("UPDATE workflow_states SET name = ?, category = ?, color = ?, position = ? WHERE id = ? AND project_id = ?");
        defer stmt.finalize();
        stmt.bindText(1, parsed.name);
        stmt.bindText(2, parsed.category orelse "active");
        if (parsed.color) |c| stmt.bindText(3, c) else stmt.bindNull(3);
        stmt.bindInt64(4, parsed.position);
        stmt.bindInt64(5, state_id.?);
        stmt.bindInt64(6, project_id);
        _ = try stmt.step();
        return alloc.dupe(u8, "{\"success\":true}");
    }
    return errJson(alloc, "method_not_allowed");
}

const StateCreatePayload = struct { entity_type: []const u8, name: []const u8, position: i64, category: ?[]const u8 = null, color: ?[]const u8 = null };
const StateUpdatePayload = struct { name: []const u8, category: ?[]const u8 = null, color: ?[]const u8 = null, position: i64 };

fn handleWorkflowTransitions(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id: i64, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    _ = it;
    if (method == .GET) {
        // Expect query param? We read entity_type from the remaining path segments.
        // Actually this is called as /api/projects/{pid}/workflow/transitions?et=epic but we don't parse query.
        // Instead, the caller passes entity_type as a path segment after 'transitions'.
        // Let's use a simpler approach: return all transitions for the project.
        var stmt = try conn.prepare(
            "SELECT t.id, s_from.name, s_to.name, s_from.entity_type FROM workflow_transitions t JOIN workflow_states s_from ON t.from_state_id = s_from.id JOIN workflow_states s_to ON t.to_state_id = s_to.id WHERE t.project_id = ? ORDER BY s_from.entity_type, s_from.position, s_to.position"
        );
        defer stmt.finalize();
        stmt.bindInt64(1, project_id);
        var result = std.array_list.Managed(u8).init(alloc);
        try result.appendSlice("[");
        var first = true;
        while (true) {
            const row = stmt.step() catch break;
            if (row != .row) break;
            if (!first) try result.append(',');
            first = false;
            const tid = stmt.columnInt64(0);
            const from_name = stmt.columnText(1) orelse "";
            const to_name = stmt.columnText(2) orelse "";
            const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"from\":\"{s}\",\"to\":\"{s}\"}}", .{ tid, from_name, to_name });
            try result.appendSlice(entry);
            alloc.free(entry);
        }
        try result.appendSlice("]");
        return result.toOwnedSlice() catch return error.OutOfMemory;
    }
    if (method == .POST) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(TransitionTogglePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        if (parsed.enabled) {
            var stmt = try conn.prepare("INSERT OR IGNORE INTO workflow_transitions (project_id, entity_type, from_state_id, to_state_id) VALUES (?, ?, ?, ?) RETURNING id");
            defer stmt.finalize();
            stmt.bindInt64(1, project_id);
            stmt.bindText(2, parsed.entity_type);
            stmt.bindInt64(3, parsed.from_state_id);
            stmt.bindInt64(4, parsed.to_state_id);
            _ = try stmt.step();
            return std.fmt.allocPrint(alloc, "{{\"id\":{d},\"enabled\":true}}", .{stmt.columnInt64(0)});
        } else {
            var stmt = try conn.prepare("DELETE FROM workflow_transitions WHERE project_id = ? AND entity_type = ? AND from_state_id = ? AND to_state_id = ?");
            defer stmt.finalize();
            stmt.bindInt64(1, project_id);
            stmt.bindText(2, parsed.entity_type);
            stmt.bindInt64(3, parsed.from_state_id);
            stmt.bindInt64(4, parsed.to_state_id);
            _ = try stmt.step();
            return alloc.dupe(u8, "{\"success\":true}");
        }
    }
    return errJson(alloc, "method_not_allowed");
}

const TransitionTogglePayload = struct { entity_type: []const u8, from_state_id: i64, to_state_id: i64, enabled: bool };

fn handleEpicsApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;
    // Check for transition sub-route: /epics/{id}/transition
    const sub = if (id != null) it.next() else null;
    if (sub != null and std.mem.eql(u8, sub.?, "transition")) {
        return handleTransition(conn, alloc, method, "epic", id.?, body);
    }

    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (id) |epic_id| {
                const epic = queries_epic.getById(conn, alloc, epic_id) catch |err| return errJson(alloc, @errorName(err));
                if (epic) |e| {
                    defer freeEpic(alloc, e);
                    const desc_field = try jsonFieldIf(alloc, "description", e.description);
                    defer alloc.free(desc_field);
                    const ts_field = try jsonTimestamps(alloc, e.created_at, e.updated_at);
                    defer alloc.free(ts_field);
                    const assign_field = try jsonOptInt(alloc, "assignee_agent_id", e.assignee_agent_id);
                    defer alloc.free(assign_field);
                    const comments_field = try jsonComments(alloc, conn, "epic", epic_id);
                    defer alloc.free(comments_field);
                    return std.fmt.allocPrint(alloc, \\{{"id":{d},"project_id":{d},"title":"{s}","status":"{s}"{s}{s}{s}{s}}}
                    , .{ e.id, e.project_id, e.title, lifecycle.epicStatusToDb(e.status), desc_field, ts_field, assign_field, comments_field });
                }
                return errJson(alloc, "not_found");
            }
            return errJson(alloc, "missing_id");
        },
        .POST => {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AllocatedEpic, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            validation.validateEpic(parsed.project_id, parsed.title, parsed.description orelse "") catch |err| return errJson(alloc, @errorName(err));
            const epic = queries_epic.insert(conn, alloc, parsed.project_id, parsed.title, parsed.description, null) catch |err| {
                if (err == error.ConstraintViolation) return errFk(alloc, "project");
                return errJson(alloc, @errorName(err));
            };
            defer freeEpic(alloc, epic);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}","status":"Backlog"}}
            , .{ epic.id, epic.title });
        },
        .PUT => {
            if (id == null) return errJson(alloc, "missing_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(EpicUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            entities_svc.updateEpic(&service, alloc, id.?, parsed.title, parsed.description) catch |err| {
                if (err == error.NoFieldsToUpdate) return errJson(alloc, "no_fields_to_update");
                return errJson(alloc, @errorName(err));
            };
            return alloc.dupe(u8, "{\"success\":true}");
        },
        .DELETE => {
            if (id == null) return errJson(alloc, "missing_id");
            entities_svc.deleteEpicWithChildren(&service, id.?) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}

const EpicUpdatePayload = struct { title: ?[]const u8 = null, description: ?[]const u8 = null };

fn handleEpicsByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    var epics = try queries_epic.listByProject(conn, alloc, project_id);
    defer epics.deinit(alloc);
    var result = std.array_list.Managed(u8).init(alloc);
    try result.appendSlice("[");
    for (epics.items, 0..) |e, i| {
        if (i > 0) try result.append(',');
        const desc_field = try jsonFieldIf(alloc, "description", e.description);
        defer alloc.free(desc_field);
        const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"title\":\"{s}\",\"status\":\"{s}\"{s}}}", .{ e.id, e.title, lifecycle.epicStatusToDb(e.status), desc_field });
        try result.appendSlice(entry);
        alloc.free(entry);
        freeEpic(alloc, e);
    }
    try result.appendSlice("]");
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

const AllocatedEpic = struct { project_id: i64, title: []const u8, description: ?[]const u8 = null };

fn freeEpic(alloc: std.mem.Allocator, e: entities.Epic) void {
    alloc.free(e.title);
    if (e.description) |d| alloc.free(d);
    alloc.free(e.created_at); alloc.free(e.updated_at);
}

fn handleStoriesApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;
    // Check for transition sub-route: /stories/{id}/transition
    const sub = if (id != null) it.next() else null;
    if (sub != null and std.mem.eql(u8, sub.?, "transition")) {
        return handleTransition(conn, alloc, method, "story", id.?, body);
    }

    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (id) |story_id| {
                const story = queries_story.getById(conn, alloc, story_id) catch |err| return errJson(alloc, @errorName(err));
                if (story) |s| {
                    defer freeStory(alloc, s);
                    const desc_field = try jsonFieldIf(alloc, "description", s.description);
                    defer alloc.free(desc_field);
                    const ac_field = try jsonFieldIf(alloc, "acceptance_criteria", s.acceptance_criteria);
                    defer alloc.free(ac_field);
                    const ts_field = try jsonTimestamps(alloc, s.created_at, s.updated_at);
                    defer alloc.free(ts_field);
                    const assign_field = try jsonOptInt(alloc, "assignee_agent_id", s.assignee_agent_id);
                    defer alloc.free(assign_field);
                    const comments_field = try jsonComments(alloc, conn, "story", story_id);
                    defer alloc.free(comments_field);
                    return std.fmt.allocPrint(alloc, \\{{"id":{d},"epic_id":{d},"title":"{s}","status":"{s}"{s}{s}{s}{s}{s}}}
                    , .{ s.id, s.epic_id, s.title, lifecycle.storyStatusToDb(s.status), desc_field, ac_field, ts_field, assign_field, comments_field });
                }
                return errJson(alloc, "not_found");
            }
            return errJson(alloc, "missing_id");
        },
        .POST => {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AllocatedStory, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            validation.validateStory(parsed.project_id, parsed.epic_id, parsed.title, parsed.description orelse "", parsed.acceptance_criteria orelse "") catch |err| return errJson(alloc, @errorName(err));
            const story = queries_story.insert(conn, alloc, parsed.project_id, parsed.epic_id, parsed.title, parsed.description, parsed.acceptance_criteria) catch |err| {
                if (err == error.ConstraintViolation) return errFk(alloc, "epic");
                return errJson(alloc, @errorName(err));
            };
            defer freeStory(alloc, story);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}","status":"Backlog"}}
            , .{ story.id, story.title });
        },
        .PUT => {
            if (id == null) return errJson(alloc, "missing_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(StoryUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            entities_svc.updateStory(&service, alloc, id.?, parsed.title, parsed.description, parsed.acceptance_criteria) catch |err| {
                if (err == error.NoFieldsToUpdate) return errJson(alloc, "no_fields_to_update");
                return errJson(alloc, @errorName(err));
            };
            return alloc.dupe(u8, "{\"success\":true}");
        },
        .DELETE => {
            if (id == null) return errJson(alloc, "missing_id");
            entities_svc.deleteStoryWithChildren(&service, id.?) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}

const StoryUpdatePayload = struct { title: ?[]const u8 = null, description: ?[]const u8 = null, acceptance_criteria: ?[]const u8 = null };

fn handleStoriesByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    var epics = try queries_epic.listByProject(conn, alloc, project_id);
    defer epics.deinit(alloc);
    var result = std.array_list.Managed(u8).init(alloc);
    try result.appendSlice("[");
    var first = true;
    for (epics.items) |e| {
        var stories = queries_story.listByEpic(conn, alloc, e.id) catch continue;
        defer stories.deinit(alloc);
        for (stories.items) |s| {
            if (!first) try result.append(',');
            first = false;
            const desc_field = try jsonFieldIf(alloc, "description", s.description);
            defer alloc.free(desc_field);
            const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"epic_id\":{d},\"title\":\"{s}\",\"status\":\"{s}\"{s}}}", .{ s.id, s.epic_id, s.title, lifecycle.storyStatusToDb(s.status), desc_field });
            try result.appendSlice(entry);
            alloc.free(entry);
            freeStory(alloc, s);
        }
        freeEpic(alloc, e);
    }
    try result.appendSlice("]");
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

const AllocatedStory = struct { project_id: i64, epic_id: i64, title: []const u8, description: ?[]const u8 = null, acceptance_criteria: ?[]const u8 = null };

fn freeStory(alloc: std.mem.Allocator, s: entities.Story) void {
    alloc.free(s.title);
    if (s.description) |d| alloc.free(d);
    if (s.acceptance_criteria) |a| alloc.free(a);
    alloc.free(s.created_at); alloc.free(s.updated_at);
}

fn handleTasksApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;
    // Check for transition sub-route: /tasks/{id}/transition
    const sub = if (id != null) it.next() else null;
    if (sub != null and std.mem.eql(u8, sub.?, "transition")) {
        return handleTransition(conn, alloc, method, "task", id.?, body);
    }

    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (id) |task_id| {
                const task = queries_task.getById(conn, alloc, task_id) catch |err| return errJson(alloc, @errorName(err));
                if (task) |t| {
                    defer freeTask(alloc, t);
                    const desc_field = try jsonFieldIf(alloc, "description", t.description);
                    defer alloc.free(desc_field);
                    const ts_field = try jsonTimestamps(alloc, t.created_at, t.updated_at);
                    defer alloc.free(ts_field);
                    const assign_field = try jsonOptInt(alloc, "assignee_agent_id", t.assignee_agent_id);
                    defer alloc.free(assign_field);
                    const comments_field = try jsonComments(alloc, conn, "task", task_id);
                    defer alloc.free(comments_field);
                    return std.fmt.allocPrint(alloc, \\{{"id":{d},"story_id":{d},"title":"{s}","status":"{s}"{s}{s}{s}{s}}}
                    , .{ t.id, t.story_id, t.title, lifecycle.taskStatusToDb(t.status), desc_field, ts_field, assign_field, comments_field });
                }
                return errJson(alloc, "not_found");
            }
            return errJson(alloc, "missing_id");
        },
        .POST => {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AllocatedTask, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            validation.validateTask(parsed.project_id, parsed.story_id, parsed.title, parsed.description orelse "") catch |err| return errJson(alloc, @errorName(err));
            const task = queries_task.insert(conn, alloc, parsed.project_id, parsed.story_id, parsed.title, parsed.description) catch |err| {
                if (err == error.ConstraintViolation) return errFk(alloc, "story");
                return errJson(alloc, @errorName(err));
            };
            defer freeTask(alloc, task);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}","status":"Todo"}}
            , .{ task.id, task.title });
        },
        .PUT => {
            if (id == null) return errJson(alloc, "missing_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(TaskUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            entities_svc.updateTask(&service, alloc, id.?, parsed.title, parsed.description) catch |err| {
                if (err == error.NoFieldsToUpdate) return errJson(alloc, "no_fields_to_update");
                return errJson(alloc, @errorName(err));
            };
            return alloc.dupe(u8, "{\"success\":true}");
        },
        .DELETE => {
            if (id == null) return errJson(alloc, "missing_id");
            entities_svc.deleteTaskWithChildren(&service, id.?) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}

const TaskUpdatePayload = struct { title: ?[]const u8 = null, description: ?[]const u8 = null };

fn handleTasksByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    var epics = try queries_epic.listByProject(conn, alloc, project_id);
    defer epics.deinit(alloc);
    var result = std.array_list.Managed(u8).init(alloc);
    try result.appendSlice("[");
    var first = true;
    for (epics.items) |e| {
        var stories = queries_story.listByEpic(conn, alloc, e.id) catch continue;
        defer stories.deinit(alloc);
        for (stories.items) |s| {
            var tasks = queries_task.listByStory(conn, alloc, s.id) catch continue;
            defer tasks.deinit(alloc);
            for (tasks.items) |t| {
                if (!first) try result.append(',');
                first = false;
                const desc_field = try jsonFieldIf(alloc, "description", t.description);
                defer alloc.free(desc_field);
                const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"story_id\":{d},\"title\":\"{s}\",\"status\":\"{s}\"{s}}}", .{ t.id, t.story_id, t.title, lifecycle.taskStatusToDb(t.status), desc_field });
                try result.appendSlice(entry);
                alloc.free(entry);
                freeTask(alloc, t);
            }
            freeStory(alloc, s);
        }
        freeEpic(alloc, e);
    }
    try result.appendSlice("]");
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

const AllocatedTask = struct { project_id: i64, story_id: i64, title: []const u8, description: ?[]const u8 = null };

fn freeTask(alloc: std.mem.Allocator, t: entities.Task) void {
    alloc.free(t.title);
    if (t.description) |d| alloc.free(d);
    alloc.free(t.created_at); alloc.free(t.updated_at);
}

fn handleSubtasksApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;
    // Check for transition sub-route: /subtasks/{id}/transition
    const sub = if (id != null) it.next() else null;
    if (sub != null and std.mem.eql(u8, sub.?, "transition")) {
        return handleTransition(conn, alloc, method, "subtask", id.?, body);
    }

    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (id) |subtask_id| {
                const subtask = queries_subtask.getById(conn, alloc, subtask_id) catch |err| return errJson(alloc, @errorName(err));
                if (subtask) |st| {
                    defer freeSubtask(alloc, st);
                    const desc_field = try jsonFieldIf(alloc, "description", st.description);
                    defer alloc.free(desc_field);
                    const ts_field = try jsonTimestamps(alloc, st.created_at, st.updated_at);
                    defer alloc.free(ts_field);
                    const assign_field = try jsonOptInt(alloc, "assignee_agent_id", st.assignee_agent_id);
                    defer alloc.free(assign_field);
                    const comments_field = try jsonComments(alloc, conn, "subtask", subtask_id);
                    defer alloc.free(comments_field);
                    return std.fmt.allocPrint(alloc, \\{{"id":{d},"task_id":{d},"title":"{s}","status":"{s}"{s}{s}{s}{s}}}
                    , .{ st.id, st.task_id, st.title, lifecycle.subTaskStatusToDb(st.status), desc_field, ts_field, assign_field, comments_field });
                }
                return errJson(alloc, "not_found");
            }
            return errJson(alloc, "missing_id");
        },
        .POST => {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AllocatedSubtask, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            validation.validateSubTask(parsed.project_id, parsed.task_id, parsed.title, parsed.description orelse "") catch |err| return errJson(alloc, @errorName(err));
            const subtask = queries_subtask.insert(conn, alloc, parsed.project_id, parsed.task_id, parsed.title, parsed.description) catch |err| {
                if (err == error.ConstraintViolation) return errFk(alloc, "task");
                return errJson(alloc, @errorName(err));
            };
            defer freeSubtask(alloc, subtask);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}","status":"Todo"}}
            , .{ subtask.id, subtask.title });
        },
        .PUT => {
            if (id == null) return errJson(alloc, "missing_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(SubtaskUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            entities_svc.updateSubtask(&service, alloc, id.?, parsed.title, parsed.description) catch |err| {
                if (err == error.NoFieldsToUpdate) return errJson(alloc, "no_fields_to_update");
                return errJson(alloc, @errorName(err));
            };
            return alloc.dupe(u8, "{\"success\":true}");
        },
        .DELETE => {
            if (id == null) return errJson(alloc, "missing_id");
            queries_subtask.delete(conn, id.?) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}

const SubtaskUpdatePayload = struct { title: ?[]const u8 = null, description: ?[]const u8 = null };

const AllocatedSubtask = struct { project_id: i64, task_id: i64, title: []const u8, description: ?[]const u8 = null };

fn freeSubtask(alloc: std.mem.Allocator, st: entities.SubTask) void {
    alloc.free(st.title);
    if (st.description) |d| alloc.free(d);
    alloc.free(st.created_at); alloc.free(st.updated_at);
}

const AllocatedBug = struct { project_id: i64, title: []const u8, description: ?[]const u8 = null, severity: []const u8, epic_id: ?i64 = null, story_id: ?i64 = null, task_id: ?i64 = null };

fn handleBugsApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;
    // Check for transition sub-route: /bugs/{id}/transition
    const sub = if (id != null) it.next() else null;
    if (sub != null and std.mem.eql(u8, sub.?, "transition")) {
        return handleTransition(conn, alloc, method, "bug", id.?, body);
    }

    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (id) |bug_id| {
                const bug = queries_bug.getById(conn, alloc, bug_id) catch |err| return errJson(alloc, @errorName(err));
                if (bug) |b| {
                    defer entities.freeBug(alloc, b);
                    const desc_field = try jsonFieldIf(alloc, "description", b.description);
                    defer alloc.free(desc_field);
                    const ts_field = try jsonTimestamps(alloc, b.created_at, b.updated_at);
                    defer alloc.free(ts_field);
                    const assign_field = try jsonOptInt(alloc, "assignee_agent_id", b.assignee_agent_id);
                    defer alloc.free(assign_field);
                    const comments_field = try jsonComments(alloc, conn, "bug", bug_id);
                    defer alloc.free(comments_field);
                    return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}","severity":"{s}","status":"{s}"{s}{s}{s}{s}}}
                    , .{ b.id, b.title, b.severity, lifecycle.bugStatusToDb(b.status), desc_field, ts_field, assign_field, comments_field });
                }
                return errJson(alloc, "not_found");
            }
            return errJson(alloc, "missing_id");
        },
        .POST => {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AllocatedBug, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            validation.validateBug(parsed.project_id, parsed.title, parsed.description orelse "", parsed.severity) catch |err| return errJson(alloc, @errorName(err));
            const bug = queries_bug.insert(conn, alloc, parsed.project_id, parsed.title, parsed.description, parsed.severity, parsed.epic_id, parsed.story_id, parsed.task_id) catch |err| {
                if (err == error.ConstraintViolation) return errFk(alloc, "project/epic/story/task");
                return errJson(alloc, @errorName(err));
            };
            defer entities.freeBug(alloc, bug);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}","severity":"{s}","status":"New"}}
            , .{ bug.id, bug.title, bug.severity });
        },
        .PUT => {
            if (id == null) return errJson(alloc, "missing_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(BugUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            entities_svc.updateBug(&service, alloc, id.?, parsed.title, parsed.description, parsed.severity) catch |err| {
                if (err == error.NoFieldsToUpdate) return errJson(alloc, "no_fields_to_update");
                return errJson(alloc, @errorName(err));
            };
            return alloc.dupe(u8, "{\"success\":true}");
        },
        .DELETE => {
            if (id == null) return errJson(alloc, "missing_id");
            queries_bug.delete(conn, id.?) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}

const BugUpdatePayload = struct { title: ?[]const u8 = null, description: ?[]const u8 = null, severity: ?[]const u8 = null };

fn handleBugsByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    var bugs = try queries_bug.listByProject(conn, alloc, project_id);
    defer bugs.deinit(alloc);
    var result = std.array_list.Managed(u8).init(alloc);
    try result.appendSlice("[");
    for (bugs.items, 0..) |b, i| {
        if (i > 0) try result.append(',');
        const desc_field = try jsonFieldIf(alloc, "description", b.description);
        defer alloc.free(desc_field);
        const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"title\":\"{s}\",\"severity\":\"{s}\",\"status\":\"{s}\"{s}}}", .{ b.id, b.title, b.severity, lifecycle.bugStatusToDb(b.status), desc_field });
        try result.appendSlice(entry);
        alloc.free(entry);
        entities.freeBug(alloc, b);
    }
    try result.appendSlice("]");
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn handleSubtasksByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    var subtasks = try queries_subtask.listByProject(conn, alloc, project_id);
    defer subtasks.deinit(alloc);
    var result = std.array_list.Managed(u8).init(alloc);
    try result.appendSlice("[");
    for (subtasks.items, 0..) |st, i| {
        if (i > 0) try result.append(',');
        const desc_field = try jsonFieldIf(alloc, "description", st.description);
        defer alloc.free(desc_field);
        const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"task_id\":{d},\"title\":\"{s}\",\"status\":\"{s}\"{s}}}", .{ st.id, st.task_id, st.title, lifecycle.subTaskStatusToDb(st.status), desc_field });
        try result.appendSlice(entry);
        alloc.free(entry);
        alloc.free(st.title);
        if (st.description) |d| alloc.free(d);
        alloc.free(st.created_at); alloc.free(st.updated_at);
    }
    try result.appendSlice("]");
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn handleWikiApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;

    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (id) |page_id| {
                const page = queries_wiki.getById(conn, alloc, page_id) catch |err| return errJson(alloc, @errorName(err));
                if (page) |p| {
                    defer freeWikiPage(alloc, p);
                    const esc_title = try jsonEscape(alloc, p.title);
                    defer alloc.free(esc_title);
                    const esc_category = try jsonEscape(alloc, p.category);
                    defer alloc.free(esc_category);
                    const esc_content = try jsonEscape(alloc, p.content);
                    defer alloc.free(esc_content);
                    const comments_field = try jsonComments(alloc, conn, "wiki", page_id);
                    defer alloc.free(comments_field);
                    return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}","category":"{s}","content":"{s}","version":{d}{s}}}
                    , .{ p.id, esc_title, esc_category, esc_content, p.version, comments_field });
                }
                return errJson(alloc, "not_found");
            }
            return errJson(alloc, "missing_id");
        },
        .POST => {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AllocatedWikiPage, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            validation.validateWikiPage(parsed.project_id, parsed.title, parsed.category, parsed.content) catch |err| return errJson(alloc, @errorName(err));
            const page = queries_wiki.insert(conn, alloc, parsed.project_id, parsed.category, null, parsed.title, parsed.content) catch |err| {
                if (err == error.ConstraintViolation) return errFk(alloc, "project");
                return errJson(alloc, @errorName(err));
            };
            defer freeWikiPage(alloc, page);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}"}}
            , .{ page.id, page.title });
        },
        .PUT => {
            if (id == null) return errJson(alloc, "missing_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(UpdateWikiPage, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            queries_wiki.updateContent(conn, id.?, parsed.content) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        .DELETE => {
            if (id == null) return errJson(alloc, "missing_id");
            entities_svc.deleteWiki(&service, id.?) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}

fn handleWikiByProject(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, project_id_str: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    const project_id = parseId(project_id_str) catch return errJson(alloc, "invalid_id");
    var pages = try queries_wiki.listByProject(conn, alloc, project_id);
    defer pages.deinit(alloc);
    var result = std.array_list.Managed(u8).init(alloc);
    try result.appendSlice("[");
    for (pages.items, 0..) |p, i| {
        if (i > 0) try result.append(',');
        const esc_title = try jsonEscape(alloc, p.title);
        const esc_category = try jsonEscape(alloc, p.category);
        const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"title\":\"{s}\",\"category\":\"{s}\"}}", .{ p.id, esc_title, esc_category });
        alloc.free(esc_title);
        alloc.free(esc_category);
        try result.appendSlice(entry);
        alloc.free(entry);
        freeWikiPage(alloc, p);
    }
    try result.appendSlice("]");
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

const AllocatedWikiPage = struct { project_id: i64, category: []const u8, title: []const u8, content: []const u8 };
const UpdateWikiPage = struct { content: []const u8 };

fn freeWikiPage(alloc: std.mem.Allocator, p: entities.WikiPage) void {
    alloc.free(p.category);
    alloc.free(p.title); alloc.free(p.content);
    alloc.free(p.created_at); alloc.free(p.updated_at);
}

fn handleAgentsApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;

    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (id) |agent_id| {
                var stmt = try conn.prepare("SELECT a.id, a.name, a.capabilities, a.description, a.role_id, COALESCE(r.name,'') FROM agent_profiles a LEFT JOIN agent_roles r ON a.role_id = r.id WHERE a.id = ?");
                defer stmt.finalize();
                stmt.bindInt64(1, agent_id);
                if (try stmt.step() == .row) {
                    const name = stmt.columnText(1) orelse return errJson(alloc, "not_found");
                    const capabilities = stmt.columnText(2) orelse return errJson(alloc, "not_found");
                    const description = stmt.columnText(3) orelse "";
                    const role_id = stmt.columnInt64Safe(4);
                    const role_name = stmt.columnText(5) orelse "";
                    return std.fmt.allocPrint(alloc, \\{{"id":{d},"name":"{s}","capabilities":"{s}","description":"{s}","role_id":{s},"role_name":"{s}"}}
                    , .{ agent_id, name, capabilities, description, if (role_id) |r| std.fmt.allocPrint(alloc, "{d}", .{r}) catch "null" else "null", role_name });
                }
                return errJson(alloc, "not_found");
            }
            // List all agents
            var stmt = try conn.prepare("SELECT a.id, a.name, a.capabilities, a.description, a.role_id, COALESCE(r.name,'') FROM agent_profiles a LEFT JOIN agent_roles r ON a.role_id = r.id ORDER BY a.name");
            defer stmt.finalize();
            var result = std.array_list.Managed(u8).init(alloc);
            try result.appendSlice("[");
            var first = true;
            while (true) {
                const row = stmt.step() catch break;
                if (row != .row) break;
                if (!first) try result.append(',');
                first = false;
                const agent_id = stmt.columnInt64(0);
                const name = stmt.columnText(1) orelse "";
                const capabilities = stmt.columnText(2) orelse "";
                const description = stmt.columnText(3);
                const role_id = stmt.columnInt64Safe(4);
                const role_name = stmt.columnText(5) orelse "";
                const entry = try std.fmt.allocPrint(alloc, \\{{"id":{d},"name":"{s}","capabilities":"{s}","description":"{s}","role_id":{s},"role_name":"{s}"}}
                , .{ agent_id, name, capabilities, description orelse "", if (role_id) |r| std.fmt.allocPrint(alloc, "{d}", .{r}) catch "null" else "null", role_name });
                try result.appendSlice(entry);
                alloc.free(entry);
            }
            try result.appendSlice("]");
            return result.toOwnedSlice() catch return error.OutOfMemory;
        },
        .POST => {
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AgentCreatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            validation.validateAgent(parsed.name, parsed.capabilities) catch |err| return errJson(alloc, @errorName(err));
            var stmt = try conn.prepare("INSERT INTO agent_profiles (name, capabilities, description, role_id) VALUES (?, ?, ?, ?) RETURNING id");
            defer stmt.finalize();
            stmt.bindText(1, parsed.name);
            stmt.bindText(2, parsed.capabilities);
            if (parsed.description) |d| stmt.bindText(3, d) else stmt.bindNull(3);
            if (parsed.role_id) |rid| stmt.bindInt64(4, rid) else stmt.bindNull(4);
            _ = try stmt.step();
            const new_id = stmt.columnInt64(0);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"name":"{s}"}}
            , .{ new_id, parsed.name });
        },
        .PUT => {
            if (id == null) return errJson(alloc, "missing_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(AgentUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            var stmt = try conn.prepare("UPDATE agent_profiles SET name = ?, capabilities = ?, description = ?, role_id = ? WHERE id = ?");
            defer stmt.finalize();
            stmt.bindText(1, parsed.name);
            stmt.bindText(2, parsed.capabilities);
            if (parsed.description) |d| stmt.bindText(3, d) else stmt.bindNull(3);
            if (parsed.role_id) |rid| stmt.bindInt64(4, rid) else stmt.bindNull(4);
            stmt.bindInt64(5, id.?);
            _ = try stmt.step();
            return alloc.dupe(u8, "{\"success\":true}");
        },
        .DELETE => {
            if (id == null) return errJson(alloc, "missing_id");
            entities_svc.deleteAgent(&service, id.?) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}

const AgentCreatePayload = struct { name: []const u8, capabilities: []const u8, description: ?[]const u8 = null, role_id: ?i64 = null };
const AgentUpdatePayload = struct { name: []const u8, capabilities: []const u8, description: ?[]const u8 = null, role_id: ?i64 = null };

fn freeAgent(alloc: std.mem.Allocator, a: entities.AgentProfile) void {
    alloc.free(a.name); alloc.free(a.capabilities);
    if (a.description) |d| alloc.free(d);
    if (a.metadata) |m| alloc.free(m);
    alloc.free(a.created_at); alloc.free(a.updated_at);
}

fn handleDashboardApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, path: []const u8, body: ?[]u8) ![]u8 {
    _ = body;
    if (method != .GET) return errJson(alloc, "method_not_allowed");
    var service = svc.init(conn);

    // Parse optional project_id from query string: /api/dashboard?project_id=1
    const project_id = parseQueryParam(alloc, path, "project_id") catch null;
    if (project_id) |pid_str| {
        defer alloc.free(pid_str);
        const pid = std.fmt.parseInt(i64, pid_str, 10) catch return errJson(alloc, "invalid_project_id");
        const counts = dashboard_svc.getProjectDashboardCounts(&service, alloc, pid) catch |err| return errJson(alloc, @errorName(err));
        return std.fmt.allocPrint(alloc, \\{{"projects":{d},"epics":{d},"stories":{d},"tasks":{d},"bugs":{d}}}
        , .{ counts.projects, counts.epics, counts.stories, counts.tasks, counts.bugs });
    }

    const counts = dashboard_svc.getDashboardCounts(&service, alloc) catch |err| return errJson(alloc, @errorName(err));
    return std.fmt.allocPrint(alloc, \\{{"projects":{d},"epics":{d},"stories":{d},"tasks":{d},"bugs":{d}}}
    , .{ counts.projects, counts.epics, counts.stories, counts.tasks, counts.bugs });
}

/// Parse a query parameter from a URL path like "/api/dashboard?project_id=1"
fn parseQueryParam(alloc: std.mem.Allocator, path: []const u8, key: []const u8) !?[]u8 {
    const qmark = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    const query = path[qmark + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |param| {
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const pkey = param[0..eq];
        const pval = param[eq + 1 ..];
        if (std.mem.eql(u8, pkey, key)) {
            return try alloc.dupe(u8, pval);
        }
    }
    return null;
}

// ─── Comments API ───

const CommentCreatePayload = struct {
    entity_type: []const u8,
    entity_id: i64,
    content: []const u8,
    author_name: []const u8,
};

fn handleCommentsApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    // Check method first to determine URL pattern:
    // - GET /api/comments/{entity_type}/{entity_id} - list comments for entity
    // - POST /api/comments - create comment (body has entity info)
    // - PUT /api/comments/{id} - update comment content
    // - DELETE /api/comments/{id} - delete comment

    // GET /api/comments/{entity_type}/{entity_id}
    if (method == .GET) {
        const entity_type = it.next() orelse return errJson(alloc, "missing_entity_type");
        const entity_id_str = it.next() orelse return errJson(alloc, "missing_entity_id");
        const entity_id = parseId(entity_id_str) catch return errJson(alloc, "invalid_entity_id");

        var comments = try queries_comments.listByEntity(conn, alloc, entity_type, entity_id);
        defer {
            for (comments.items) |c| entities.freeComment(alloc, c);
            comments.deinit(alloc);
        }

        var result = std.array_list.Managed(u8).init(alloc);
        try result.appendSlice("[");
        for (comments.items, 0..) |c, i| {
            if (i > 0) try result.append(',');
            const esc_content = try jsonEscape(alloc, c.content);
            defer alloc.free(esc_content);
            const esc_name = try jsonEscape(alloc, c.author_name);
            defer alloc.free(esc_name);
            const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"author_type\":\"{s}\",\"author_name\":\"{s}\",\"content\":\"{s}\",\"created_at\":\"{s}\"}}", .{ c.id, c.author_type, esc_name, esc_content, c.created_at });
            try result.appendSlice(entry);
            alloc.free(entry);
        }
        try result.appendSlice("]");
        return result.toOwnedSlice() catch return error.OutOfMemory;
    }

    // POST /api/comments — create a comment (human author)
    if (method == .POST) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(CommentCreatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        validation.validateComment(parsed.content) catch |err| return errJson(alloc, @errorName(err));

        // Resolve project_id from the entity
        const project_id = try getEntityProjectIdFromConn(conn, parsed.entity_type, parsed.entity_id);
        if (project_id == null) return errJson(alloc, "entity_not_found");

        const comment = queries_comments.insert(conn, alloc, project_id.?, parsed.entity_type, parsed.entity_id, "human", null, parsed.author_name, parsed.content) catch |err| return errJson(alloc, @errorName(err));
        defer entities.freeComment(alloc, comment);
        return std.fmt.allocPrint(alloc, \\{{"id":{d},"author_name":"{s}"}}
        , .{ comment.id, parsed.author_name });
    }

    // For PUT/DELETE, consume comment_id from path
    const comment_id_str = it.next();
    const comment_id = if (comment_id_str) |s| parseId(s) catch null else null;

    // PUT /api/comments/{id} — update comment content (human can edit any)
    if (method == .PUT and comment_id != null) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(struct { content: []const u8 }, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
        validation.validateComment(parsed.content) catch |err| return errJson(alloc, @errorName(err));
        queries_comments.updateContent(conn, comment_id.?, parsed.content) catch |err| return errJson(alloc, @errorName(err));
        return alloc.dupe(u8, "{\"success\":true}");
    }

    // DELETE /api/comments/{id} — delete comment (human can delete any)
    if (method == .DELETE and comment_id != null) {
        queries_comments.delete(conn, comment_id.?) catch |err| return errJson(alloc, @errorName(err));
        return alloc.dupe(u8, "{\"success\":true}");
    }

    return errJson(alloc, "method_not_allowed");
}

/// Resolve project_id from an entity type and id. Used by the comments API
/// to scope comments to the correct project.
fn getEntityProjectIdFromConn(conn: *db.Connection, entity_type: []const u8, entity_id: i64) !?i64 {
    const table = if (std.mem.eql(u8, entity_type, "epic")) "epics"
        else if (std.mem.eql(u8, entity_type, "story")) "stories"
        else if (std.mem.eql(u8, entity_type, "task")) "tasks"
        else if (std.mem.eql(u8, entity_type, "subtask")) "subtasks"
        else if (std.mem.eql(u8, entity_type, "bug")) "bugs"
        else if (std.mem.eql(u8, entity_type, "wiki")) "wiki_pages"
        else return null;
    var sql_buf = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer sql_buf.deinit();
    try sql_buf.appendSlice("SELECT project_id FROM ");
    try sql_buf.appendSlice(table);
    try sql_buf.appendSlice(" WHERE id = ?");

    var stmt = try conn.prepare(sql_buf.items);
    defer stmt.finalize();
    stmt.bindInt64(1, entity_id);
    if (try stmt.step() == .row) return stmt.columnInt64(0);
    return null;
}

// ─── Memory API ───

const MemoryCreatePayload = struct {
    project_id: i64,
    role_name: ?[]const u8 = null,
    scope: []const u8,
    entity_id: ?i64 = null,
    category: []const u8,
    title: []const u8,
    content: []const u8,
    summary: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    importance: ?[]const u8 = null,
};

const MemoryUpdatePayload = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    importance: ?[]const u8 = null,
};

fn handleMemoriesApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const id_str = it.next();
    const id = if (id_str) |s| parseId(s) catch null else null;

    // GET /api/memories — list all memories for a project (query param: project_id)
    if (method == .GET and id == null) {
        var result = std.array_list.Managed(u8).init(alloc);
        try result.appendSlice("[");
        var first = true;
        var stmt = try conn.prepare("SELECT id, project_id, role_name, scope, entity_id, category, title, importance, created_at FROM agent_memory ORDER BY importance DESC, created_at DESC");
        defer stmt.finalize();
        while (true) {
            const row = stmt.step() catch break;
            if (row != .row) break;
            if (!first) try result.append(',');
            first = false;
            const mid = stmt.columnInt64(0);
            const project_id = stmt.columnInt64(1);
            const role_name = stmt.columnText(2);
            const scope = stmt.columnText(3) orelse "";
            const entity_id = stmt.columnInt64Safe(4);
            const category = stmt.columnText(5) orelse "";
            const title = stmt.columnText(6) orelse "";
            const importance = stmt.columnInt64(7);
            const created_at = stmt.columnText(8) orelse "";
            const esc_title = try jsonEscape(alloc, title);
            defer alloc.free(esc_title);
            const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"project_id\":{d},\"role_name\":{s},\"scope\":\"{s}\",\"entity_id\":{s},\"category\":\"{s}\",\"title\":\"{s}\",\"importance\":{d},\"created_at\":\"{s}\"}}", .{
                mid,
                project_id,
                if (role_name) |rn| try std.fmt.allocPrint(alloc, "\"{s}\"", .{rn}) else "null",
                scope,
                if (entity_id) |eid| try std.fmt.allocPrint(alloc, "{d}", .{eid}) else "null",
                category,
                esc_title,
                importance,
                created_at,
            });
            try result.appendSlice(entry);
            alloc.free(entry);
        }
        try result.appendSlice("]");
        return result.toOwnedSlice() catch return error.OutOfMemory;
    }

    // GET /api/memories/{id} — get single memory
    if (method == .GET and id != null) {
        const mem = queries_memory.getById(conn, alloc, id.?) catch |err| return errJson(alloc, @errorName(err));
        if (mem) |m| {
            defer entities.freeMemoryEntry(alloc, m);
            const esc_title = try jsonEscape(alloc, m.title);
            defer alloc.free(esc_title);
            const esc_content = try jsonEscape(alloc, m.content);
            defer alloc.free(esc_content);
            const esc_summary = if (m.summary) |s| try jsonEscape(alloc, s) else null;
            defer if (esc_summary) |es| alloc.free(es);
            const esc_tags = if (m.tags) |t| try jsonEscape(alloc, t) else null;
            defer if (esc_tags) |et| alloc.free(et);
            return std.fmt.allocPrint(alloc, \\{{"id":{d},"project_id":{d},"role_name":{s},"scope":"{s}","entity_id":{s},"category":"{s}","title":"{s}","content":"{s}","summary":{s},"tags":{s},"importance":{d},"access_count":{d},"created_at":"{s}","updated_at":"{s}"}}
            , .{
                m.id,
                m.project_id,
                if (m.role_name) |rn| try std.fmt.allocPrint(alloc, "\"{s}\"", .{rn}) else "null",
                m.scope,
                if (m.entity_id) |eid| try std.fmt.allocPrint(alloc, "{d}", .{eid}) else "null",
                m.category,
                esc_title,
                esc_content,
                if (esc_summary) |es| try std.fmt.allocPrint(alloc, "\"{s}\"", .{es}) else "null",
                if (esc_tags) |et| try std.fmt.allocPrint(alloc, "\"{s}\"", .{et}) else "null",
                m.importance,
                m.access_count,
                m.created_at,
                m.updated_at,
            });
        }
        return errJson(alloc, "not_found");
    }

    // POST /api/memories — create memory
    if (method == .POST) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(MemoryCreatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");

        // Parse scope enum
        const scope = lifecycle.memoryScopeFromDb(parsed.scope) orelse return errJson(alloc, "invalid_scope");

        // Parse category enum
        const category = lifecycle.memoryCategoryFromDb(parsed.category) orelse return errJson(alloc, "invalid_category");

        // Parse importance enum (default: high)
        const importance: lifecycle.MemoryImportance = if (parsed.importance) |imp| switch (imp[0]) {
            '1' => .low,
            '2' => .medium,
            '3' => .high,
            '4' => .critical,
            else => .high,
        } else .high;

        const mem = queries_memory.insert(conn, alloc, parsed.project_id, parsed.role_name, scope, parsed.entity_id, category, parsed.title, parsed.content, parsed.summary, parsed.tags, importance) catch |err| {
            if (err == error.ConstraintViolation) return errJson(alloc, "duplicate_memory");
            return errJson(alloc, @errorName(err));
        };
        defer entities.freeMemoryEntry(alloc, mem);
        return std.fmt.allocPrint(alloc, \\{{"id":{d},"title":"{s}"}}
        , .{ mem.id, mem.title });
    }

    // PUT /api/memories/{id} — update memory
    if (method == .PUT and id != null) {
        const body_str = body orelse return errJson(alloc, "missing_body");
        const parsed = std.json.parseFromSliceLeaky(MemoryUpdatePayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");

        var importance_opt: ?lifecycle.MemoryImportance = null;
        if (parsed.importance) |imp| {
            importance_opt = switch (imp[0]) {
                '1' => .low,
                '2' => .medium,
                '3' => .high,
                '4' => .critical,
                else => return errJson(alloc, "invalid_importance"),
            };
        }

        queries_memory.update(conn, alloc, id.?, parsed.title, parsed.content, parsed.summary, parsed.tags, importance_opt) catch |err| {
            if (err == error.NoFieldsToUpdate) return errJson(alloc, "no_fields_to_update");
            return errJson(alloc, @errorName(err));
        };
        return alloc.dupe(u8, "{\"success\":true}");
    }

    // DELETE /api/memories/{id} — delete memory
    if (method == .DELETE and id != null) {
        queries_memory.delete(conn, id.?) catch |err| return errJson(alloc, @errorName(err));
        return alloc.dupe(u8, "{\"success\":true}");
    }

    return errJson(alloc, "method_not_allowed");
}

// ─── Config API ───

const ConfigSetPayload = struct { key: []const u8, value: []const u8 };

fn handleConfigApi(conn: *db.Connection, alloc: std.mem.Allocator, method: std.http.Method, it: *std.mem.SplitIterator(u8, .scalar), body: ?[]u8) ![]u8 {
    const project_id_str = it.next();
    var service = svc.init(conn);

    switch (method) {
        .GET => {
            if (project_id_str == null) return errJson(alloc, "missing_project_id");
            const project_id = parseId(project_id_str.?) catch return errJson(alloc, "invalid_id");
            var configs = project_svc.getConfig(&service, alloc, project_id) catch |err| return errJson(alloc, @errorName(err));
            defer {
                for (configs.items) |c| {
                    alloc.free(c.key);
                    alloc.free(c.value);
                }
                configs.deinit(alloc);
            }
            var result = std.array_list.Managed(u8).init(alloc);
            try result.appendSlice("[");
            for (configs.items, 0..) |c, i| {
                if (i > 0) try result.append(',');
                const entry = try std.fmt.allocPrint(alloc, "{{\"key\":\"{s}\",\"value\":\"{s}\"}}", .{ c.key, c.value });
                try result.appendSlice(entry);
                alloc.free(entry);
            }
            try result.appendSlice("]");
            return result.toOwnedSlice() catch return error.OutOfMemory;
        },
        .POST => {
            if (project_id_str == null) return errJson(alloc, "missing_project_id");
            const project_id = parseId(project_id_str.?) catch return errJson(alloc, "invalid_id");
            const body_str = body orelse return errJson(alloc, "missing_body");
            const parsed = std.json.parseFromSliceLeaky(ConfigSetPayload, alloc, body_str, .{}) catch return errJson(alloc, "invalid_json");
            project_svc.setConfig(&service, project_id, parsed.key, parsed.value) catch |err| return errJson(alloc, @errorName(err));
            return alloc.dupe(u8, "{\"success\":true}");
        },
        else => return errJson(alloc, "method_not_allowed"),
    }
}
