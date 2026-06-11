// Test root — imports every module containing test blocks so
// those tests are compiled and run by `zig build test`.
const std = @import("std");

// Domain layer
const _lifecycle = @import("domain/lifecycle.zig");
const _entities = @import("domain/entities.zig");
const _errors = @import("domain/errors.zig");
const _dependencies = @import("domain/dependencies.zig");
const _progress = @import("domain/progress.zig");
const _domain_assignment = @import("domain/assignment.zig");

// DB layer
const _connection = @import("db/connection.zig");
const _schema = @import("db/schema.zig");
const _projects = @import("db/queries/projects.zig");
const _epics = @import("db/queries/epics.zig");
const _stories = @import("db/queries/stories.zig");
const _tasks = @import("db/queries/tasks.zig");
const _subtasks = @import("db/queries/subtasks.zig");
const _wiki = @import("db/queries/wiki.zig");
const _agents = @import("db/queries/agents.zig");
const _deps = @import("db/queries/dependencies.zig");

// MCP layer
const _mcp_types = @import("mcp/types.zig");
const _mcp_json = @import("mcp/json.zig");
const _mcp_server = @import("mcp/server.zig");

// Service layer
const _svc_root = @import("service/root.zig");
const _svc_transition = @import("service/transition.zig");
const _svc_project = @import("service/project.zig");
const _svc_dashboard = @import("service/dashboard.zig");
const _svc_assignment = @import("service/assignment.zig");

// HTTP layer
const _http_server = @import("http/server.zig");

// Error catalog
const _error_catalog = @import("error.zig");

// MCP server integration tests
const _test_mcp_server = @import("test_mcp_server.zig");
