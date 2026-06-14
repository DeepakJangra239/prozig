const std = @import("std");

/// A catalog entry for a single application error.
/// Each entry has a machine-readable code, HTTP-like status category,
/// and a human-readable message template.
pub const ErrorCode = struct {
    /// Machine-readable error code (e.g., "VAL-001", "RES-001")
    code: []const u8,
    /// Human-readable message template
    message: []const u8,
};

/// Centralized error catalog — every error the application can produce.
pub const Errors = struct {
    // Validation errors
    pub const MISSING_FIELD = ErrorCode{ .code = "VAL-001", .message = "Missing required field" };
    pub const INVALID_FIELD = ErrorCode{ .code = "VAL-002", .message = "Invalid field value" };

    // Resource errors
    pub const NOT_FOUND = ErrorCode{ .code = "RES-001", .message = "Resource not found" };
    pub const ALREADY_EXISTS = ErrorCode{ .code = "RES-002", .message = "Resource already exists" };
    pub const DELETE_FAILED = ErrorCode{ .code = "RES-003", .message = "Failed to delete resource" };

    // Business logic errors
    pub const INVALID_STATE = ErrorCode{ .code = "BIZ-001", .message = "Invalid state transition" };
    pub const PERMISSION_DENIED = ErrorCode{ .code = "BIZ-002", .message = "Permission denied" };
    pub const NOT_IMPLEMENTED = ErrorCode{ .code = "BIZ-003", .message = "Not yet implemented" };

    // Database errors
    pub const DB_ERROR = ErrorCode{ .code = "DB-001", .message = "Database operation failed" };
    pub const DB_BUSY = ErrorCode{ .code = "DB-002", .message = "Database is busy" };

    // Memory errors
    pub const MEMORY_CAP_EXCEEDED = ErrorCode{ .code = "MEM-001", .message = "Memory cap exceeded — consolidate before saving" };
    pub const MEMORY_DUPLICATE = ErrorCode{ .code = "MEM-002", .message = "Duplicate memory entry" };
    pub const MEMORY_INVALID_SCOPE = ErrorCode{ .code = "MEM-003", .message = "Invalid memory scope" };
    pub const MEMORY_INVALID_CATEGORY = ErrorCode{ .code = "MEM-004", .message = "Invalid memory category" };
    pub const MEMORY_INVALID_IMPORTANCE = ErrorCode{ .code = "MEM-005", .message = "Invalid importance level" };
    pub const MEMORY_INVALID_ROLE = ErrorCode{ .code = "MEM-006", .message = "Invalid role name" };

    // Internal errors
    pub const INTERNAL = ErrorCode{ .code = "INT-001", .message = "Internal server error" };
    pub const UNKNOWN_TOOL = ErrorCode{ .code = "INT-002", .message = "Unknown tool name" };
};

/// Format an error message with the error code prefix.
pub fn formatError(allocator: std.mem.Allocator, code: ErrorCode, detail: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{ code.code, code.message, detail });
}
