/// Latest schema version
pub const LATEST_VERSION: u32 = 5;

/// A single migration
pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
};

/// All migrations in order
pub const migrations: []const Migration = &.{
    .{
        .version = 1,
        .name = "initial_schema",
        .sql = initialSchema,
    },
    .{
        .version = 2,
        .name = "bugs_table",
        .sql = bugsTable,
    },
    .{
        .version = 3,
        .name = "project_config_table",
        .sql = projectConfigTable,
    },
    .{
        .version = 4,
        .name = "workflow_tables",
        .sql = workflowSchema,
    },
    .{
        .version = 5,
        .name = "comments_table",
        .sql = commentsTable,
    },
};

const initialSchema =
    \\CREATE TABLE IF NOT EXISTS projects (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    root_path TEXT NOT NULL,
    \\    description TEXT,
    \\    metadata TEXT,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now'))
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS agent_profiles (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    capabilities TEXT NOT NULL,
    \\    description TEXT,
    \\    metadata TEXT,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now'))
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS epics (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    title TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'Backlog',
    \\    priority INTEGER DEFAULT 3,
    \\    assignee_agent_id INTEGER,
    \\    parent_epic_id INTEGER,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (assignee_agent_id) REFERENCES agent_profiles(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS stories (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    epic_id INTEGER NOT NULL,
    \\    title TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    acceptance_criteria TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'Backlog',
    \\    priority INTEGER DEFAULT 3,
    \\    assignee_agent_id INTEGER,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (epic_id) REFERENCES epics(id),
    \\    FOREIGN KEY (assignee_agent_id) REFERENCES agent_profiles(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS tasks (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    story_id INTEGER NOT NULL,
    \\    title TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'Todo',
    \\    priority INTEGER DEFAULT 3,
    \\    assignee_agent_id INTEGER,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (story_id) REFERENCES stories(id),
    \\    FOREIGN KEY (assignee_agent_id) REFERENCES agent_profiles(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS subtasks (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    task_id INTEGER NOT NULL,
    \\    title TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'Todo',
    \\    priority INTEGER DEFAULT 3,
    \\    assignee_agent_id INTEGER,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (task_id) REFERENCES tasks(id),
    \\    FOREIGN KEY (assignee_agent_id) REFERENCES agent_profiles(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS dependencies (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    blocker_type TEXT NOT NULL,
    \\    blocker_id INTEGER NOT NULL,
    \\    blocked_type TEXT NOT NULL,
    \\    blocked_id INTEGER NOT NULL,
    \\    FOREIGN KEY (project_id) REFERENCES projects(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS wiki_pages (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    category TEXT NOT NULL,
    \\    parent_id INTEGER,
    \\    title TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    version INTEGER DEFAULT 1,
    \\    is_current INTEGER DEFAULT 1,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (parent_id) REFERENCES wiki_pages(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS wiki_history (
    \\    id INTEGER PRIMARY KEY,
    \\    page_id INTEGER NOT NULL,
    \\    content TEXT NOT NULL,
    \\    version INTEGER NOT NULL,
    \\    edited_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (page_id) REFERENCES wiki_pages(id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_epics_project ON epics(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_stories_project ON stories(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_stories_epic ON stories(epic_id);
    \\CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_tasks_story ON tasks(story_id);
    \\CREATE INDEX IF NOT EXISTS idx_subtasks_project ON subtasks(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_subtasks_task ON subtasks(task_id);
    \\CREATE INDEX IF NOT EXISTS idx_deps_project ON dependencies(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_deps_blocker ON dependencies(blocker_id, blocker_type);
    \\CREATE INDEX IF NOT EXISTS idx_deps_blocked ON dependencies(blocked_id, blocked_type);
    \\CREATE INDEX IF NOT EXISTS idx_wiki_project ON wiki_pages(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_wiki_category ON wiki_pages(category);
    \\CREATE INDEX IF NOT EXISTS idx_wiki_parent ON wiki_pages(parent_id);
;

const bugsTable =
    \\CREATE TABLE IF NOT EXISTS bugs (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    title TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    severity TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'New',
    \\    assignee_agent_id INTEGER,
    \\    epic_id INTEGER,
    \\    story_id INTEGER,
    \\    task_id INTEGER,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (assignee_agent_id) REFERENCES agent_profiles(id),
    \\    FOREIGN KEY (epic_id) REFERENCES epics(id),
    \\    FOREIGN KEY (story_id) REFERENCES stories(id),
    \\    FOREIGN KEY (task_id) REFERENCES tasks(id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_bugs_project ON bugs(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_bugs_epic ON bugs(epic_id);
    \\CREATE INDEX IF NOT EXISTS idx_bugs_story ON bugs(story_id);
    \\CREATE INDEX IF NOT EXISTS idx_bugs_task ON bugs(task_id);
;

const projectConfigTable =
    \\CREATE TABLE IF NOT EXISTS project_configs (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    key TEXT NOT NULL,
    \\    value TEXT NOT NULL DEFAULT '',
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    UNIQUE(project_id, key),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_project_configs_project ON project_configs(project_id);
;

const workflowSchema =
    \\CREATE TABLE IF NOT EXISTS workflow_states (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    entity_type TEXT NOT NULL,
    \\    name TEXT NOT NULL,
    \\    position INTEGER NOT NULL,
    \\    category TEXT NOT NULL DEFAULT 'active',
    \\    color TEXT DEFAULT '#94a3b8',
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    UNIQUE(project_id, entity_type, position),
    \\    UNIQUE(project_id, entity_type, name)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS workflow_transitions (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    entity_type TEXT NOT NULL,
    \\    from_state_id INTEGER NOT NULL,
    \\    to_state_id INTEGER NOT NULL,
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (from_state_id) REFERENCES workflow_states(id),
    \\    FOREIGN KEY (to_state_id) REFERENCES workflow_states(id),
    \\    UNIQUE(project_id, entity_type, from_state_id, to_state_id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS agent_roles (
    \\    id INTEGER PRIMARY KEY,
    \\    project_id INTEGER NOT NULL,
    \\    name TEXT NOT NULL,
    \\    description TEXT,
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    UNIQUE(project_id, name)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS role_permissions (
    \\    id INTEGER PRIMARY KEY,
    \\    role_id INTEGER NOT NULL,
    \\    transition_id INTEGER NOT NULL,
    \\    FOREIGN KEY (role_id) REFERENCES agent_roles(id) ON DELETE CASCADE,
    \\    FOREIGN KEY (transition_id) REFERENCES workflow_transitions(id) ON DELETE CASCADE,
    \\    UNIQUE(role_id, transition_id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_wf_states_project ON workflow_states(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_wf_states_entity ON workflow_states(project_id, entity_type);
    \\CREATE INDEX IF NOT EXISTS idx_wf_transitions_project ON workflow_transitions(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_agent_roles_project ON agent_roles(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_role_permissions_role ON role_permissions(role_id);
    \\CREATE INDEX IF NOT EXISTS idx_role_permissions_transition ON role_permissions(transition_id);
    \\
    \\ALTER TABLE agent_profiles ADD COLUMN role_id INTEGER REFERENCES agent_roles(id);
;

const commentsTable =
    \\CREATE TABLE IF NOT EXISTS comments (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    project_id INTEGER NOT NULL,
    \\    entity_type TEXT NOT NULL CHECK (entity_type IN ('epic','story','task','subtask','bug','wiki')),
    \\    entity_id INTEGER NOT NULL,
    \\    author_type TEXT NOT NULL CHECK (author_type IN ('agent','human')),
    \\    author_id INTEGER,
    \\    author_name TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    created_at TEXT DEFAULT (datetime('now')),
    \\    updated_at TEXT DEFAULT (datetime('now')),
    \\    FOREIGN KEY (project_id) REFERENCES projects(id),
    \\    FOREIGN KEY (author_id) REFERENCES agent_profiles(id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_comments_entity ON comments(entity_type, entity_id);
    \\CREATE INDEX IF NOT EXISTS idx_comments_project ON comments(project_id);
    \\CREATE INDEX IF NOT EXISTS idx_comments_author ON comments(author_id);
;
