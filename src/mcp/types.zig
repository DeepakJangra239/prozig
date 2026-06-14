const std = @import("std");
const db = @import("../db/connection.zig");
const json = @import("json.zig");
const svc = @import("../service/root.zig");
const tools_project = @import("tools/project.zig");
const tools_epic = @import("tools/epic.zig");
const tools_story = @import("tools/story.zig");
const tools_task = @import("tools/task.zig");
const tools_subtask = @import("tools/subtask.zig");
const tools_lifecycle = @import("tools/lifecycle.zig");
const tools_wiki = @import("tools/wiki.zig");
const tools_assignment = @import("tools/assignment.zig");
const tools_bug = @import("tools/bug.zig");
const tools_query = @import("tools/query.zig");
const tools_dashboard = @import("tools/dashboard.zig");
const tools_config = @import("tools/config.zig");
const tools_comments = @import("tools/comments.zig");
const tools_memory = @import("tools/memory.zig");

pub const Server = struct {
    conn: *db.Connection,
    service: *svc.Service,
    allocator: std.mem.Allocator,
    initialized: bool = false,

    pub fn handleMessage(s: *Server, raw: []const u8) !?[]u8 {
        const alloc = s.allocator;

        // DEBUG: log incoming raw length
        const dbg_raw = if (raw.len > 80) raw[0..80] else raw;
        std.log.debug(">> raw(len={d}): {s}", .{ raw.len, dbg_raw });

        var value = json.JsonValue.parse(alloc, raw) catch |err| {
            std.log.err("JSON parse error: {s}", .{@errorName(err)});
            return null;
        };
        defer value.deinit(alloc);

        const method_str = value.getString("method") orelse {
            std.log.err("No method in message", .{});
            return null;
        };
        // Extract id as raw text from the source JSON to preserve numeric IDs.
        const id_str = extractId(raw);
        const params: json.JsonValue = if (std.meta.activeTag(value) == .object_val) value.object_val.get("params") orelse json.JsonValue{ .null_value = {} } else json.JsonValue{ .null_value = {} };

        if (std.mem.eql(u8, method_str, "initialize")) return s.handleInitialize(id_str, params) catch return null;
        if (std.mem.eql(u8, method_str, "notifications/initialized")) return null;
        if (std.mem.eql(u8, method_str, "ping")) return makeResponse(alloc, id_str, "") catch return null;
        if (std.mem.eql(u8, method_str, "tools/list")) return s.handleToolsList(id_str) catch return null;
        if (std.mem.eql(u8, method_str, "tools/call")) return s.handleToolsCall(id_str, params) catch return null;
        return null;
    }

    fn handleInitialize(s: *Server, id: ?[]const u8, params: json.JsonValue) !?[]u8 {
        _ = params;
        s.initialized = true;
        const result =
            \\"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"prozig","version":"0.1.0"}
        ;
        return makeResponse(s.allocator, id, result);
    }

    fn handleToolsList(s: *Server, id: ?[]const u8) !?[]u8 {
        // Strip newlines from allToolsDefinition — MCP uses \n as message
        // delimiter, so embedded newlines in JSON responses break framing.
        var clean = try std.array_list.Managed(u8).initCapacity(s.allocator, allToolsDefinition.len);
        defer clean.deinit();
        for (allToolsDefinition) |c| {
            if (c != '\n') try clean.append(c);
        }
        const result = try std.fmt.allocPrint(s.allocator,
            \\"tools":[{s}]
        , .{clean.items});
        defer s.allocator.free(result);
        return makeResponse(s.allocator, id, result);
    }

    fn handleToolsCall(s: *Server, id: ?[]const u8, params: json.JsonValue) !?[]u8 {
        const tool_name = params.getString("name") orelse {
            std.log.err("Missing tool name", .{});
            return makeErrorResponse(s.allocator, id, -32602, "Missing tool name");
        };
        std.log.debug(">> tools/call: {s}", .{tool_name});
        const args = params.getArguments() orelse json.JsonValue{ .null_value = {} };
        const result = routeToolCall(s, tool_name, args) catch |err| {
            std.log.err("routeToolCall error: {s}", .{@errorName(err)});
            return makeErrorResponse(s.allocator, id, -32603, std.fmt.allocPrint(s.allocator, "Internal error: {s}", .{@errorName(err)}) catch "Internal error");
        };
        return makeResponse(s.allocator, id, result);
    }
};

/// Extract the raw id value text from a JSON-RPC request string.
/// Returns the raw text of the id value (e.g. `1`, `"abc"`, `null`).
/// This preserves numeric/non-string IDs that `getString("id")` would miss.
fn extractId(raw: []const u8) ?[]const u8 {
    const key = "\"id\"";
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return null;
    const after_key = raw[key_pos + key.len..];
    const colon_pos = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var start = colon_pos + 1;
    while (start < after_key.len and (after_key[start] == ' ' or after_key[start] == '\t')) {
        start += 1;
    }
    if (start >= after_key.len) return null;
    const first = after_key[start];
    // String value: find matching closing quote (handle escaped quotes)
    if (first == '"') {
        var i = start + 1;
        while (i < after_key.len) {
            if (after_key[i] == '\\') { if (i + 1 < after_key.len) i += 1; i += 1; continue; }
            if (after_key[i] == '"') return after_key[start .. i + 1];
            i += 1;
        }
        return null;
    }
    // null literal
    if (first == 'n') {
        if (start + 4 <= after_key.len and std.mem.eql(u8, after_key[start..start+4], "null")) {
            return after_key[start..start+4];
        }
        return null;
    }
    // Number (int or float) — stop at comma, close-brace, whitespace
    if (first == '-' or (first >= '0' and first <= '9')) {
        var i = start;
        while (i < after_key.len) {
            const c = after_key[i];
            if (c == ',' or c == '}' or c == ' ' or c == '\n' or c == '\t' or c == '\r') break;
            i += 1;
        }
        return after_key[start..i];
    }
    return null;
}

fn makeResponse(alloc: std.mem.Allocator, id: ?[]const u8, result: []const u8) !?[]u8 {
    const id_str = id orelse "null";
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{{s}}}}}", .{ id_str, result });
    return resp;
}

fn makeErrorResponse(alloc: std.mem.Allocator, id: ?[]const u8, code: i32, message: []const u8) !?[]u8 {
    const id_str = id orelse "null";
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id_str, code, message });
    return resp;
}

fn routeToolCall(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    if (std.mem.startsWith(u8, tool_name, "project_")) return try tools_project.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "epic_")) return try tools_epic.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "story_")) return try tools_story.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "task_")) return try tools_task.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "subtask_")) return try tools_subtask.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "bug_")) return try tools_bug.handle(s, tool_name, args);
    if (std.mem.eql(u8, tool_name, "transition_status")) return try tools_lifecycle.handle(s, args);
    if (std.mem.startsWith(u8, tool_name, "wiki_")) return try tools_wiki.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "assign_") or std.mem.eql(u8, tool_name, "get_my_work") or std.mem.eql(u8, tool_name, "suggest_assignment")) return try tools_assignment.handle(s, tool_name, args);
    if (std.mem.eql(u8, tool_name, "search") or std.mem.eql(u8, tool_name, "filter")) return try tools_query.handle(s, tool_name, args);
    if (std.mem.eql(u8, tool_name, "get_dashboard")) return try tools_dashboard.handle(s, args);
    if (std.mem.startsWith(u8, tool_name, "config_")) return try tools_config.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "comment_")) return try tools_comments.handle(s, tool_name, args);
    if (std.mem.startsWith(u8, tool_name, "memory_") or std.mem.eql(u8, tool_name, "update_project_summary")) return try tools_memory.handle(s, tool_name, args);
    return std.fmt.allocPrint(s.allocator, "Unknown tool: {s}", .{tool_name});
}

const allToolsDefinition: []const u8 =
    \\{"name":"project_init","description":"Initialize a new project","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"root_path":{"type":"string"},"description":{"type":"string"}},"required":["name","root_path"]}},
    \\{"name":"project_list","description":"List all projects","inputSchema":{"type":"object"}},
    \\{"name":"project_get","description":"Get project details","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"epic_create","description":"Create a new epic. All of project_id, title, and description are required. Title must be at least 3 characters and description at least 20 characters — provide a meaningful description so the epic is well-documented.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"}},"required":["project_id","title","description"]}},
    \\{"name":"epic_get","description":"Get epic details","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"epic_list","description":"List epics for a project","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"epic_update","description":"Update an epic (PATCH semantics — only the fields you provide are written; existing fields are preserved). At least one of title, description must be provided. If provided, title must be at least 3 chars, description at least 20 chars.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"epic_delete","description":"Delete an epic","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"story_create","description":"Create a user story. All of project_id, epic_id, title, description, and acceptance_criteria are required. Title must be at least 3 chars, description and acceptance_criteria at least 20 chars each — write a clear description and well-formed acceptance criteria so the story is actionable.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"epic_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"},"acceptance_criteria":{"type":"string"}},"required":["project_id","epic_id","title","description","acceptance_criteria"]}},
    \\{"name":"story_get","description":"Get story details","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"story_list","description":"List stories for an epic","inputSchema":{"type":"object","properties":{"epic_id":{"type":"string"}},"required":["epic_id"]}},
    \\{"name":"story_update","description":"Update a story (PATCH semantics — only the fields you provide are written; existing fields are preserved). At least one of title, description, acceptance_criteria must be provided. Same min-length rules as create apply to any field you do provide.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"},"acceptance_criteria":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"story_delete","description":"Delete a story","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"task_create","description":"Create a task. All of project_id, story_id, title, and description are required. Title must be at least 3 chars and description at least 20 chars — describe the work to be done in the description.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"story_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"}},"required":["project_id","story_id","title","description"]}},
    \\{"name":"task_get","description":"Get task details","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"task_list","description":"List tasks for a story","inputSchema":{"type":"object","properties":{"story_id":{"type":"string"}},"required":["story_id"]}},
    \\{"name":"task_update","description":"Update a task (PATCH semantics — only the fields you provide are written; existing fields are preserved). At least one of title, description must be provided. Same min-length rules as create apply to any field you do provide.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"task_delete","description":"Delete a task","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"subtask_create","description":"Create a subtask. All of project_id, task_id, title, and description are required. Title must be at least 3 chars and description at least 20 chars — describe the work to be done in the description.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"task_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"}},"required":["project_id","task_id","title","description"]}},
    \\{"name":"subtask_get","description":"Get subtask details","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"subtask_list","description":"List subtasks for a task","inputSchema":{"type":"object","properties":{"task_id":{"type":"string"}},"required":["task_id"]}},
    \\{"name":"subtask_update","description":"Update a subtask (PATCH semantics — only the fields you provide are written; existing fields are preserved). At least one of title, description must be provided. Same min-length rules as create apply to any field you do provide.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"subtask_delete","description":"Delete a subtask","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"transition_status","description":"Transition entity to new status. You MUST pass your own agent_id (the caller's identity) — role-based permission is enforced.","inputSchema":{"type":"object","properties":{"entity_type":{"type":"string","enum":["epic","story","task","subtask","bug"]},"entity_id":{"type":"string"},"new_status":{"type":"string"},"agent_id":{"type":"string"}},"required":["entity_type","entity_id","new_status","agent_id"]}},
    \\{"name":"wiki_create","description":"Create a wiki page","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"category":{"type":"string"},"title":{"type":"string"},"content":{"type":"string"}},"required":["project_id","category","title","content"]}},
    \\{"name":"wiki_get","description":"Get a wiki page","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"wiki_update","description":"Update a wiki page","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"content":{"type":"string"}},"required":["entity_id","content"]}},
    \\{"name":"wiki_list","description":"List wiki pages","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"wiki_search","description":"Search wiki pages","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"query":{"type":"string"}},"required":["project_id","query"]}},
    \\{"name":"wiki_versions","description":"Get wiki page versions","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"assign_work","description":"Assign work to an agent","inputSchema":{"type":"object","properties":{"entity_type":{"type":"string"},"entity_id":{"type":"string"},"agent_id":{"type":"string"}},"required":["entity_type","entity_id","agent_id"]}},
    \\{"name":"get_my_work","description":"Get work assigned to an agent","inputSchema":{"type":"object","properties":{"agent_id":{"type":"string"}},"required":["agent_id"]}},
    \\{"name":"suggest_assignment","description":"Suggest agents for a task","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"entity_type":{"type":"string"}},"required":["entity_id","entity_type"]}},
    \\{"name":"search","description":"Search across all entities","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"query":{"type":"string"}},"required":["project_id","query"]}},
    \\{"name":"filter","description":"Filter entities by criteria","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"entity_type":{"type":"string"},"status":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"get_dashboard","description":"Get project dashboard","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"config_get","description":"Get project configuration","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"config_set","description":"Set project configuration","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"key":{"type":"string"},"value":{"type":"string"}},"required":["project_id","key","value"]}},
    \\{"name":"bug_create","description":"Create a bug. All of project_id, title, description, and severity are required. Title must be at least 3 chars and description at least 20 chars — describe the bug clearly with reproduction steps.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"},"severity":{"type":"string","enum":["critical","high","medium","low"]},"epic_id":{"type":"string"},"story_id":{"type":"string"},"task_id":{"type":"string"}},"required":["project_id","title","description","severity"]}},
    \\{"name":"bug_get","description":"Get bug details","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"bug_list","description":"List bugs for a project","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"bug_delete","description":"Delete a bug","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"}},"required":["entity_id"]}},
    \\{"name":"comment_create","description":"Add a comment to any entity (epic, story, task, subtask, bug, wiki). Content supports markdown formatting. Use @AgentName to mention other agents. Content must be at least 5 characters.","inputSchema":{"type":"object","properties":{"entity_type":{"type":"string","enum":["epic","story","task","subtask","bug","wiki"]},"entity_id":{"type":"string"},"content":{"type":"string"},"agent_id":{"type":"string"}},"required":["entity_type","entity_id","content","agent_id"]}},
    \\{"name":"comment_list","description":"List all comments on a specific entity, ordered chronologically. Returns author type (agent/human), author name, timestamp, and content.","inputSchema":{"type":"object","properties":{"entity_type":{"type":"string","enum":["epic","story","task","subtask","bug","wiki"]},"entity_id":{"type":"string"}},"required":["entity_type","entity_id"]}},
    \\{"name":"comment_update","description":"Update the content of a comment. Only the author can update their own comment. Content supports markdown and must be at least 5 characters.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"content":{"type":"string"},"agent_id":{"type":"string"}},"required":["entity_id","content","agent_id"]}},
    \\{"name":"comment_delete","description":"Delete a comment. Only the author can delete their own comment.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"agent_id":{"type":"string"}},"required":["entity_id","agent_id"]}},
    \\{"name":"memory_save","description":"Save a memory entry. Use this when concluding work on a ticket to preserve decisions, patterns, blockers, or outcomes. Memory tiers: shared (project/epic/story/task/bug — visible to all roles), role-siloed (subtask patterns — visible only to your role). Include both narrative content and structured bullet points for best recall.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"role_name":{"type":"string","enum":["architect","developer","qa","product-manager","shared"]},"scope":{"type":"string","enum":["project","epic","story","task","subtask","bug","wiki"]},"entity_id":{"type":"string"},"category":{"type":"string","enum":["decision","blocker","pattern","outcome","note","learning"]},"title":{"type":"string"},"content":{"type":"string"},"summary":{"type":"string"},"tags":{"type":"string"},"importance":{"type":"string","enum":["1","2","3","4"]}},"required":["project_id","scope","category","title","content"]}},
    \\{"name":"memory_get","description":"Retrieve memories relevant to a ticket or project. Returns shared memories (visible to all roles) plus your role-specific memories. Results are re-ranked by recency and access frequency.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"role_name":{"type":"string"},"scope":{"type":"string"},"entity_id":{"type":"string"},"category":{"type":"string"},"query":{"type":"string"},"limit":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"memory_list","description":"List all memory entries for your role in a project. Use this to review and consolidate memories when approaching the hard cap.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"role_name":{"type":"string"},"scope":{"type":"string"},"category":{"type":"string"}},"required":["project_id"]}},
    \\{"name":"memory_delete","description":"Delete a memory entry. Use this during consolidation to remove outdated or redundant entries.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"project_id":{"type":"string"}},"required":["entity_id","project_id"]}},
    \\{"name":"memory_update","description":"Update a memory entry. Use this to merge related entries or update outdated information.","inputSchema":{"type":"object","properties":{"entity_id":{"type":"string"},"project_id":{"type":"string"},"title":{"type":"string"},"content":{"type":"string"},"summary":{"type":"string"},"tags":{"type":"string"},"importance":{"type":"string"}},"required":["entity_id","project_id"]}},
    \\{"name":"update_project_summary","description":"Update the running project summary. Use this when significant changes occur (major decisions, tech stack changes, key learnings). The summary is injected into every agent's context — keep it concise and actionable.","inputSchema":{"type":"object","properties":{"project_id":{"type":"string"},"narrative":{"type":"string"},"bullets":{"type":"string"}},"required":["project_id"]}}
;
