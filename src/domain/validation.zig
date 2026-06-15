const std = @import("std");
const errors = @import("../error.zig");
const lifecycle = @import("lifecycle.zig");

/// Minimum length for entity titles — reject single-character placeholders.
pub const MIN_TITLE_LEN: usize = 3;
/// Minimum length for descriptions — forces a real sentence, not a one-word field.
pub const MIN_DESCRIPTION_LEN: usize = 20;
/// Minimum length for acceptance criteria — must describe behavior.
pub const MIN_ACCEPTANCE_CRITERIA_LEN: usize = 20;
/// Minimum length for comment content — short comments add no signal.
pub const MIN_COMMENT_LEN: usize = 5;

/// Validate project fields
pub fn validateProject(name: []const u8, root_path: []const u8) !void {
    if (name.len == 0) return error.MissingField;
    if (root_path.len == 0) return error.MissingField;
}

/// Validate epic fields
pub fn validateEpic(project_id: i64, title: []const u8, description: []const u8) !void {
    if (project_id <= 0) return error.InvalidField;
    if (title.len < MIN_TITLE_LEN) return error.MissingField;
    if (description.len < MIN_DESCRIPTION_LEN) return error.MissingField;
}

/// Validate story fields
pub fn validateStory(project_id: i64, epic_id: i64, title: []const u8, description: []const u8, acceptance_criteria: []const u8) !void {
    if (project_id <= 0) return error.InvalidField;
    if (epic_id <= 0) return error.InvalidField;
    if (title.len < MIN_TITLE_LEN) return error.MissingField;
    if (description.len < MIN_DESCRIPTION_LEN) return error.MissingField;
    if (acceptance_criteria.len < MIN_ACCEPTANCE_CRITERIA_LEN) return error.MissingField;
}

/// Validate task fields
pub fn validateTask(project_id: i64, story_id: i64, title: []const u8, description: []const u8) !void {
    if (project_id <= 0) return error.InvalidField;
    if (story_id <= 0) return error.InvalidField;
    if (title.len < MIN_TITLE_LEN) return error.MissingField;
    if (description.len < MIN_DESCRIPTION_LEN) return error.MissingField;
}

/// Validate subtask fields
pub fn validateSubTask(project_id: i64, task_id: i64, title: []const u8, description: []const u8) !void {
    if (project_id <= 0) return error.InvalidField;
    if (task_id <= 0) return error.InvalidField;
    if (title.len < MIN_TITLE_LEN) return error.MissingField;
    if (description.len < MIN_DESCRIPTION_LEN) return error.MissingField;
}

/// Validate bug fields
pub fn validateBug(project_id: i64, title: []const u8, description: []const u8, severity: []const u8) !void {
    if (project_id <= 0) return error.InvalidField;
    if (title.len < MIN_TITLE_LEN) return error.MissingField;
    if (description.len < MIN_DESCRIPTION_LEN) return error.MissingField;
    if (severity.len == 0) return error.MissingField;
    if (!std.mem.eql(u8, severity, "critical") and
        !std.mem.eql(u8, severity, "high") and
        !std.mem.eql(u8, severity, "medium") and
        !std.mem.eql(u8, severity, "low")) return error.InvalidField;
}

/// Validate a comment's content. Used by both MCP `comment_create`/`comment_update`
/// and the dashboard HTTP API.
pub fn validateComment(content: []const u8) !void {
    if (content.len < MIN_COMMENT_LEN) return error.MissingField;
}

/// Validate that a partial-update field value is acceptable. If a field is
/// provided (non-null), it must meet the same minimum-length standard as a
/// create call. Empty or too-short values are rejected so PATCH calls can't
/// blank out existing content.
pub fn validateTitleOpt(title: ?[]const u8) !void {
    if (title) |t| if (t.len < MIN_TITLE_LEN) return error.MissingField;
}
pub fn validateDescriptionOpt(description: ?[]const u8) !void {
    if (description) |d| if (d.len < MIN_DESCRIPTION_LEN) return error.MissingField;
}
pub fn validateAcceptanceCriteriaOpt(ac: ?[]const u8) !void {
    if (ac) |a| if (a.len < MIN_ACCEPTANCE_CRITERIA_LEN) return error.MissingField;
}

/// Validate severity for bug updates (optional field).
pub fn validateSeverityOpt(severity: ?[]const u8) !void {
    if (severity) |s| {
        if (s.len == 0) return error.MissingField;
        if (!std.mem.eql(u8, s, "critical") and
            !std.mem.eql(u8, s, "high") and
            !std.mem.eql(u8, s, "medium") and
            !std.mem.eql(u8, s, "low")) return error.InvalidField;
    }
}

/// Validate epic partial update fields (at least one must be provided).
pub fn validateEpicOpt(title: ?[]const u8, description: ?[]const u8) !void {
    if (title == null and description == null) return error.MissingField;
    try validateTitleOpt(title);
    try validateDescriptionOpt(description);
}

/// Validate story partial update fields (at least one must be provided).
pub fn validateStoryOpt(title: ?[]const u8, description: ?[]const u8, acceptance_criteria: ?[]const u8) !void {
    if (title == null and description == null and acceptance_criteria == null) return error.MissingField;
    try validateTitleOpt(title);
    try validateDescriptionOpt(description);
    try validateAcceptanceCriteriaOpt(acceptance_criteria);
}

/// Validate task partial update fields (at least one must be provided).
pub fn validateTaskOpt(title: ?[]const u8, description: ?[]const u8) !void {
    if (title == null and description == null) return error.MissingField;
    try validateTitleOpt(title);
    try validateDescriptionOpt(description);
}

/// Validate subtask partial update fields (at least one must be provided).
pub fn validateSubTaskOpt(title: ?[]const u8, description: ?[]const u8) !void {
    if (title == null and description == null) return error.MissingField;
    try validateTitleOpt(title);
    try validateDescriptionOpt(description);
}

/// Validate bug partial update fields (at least one must be provided).
pub fn validateBugOpt(title: ?[]const u8, description: ?[]const u8, severity: ?[]const u8) !void {
    if (title == null and description == null and severity == null) return error.MissingField;
    try validateTitleOpt(title);
    try validateDescriptionOpt(description);
    try validateSeverityOpt(severity);
}

/// Validate agent profile fields
pub fn validateAgent(name: []const u8, capabilities: []const u8) !void {
    if (name.len == 0) return error.MissingField;
    if (capabilities.len == 0) return error.MissingField;
}

/// Validate wiki page fields
pub fn validateWikiPage(project_id: i64, title: []const u8, category: []const u8, content: []const u8) !void {
    if (project_id <= 0) return error.InvalidField;
    if (title.len == 0) return error.MissingField;
    if (category.len == 0) return error.MissingField;
    if (content.len == 0) return error.MissingField;
}

test "validateProject: accepts valid fields" {
    try validateProject("My Project", "/path/to/project");
}

test "validateProject: rejects empty name" {
    try std.testing.expectError(error.MissingField, validateProject("", "/path"));
}

test "validateProject: rejects empty root_path" {
    try std.testing.expectError(error.MissingField, validateProject("Name", ""));
}

test "validateEpic: accepts valid fields" {
    try validateEpic(1, "Epic Title", "Description here that is long enough to pass");
}

test "validateEpic: rejects short title" {
    try std.testing.expectError(error.MissingField, validateEpic(1, "ab", "Description here that is long enough to pass"));
}

test "validateEpic: rejects short description" {
    try std.testing.expectError(error.MissingField, validateEpic(1, "Valid Title", "short"));
}

test "validateEpic: rejects project_id <= 0" {
    try std.testing.expectError(error.InvalidField, validateEpic(0, "Title", "Desc that is long enough"));
}

test "validateStory: accepts valid fields" {
    try validateStory(1, 1, "Story Title", "Description with enough content", "- AC 1\n- AC 2 with detail");
}

test "validateStory: rejects short acceptance_criteria" {
    try std.testing.expectError(error.MissingField, validateStory(1, 1, "Title", "Desc with enough content", "AC"));
}

test "validateTask: accepts valid fields" {
    try validateTask(1, 1, "Task Title", "Description with enough content");
}

test "validateTask: rejects short description" {
    try std.testing.expectError(error.MissingField, validateTask(1, 1, "Title", "short"));
}

test "validateSubTask: accepts valid fields" {
    try validateSubTask(1, 1, "SubTask Title", "Description with enough content");
}

test "validateSubTask: rejects short description" {
    try std.testing.expectError(error.MissingField, validateSubTask(1, 1, "Title", "short"));
}

test "validateComment: accepts valid content" {
    try validateComment("This is a useful comment");
}

test "validateComment: rejects too short" {
    try std.testing.expectError(error.MissingField, validateComment("hi"));
}

test "validateComment: rejects empty" {
    try std.testing.expectError(error.MissingField, validateComment(""));
}

test "validateTitleOpt: null passes" {
    try validateTitleOpt(null);
}

test "validateTitleOpt: non-null meeting min passes" {
    try validateTitleOpt("Valid Title");
}

test "validateTitleOpt: non-null too short fails" {
    try std.testing.expectError(error.MissingField, validateTitleOpt("ab"));
}

test "validateDescriptionOpt: null passes" {
    try validateDescriptionOpt(null);
}

test "validateDescriptionOpt: non-null too short fails" {
    try std.testing.expectError(error.MissingField, validateDescriptionOpt("short"));
}

test "validateAcceptanceCriteriaOpt: null passes" {
    try validateAcceptanceCriteriaOpt(null);
}

test "validateAcceptanceCriteriaOpt: non-null too short fails" {
    try std.testing.expectError(error.MissingField, validateAcceptanceCriteriaOpt("AC"));
}

test "validateAgent: accepts valid fields" {
    try validateAgent("Test Agent", "testing,automation");
}

test "validateAgent: rejects empty capabilities" {
    try std.testing.expectError(error.MissingField, validateAgent("Name", ""));
}

test "validateWikiPage: accepts valid fields" {
    try validateWikiPage(1, "Page Title", "Docs", "Content here");
}

test "validateWikiPage: rejects empty content" {
    try std.testing.expectError(error.MissingField, validateWikiPage(1, "Title", "Docs", ""));
}

test "validateBug: accepts valid fields" {
    try validateBug(1, "Bug Title", "Description with enough content", "high");
}

test "validateBug: rejects empty severity" {
    try std.testing.expectError(error.MissingField, validateBug(1, "Title", "Desc with enough content", ""));
}

test "validateBug: rejects invalid severity" {
    try std.testing.expectError(error.InvalidField, validateBug(1, "Title", "Desc with enough content", "invalid"));
}

test "validateBug: rejects short title" {
    try std.testing.expectError(error.MissingField, validateBug(1, "ab", "Desc with enough content", "high"));
}

// ── Memory Validation ──

/// Minimum length for memory titles
pub const MIN_MEMORY_TITLE_LEN: usize = 10;
/// Maximum length for memory titles
pub const MAX_MEMORY_TITLE_LEN: usize = 200;
/// Minimum length for memory content
pub const MIN_MEMORY_CONTENT_LEN: usize = 50;
/// Maximum length for memory content
pub const MAX_MEMORY_CONTENT_LEN: usize = 2000;
/// Minimum length for memory summary
pub const MIN_MEMORY_SUMMARY_LEN: usize = 5;
/// Maximum length for memory summary
pub const MAX_MEMORY_SUMMARY_LEN: usize = 500;
/// Maximum number of tags per memory entry
pub const MAX_MEMORY_TAGS: usize = 20;
/// Default memory cap in bytes (10MB)
pub const DEFAULT_MEMORY_CAP_BYTES: usize = 10485760;

/// Validate memory save fields
pub fn validateMemorySave(
    project_id: i64,
    scope: lifecycle.MemoryScope,
    category: lifecycle.MemoryCategory,
    title: []const u8,
    content: []const u8,
    summary: ?[]const u8,
    tags: ?[]const u8,
    importance: lifecycle.MemoryImportance,
) !void {
    _ = scope;
    _ = category;
    _ = importance;
    if (project_id <= 0) return error.InvalidField;
    if (title.len < MIN_MEMORY_TITLE_LEN or title.len > MAX_MEMORY_TITLE_LEN) return error.InvalidField;
    if (content.len < MIN_MEMORY_CONTENT_LEN or content.len > MAX_MEMORY_CONTENT_LEN) return error.InvalidField;
    if (summary) |s| {
        if (s.len < MIN_MEMORY_SUMMARY_LEN or s.len > MAX_MEMORY_SUMMARY_LEN) return error.InvalidField;
    }
    if (tags) |t| {
        // Validate as JSON array — basic check for brackets
        if (t.len == 0) return error.InvalidField;
        if (t[0] != '[') return error.InvalidField;
    }
}

/// Validate memory update fields (at least one must be provided)
pub fn validateMemoryUpdate(
    title: ?[]const u8,
    content: ?[]const u8,
    summary: ?[]const u8,
    tags: ?[]const u8,
    importance: ?lifecycle.MemoryImportance,
) !void {
    _ = importance;
    if (title == null and content == null and summary == null and tags == null)
        return error.MissingField;
    if (title) |t| {
        if (t.len < MIN_MEMORY_TITLE_LEN or t.len > MAX_MEMORY_TITLE_LEN) return error.InvalidField;
    }
    if (content) |c| {
        if (c.len < MIN_MEMORY_CONTENT_LEN or c.len > MAX_MEMORY_CONTENT_LEN) return error.InvalidField;
    }
    if (summary) |s| {
        if (s.len < MIN_MEMORY_SUMMARY_LEN or s.len > MAX_MEMORY_SUMMARY_LEN) return error.InvalidField;
    }
    if (tags) |t| {
        if (t.len == 0) return error.InvalidField;
        if (t[0] != '[') return error.InvalidField;
    }
}

// ── Memory Validation Tests ──

test "validateMemorySave: accepts valid fields" {
    try validateMemorySave(1, .project, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", null, null, .high);
}

test "validateMemorySave: accepts valid summary" {
    try validateMemorySave(1, .project, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", "Valid summary", null, .high);
}

test "validateMemorySave: accepts valid tags" {
    try validateMemorySave(1, .project, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", null, "[\"tag1\",\"tag2\"]", .high);
}

test "validateMemorySave: rejects short title" {
    try std.testing.expectError(error.InvalidField, validateMemorySave(1, .project, .decision, "Short", "This is valid memory content that meets the minimum length requirement for testing", null, null, .high));
}

test "validateMemorySave: rejects long title" {
    var long_title: [201]u8 = undefined;
    @memset(&long_title, 'x');
    try std.testing.expectError(error.InvalidField, validateMemorySave(1, .project, .decision, &long_title, "This is valid memory content that meets the minimum length requirement for testing", null, null, .high));
}

test "validateMemorySave: rejects short content" {
    try std.testing.expectError(error.InvalidField, validateMemorySave(1, .project, .decision, "This is a valid memory title", "Too short", null, null, .high));
}

test "validateMemorySave: rejects empty project_id" {
    try std.testing.expectError(error.InvalidField, validateMemorySave(0, .project, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", null, null, .high));
}

test "validateMemorySave: rejects short summary" {
    try std.testing.expectError(error.InvalidField, validateMemorySave(1, .project, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", "abc", null, .high));
}

test "validateMemorySave: rejects invalid tags format" {
    try std.testing.expectError(error.InvalidField, validateMemorySave(1, .project, .decision, "This is a valid memory title", "This is valid memory content that meets the minimum length requirement for testing", null, "not-json", .high));
}

test "validateMemoryUpdate: accepts valid title" {
    try validateMemoryUpdate("This is a valid updated title", null, null, null, null);
}

test "validateMemoryUpdate: accepts valid content" {
    try validateMemoryUpdate(null, "This is valid memory content that meets the minimum length requirement for testing", null, null, null);
}

test "validateMemoryUpdate: rejects no fields provided" {
    try std.testing.expectError(error.MissingField, validateMemoryUpdate(null, null, null, null, null));
}

test "validateMemoryUpdate: rejects short title" {
    try std.testing.expectError(error.InvalidField, validateMemoryUpdate("Short", null, null, null, null));
}

test "validateMemoryUpdate: rejects short content" {
    try std.testing.expectError(error.InvalidField, validateMemoryUpdate(null, "Too short", null, null, null));
}
