const std = @import("std");
const db = @import("../connection.zig");
const entities = @import("../../domain/entities.zig");

pub fn insert(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, category: []const u8, parent_id: ?i64, title: []const u8, content: []const u8) !entities.WikiPage {
    var stmt = try conn.prepare("INSERT INTO wiki_pages (project_id, category, parent_id, title, content) VALUES (?, ?, ?, ?, ?) RETURNING id, created_at, updated_at");
    defer stmt.finalize();

    stmt.bindInt64(1, project_id);
    stmt.bindText(2, category);
    if (parent_id) |p| stmt.bindInt64(3, p) else stmt.bindNull(3);
    stmt.bindText(4, title);
    stmt.bindText(5, content);
    _ = try stmt.step();

    const id = stmt.columnInt64(0);
    const created_at = stmt.columnText(1) orelse "unknown";
    const updated_at = stmt.columnText(2) orelse "unknown";

    return entities.WikiPage{
        .id = id,
        .project_id = project_id,
        .category = try allocator.dupe(u8, category),
        .parent_id = parent_id,
        .title = try allocator.dupe(u8, title),
        .content = try allocator.dupe(u8, content),
        .version = 1,
        .is_current = true,
        .created_at = try allocator.dupe(u8, created_at),
        .updated_at = try allocator.dupe(u8, updated_at),
    };
}

pub fn getById(conn: *db.Connection, allocator: std.mem.Allocator, page_id: i64) !?entities.WikiPage {
    var stmt = try conn.prepare("SELECT id, project_id, category, parent_id, title, content, version, is_current, created_at, updated_at FROM wiki_pages WHERE id = ? AND is_current = 1");
    defer stmt.finalize();
    stmt.bindInt64(1, page_id);
    const result = try stmt.step();
    if (result != .row) return null;
    const id_opt = stmt.columnInt64Safe(0);
    if (id_opt == null) return null;

    return entities.WikiPage{
        .id = id_opt.?,
        .project_id = stmt.columnInt64(1),
        .category = try allocator.dupe(u8, stmt.columnText(2).?),
        .parent_id = stmt.columnInt64Safe(3),
        .title = try allocator.dupe(u8, stmt.columnText(4).?),
        .content = try allocator.dupe(u8, stmt.columnText(5).?),
        .version = @as(u32, @intCast(stmt.columnInt64(6))),
        .is_current = stmt.columnInt64(7) == 1,
        .created_at = try allocator.dupe(u8, stmt.columnText(8).?),
        .updated_at = try allocator.dupe(u8, stmt.columnText(9).?),
    };
}

pub fn updateContent(conn: *db.Connection, page_id: i64, new_content: []const u8) !void {
    // Save old version to history before updating (let SQLite auto-assign history id)
    {
        var hist_stmt = try conn.prepare("INSERT INTO wiki_history (page_id, content, version) SELECT id, content, version FROM wiki_pages WHERE id = ? AND is_current = 1");
        defer hist_stmt.finalize();
        hist_stmt.bindInt64(1, page_id);
        _ = try hist_stmt.step();
    }

    // Update current page content and increment version
    {
        var stmt = try conn.prepare("UPDATE wiki_pages SET content = ?, version = version + 1, updated_at = datetime('now') WHERE id = ? AND is_current = 1");
        defer stmt.finalize();
        stmt.bindText(1, new_content);
        stmt.bindInt64(2, page_id);
        _ = try stmt.step();
    }
}

pub fn listByProject(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64) !std.ArrayList(entities.WikiPage) {
    var results = std.ArrayList(entities.WikiPage).empty;
    var stmt = try conn.prepare("SELECT id, project_id, category, parent_id, title, content, version, is_current, created_at, updated_at FROM wiki_pages WHERE project_id = ? AND is_current = 1 ORDER BY category, title");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        try results.append(allocator, entities.WikiPage{
            .id = id_opt.?,
            .project_id = stmt.columnInt64(1),
            .category = try allocator.dupe(u8, stmt.columnText(2).?),
            .parent_id = stmt.columnInt64Safe(3),
            .title = try allocator.dupe(u8, stmt.columnText(4).?),
            .content = try allocator.dupe(u8, stmt.columnText(5).?),
            .version = @as(u32, @intCast(stmt.columnInt64(6))),
            .is_current = stmt.columnInt64(7) == 1,
            .created_at = try allocator.dupe(u8, stmt.columnText(8).?),
            .updated_at = try allocator.dupe(u8, stmt.columnText(9).?),
        });
    }
    return results;
}

/// Wiki version history row
pub const WikiVersion = struct {
    version: u32,
    content: []const u8,
    edited_at: []const u8,
};

pub fn getVersions(conn: *db.Connection, allocator: std.mem.Allocator, page_id: i64) !std.ArrayList(WikiVersion) {
    var results = std.ArrayList(WikiVersion).empty;
    // Include current version from wiki_pages + archived versions from wiki_history
    var stmt = try conn.prepare(
        \\SELECT version, content, updated_at AS edited_at FROM wiki_pages WHERE id = ? AND is_current = 1
        \\UNION
        \\SELECT version, content, edited_at FROM wiki_history WHERE page_id = ?
        \\ORDER BY version DESC
    );
    defer stmt.finalize();
    stmt.bindInt64(1, page_id);
    stmt.bindInt64(2, page_id);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const version = stmt.columnInt64Safe(0) orelse break;
        const content = stmt.columnText(1) orelse break;
        const edited_at = stmt.columnText(2) orelse "unknown";
        try results.append(allocator, WikiVersion{
            .version = @as(u32, @intCast(version)),
            .content = try allocator.dupe(u8, content),
            .edited_at = try allocator.dupe(u8, edited_at),
        });
    }
    return results;
}

pub fn searchByProject(conn: *db.Connection, allocator: std.mem.Allocator, project_id: i64, query: []const u8) !std.ArrayList(entities.WikiPage) {
    // Build LIKE pattern: %query%
    var like_pattern = std.array_list.Managed(u8).init(allocator);
    defer like_pattern.deinit();
    try like_pattern.append('%');
    try like_pattern.appendSlice(query);
    try like_pattern.append('%');

    var results = std.ArrayList(entities.WikiPage).empty;
    var stmt = try conn.prepare("SELECT id, project_id, category, parent_id, title, content, version, is_current, created_at, updated_at FROM wiki_pages WHERE project_id = ? AND is_current = 1 AND (title LIKE ? OR content LIKE ?) ORDER BY title");
    defer stmt.finalize();
    stmt.bindInt64(1, project_id);
    stmt.bindText(2, like_pattern.items);
    stmt.bindText(3, like_pattern.items);

    while (true) {
        const result = stmt.step() catch break;
        if (result != .row) break;
        const id_opt = stmt.columnInt64Safe(0);
        if (id_opt == null) break;
        try results.append(allocator, entities.WikiPage{
            .id = id_opt.?,
            .project_id = stmt.columnInt64(1),
            .category = try allocator.dupe(u8, stmt.columnText(2).?),
            .parent_id = stmt.columnInt64Safe(3),
            .title = try allocator.dupe(u8, stmt.columnText(4).?),
            .content = try allocator.dupe(u8, stmt.columnText(5).?),
            .version = @as(u32, @intCast(stmt.columnInt64(6))),
            .is_current = stmt.columnInt64(7) == 1,
            .created_at = try allocator.dupe(u8, stmt.columnText(8).?),
            .updated_at = try allocator.dupe(u8, stmt.columnText(9).?),
        });
    }
    return results;
}

/// Delete a wiki page by ID.
pub fn delete(conn: *db.Connection, page_id: i64) !void {
    var stmt = try conn.prepare("DELETE FROM wiki_pages WHERE id = ?");
    defer stmt.finalize();
    stmt.bindInt64(1, page_id);
    _ = try stmt.step();
}
