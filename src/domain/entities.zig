const std = @import("std");
const lifecycle = @import("lifecycle.zig");

/// Priority levels for work items
pub const Priority = enum(u4) {
    critical = 1,
    high = 2,
    medium = 3,
    low = 4,
};

/// A project tracked by Prozig
pub const Project = struct {
    id: i64,
    name: []const u8,
    root_path: []const u8,
    description: ?[]const u8 = null,
    metadata: ?[]const u8 = null, // JSON
    created_at: []const u8,
    updated_at: []const u8,
};

/// An Epic — large body of work containing User Stories
pub const Epic = struct {
    id: i64,
    project_id: i64,
    title: []const u8,
    description: ?[]const u8 = null,
    status: lifecycle.EpicStatus,
    priority: Priority = .medium,
    assignee_agent_id: ?i64 = null,
    parent_epic_id: ?i64 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A User Story — belongs to an Epic, contains Tasks
pub const Story = struct {
    id: i64,
    project_id: i64,
    epic_id: i64,
    title: []const u8,
    description: ?[]const u8 = null,
    acceptance_criteria: ?[]const u8 = null, // JSON array
    status: lifecycle.StoryStatus,
    priority: Priority = .medium,
    assignee_agent_id: ?i64 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A Task — belongs to a Story, contains SubTasks
pub const Task = struct {
    id: i64,
    project_id: i64,
    story_id: i64,
    title: []const u8,
    description: ?[]const u8 = null,
    status: lifecycle.TaskStatus,
    priority: Priority = .medium,
    assignee_agent_id: ?i64 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A Bug — can belong to a Project, Epic, Story, or Task
pub const Bug = struct {
    id: i64,
    project_id: i64,
    title: []const u8,
    description: ?[]const u8 = null,
    severity: []const u8, // critical|high|medium|low
    status: lifecycle.BugStatus,
    assignee_agent_id: ?i64 = null,
    epic_id: ?i64 = null,
    story_id: ?i64 = null,
    task_id: ?i64 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A SubTask — smallest work unit, belongs to a Task
pub const SubTask = struct {
    id: i64,
    project_id: i64,
    task_id: i64,
    title: []const u8,
    description: ?[]const u8 = null,
    status: lifecycle.SubTaskStatus,
    priority: Priority = .medium,
    assignee_agent_id: ?i64 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

/// An agent profile with capabilities
pub const AgentProfile = struct {
    id: i64,
    name: []const u8,
    capabilities: []const u8, // JSON array
    description: ?[]const u8 = null,
    metadata: ?[]const u8 = null, // JSON
    created_at: []const u8,
    updated_at: []const u8,
};

/// A wiki page
pub const WikiPage = struct {
    id: i64,
    project_id: i64,
    category: []const u8,
    parent_id: ?i64 = null,
    title: []const u8,
    content: []const u8, // Markdown
    version: u32,
    is_current: bool,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A dependency (blocked_by relationship)
pub const Dependency = struct {
    id: i64,
    project_id: i64,
    blocker_type: []const u8, // epic|story|task|subtask
    blocker_id: i64,
    blocked_type: []const u8,
    blocked_id: i64,
};

/// A comment on any trackable entity (epic, story, task, subtask, bug, wiki).
/// Comments are written by either agents (with author_id set) or humans
/// (with author_id NULL and author_type = "human"). author_name is denormalized
/// at write time so reads don't need a JOIN.
pub const Comment = struct {
    id: i64,
    project_id: i64,
    entity_type: []const u8, // 'epic'|'story'|'task'|'subtask'|'bug'|'wiki'
    entity_id: i64,
    author_type: []const u8, // 'agent'|'human'
    author_id: ?i64,
    author_name: []const u8,
    content: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Free all heap-allocated fields in a Project
pub fn freeProject(allocator: std.mem.Allocator, p: Project) void {
    allocator.free(p.name);
    allocator.free(p.root_path);
    if (p.description) |d| allocator.free(d);
    if (p.metadata) |m| allocator.free(m);
    allocator.free(p.created_at);
    allocator.free(p.updated_at);
}

/// Free all heap-allocated fields in an Epic
pub fn freeEpic(allocator: std.mem.Allocator, e: Epic) void {
    allocator.free(e.title);
    if (e.description) |d| allocator.free(d);
    allocator.free(e.created_at);
    allocator.free(e.updated_at);
}

/// Free all heap-allocated fields in a Story
pub fn freeStory(allocator: std.mem.Allocator, s: Story) void {
    allocator.free(s.title);
    if (s.description) |d| allocator.free(d);
    if (s.acceptance_criteria) |a| allocator.free(a);
    allocator.free(s.created_at);
    allocator.free(s.updated_at);
}

/// Free all heap-allocated fields in a Task
pub fn freeTask(allocator: std.mem.Allocator, t: Task) void {
    allocator.free(t.title);
    if (t.description) |d| allocator.free(d);
    allocator.free(t.created_at);
    allocator.free(t.updated_at);
}

/// Free all heap-allocated fields in a SubTask
pub fn freeSubTask(allocator: std.mem.Allocator, st: SubTask) void {
    allocator.free(st.title);
    if (st.description) |d| allocator.free(d);
    allocator.free(st.created_at);
    allocator.free(st.updated_at);
}

/// Free all heap-allocated fields in a Bug
pub fn freeBug(allocator: std.mem.Allocator, b: Bug) void {
    allocator.free(b.title);
    if (b.description) |d| allocator.free(d);
    allocator.free(b.severity);
    allocator.free(b.created_at);
    allocator.free(b.updated_at);
}

/// Free all heap-allocated fields in an AgentProfile
pub fn freeAgentProfile(allocator: std.mem.Allocator, a: AgentProfile) void {
    allocator.free(a.name);
    allocator.free(a.capabilities);
    if (a.description) |d| allocator.free(d);
    if (a.metadata) |m| allocator.free(m);
    allocator.free(a.created_at);
    allocator.free(a.updated_at);
}

/// Free all heap-allocated fields in a WikiPage
pub fn freeWikiPage(allocator: std.mem.Allocator, w: WikiPage) void {
    allocator.free(w.category);
    allocator.free(w.title);
    allocator.free(w.content);
    allocator.free(w.created_at);
    allocator.free(w.updated_at);
}

/// Free all heap-allocated fields in a Comment
pub fn freeComment(allocator: std.mem.Allocator, c: Comment) void {
    allocator.free(c.entity_type);
    allocator.free(c.author_type);
    if (c.author_name.len > 0) allocator.free(c.author_name);
    allocator.free(c.content);
    allocator.free(c.created_at);
    allocator.free(c.updated_at);
}

/// A memory entry for agent context retention across sessions.
/// Stored in agent_memory table with FTS5 indexing.
pub const MemoryEntry = struct {
    id: i64,
    project_id: i64,
    role_name: ?[]const u8, // NULL for shared, 'architect'/'developer'/'qa'/'product_manager' for role-siloed
    scope: []const u8, // 'project'/'epic'/'story'/'task'/'subtask'/'bug'/'wiki'
    entity_id: ?i64, // NULL for project-level, entity ID for scoped memory
    category: []const u8, // 'decision'/'blocker'/'pattern'/'outcome'/'note'/'learning'
    title: []const u8,
    content: []const u8,
    summary: ?[]const u8 = null,
    tags: ?[]const u8 = null, // JSON array of keywords
    importance: u3, // 1=low, 2=medium, 3=high, 4=critical
    access_count: i64,
    last_accessed_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Running project summary (narrative + structured bullets).
/// Injected into every agent's context for continuity.
pub const ProjectSummary = struct {
    id: i64,
    project_id: i64,
    narrative: ?[]const u8 = null,
    bullets: ?[]const u8 = null, // JSON array of structured bullet points
    version: u32,
    updated_at: []const u8,
};

/// Free all heap-allocated fields in a MemoryEntry
pub fn freeMemoryEntry(allocator: std.mem.Allocator, m: MemoryEntry) void {
    if (m.role_name) |r| allocator.free(r);
    allocator.free(m.scope);
    allocator.free(m.category);
    allocator.free(m.title);
    allocator.free(m.content);
    if (m.summary) |s| allocator.free(s);
    if (m.tags) |t| allocator.free(t);
    if (m.last_accessed_at) |l| allocator.free(l);
    allocator.free(m.created_at);
    allocator.free(m.updated_at);
}

/// Free all heap-allocated fields in a ProjectSummary
pub fn freeProjectSummary(allocator: std.mem.Allocator, s: ProjectSummary) void {
    if (s.narrative) |n| allocator.free(n);
    if (s.bullets) |b| allocator.free(b);
    allocator.free(s.updated_at);
}
