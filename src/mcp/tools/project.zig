const Server = @import("../types.zig").Server;
const std = @import("std");
const json = @import("../json.zig");
const db = @import("../../db/connection.zig");
const seed = @import("../../db/seed.zig");
const queries = @import("../../db/queries/projects.zig");
const entities = @import("../../domain/entities.zig");
const errorz = @import("../../error.zig");
const validation = @import("../../domain/validation.zig");

pub fn handle(s: *Server, tool_name: []const u8, args: json.JsonValue) ![]const u8 {
    const alloc = s.allocator;

    if (std.mem.eql(u8, tool_name, "project_init")) {
        const name = args.getRequiredString("name") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "name");
        const root_path = args.getRequiredString("root_path") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "root_path");
        const description = args.getOptionalString("description");

        // Check if a project already exists for this root_path
        const existing = queries.getByRootPath(s.conn, alloc, root_path) catch |err| {
            return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        };
        if (existing) |ep| {
            defer {
                alloc.free(ep.name);
                alloc.free(ep.root_path);
                if (ep.description) |d| alloc.free(d);
                if (ep.metadata) |m| alloc.free(m);
                alloc.free(ep.created_at);
                alloc.free(ep.updated_at);
            }
            return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Project already exists for this directory: '{s}' (id: {d}). Use this existing project instead of creating a new one.", .{ ep.name, ep.id }) catch "exists");
        }

        const project = try queries.insert(s.conn, alloc, name, root_path, description);
        defer {
            s.allocator.free(project.name);
            s.allocator.free(project.root_path);
            if (project.description) |d| s.allocator.free(d);
        }

        // Seed default workflow for the new project
        seed.seedProjectWorkflow(s.conn, project.id) catch |err| {
            std.log.err("Failed to seed workflow for new project: {any}\n", .{err});
        };

        return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Project '{s}' created", .{name}) catch "created");
    }

    if (std.mem.eql(u8, tool_name, "project_list")) {
        var projects = try queries.listAll(s.conn, alloc);
        defer {
            for (projects.items) |p| entities.freeProject(s.allocator, p);
            projects.deinit(s.allocator);
        }
        var result = std.array_list.Managed(u8).init(alloc);
        try result.append('[');
        for (projects.items, 0..) |p, i| {
            if (i > 0) try result.append(',');
            const entry = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"name\":\"{s}\",\"root_path\":\"{s}\"}}", .{ p.id, p.name, p.root_path });
            try result.appendSlice(entry);
            alloc.free(entry);
        }
        try result.append(']');
        return json.stringifyTextResponse(alloc, result.items);
    }

    if (std.mem.eql(u8, tool_name, "project_get")) {
        const id_str = args.getRequiredString("entity_id") catch return json.stringifyCatalogError(alloc, errorz.Errors.MISSING_FIELD.code, errorz.Errors.MISSING_FIELD.message, "entity_id");
        const id = std.fmt.parseInt(i64, id_str, 10) catch return json.stringifyCatalogError(alloc, errorz.Errors.INVALID_FIELD.code, errorz.Errors.INVALID_FIELD.message, "entity_id must be an integer");
        const project = queries.getById(s.conn, alloc, id) catch |err| return json.stringifyCatalogError(alloc, errorz.Errors.DB_ERROR.code, errorz.Errors.DB_ERROR.message, @errorName(err));
        if (project) |p| {
            defer {
                s.allocator.free(p.name);
                s.allocator.free(p.root_path);
                if (p.description) |d| s.allocator.free(d);
                if (p.metadata) |m| s.allocator.free(m);
                s.allocator.free(p.created_at);
                s.allocator.free(p.updated_at);
            }
            return json.stringifyTextResponse(alloc, std.fmt.allocPrint(alloc, "Project: {s} (id: {d}, path: {s})", .{ p.name, p.id, p.root_path }) catch "alloc error");
        }
        return json.stringifyCatalogError(alloc, errorz.Errors.NOT_FOUND.code, errorz.Errors.NOT_FOUND.message, "Project");
    }

    return json.stringifyCatalogError(alloc, errorz.Errors.UNKNOWN_TOOL.code, errorz.Errors.UNKNOWN_TOOL.message, tool_name);
}
