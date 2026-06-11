const std = @import("std");
const errors = @import("../error.zig");

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
