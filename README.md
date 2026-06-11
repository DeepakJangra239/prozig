# Prozig — Local-First MCP Planning Tracker

**Prozig** is a local-first MCP (Model Context Protocol) server written in **Zig 0.16.0** that acts as a planning tracker for agentic coding harnesses like [pi](https://github.com/nicepkg/pi) and [opencode](https://github.com/opencode-ai/opencode). It manages the full SDLC hierarchy: **Projects → Epics → User Stories → Tasks → SubTasks**, with a built-in Wiki for documentation and an embedded web dashboard.

Built with the same philosophy as [OpenAI Symphony](https://github.com/openai/symphony) — let agents do the work, humans review the results. Prozig is the MCP-native tracker that agent orchestrators poll for work.

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

- **MCP Server**: JSON-RPC 2.0 over stdio with 39 tool handlers for full CRUD operations
- **HTTP Dashboard**: Embedded web UI with REST API on port 9181
- **SQLite Storage**: Local-first, single-file database at `~/.prozig/tracker.db`
- **Entity Lifecycles**: Strict state machine validation per entity type
- **Dependency Tracking**: Blocker/blocked relationships with cycle detection
- **Progress Calculation**: Automatic progress rollup from SubTasks → Epics
- **Agent Profiles**: Register AI agents with capabilities for task assignment
- **Bug Tracking**: Full bug lifecycle with severity (critical/high/medium/low) and blocker gating
- **Comments System**: Markdown comments with @-mentions on any entity, author-scoped editing
- **Roles & Permissions**: Admin, PM, architect, developer, QA roles with granular transition permissions
- **Custom Workflow Designer**: Define custom states, transitions, and colors per entity type per project
- **Wiki**: Versioned documentation pages with full history, search, and page hierarchy
- **Full-Text Search**: Search across epics, stories, tasks, bugs, and wiki
- **Entity Filtering**: Filter entities by type and/or status
- **PATCH Updates**: Partial updates on all entities — only provided fields change
- **Priority Levels**: Critical, high, medium, low on all work items
- **Seed Data**: Auto-seeds workflow config, roles, and permissions on project init

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
├── LICENSE                    # MIT license
├── THIRD_PARTY_LICENSES       # Dependency license attributions
├── src/
│   ├── main.zig               # CLI entry point (mcp, dashboard, init, help)
│   ├── error.zig              # Centralized error codes
│   ├── db/
│   │   ├── connection.zig     # SQLite connection wrapper + migrations
│   │   ├── schema.zig         # Schema migrations (v1–v5)
│   │   ├── seed.zig           # Auto-seed workflow states, roles, permissions
│   │   ├── test_helpers.zig   # Test database setup helpers
│   │   └── queries/           # CRUD queries per entity
│   │       ├── projects.zig
│   │       ├── epics.zig
│   │       ├── stories.zig
│   │       ├── tasks.zig
│   │       ├── subtasks.zig
│   │       ├── bug.zig
│   │       ├── agents.zig
│   │       ├── wiki.zig
│   │       ├── comments.zig
│   │       └── dependencies.zig
│   ├── domain/
│   │   ├── entities.zig       # Entity structs + UUID generation
│   │   ├── lifecycle.zig      # State machine validation per entity
│   │   ├── dependencies.zig   # Dependency cycle detection
│   │   ├── progress.zig       # Progress calculation rollup
│   │   ├── assignment.zig     # Agent assignment logic
│   │   ├── validation.zig     # Input validation (min lengths, required fields)
│   │   └── errors.zig         # Domain error types
│   ├── service/
│   │   ├── root.zig           # Service layer root
│   │   ├── project.zig        # Project service operations
│   │   ├── transition.zig     # Entity state transitions
│   │   ├── workflow.zig       # Workflow designer, roles, permissions
│   │   ├── dashboard.zig      # Dashboard statistics
│   │   └── assignment.zig     # Agent assignment suggestions
│   ├── mcp/
│   │   ├── server.zig         # JSON-RPC 2.0 server over stdio
│   │   ├── types.zig          # Server struct + tool routing + 39 tool definitions
│   │   ├── json.zig           # Custom JSON parser (Zig 0.16.0 compatible)
│   │   └── tools/             # MCP tool handlers
│   │       ├── project.zig
│   │       ├── epic.zig
│   │       ├── story.zig
│   │       ├── task.zig
│   │       ├── subtask.zig
│   │       ├── bug.zig
│   │       ├── wiki.zig
│   │       ├── assignment.zig
│   │       ├── lifecycle.zig
│   │       ├── query.zig
│   │       ├── dashboard.zig
│   │       ├── config.zig
│   │       └── comments.zig
│   ├── http/
│   │   └── server.zig         # HTTP server + REST API + static file serving
│   ├── ui/
│   │   ├── index.html         # SPA shell
│   │   ├── app.js             # Full SPA (Dashboard, Board, Wiki, Roles, Workflow, Agents)
│   │   └── styles.css         # Dark theme styles
│   ├── test_mcp_server.zig    # MCP server integration tests
│   └── test_root.zig          # Test root module
├── deps/
│   └── include/
│       ├── sqlite3.h          # SQLite amalgamation header (Public Domain)
│       └── sqlite3ext.h
└── goals/                     # Planning artifacts (removed from tracking)
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

All 39 tools, grouped by category:

#### Project
| Tool | Description |
|------|-------------|
| `project_init` | Initialize a new project |
| `project_list` | List all projects |
| `project_get` | Get project details |

#### Epic
| Tool | Description |
|------|-------------|
| `epic_create` | Create an epic under a project |
| `epic_get` | Get epic details |
| `epic_list` | List epics for a project |
| `epic_update` | Update an epic (PATCH semantics) |
| `epic_delete` | Delete an epic |

#### Story
| Tool | Description |
|------|-------------|
| `story_create` | Create a user story with acceptance criteria |
| `story_get` | Get story details |
| `story_list` | List stories for an epic |
| `story_update` | Update a story (PATCH semantics) |
| `story_delete` | Delete a story |

#### Task
| Tool | Description |
|------|-------------|
| `task_create` | Create a task under a story |
| `task_get` | Get task details |
| `task_list` | List tasks for a story |
| `task_update` | Update a task (PATCH semantics) |
| `task_delete` | Delete a task |

#### SubTask
| Tool | Description |
|------|-------------|
| `subtask_create` | Create a subtask under a task |
| `subtask_get` | Get subtask details |
| `subtask_list` | List subtasks for a task |
| `subtask_update` | Update a subtask (PATCH semantics) |
| `subtask_delete` | Delete a subtask |

#### Lifecycle
| Tool | Description |
|------|-------------|
| `transition_status` | Transition any entity to a new status (role-permission enforced) |

#### Bug
| Tool | Description |
|------|-------------|
| `bug_create` | Create a bug with severity (critical/high/medium/low) |
| `bug_get` | Get bug details |
| `bug_list` | List bugs for a project |
| `bug_delete` | Delete a bug |

#### Comment
| Tool | Description |
|------|-------------|
| `comment_create` | Add a markdown comment to any entity (supports @-mentions) |
| `comment_list` | List comments on an entity |
| `comment_update` | Update your own comment |
| `comment_delete` | Delete your own comment |

#### Wiki
| Tool | Description |
|------|-------------|
| `wiki_create` | Create a wiki page |
| `wiki_get` | Get a wiki page |
| `wiki_update` | Update wiki page content |
| `wiki_list` | List wiki pages for a project |
| `wiki_search` | Search wiki pages |
| `wiki_versions` | Get wiki page version history |

#### Assignment
| Tool | Description |
|------|-------------|
| `assign_work` | Assign work to an agent |
| `get_my_work` | Get work assigned to an agent |
| `suggest_assignment` | Suggest agents for a task based on capabilities |

#### Query
| Tool | Description |
|------|-------------|
| `search` | Search across epics, stories, tasks, and bugs |
| `filter` | Filter entities by type and/or status |

#### Config
| Tool | Description |
|------|-------------|
| `config_get` | Get project configuration |
| `config_set` | Set project configuration |

#### Dashboard
| Tool | Description |
|------|-------------|
| `get_dashboard` | Get project dashboard with all counts |

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
| POST | `/api/epics` | Create epic |
| DELETE | `/api/epics/:id` | Delete epic |
| POST | `/api/epics/:id/transition` | Transition epic status |
| GET | `/api/projects/:id/epics` | List epics for project |

### Stories

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/stories/:id` | Get story by ID |
| POST | `/api/stories` | Create story |
| DELETE | `/api/stories/:id` | Delete story |
| POST | `/api/stories/:id/transition` | Transition story status |
| GET | `/api/projects/:id/stories` | List stories for project |

### Tasks

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/tasks/:id` | Get task by ID |
| POST | `/api/tasks` | Create task |
| DELETE | `/api/tasks/:id` | Delete task |
| POST | `/api/tasks/:id/transition` | Transition task status |
| GET | `/api/projects/:id/tasks` | List tasks for project |

### SubTasks

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/subtasks/:id` | Get subtask by ID |
| POST | `/api/subtasks` | Create subtask |
| DELETE | `/api/subtasks/:id` | Delete subtask |
| POST | `/api/subtasks/:id/transition` | Transition subtask status |
| GET | `/api/projects/:id/subtasks` | List subtasks for project |

### Bugs

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/bugs/:id` | Get bug by ID |
| POST | `/api/bugs` | Create bug |
| DELETE | `/api/bugs/:id` | Delete bug |
| POST | `/api/bugs/:id/transition` | Transition bug status |
| GET | `/api/projects/:id/bugs` | List bugs for project |

### Wiki

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/wiki/:id` | Get wiki page |
| POST | `/api/wiki` | Create wiki page |
| PUT | `/api/wiki/:id` | Update wiki page |
| GET | `/api/projects/:id/wiki` | List wiki pages |

### Comments

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/comments/:entity_type/:entity_id` | List comments on an entity |
| POST | `/api/comments` | Create a human comment |
| PUT | `/api/comments/:id` | Update a comment |
| DELETE | `/api/comments/:id` | Delete a comment |

### Roles & Permissions

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET/POST | `/api/projects/:id/roles` | List / create roles |
| GET/PUT/DELETE | `/api/projects/:id/roles/:rid` | Get / update / delete role |
| GET/PUT | `/api/projects/:id/roles/:rid/permissions` | View / update role permissions |

### Workflow Designer

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET/POST | `/api/projects/:id/workflow/states` | List / create workflow states |
| PUT/DELETE | `/api/projects/:id/workflow/states/:sid` | Update / delete state |
| GET/POST | `/api/projects/:id/workflow/transitions` | List / toggle transitions |

### Agents

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/agents` | List all agents |
| GET | `/api/agents/:id` | Get agent details |
| POST | `/api/agents` | Register an agent |
| PUT | `/api/agents/:id` | Update agent profile |

### Other

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/dashboard` | Dashboard stats with all counts |
| GET | `/api/health` | Health check |

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
- **Migrations**: Auto-applied on first run (current schema: v5)
- **Foreign Keys**: Enforced (parent must exist before child)

### Tables

| Table | Purpose |
|-------|---------|
| `projects` | Project root entities |
| `epics` | Epics with parent project FK |
| `stories` | User stories with parent epic FK |
| `tasks` | Tasks with parent story FK |
| `subtasks` | Sub-tasks with parent task FK |
| `bugs` | Bug tracking with severity (critical/high/medium/low) |
| `comments` | Agent and human comments on any entity (markdown content) |
| `project_configs` | Key-value configuration store per project |
| `workflow_states` | Custom workflow states (name, color, category, position) |
| `workflow_transitions` | Valid from → to transitions per entity type per project |
| `agent_roles` | Role definitions (admin, architect, developer, QA, etc.) |
| `role_permissions` | Granular permission-to-transition mappings |
| `agent_profiles` | AI agent registrations with capabilities and role FK |
| `dependencies` | Blocker/blocked relationships between entities |
| `wiki_pages` | Wiki documentation pages with category and hierarchy |
| `wiki_history` | Version history snapshots for wiki pages |

## CLI Commands

| Command | Description |
|---------|-------------|
| `mcp` | Start MCP server over stdio (default, auto-starts dashboard on port 9181 in background) |
| `dashboard` | Start web dashboard on port 9181 |
| `init` | Initialize the tracker database and apply migrations |
| `help` | Show help message |
| `version` | Show version string |

| Flag | Description | Default |
|------|-------------|---------|
| `--port <N>` | Dashboard HTTP port | `9181` |

## Development

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe

# Run tests (when available)
zig build test
```

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
