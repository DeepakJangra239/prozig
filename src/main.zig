const std = @import("std");

const Version = "0.1.0";

pub const db = @import("db/connection.zig");
pub const mcp = @import("mcp/server.zig");
pub const http_server = @import("http/server.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Parse CLI args
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next(); // skip program name

    var port: u16 = 9181;
    var command: ?[]const u8 = null;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (it.next()) |port_arg| {
                port = try std.fmt.parseUnsigned(u16, port_arg, 10);
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            command = "help";
        } else {
            command = arg;
        }
    }

    const cmd = command orelse "mcp";

    // Resolve database path (use arena allocator — auto-cleaned on exit)
    const arena_allocator = init.arena.allocator();
    const db_path = try resolveDbPath(arena_allocator, init.minimal.environ);
    // Ensure the directory exists
    try ensureDbDir(io, db_path);

    if (std.mem.eql(u8, cmd, "mcp")) {
        try runMcp(io, db_path);
    } else if (std.mem.eql(u8, cmd, "dashboard")) {
        var dconn = try db.Connection.init(db_path);
        try dconn.migrate();
        try runDashboard(io, db_path, port, &dconn);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try runInit(io, db_path);
    } else if (std.mem.eql(u8, cmd, "help")) {
        try printHelp(io);
    } else if (std.mem.eql(u8, cmd, "version")) {
        var buf: [128]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll("prozig " ++ Version ++ "\n");
        try w.flush();
    } else {
        var buf: [128]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.writeAll("Unknown command: ");
        try w.interface.writeAll(cmd);
        try w.interface.writeAll("\n");
        try printHelp(io);
        std.process.exit(1);
    }
}

fn resolveDbPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.HomeDirNotFound;
    return std.fmt.allocPrint(allocator, "{s}/.prozig/tracker.db", .{home});
}

fn ensureDbDir(io: std.Io, db_path: []const u8) !void {
    const last_slash = std.mem.lastIndexOfScalar(u8, db_path, '/') orelse return;
    const dir_path = db_path[0..last_slash];
    std.Io.Dir.createDirAbsolute(io, dir_path, std.Io.File.Permissions.default_dir) catch {};
}

fn printHelp(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(
        "Usage: prozig <command> [options]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  mcp         Start MCP server (stdio, default)\n" ++
        "  dashboard   Start web dashboard (HTTP on port 9181)\n" ++
        "  init        Initialize the tracker database\n" ++
        "  help        Show this help message\n" ++
        "  version     Show version\n" ++
        "\n" ++
        "Options:\n" ++
        "  --port <N>  Port for dashboard (default: 9181)\n",
    );
    try w.flush();
}

fn runInit(io: std.Io, db_path: []u8) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);

    try w.interface.writeAll("Initializing Prozig tracker database...\n");
    var connection = try db.Connection.init(db_path);
    defer connection.deinit();
    try connection.migrate();
    try w.interface.writeAll("Database initialized successfully.\n");
    try w.interface.writeAll("  Path: ");
    try w.interface.writeAll(connection.db_path);
    try w.interface.writeAll("\n");
}

fn runMcp(io: std.Io, db_path: []u8) !void {
    var connection = try db.Connection.init(db_path);
    defer connection.deinit();
    try connection.migrate();

    // Try to start HTTP dashboard on background thread.
    // If port is already in use, another MCP session already started it.
    startDashboardIfNotRunning(io, db_path, 9181) catch |err| {
        std.log.info("Dashboard already running ({s}), skipping...", .{@errorName(err)});
    };

    try mcp.run(&connection, io);
}

fn startDashboardIfNotRunning(io: std.Io, db_path: []u8, port: u16) !void {
    // Quick listen test — if port is free, probe succeeds
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var probe = try addr.listen(io, .{ .reuse_address = true });
    probe.deinit(io);

    // Port is free — start dashboard in a background thread.
    // The thread creates its own connection so there's no dangling pointer.
    const handle = try std.Thread.spawn(.{}, runDashboardThread, .{ io, db_path, port });
    handle.detach();
}

fn runDashboardThread(io: std.Io, db_path: []u8, port: u16) !void {
    var conn = db.Connection.init(db_path) catch |err| {
        std.log.err("Dashboard failed to open DB: {s}", .{@errorName(err)});
        return;
    };
    runDashboard(io, db_path, port, &conn) catch |err| {
        std.log.err("Dashboard thread failed: {s}", .{@errorName(err)});
    };
    conn.deinit();
}

fn runDashboard(io: std.Io, _: []u8, port: u16, conn: *db.Connection) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("Prozig dashboard on http://localhost:{d}\n", .{port});

    try http_server.run(conn, io, port);
}
