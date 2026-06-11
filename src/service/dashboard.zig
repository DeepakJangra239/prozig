const std = @import("std");
const Service = @import("root.zig").Service;
const entities = @import("../domain/entities.zig");
const queries_project = @import("../db/queries/projects.zig");
const queries_epic = @import("../db/queries/epics.zig");
const queries_story = @import("../db/queries/stories.zig");
const queries_task = @import("../db/queries/tasks.zig");
const queries_bug = @import("../db/queries/bug.zig");

/// Aggregate counts across all entities for the dashboard.
pub const DashboardCounts = struct {
    projects: usize,
    epics: usize,
    stories: usize,
    tasks: usize,
    bugs: usize,
};

/// Compute aggregate counts for the dashboard.
/// Iterates the full hierarchy and frees entities as it goes.
pub fn getDashboardCounts(srv: *Service, allocator: std.mem.Allocator) !DashboardCounts {
    const conn = srv.conn;

    var projects = try queries_project.listAll(conn, allocator);
    defer projects.deinit(allocator);

    var epics_count: usize = 0;
    var stories_count: usize = 0;
    var tasks_count: usize = 0;
    var bugs_count: usize = 0;

    for (projects.items) |p| {
        var epics = queries_epic.listByProject(conn, allocator, p.id) catch {
            entities.freeProject(allocator, p);
            continue;
        };
        epics_count += epics.items.len;

        for (epics.items) |e| {
            var stories = queries_story.listByEpic(conn, allocator, e.id) catch {
                entities.freeEpic(allocator, e);
                continue;
            };
            stories_count += stories.items.len;

            for (stories.items) |s| {
                var tasks = queries_task.listByStory(conn, allocator, s.id) catch {
                entities.freeStory(allocator, s);
                    continue;
                };
                tasks_count += tasks.items.len;

                for (tasks.items) |t| entities.freeTask(allocator, t);
                tasks.deinit(allocator);
                entities.freeStory(allocator, s);
            }
            stories.deinit(allocator);
            entities.freeEpic(allocator, e);
        }
        epics.deinit(allocator);
        entities.freeProject(allocator, p);
    }

    // Count bugs separately (bugs are not in the epic/story/task hierarchy)
    for (projects.items) |p| {
        var bugs = queries_bug.listByProject(conn, allocator, p.id) catch continue;
        bugs_count += bugs.items.len;
        for (bugs.items) |b| entities.freeBug(allocator, b);
        bugs.deinit(allocator);
    }

    return DashboardCounts{
        .projects = projects.items.len,
        .epics = epics_count,
        .stories = stories_count,
        .tasks = tasks_count,
        .bugs = bugs_count,
    };
}
