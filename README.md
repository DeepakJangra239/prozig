# Prozig — Local-First MCP Planning Tracker

**Prozig** is a local-first MCP (Model Context Protocol) server written in **Zig 0.16.0** that acts as a planning tracker for agentic coding harnesses like [pi](https://github.com/nicepkg/pi) and [opencode](https://github.com/opencode-ai/opencode). It manages the full SDLC hierarchy: **Projects → Epics → User Stories → Tasks → SubTasks**, with a built-in Wiki for documentation and an embedded web dashboard.

```
Project
├── Epic (Backlog → Planned → In Progress → In Review → Done)
│   ├── Story (Backlog → Planned → In Progress → In Review → Done)
│   │   ├── Task (Todo → In Progress → In Review → In QA → Done)
│   │   │   └── SubTask (Todo → In Progress → UT → Done)
│   │   └── Task
│   └── Story
└── Wiki Pages (versioned, categorized)
```

## Features

- **MCP Server**: JSON-RPC 2.0 over stdio with 35+ tool handlers for full CRUD operations
- **HTTP Dashboard**: Embedded web UI on port 9181 with REST API
- **SQLite Storage**: Local-first, single-file database at `~/.prozig/tracker.db`
- **Entity Lifecycles**: Strict state machine validation per entity type
- **Dependency Tracking**: Blocker/blocked relationships with cycle detection
- **Progress Calculation**: Automatic progress rollup from SubTasks → Epics
- **Agent Profiles**: Register AI agents with capabilities for task assignment
- **Wiki**: Versioned documentation pages per project

## Quick Start

### Prerequisites

- **Zig 0.16.0** (`brew install zig@0.16` or download from [ziglang.org](https://ziglang.org/download/))
- **SQLite3** (`brew install sqlite`)
- **C library** (Xcode Command Line Tools on macOS, `build-essential` on Linux)

### Build & Run

```bash
# Clone and build
git clone <repo> && cd prozig
zig build

# Initialize the database
./zig-out/bin/prozig init

# Start MCP server (for AI agents)
./zig-out/bin/prozig mcp

# Start web dashboard
./zig-out/bin/prozig dashboard
# Opens http://127.0.0.1:9181
```

### Release Build

```bash
zig build -Doptimize=ReleaseSafe
```

## Architecture

```
prozig/
├── build.zig                  # Zig 0.16.0 build configuration
├── src/
│   ├── main.zig               # CLI entry point (mcp, dashboard, init, help)
│   ├── db/
│   │   ├── connection.zig     # SQLite connection wrapper + migrations
│   │   ├── schema.zig         # Schema migrations (v1: initial_schema)
│   │   └── queries/           # CRUD queries per entity
│   │       ├── projects.zig
│   │       ├── epics.zig
│   │       ├── stories.zig
│   │       ├── tasks.zig
│   │       ├── subtasks.zig
│   │       ├── agents.zig
│   │       ├── wiki.zig
│   │       └── dependencies.zig
│   ├── domain/
│   │   ├── entities.zig       # Entity structs + UUID generation
│   │   ├── lifecycle.zig      # State machine validation per entity
│   │   ├── dependencies.zig   # Dependency cycle detection
│   │   ├── progress.zig       # Progress calculation rollup
│   │   ├── assignment.zig     # Agent assignment logic
│   │   └── errors.zig         # Domain error types
│   ├── mcp/
│   │   ├── server.zig         # JSON-RPC 2.0 server over stdio
│   │   ├── types.zig          # Server struct + tool routing
│   │   ├── json.zig           # Custom JSON parser (Zig 0.16.0 compatible)
│   │   └── tools/             # 35+ MCP tool handlers
│   │       ├── project.zig
│   │       ├── epic.zig
│   │       ├── story.zig
│   │       ├── task.zig
│   │       ├── subtask.zig
│   │       ├── wiki.zig
│   │       ├── assignment.zig
│   │       ├── lifecycle.zig
│   │       ├── query.zig
│   │       └── config.zig
│   ├── http/
│   │   └── server.zig         # HTTP server + REST API + static file serving
│   └── ui/
│       ├── index.html         # SPA shell
│       ├── app.js             # Full SPA (Dashboard, Board, Wiki views)
│       └── styles.css         # Dark theme styles
└── docs/
    └── ZIG-0.16.0-REFERENCE.md  # Zig 0.16.0 API migration notes
```

### Layer Design

```
┌─────────────────────────────────────────┐
│           UI Layer (Web SPA)            │
│  index.html / app.js / styles.css       │
├─────────────────────────────────────────┤
│         HTTP Server Layer               │
│  REST API + Static File Serving         │
├─────────────────────────────────────────┤
│          MCP Protocol Layer             │
│  JSON-RPC 2.0 over stdio                │
├─────────────────────────────────────────┤
│          Domain Layer                   │
│  Lifecycle validation, dependencies,    │
│  progress calculation, assignment       │
├─────────────────────────────────────────┤
│         Storage Layer                   │
│  SQLite via C interop (-lsqlite3)       │
└─────────────────────────────────────────┘
```

## MCP Integration

### Using with pi

Add to your pi configuration:

```json
{
  "mcpServers": {
    "prozig": {
      "command": "./zig-out/bin/prozig",
      "args": ["mcp"]
    }
  }
}
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `project_init` | Initialize a new project |
| `project_list` | List all projects |
| `project_get` | Get project by ID |
| `epic_create` | Create an epic under a project |
| `epic_list` | List epics for a project |
| `epic_get` | Get epic by ID |
| `epic_delete` | Delete an epic |
| `story_create` | Create a story under an epic |
| `story_list` | List stories for an epic |
| `story_get` | Get story by ID |
| `story_delete` | Delete a story |
| `task_create` | Create a task under a story |
| `task_list` | List tasks for a story |
| `task_get` | Get task by ID |
| `task_delete` | Delete a task |
| `subtask_create` | Create a subtask under a task |
| `subtask_list` | List subtasks for a task |
| `subtask_get` | Get subtask by ID |
| `subtask_delete` | Delete a subtask |
| `transition_status` | Transition any entity's status |
| `assign_agent` | Assign an agent to an entity |
| `agent_register` | Register an agent profile |
| `agent_list` | List all agents |
| `wiki_create` | Create a wiki page |
| `wiki_get` | Get wiki page by ID |
| `wiki_update` | Update wiki page content |
| `wiki_list` | List wiki pages for a project |
| `dependency_add` | Add a blocker relationship |
| `dependency_list` | List dependencies |
| `progress_get` | Get progress for an entity |
| `dashboard_get` | Get dashboard stats |

### Example MCP Call

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "epic_create",
    "arguments": {
      "project_id": "my-project",
      "title": "Authentication",
      "description": "Implement auth system"
    }
  }
}
```

## REST API

The HTTP dashboard exposes a full REST API:

### Projects

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/projects` | List all projects |
| GET | `/api/projects/:id` | Get project by ID |
| POST | `/api/projects` | Create project |

### Epics

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/epics/:id` | Get epic by ID |
| GET | `/api/projects/:id/epics` | List epics for project |
| POST | `/api/epics` | Create epic |
| DELETE | `/api/epics/:id` | Delete epic |

### Stories

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/stories/:id` | Get story by ID |
| GET | `/api/projects/:id/stories` | List stories for project |
| POST | `/api/stories` | Create story |
| DELETE | `/api/stories/:id` | Delete story |

### Tasks

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/tasks/:id` | Get task by ID |
| GET | `/api/projects/:id/tasks` | List tasks for project |
| POST | `/api/tasks` | Create task |
| DELETE | `/api/tasks/:id` | Delete task |

### Wiki

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/wiki/:id` | Get wiki page |
| GET | `/api/projects/:id/wiki` | List wiki pages |
| POST | `/api/wiki` | Create wiki page |
| PUT | `/api/wiki/:id` | Update wiki page |

### Other

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/dashboard` | Dashboard stats |
| GET | `/api/health` | Health check |
| GET | `/api/agents` | List agents |
| POST | `/api/agents` | Register agent |

### Error Responses

```json
{ "error": "not_found" }
{ "error": "parent_not_found", "detail": "epic does not exist" }
{ "error": "invalid_json" }
{ "error": "missing_body" }
```

## Entity Lifecycles

Each entity type has its own valid state transitions:

### Epic / Story
`Backlog → Planned → In Progress → In Review → Done`
`→ Cancelled` (from any state)

### Task
`Todo → In Progress → In Review → In QA → Done`
`→ Cancelled` (from any state)

### SubTask
`Todo → In Progress → UT → Done`
`→ Cancelled` (from any state)

Invalid transitions are rejected with an error.

## Database

- **Location**: `~/.prozig/tracker.db`
- **Engine**: SQLite3 with WAL mode
- **Schema**: Auto-migrated on first run
- **Foreign Keys**: Enforced (parent must exist before child)

## Configuration

| Flag | Description | Default |
|------|-------------|---------|
| `--port <N>` | Dashboard port | `9181` |

## Development

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe

# Run tests (when available)
zig build test
```

### Zig 0.16.0 Notes

This project targets Zig 0.16.0 which has significant breaking changes from 0.13:
- `std.ArrayList` → `std.array_list.Managed`
- `std.json.Scanner` tokens renamed (`.null_literal` → `.null`)
- `std.os.getenv` → `std.process.Environ.getPosix`
- `std.net` → `std.Io.net`
- HTTP method enums are uppercase (`.GET`, `.POST`)

See `docs/ZIG-0.16.0-REFERENCE.md` for full migration notes.

## Tech Stack

| Component | Technology | License |
|-----------|-----------|---------|
| Language | Zig 0.16.0 | MIT / Apache 2.0 |
| Database | SQLite3 | Public Domain |
| Protocol | JSON-RPC 2.0 over stdio | — |
| Frontend | Vanilla JS + CSS (no framework) | — |

See [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) for full dependency license details.

## License

MIT — see [LICENSE](LICENSE) for full text.
