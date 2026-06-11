const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const queries = @import("../../db/queries/wiki.zig");
const queries_comments = @import("../../db/queries/comments.zig");
const errorz = @import("../../error.zig");
const entities = @import("../../domain/entities.zig");
const validation = @import("../../domain/validation.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "wiki_create")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const category = args.getRequiredString("category") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "category");
        const title = args.getRequiredString("title") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title");
        const content = args.getRequiredString("content") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "content");
        const parent_id_str = args.getOptionalString("parent_id");
        const parent_id = if (parent_id_str) |ps| std.fmt.parseInt(i64, ps, 10) catch null else null;

        validation.validateWikiPage(project_id, title, category, content) catch |err| return switch (err) {
            error.MissingField => json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "title, category, content are required"),
            error.InvalidField => json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be > 0"),
        };

        const page = try queries.insert(s.conn, alloc, project_id, category, parent_id, title, content);
        defer {
            s.allocator.free(page.category);
            s.allocator.free(page.title);
            s.allocator.free(page.content);
            s.allocator.free(page.created_at);
            s.allocator.free(page.updated_at);
        }
        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Wiki page '{s}' created (id: {d})", .{title, page.id}) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "wiki_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const page = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (page) |p| {
            defer {
                s.allocator.free(p.category);
                s.allocator.free(p.title);
                s.allocator.free(p.content);
                s.allocator.free(p.created_at);
                s.allocator.free(p.updated_at);
            }
            var buf = std.array_list.Managed(u8).init(alloc);
            defer buf.deinit();
            try buf.appendSlice(p.content);
            if (try queries_comments.formatCommentsForResponse(alloc, s.conn, "wiki", id)) |comments_str| {
                defer alloc.free(comments_str);
                try buf.appendSlice(comments_str);
            }
            return json.stringifyTextResponse(alloc, buf.items);
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Wiki page");
    }

    if (std.mem.eql(u8, tool_name, "wiki_update")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const content = args.getRequiredString("content") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "content");
        queries.updateContent(s.conn, id, content) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        return json.stringifyTextResponse(alloc, "Wiki page updated");
    }

    if (std.mem.eql(u8, tool_name, "wiki_list")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        var pages = try queries.listByProject(s.conn, alloc, project_id);
        defer {
            for (pages.items) |p| entities.freeWikiPage(alloc, p);
            pages.deinit(alloc);
        }
        {
            var list_buf = std.array_list.Managed(u8).init(alloc);
            try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} wiki pages:", .{pages.items.len}));
            for (pages.items) |p| {
                const piece = try std.fmt.allocPrint(alloc, " {d} ({s})", .{ p.id, p.title });
                try list_buf.appendSlice(piece);
                alloc.free(piece);
            }
            const result = try json.stringifyTextResponse(alloc, list_buf.items);
            list_buf.deinit();
            return result;
        }
    }

    if (std.mem.eql(u8, tool_name, "wiki_search")) {
        const project_id_str = args.getRequiredString("project_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "project_id");
        const project_id = std.fmt.parseInt(i64, project_id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "project_id must be an integer");
        const query_text = args.getRequiredString("query") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "query");

        var pages = try queries.searchByProject(s.conn, alloc, project_id, query_text);
        defer {
            for (pages.items) |p| entities.freeWikiPage(alloc, p);
            pages.deinit(alloc);
        }

        if (pages.items.len == 0) {
            return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "No wiki pages found for '{s}'", .{query_text}) catch "not found");
        }

        var list_buf = std.array_list.Managed(u8).init(alloc);
        defer list_buf.deinit();
        try list_buf.appendSlice(try std.fmt.allocPrint(alloc, "Found {d} wiki pages for '{s}':", .{ pages.items.len, query_text }));
        for (pages.items) |p| {
            const piece = try std.fmt.allocPrint(alloc, " {d} ({s})", .{ p.id, p.title });
            try list_buf.appendSlice(piece);
            alloc.free(piece);
        }
        return json.stringifyTextResponse(alloc, list_buf.items);
    }

    if (std.mem.eql(u8, tool_name, "wiki_versions")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");

        var versions = try queries.getVersions(s.conn, alloc, id);
        defer {
            for (versions.items) |v| {
                alloc.free(v.content);
                alloc.free(v.edited_at);
            }
            versions.deinit(alloc);
        }

        if (versions.items.len == 0) {
            return json.stringifyTextResponse(alloc, "No version history found");
        }

        var buf = std.array_list.Managed(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice(try std.fmt.allocPrint(alloc, "Version history ({d} versions):", .{versions.items.len}));
        for (versions.items, 0..) |v, i| {
            try buf.appendSlice(try std.fmt.allocPrint(alloc, " v{d} ({s})", .{ v.version, v.edited_at }));
            _ = i;
        }
        return json.stringifyTextResponse(alloc, buf.items);
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}
