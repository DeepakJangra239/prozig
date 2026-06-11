const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const seed = @import("seed.zig");

pub const Connection = struct {
    db: ?*sqlite.c.sqlite3,
    db_path: []const u8,

    /// Initialize a database connection.
    /// The caller ensures the directory exists and owns db_path.
    pub fn init(db_path: []const u8) !Connection {
        var db: ?*sqlite.c.sqlite3 = null;
        const flags: c_int = sqlite.c.SQLITE_OPEN_READWRITE | sqlite.c.SQLITE_OPEN_CREATE | sqlite.c.SQLITE_OPEN_FULLMUTEX;

        // Null-terminate for C
        var c_path: [512]u8 = undefined;
        const path_len = @min(db_path.len, c_path.len - 1);
        @memcpy(c_path[0..path_len], db_path[0..path_len]);
        c_path[path_len] = 0;

        const result = sqlite.c.sqlite3_open_v2(&c_path, &db, flags, null);
        if (result != sqlite.c.SQLITE_OK or db == null) {
            const err_cstr: [*c]const u8 = if (db) |d| sqlite.c.sqlite3_errmsg(d) else @as([*c]const u8, @ptrCast("unknown error"));
            std.log.err("Failed to open database: {s}\n", .{std.mem.span(err_cstr)});
            return error.DatabaseOpenFailed;
        }

        // Enable foreign keys
        _ = sqlite.c.sqlite3_exec(db, "PRAGMA foreign_keys = ON;", null, null, null);
        // WAL mode for concurrent reads
        _ = sqlite.c.sqlite3_exec(db, "PRAGMA journal_mode = WAL;", null, null, null);

        return Connection{ .db = db, .db_path = db_path };
    }

    pub fn deinit(self: *Connection) void {
        if (self.db) |d| {
            _ = sqlite.c.sqlite3_close(d);
            self.db = null;
        }
    }

    pub fn migrate(self: *Connection) !void {
        var current_version: u32 = 0;

        // Check current migration version
        const version_sql = "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1";
        var stmt: ?*sqlite.c.sqlite3_stmt = null;
        if (sqlite.c.sqlite3_prepare_v2(self.db, version_sql.ptr, @intCast(version_sql.len), &stmt, null) == sqlite.c.SQLITE_OK) {
            if (stmt != null and sqlite.c.sqlite3_step(stmt) == sqlite.c.SQLITE_ROW) {
                current_version = @intCast(sqlite.c.sqlite3_column_int(stmt, 0));
            }
            _ = sqlite.c.sqlite3_finalize(stmt);
        }

        // Ensure migrations table exists
        _ = sqlite.c.sqlite3_exec(self.db, "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT DEFAULT (datetime('now')));", null, null, null);

        // Apply pending migrations
        for (schema.migrations) |migration| {
            if (migration.version > current_version) {
                std.log.info("Applying migration v{d}: {s}\n", .{ migration.version, migration.name });

                const result = sqlite.c.sqlite3_exec(self.db, migration.sql.ptr, null, null, null);
                if (result != sqlite.c.SQLITE_OK) {
                    const err_cstr = sqlite.c.sqlite3_errmsg(self.db);
                    std.log.err("Migration v{d} failed: {s}\n", .{ migration.version, std.mem.span(err_cstr) });
                    return error.MigrationFailed;
                }

                // Record migration version
                var insert_buf: [128]u8 = undefined;
                const insert_sql = std.fmt.bufPrint(&insert_buf, "INSERT INTO schema_migrations (version) VALUES ({d});", .{migration.version}) catch continue;
                _ = sqlite.c.sqlite3_exec(self.db, insert_sql.ptr, null, null, null);
            }
        }

        std.log.info("Database schema at version {d}\n", .{schema.LATEST_VERSION});

        // Seed default workflow data for any unseeded projects
        seed.seedAllProjects(self) catch |err| {
            std.log.err("Failed to seed workflow data: {any}\n", .{err});
        };
    }

    /// Begin a transaction
    pub fn begin(self: *Connection) !void {
        const result = sqlite.c.sqlite3_exec(self.db, "BEGIN TRANSACTION", null, null, null);
        if (result != sqlite.c.SQLITE_OK) return error.BeginFailed;
    }

    /// Commit the current transaction
    pub fn commit(self: *Connection) !void {
        const result = sqlite.c.sqlite3_exec(self.db, "COMMIT", null, null, null);
        if (result != sqlite.c.SQLITE_OK) return error.CommitFailed;
    }

    /// Rollback the current transaction
    pub fn rollback(self: *Connection) void {
        _ = sqlite.c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
    }

    /// Execute a simple SQL statement (no results)
    pub fn exec(self: *Connection, sql: []const u8) !void {
        const result = sqlite.c.sqlite3_exec(self.db, sql.ptr, null, null, null);
        if (result != sqlite.c.SQLITE_OK) {
            return error.SqliteError;
        }
    }

    /// Prepare a statement for execution
    pub fn prepare(self: *Connection, sql: []const u8) !PreparedStmt {
        var stmt: ?*sqlite.c.sqlite3_stmt = null;
        const result = sqlite.c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (result != sqlite.c.SQLITE_OK) {
            const err_cstr = sqlite.c.sqlite3_errmsg(self.db);
            std.log.err("Failed to prepare: {s}\n", .{std.mem.span(err_cstr)});
            return error.PrepareFailed;
        }
        return PreparedStmt{ .stmt = stmt.?, .parent = self };
    }
};

pub const PreparedStmt = struct {
    stmt: *sqlite.c.sqlite3_stmt,
    parent: *Connection,

    /// Result of stepping a prepared statement.
    pub const StepResult = enum {
        /// A row of results is available via column* accessors.
        row,
        /// Statement completed with no more rows (e.g. SELECT returned empty,
        /// or INSERT/UPDATE/DELETE finished).
        done,
    };

    pub fn step(self: *PreparedStmt) !StepResult {
        const result = sqlite.c.sqlite3_step(self.stmt);
        switch (result) {
            sqlite.c.SQLITE_ROW => return .row,
            sqlite.c.SQLITE_DONE => return .done,
            sqlite.c.SQLITE_BUSY => return error.DatabaseBusy,
            sqlite.c.SQLITE_CONSTRAINT => return error.ConstraintViolation,
            sqlite.c.SQLITE_ERROR => return error.SqliteError,
            else => return error.StepFailed,
        }
    }

    pub fn reset(self: *PreparedStmt) void {
        _ = sqlite.c.sqlite3_reset(self.stmt);
        _ = sqlite.c.sqlite3_clear_bindings(self.stmt);
    }

    pub fn finalize(self: *PreparedStmt) void {
        _ = sqlite.c.sqlite3_finalize(self.stmt);
    }

    pub fn bindText(self: *PreparedStmt, index: usize, value: []const u8) void {
        _ = sqlite.c.sqlite3_bind_text(self.stmt, @intCast(index), value.ptr, @intCast(value.len), null);
    }

    pub fn bindInt64(self: *PreparedStmt, index: usize, value: i64) void {
        _ = sqlite.c.sqlite3_bind_int64(self.stmt, @intCast(index), value);
    }

    pub fn bindNull(self: *PreparedStmt, index: usize) void {
        _ = sqlite.c.sqlite3_bind_null(self.stmt, @intCast(index));
    }

    pub fn columnText(self: *PreparedStmt, index: usize) ?[]const u8 {
        const text = sqlite.c.sqlite3_column_text(self.stmt, @intCast(index));
        if (text == null) return null;
        const bytes = sqlite.c.sqlite3_column_bytes(self.stmt, @intCast(index));
        return text[0..@intCast(bytes)];
    }

    pub fn columnInt64(self: *PreparedStmt, index: usize) i64 {
        return sqlite.c.sqlite3_column_int64(self.stmt, @intCast(index));
    }

    /// Read an INTEGER column, returning null if the SQL value is NULL.
    pub fn columnInt64Safe(self: *PreparedStmt, index: usize) ?i64 {
        if (sqlite.c.sqlite3_column_type(self.stmt, @intCast(index)) == sqlite.c.SQLITE_NULL) return null;
        return sqlite.c.sqlite3_column_int64(self.stmt, @intCast(index));
    }
};

test "database connection in-memory" {
    const testing = std.testing;
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    try conn.migrate();
    try testing.expect(conn.db != null);
}
