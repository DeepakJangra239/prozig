// Prozig — Web Dashboard
const API = '/api';
let currentProject = null;
let currentView = 'dashboard';
let projects = [];
let epics = [];
let stories = [];
let wikiPages = [];
let agents = [];
let agentsMap = {};
const SEVERITY_LABELS = { critical: 'Critical', high: 'High', medium: 'Medium', low: 'Low' };
const SEVERITY_COLORS = { critical: '#ef4444', high: '#f97316', medium: '#eab308', low: '#6b7280' };
let modalCallback = null;

// Restore persisted state from localStorage
try {
  const savedProject = localStorage.getItem('prozig_project');
  if (savedProject) currentProject = Number(savedProject);
  const savedView = localStorage.getItem('prozig_view');
  if (savedView) currentView = savedView;
} catch {}

function formatDate(iso) {
  if (!iso) return '';
  try { return new Date(iso).toLocaleString(); } catch { return iso; }
}

// ─── Simple Markdown Renderer ───
function renderMarkdown(md) {
  if (!md) return '';
  let html = esc(md);
  // Code blocks (``` ... ```)
  html = html.replace(/```([\s\S]*?)```/g, '<pre><code>$1</code></pre>');
  // Inline code (`code`)
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  // Headers
  html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
  html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
  html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');
  // Bold and Italic
  html = html.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>');
  html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');
  // Links
  html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  // Unordered lists
  html = html.replace(/^- (.+)$/gm, '<li>$1</li>');
  html = html.replace(/(<li>.*<\/li>)/s, '<ul>$1</ul>');
  // Paragraphs (double newlines)
  html = html.replace(/\n\n/g, '</p><p>');
  html = '<p>' + html + '</p>';
  // Clean up empty paragraphs
  html = html.replace(/<p>\s*<\/p>/g, '');
  html = html.replace(/<p>\s*(<h[1-6]>)/g, '$1');
  html = html.replace(/(<\/h[1-6]>)\s*<\/p>/g, '$1');
  html = html.replace(/<p>\s*(<ul>)/g, '$1');
  html = html.replace(/(<\/ul>)\s*<\/p>/g, '$1');
  html = html.replace(/<p>\s*(<pre>)/g, '$1');
  html = html.replace(/(<\/pre>)\s*<\/p>/g, '$1');
  return html;
}

// ─── Inline Markdown Renderer (for comments, memory entries) ───
function renderCommentMarkdown(md) {
  if (!md) return '';
  let html = esc(md);
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/\*([^*]+)\*/g, '<em>$1</em>');
  html = html.replace(/@(\w+)/g, '<span class="mention">@$1</span>');
  html = html.replace(/\n/g, '<br>');
  return html;
}

// ─── DOM Helpers ───
const $ = s => document.querySelector(s);
const $$ = s => document.querySelectorAll(s);

// ─── Loading Overlay ───
function showLoading() {
  hideLoading();
  const overlay = document.createElement('div');
  overlay.id = 'loading-overlay';
  overlay.className = 'loading-overlay';
  overlay.innerHTML = '<div class="loading-spinner"></div>';
  document.body.appendChild(overlay);
}
function hideLoading() {
  const existing = $('#loading-overlay');
  if (existing) existing.remove();
}

function esc(s) {
  if (!s) return '';
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

// ─── Sidebar Toggle ───
(() => {
  const btn = document.querySelector('[data-sidebar-toggle]');
  if (btn) {
    btn.addEventListener('click', (e) => {
      // Prevent Oat's built-in handler from conflicting
      e.stopImmediatePropagation();
      document.body.toggleAttribute('data-sidebar-open');
    });
  }
})();

// ─── API ───
async function api(path, opts = {}) {
  const res = await fetch(`${API}${path}`, {
    headers: { 'Content-Type': 'application/json', ...opts.headers },
    ...opts,
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(body || `HTTP ${res.status}`);
  }
  const data = await res.json().catch(() => null);
  if (data && data.error) throw new Error(data.error);
  return data;
}
const apiGet = p => api(p);
const apiPost = (p, b) => api(p, { method: 'POST', body: JSON.stringify(b) });
const apiPut = (p, b) => api(p, { method: 'PUT', body: JSON.stringify(b) });
const apiDel = p => api(p, { method: 'DELETE' });

// ─── Navigation ───
function initNavigation() {
  $$('#main-nav a').forEach(link => {
    link.addEventListener('click', () => switchView(link.dataset.view));
  });
}

function switchView(view) {
  currentView = view;
  try { localStorage.setItem('prozig_view', view); } catch {}
  // Update sidebar nav active state
  $$('#main-nav a').forEach(a => {
    a.toggleAttribute('aria-current', a.dataset.view === view);
  });
  // Show the active view
  $$('.view').forEach(v => v.classList.toggle('active', v.id === view));
  // Close sidebar on mobile after navigation
  document.body.removeAttribute('data-sidebar-open');
  // Load view content
  if (view === 'dashboard') loadDashboard();
  if (view === 'board') loadBoard();
  if (view === 'roles') loadRoles();
  if (view === 'workflow') loadWorkflow();
  if (view === 'wiki') loadWiki();
  if (view === 'agents') loadAgents();
  if (view === 'memories') loadMemories();
}

// ─── Dashboard ───
async function loadDashboard() {
  try {
    const statsUrl = currentProject ? `/dashboard?project_id=${currentProject}` : '/dashboard';
    const [stats, projList] = await Promise.all([
      apiGet(statsUrl).catch(() => ({ projects: 0, epics: 0, stories: 0, tasks: 0 })),
      apiGet('/projects').catch(() => []),
    ]);
    projects = projList;
    renderStats(stats);
    renderProjectCards();
    populateProjectSelect();
  } catch (e) { console.error('Dashboard:', e); }
}

function renderStats(stats) {
  const row = $('#stats-row');
  if (!row) return;
  row.innerHTML = `
    <article class="card stat-card"><div class="stat-value">${stats.projects||0}</div><div class="stat-label">Projects</div></article>
    <article class="card stat-card"><div class="stat-value">${stats.epics||0}</div><div class="stat-label">Epics</div></article>
    <article class="card stat-card"><div class="stat-value">${stats.stories||0}</div><div class="stat-label">Stories</div></article>
    <article class="card stat-card"><div class="stat-value">${stats.tasks||0}</div><div class="stat-label">Tasks</div></article>
    <article class="card stat-card"><div class="stat-value">${stats.bugs||0}</div><div class="stat-label">Bugs</div></article>
  `;
}

function renderProjectCards() {
  const c = $('#project-cards');
  if (!c) return;
  if (!projects.length) {
    c.innerHTML = '<div class="empty-state"><p>No projects yet. Create one to get started.</p></div>';
    return;
  }
  c.innerHTML = projects.map(p => `
    <article class="card" data-project-id="${p.id}">
      <h3>${esc(p.name)}</h3>
      <p class="meta">${esc(p.root_path||'')}</p>
    </article>
  `).join('');
  c.onclick = (e) => {
    const card = e.target.closest('[data-project-id]');
    if (card) selectProject(Number(card.dataset.projectId));
  };
}

function populateProjectSelect() {
  const sel = $('#project-select');
  if (!sel) return;
  const prev = sel.value;
  sel.innerHTML = '<option value="">Select a project&hellip;</option>' +
    projects.map(p => `<option value="${p.id}">${esc(p.name)}</option>`).join('');
  sel.onchange = () => {
    currentProject = sel.value ? Number(sel.value) : null;
    try { localStorage.setItem('prozig_project', String(currentProject || '')); } catch {}
    updateSidebarContext();
    if (currentView === 'dashboard') loadDashboard();
    if (currentView === 'board') loadBoard();
    if (currentView === 'wiki') loadWiki();
    if (currentView === 'roles') loadRoles();
    if (currentView === 'workflow') loadWorkflow();
    if (currentView === 'agents') loadAgents();
  };
  if (prev) sel.value = prev;
}

function selectProject(id) {
  currentProject = id;
  try { localStorage.setItem('prozig_project', String(id)); } catch {}
  const sel = $('#project-select');
  if (sel) sel.value = id;
  updateSidebarContext();
  switchView('board');
}

function updateSidebarContext() {
  const ctx = $('#sidebar-context');
  if (!ctx) return;
  const p = projects.find(x => x.id === currentProject);
  ctx.innerHTML = p
    ? `<div class="sidebar-context-item"><strong>${esc(p.name)}</strong>${esc(p.root_path||'')}</div>`
    : '<p style="color:var(--muted-foreground);font-size:var(--text-8)">Select a project</p>';
}

// ─── Role Manager ───
async function loadRoles() {
  const container = $('#roles-list');
  if (!container) return;
  if (!currentProject) {
    container.innerHTML = '<div class="empty-state"><p>Select a project to manage roles.</p></div>';
    return;
  }
  const p = projects.find(x => x.id === currentProject);
  const bc = $('#roles-breadcrumb');
  bc.innerHTML = `<span>${esc(p ? p.name : 'Project')}</span> <span style="color:var(--muted-foreground)">&rsaquo;</span> <strong>Roles</strong>`;
  try {
    const roles = await apiGet(`/projects/${currentProject}/roles`).catch(() => []);
    const $btn = $('#btn-new-role');
    $btn.onclick = showNewRoleForm;
    if (!roles.length) {
      container.innerHTML = '<div class="empty-state"><p>No roles defined. Create one to assign permissions.</p></div>';
      return;
    }
    container.innerHTML = roles.map(r => `
      <article class="card" onclick="showRoleDetail(${r.id})">
        <h3>${esc(r.name)}</h3>
        <p class="meta">${esc(r.description||'')}</p>
        <div style="margin-top:var(--space-2);font-size:var(--text-8);color:var(--muted-foreground)">${r.agent_count} agent(s)</div>
      </article>
    `).join('');
  } catch(e) { console.error('Roles:', e); }
}

function showNewRoleForm() {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  openModal('New Role', `
    <div data-field><label>Name *</label><input type="text" id="f-r-name" placeholder="e.g. designer" required></div>
    <div data-field><label>Description</label><textarea id="f-r-desc" rows="2" placeholder="Optional description"></textarea></div>
  `, 'Create', async () => {
    const name = $('#f-r-name').value.trim();
    if (!name) { ot.toast('Name is required', '', { variant: 'danger' }); return; }
    await apiPost(`/projects/${currentProject}/roles`, { name, description: $('#f-r-desc').value.trim()||null });
    ot.toast('Role created', '', { variant: 'success' });
    loadRoles();
  });
}

async function showRoleDetail(roleId) {
  try {
    const roles = await apiGet(`/projects/${currentProject}/roles`).catch(() => []);
    const role = roles.find(r => r.id === roleId);
    if (!role) return;
    const perms = await apiGet(`/projects/${currentProject}/roles/${roleId}/permissions`).catch(() => []);

    // Group permissions by entity_type, with section subheadings
    const entityTypes = ['epic', 'story', 'task', 'subtask', 'bug'];
    const grouped = {};
    for (const et of entityTypes) grouped[et] = [];
    for (const p of perms) {
      if (!grouped[p.entity_type]) grouped[p.entity_type] = [];
      grouped[p.entity_type].push(p);
    }
    const entityLabels = { epic: 'Epic', story: 'Story', task: 'Task', subtask: 'Subtask', bug: 'Bug' };
    const permsHtml = entityTypes
      .filter(et => grouped[et].length > 0)
      .map(et => `
        <div style="margin-top:var(--space-2)">
          <div class="section-title" style="font-size:0.85rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:var(--space-1)">${entityLabels[et]}</div>
          ${grouped[et].map(p => `
            <label class="perm-row" style="display:flex;align-items:center;gap:var(--space-2);padding:var(--space-1) 0">
              <input type="checkbox" data-tid="${p.id}" ${p.permitted?'checked':''}/>
              <span>${esc(p.from)} → ${esc(p.to)}</span>
            </label>
          `).join('')}
        </div>
      `).join('');

    openModal(`Role: ${esc(role.name)}`, `
      <div data-field><label>Name</label><input type="text" id="f-re-name" value="${esc(role.name)}"></div>
      <div data-field><label>Description</label><textarea id="f-re-desc" rows="2">${esc(role.description||'')}</textarea></div>
      <h6 class="section-title" style="margin-top:var(--space-3)">Transition Permissions</h6>
      <div style="max-height:300px;overflow-y:auto">${permsHtml}</div>
      <div style="margin-top:var(--space-2);display:flex;gap:var(--space-2)">
        <button class="small" style="color:var(--danger)" onclick="deleteRole(${roleId})">Delete Role</button>
      </div>
    `, 'Save', async () => {
      const name = $('#f-re-name').value.trim();
      if (!name) { ot.toast('Name is required', '', { variant: 'danger' }); return; }
      await apiPut(`/projects/${currentProject}/roles/${roleId}`, { name, description: $('#f-re-desc').value.trim()||null });
      // Save permission toggles
      const checkboxes = document.querySelectorAll('[data-tid]');
      for (const cb of checkboxes) {
        const tid = Number(cb.dataset.tid);
        const permitted = cb.checked;
        await apiPut(`/projects/${currentProject}/roles/${roleId}/permissions`, { transition_id: tid, permitted });
      }
      ot.toast('Role updated', '', { variant: 'success' });
      loadRoles();
    });
  } catch(e) { console.error('Role detail:', e); }
}

async function deleteRole(roleId) {
  await apiDel(`/projects/${currentProject}/roles/${roleId}`);
  closeModal();
  ot.toast('Role deleted', '', { variant: 'success' });
  loadRoles();
}

// ─── Workflow Designer ───
const ENTITY_TYPES = ['epic','story','task','subtask','bug'];
let currentWorkflowEntity = 'epic';

async function loadWorkflow() {
  if (!currentProject) {
    $('#workflow-content').innerHTML = '<div class="empty-state"><p>Select a project to configure workflows.</p></div>';
    return;
  }
  const p = projects.find(x => x.id === currentProject);
  const bc = $('#workflow-breadcrumb');
  bc.innerHTML = `<span>${esc(p ? p.name : 'Project')}</span> <span style="color:var(--muted-foreground)">&rsaquo;</span> <strong>Workflow</strong>`;
  renderWorkflowTabs();
  await loadWorkflowForEntity(currentWorkflowEntity);
}

function renderWorkflowTabs() {
  const tabs = $('#workflow-tabs');
  if (!tabs) return;
  tabs.innerHTML = ENTITY_TYPES.map(et => `
    <button class="tab${et === currentWorkflowEntity ? ' active' : ''}" data-et="${et}">${et.charAt(0).toUpperCase()+et.slice(1)}</button>
  `).join('');
  tabs.onclick = async (e) => {
    const btn = e.target.closest('.tab');
    if (!btn) return;
    currentWorkflowEntity = btn.dataset.et;
    renderWorkflowTabs();
    await loadWorkflowForEntity(currentWorkflowEntity);
  };
}

async function loadWorkflowForEntity(entityType) {
  const container = $('#workflow-content');
  if (!container) return;
  try {
    const [states, transitions] = await Promise.all([
      apiGet(`/projects/${currentProject}/workflow/states/${entityType}`).catch(() => []),
      apiGet(`/projects/${currentProject}/workflow/transitions`).catch(() => []),
    ]);
    // Build transition lookup: "from_id->to_id" => exists
    const transitionMap = {};
    transitions.forEach(t => { transitionMap[`${t.from}->${t.to}`] = true; });
    renderWorkflowEditor(container, entityType, states, transitionMap);
  } catch(e) { console.error('Workflow:', e); }
}

function renderWorkflowEditor(container, entityType, states, transitionMap) {
  let html = `<div class="view-actions" style="margin-bottom:var(--space-3)">
    <button class="small" data-variant="primary" onclick="showAddStateForm('${entityType}')">+ State</button>
  </div>`;
  // States list
  html += `<h6 class="section-title">States</h6><div class="card-grid" style="margin-bottom:var(--space-4)">`;
  states.forEach(s => {
    const catColors = {initial:'#3b82f6', active:'#eab308', terminal:'#22c55e', cancellation:'#ef4444'};
    const catColor = catColors[s.category] || '#6b7280';
    html += `<article class="card">
      <div style="display:flex;align-items:center;gap:var(--space-2)">
        <span style="width:12px;height:12px;border-radius:50%;background:${s.color||catColor};display:inline-block"></span>
        <strong>${esc(s.name)}</strong>
        <span style="font-size:var(--text-8);color:var(--muted-foreground)">#${s.position}</span>
        <span class="tag" style="background:${catColor}20;color:${catColor}">${s.category}</span>
      </div>
    </article>`;
  });
  html += `</div>`;
  // Transition matrix
  if (states.length > 1) {
    html += `<h6 class="section-title">Transitions (from \\ to)</h6>`;
    html += `<div style="overflow-x:auto"><table class="transition-matrix">`;
    html += `<tr><th></th>${states.map(s => `<th style="writing-mode:vertical-lr;padding:var(--space-1);font-size:var(--text-8)">${esc(s.name)}</th>`).join('')}</tr>`;
    states.forEach(from => {
      html += `<tr><td style="font-size:var(--text-8);padding-right:var(--space-2)"><strong>${esc(from.name)}</strong></td>`;
      states.forEach(to => {
        const key = `${from.name}->${to.name}`;
        const checked = transitionMap[key] ? 'checked' : '';
        const isSelf = from.id === to.id;
        html += `<td style="text-align:center;padding:var(--space-1)">
          <input type="checkbox" data-from-id="${from.id}" data-to-id="${to.id}" ${checked} ${isSelf?'disabled':''}/>
        </td>`;
      });
      html += `</tr>`;
    });
    html += `</table></div>`;
    html += `<div style="margin-top:var(--space-2)"><button class="small" data-variant="primary" onclick="saveWorkflowTransitions('${entityType}')">Save Transitions</button></div>`;
  }
  container.innerHTML = html;
}

function showAddStateForm(entityType) {
  openModal('Add State', `
    <div data-field><label>Name *</label><input type="text" id="f-ws-name" placeholder="e.g. Design Review" required></div>
    <div data-field><label>Category</label><select id="f-ws-cat">
      <option value="active">Active</option>
      <option value="initial">Initial</option>
      <option value="terminal">Terminal</option>
      <option value="cancellation">Cancellation</option>
    </select></div>
    <div data-field><label>Color</label><input type="color" id="f-ws-color" value="#6b7280"></div>
  `, 'Create', async () => {
    const name = $('#f-ws-name').value.trim();
    if (!name) { ot.toast('Name is required', '', { variant: 'danger' }); return; }
    await apiPost(`/projects/${currentProject}/workflow/states`, {
      entity_type: entityType,
      name,
      position: 999,
      category: $('#f-ws-cat').value,
      color: $('#f-ws-color').value,
    });
    ot.toast('State added', '', { variant: 'success' });
    await loadWorkflowForEntity(entityType);
  });
}

async function saveWorkflowTransitions(entityType) {
  const checkboxes = document.querySelectorAll('[data-from-id]');
  const changes = [];
  for (const cb of checkboxes) {
    if (cb.disabled) continue;
    changes.push({
      entity_type: entityType,
      from_state_id: Number(cb.dataset.fromId),
      to_state_id: Number(cb.dataset.toId),
      enabled: cb.checked,
    });
  }
  try {
    for (const c of changes) {
      await apiPost(`/projects/${currentProject}/workflow/transitions`, c);
    }
    ot.toast('Transitions saved', '', { variant: 'success' });
  } catch(e) { ot.toast('Error saving: '+e.message, '', { variant: 'danger' }); }
}

// ─── Board ───
const STATUS_COLUMNS = [
  { key: 'Backlog', label: 'Backlog', color: '#475569' },
  { key: 'Planned', label: 'Planned', color: '#3b82f6' },
  { key: 'In Progress', label: 'In Progress', color: '#eab308' },
  { key: 'In Review', label: 'In Review', color: '#a78bfa' },
  { key: 'In QA', label: 'In QA', color: '#22d3ee' },
  { key: 'UAT', label: 'UAT', color: '#f97316' },
  { key: 'Done', label: 'Done', color: '#22c55e' },
  { key: 'Cancelled', label: 'Cancelled', color: '#ef4444' },
];

// Reverse maps: column key → entity-specific status (for drag-drop transitions)
const COLUMN_TO_EPIC_STATUS = { 'Backlog': 'Backlog', 'Planned': 'Planned', 'In Progress': 'In Progress', 'In Review': 'In Review', 'Done': 'Done', 'Cancelled': 'Cancelled' };
const COLUMN_TO_STORY_STATUS = { 'Backlog': 'Backlog', 'Planned': 'Planned', 'In Progress': 'In Progress', 'In Review': 'In Review', 'UAT': 'UAT', 'Done': 'Done', 'Cancelled': 'Cancelled' };
const COLUMN_TO_TASK_STATUS = { 'Backlog': 'Todo', 'Planned': 'Todo', 'In Progress': 'In Progress', 'In Review': 'In Review', 'In QA': 'In QA', 'Done': 'Done', 'Cancelled': 'Cancelled' };
const COLUMN_TO_SUBTASK_STATUS = { 'Backlog': 'Todo', 'Planned': 'Todo', 'In Progress': 'In Progress', 'In Review': 'UT', 'In QA': 'UT', 'Done': 'Done', 'Cancelled': 'Cancelled' };
const COLUMN_TO_BUG_STATUS = { 'Backlog': 'New', 'Planned': 'New', 'In Progress': 'In Progress', 'In Review': 'In Review', 'Done': 'Resolved', 'Cancelled': 'Closed' };

// Bulk selection state
let selectedCards = new Set(); // Set of "type:id" strings

async function loadBoard() {
  const container = $('#board-columns');
  if (!container) return;
  if (!currentProject) {
    container.innerHTML = '<div class="empty-state"><p>Select a project to view the board.</p></div>';
    return;
  }
  showLoading();
  try {
    const p = projects.find(x => x.id === currentProject);
    const bc = $('#board-breadcrumb');
    bc.innerHTML = `<span>${esc(p ? p.name : 'Project')}</span> <span style="color:var(--muted-foreground)">&rsaquo;</span> <strong>Board</strong>`;

    epics = await apiGet(`/projects/${currentProject}/epics`).catch(() => []);
    stories = await apiGet(`/projects/${currentProject}/stories`).catch(() => []);
    const tasks = await apiGet(`/projects/${currentProject}/tasks`).catch(() => []);
    const subtasks = await apiGet(`/projects/${currentProject}/subtasks`).catch(() => []);
    const bugs = await apiGet(`/projects/${currentProject}/bugs`).catch(() => []);
    // Build agents map for assignment display
    if (!Object.keys(agentsMap).length) {
      agents = await apiGet('/agents').catch(() => []);
      agentsMap = {};
      agents.forEach(a => agentsMap[a.id] = a.name);
    }

    const savedEpicFilter = $('#board-epic-select')?.value || '';
    const savedAgentFilter = $('#board-agent-select')?.value || '';
    populateEpicSelect(epics);
    if (savedEpicFilter) $('#board-epic-select').value = savedEpicFilter;
    populateAgentSelect();
    if (savedAgentFilter) $('#board-agent-select').value = savedAgentFilter;
    renderBoard(epics, stories, tasks, subtasks, bugs);
  } catch (e) {
    console.error('Board:', e);
    container.innerHTML = '<div class="empty-state"><p>Error loading board.</p></div>';
  } finally { hideLoading(); }
}

function populateEpicSelect(epicList) {
  const sel = $('#board-epic-select');
  if (!sel) return;
  sel.innerHTML = '<option value="">All Epics</option>' +
    epicList.map(e => `<option value="${e.id}">${esc(e.title)}</option>`).join('');
  sel.onchange = () => loadBoard();
}

function populateAgentSelect() {
  const sel = $('#board-agent-select');
  if (!sel) return;
  const prev = sel.value;
  sel.innerHTML = '<option value="">All Agents</option>' +
    agents.map(a => `<option value="${a.id}">${esc(a.name)}</option>`).join('');
  sel.onchange = () => loadBoard();
  if (prev) sel.value = prev;
}

function renderBoard(epicList, stories, tasks, subtasks, bugs) {
  const container = $('#board-columns');
  if (!container) return;
  const ef = Number($('#board-epic-select')?.value) || 0;
  const af = Number($('#board-agent-select')?.value) || 0; // agent filter

  const eGroups = {}, sGroups = {}, tGroups = {}, stGroups = {}, bGroups = {};
  for (const col of STATUS_COLUMNS) {
    let colEp = ef ? epicList.filter(e => e.id === ef && e.status === col.key) : epicList.filter(e => e.status === col.key);
    if (af) colEp = colEp.filter(e => e.assignee_agent_id === af);
    eGroups[col.key] = colEp;
    let colSt = stories.filter(s => s.status === col.key);
    if (ef) colSt = colSt.filter(s => s.epic_id === ef);
    if (af) colSt = colSt.filter(s => s.assignee_agent_id === af);
    sGroups[col.key] = colSt;
    // Map task statuses to columns: Todo→Backlog, In Progress→In Progress, In Review→In Review, In QA→In QA, Done→Done, Cancelled→Cancelled
    const TASK_COLUMN_MAP = { 'Todo': 'Backlog', 'In Progress': 'In Progress', 'In Review': 'In Review', 'In QA': 'In QA', 'Done': 'Done', 'Cancelled': 'Cancelled' };
    let colTs = tasks.filter(t => TASK_COLUMN_MAP[t.status] === col.key);
    if (ef) {
      const eStoryIds = stories.filter(s => s.epic_id === ef).map(s => s.id);
      colTs = colTs.filter(t => eStoryIds.includes(t.story_id));
    }
    if (af) colTs = colTs.filter(t => t.assignee_agent_id === af);
    tGroups[col.key] = colTs;
    // Map subtask statuses to columns: Todo→Backlog, In Progress→In Progress, UT→In Review, Done→Done, Cancelled→Cancelled
    const SUBTASK_COLUMN_MAP = { 'Todo': 'Backlog', 'In Progress': 'In Progress', 'UT': 'In Review', 'Done': 'Done', 'Cancelled': 'Cancelled' };
    let colSts = subtasks.filter(st => SUBTASK_COLUMN_MAP[st.status] === col.key);
    if (ef) {
      const eStoryIds = stories.filter(s => s.epic_id === ef).map(s => s.id);
      const eTaskIds = tasks.filter(t => eStoryIds.includes(t.story_id)).map(t => t.id);
      colSts = colSts.filter(st => eTaskIds.includes(st.task_id));
    }
    if (af) colSts = colSts.filter(st => st.assignee_agent_id === af);
    stGroups[col.key] = colSts;
    // Map bug statuses to columns: New→Backlog, In Progress→In Progress, In Review→In Review, Resolved→Done, Closed→Done
    const BUG_COLUMN_MAP = { 'New': 'Backlog', 'In Progress': 'In Progress', 'In Review': 'In Review', 'Resolved': 'Done', 'Closed': 'Done' };
    let colBg = bugs.filter(b => BUG_COLUMN_MAP[b.status] === col.key);
    if (af) colBg = colBg.filter(b => b.assignee_agent_id === af);
    bGroups[col.key] = colBg;
  }

  container.innerHTML = STATUS_COLUMNS.map(col => {
    const ec = eGroups[col.key] || [];
    const sc = sGroups[col.key] || [];
    const tc = tGroups[col.key] || [];
    const stc = stGroups[col.key] || [];
    const bc = bGroups[col.key] || [];
    const total = ec.length + sc.length + tc.length + stc.length + bc.length;
    // Always show In QA and UAT columns (workflow states), hide others when empty
    const isEmpty = total === 0 && col.key !== 'In QA' && col.key !== 'UAT';
    return `
    <div class="column${isEmpty ? ' column-empty' : ''}" data-column="${col.key}">
      <div class="column-header" style="border-bottom-color:${col.color}">
        ${col.label}
        <span class="count">${total}</span>
      </div>
      ${ec.map(e => makeCard('epic', e.id, 'EPIC', e.title, e.assignee_agent_id, e.status)).join('')}
      ${sc.map(s => makeCard('story', s.id, 'STORY', s.title, s.assignee_agent_id, s.status)).join('')}
      ${tc.map(t => makeCard('task', t.id, 'TASK', t.title, t.assignee_agent_id, t.status)).join('')}
      ${stc.map(st => makeCard('subtask', st.id, 'SUBTASK', st.title, st.assignee_agent_id, st.status)).join('')}
      ${bc.map(b => makeCardBug(b.id, b.title, b.assignee_agent_id, b.severity, b.status)).join('')}
    </div>`;
  }).join('');
}

function makeCard(type, id, label, title, agentId, status) {
  const key = `${type}:${id}`;
  const checked = selectedCards.has(key) ? ' checked' : '';
  return `<div class="item-card type-${type}" draggable="true" data-card-key="${key}" data-card-type="${type}" data-card-id="${id}" data-card-status="${esc(status)}">
    <div class="card-header">
      <label class="card-checkbox" onclick="event.stopPropagation()"><input type="checkbox"${checked} data-select="${key}"/></label>
      <div class="item-type">${label}</div>
    </div>
    <div class="item-title">${esc(title)}</div>
    <div class="card-footer">
      ${agentBadge(agentId) || '<span></span>'}
      <span class="card-status">${esc(status)}</span>
    </div>
  </div>`;
}

function makeCardBug(id, title, agentId, severity, status) {
  const key = `bug:${id}`;
  const checked = selectedCards.has(key) ? ' checked' : '';
  return `<div class="item-card type-bug" draggable="true" data-card-key="${key}" data-card-type="bug" data-card-id="${id}" data-card-status="${esc(status)}">
    <div class="card-header">
      <label class="card-checkbox" onclick="event.stopPropagation()"><input type="checkbox"${checked} data-select="${key}"/></label>
      <div class="item-type">BUG</div>
    </div>
    <div class="item-title">${esc(title)} <span style="font-size:0.6rem;color:${SEVERITY_COLORS[severity]||'#6b7280'}">(${SEVERITY_LABELS[severity]||severity})</span></div>
    <div class="card-footer">
      ${agentBadge(agentId) || '<span></span>'}
      <span class="card-status">${esc(status)}</span>
    </div>
  </div>`;
}

// ─── Drag and Drop ───
function initDragDrop() {
  const container = $('#board-columns');
  if (!container) return;
  container.addEventListener('dragstart', (e) => {
    const card = e.target.closest('.item-card');
    if (!card) return;
    card.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', JSON.stringify({
      type: card.dataset.cardType, id: Number(card.dataset.cardId), status: card.dataset.cardStatus,
    }));
  });
  container.addEventListener('dragend', (e) => {
    const card = e.target.closest('.item-card');
    if (card) card.classList.remove('dragging');
    $$('.column.drop-over').forEach(c => c.classList.remove('drop-over'));
  });
  container.addEventListener('dragover', (e) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    const col = e.target.closest('.column');
    if (col) { $$('.column.drop-over').forEach(c => c.classList.remove('drop-over')); col.classList.add('drop-over'); }
  });
  container.addEventListener('dragleave', (e) => {
    const col = e.target.closest('.column');
    if (col && !col.contains(e.relatedTarget)) col.classList.remove('drop-over');
  });
  container.addEventListener('drop', (e) => {
    e.preventDefault();
    const col = e.target.closest('.column');
    if (!col) return;
    col.classList.remove('drop-over');
    let data;
    try { data = JSON.parse(e.dataTransfer.getData('text/plain')); } catch { return; }
    const colKey = col.dataset.column;
    const statusMap = { epic: COLUMN_TO_EPIC_STATUS, story: COLUMN_TO_STORY_STATUS, task: COLUMN_TO_TASK_STATUS, subtask: COLUMN_TO_SUBTASK_STATUS, bug: COLUMN_TO_BUG_STATUS };
    const targetStatus = (statusMap[data.type] || {})[colKey];
    if (!targetStatus || targetStatus === data.status) return;
    doTransition(data.type, data.id, targetStatus);
  });
}

// ─── Bulk Selection ───
function initBulkSelection() {
  const container = $('#board-columns');
  if (!container) return;
  container.addEventListener('change', (e) => {
    if (e.target.dataset.select) {
      const key = e.target.dataset.select;
      if (e.target.checked) selectedCards.add(key); else selectedCards.delete(key);
      updateBulkBar();
    }
  });
  container.addEventListener('click', (e) => {
    const card = e.target.closest('.item-card');
    if (!card || e.target.closest('.card-checkbox')) return;
    showDetail(card.dataset.cardType, Number(card.dataset.cardId));
  });
  container.addEventListener('dblclick', (e) => {
    const card = e.target.closest('.item-card');
    if (!card) return;
    const key = card.dataset.cardKey;
    const cb = card.querySelector('input[type="checkbox"]');
    if (cb) { cb.checked = !cb.checked; if (cb.checked) selectedCards.add(key); else selectedCards.delete(key); updateBulkBar(); }
  });
}

function updateBulkBar() {
  const bar = $('#bulk-bar');
  if (!bar) return;
  if (selectedCards.size === 0) { bar.classList.remove('visible'); return; }
  bar.classList.add('visible');
  const countEl = bar.querySelector('.bulk-count');
  if (countEl) countEl.textContent = selectedCards.size;
}

function columnToEntityStatus(type, colKey) {
  const maps = { epic: COLUMN_TO_EPIC_STATUS, story: COLUMN_TO_STORY_STATUS, task: COLUMN_TO_TASK_STATUS, subtask: COLUMN_TO_SUBTASK_STATUS, bug: COLUMN_TO_BUG_STATUS };
  return (maps[type] || {})[colKey] || colKey;
}

async function bulkTransition(colStatus) {
  const results = [];
  for (const key of selectedCards) {
    const [type, id] = key.split(':');
    const targetStatus = columnToEntityStatus(type, colStatus);
    try { await apiPost(`/${plural(type)}/${id}/transition`, { status: targetStatus }); results.push({ key, ok: true }); }
    catch (e) { results.push({ key, ok: false, error: e.message }); }
  }
  const ok = results.filter(r => r.ok).length;
  const fail = results.filter(r => !r.ok).length;
  ot.toast(`Transitioned ${ok} item${ok !== 1 ? 's' : ''}${fail ? `, ${fail} failed` : ''}`, '', { variant: fail > 0 ? 'warning' : 'success' });
  selectedCards.clear(); updateBulkBar(); loadBoard();
}

async function bulkDelete() {
  openModal('Confirm Bulk Delete', `<p>Delete <strong>${selectedCards.size}</strong> selected item${selectedCards.size !== 1 ? 's' : ''}?</p><p style="color:var(--danger);font-size:var(--text-8)">This action cannot be undone.</p>`, 'Delete All', async () => {
    const results = [];
    for (const key of selectedCards) { const [type, id] = key.split(':'); try { await apiDel(`/${plural(type)}/${id}`); results.push({ ok: true }); } catch { results.push({ ok: false }); } }
    const ok = results.filter(r => r.ok).length;
    ot.toast(`Deleted ${ok} item${ok !== 1 ? 's' : ''}`, '', { variant: 'success' });
    selectedCards.clear(); updateBulkBar(); loadBoard();
  });
}

// ─── Entity Detail ───
function plural(type) {
  return type === 'story' ? 'stories' : type === 'category' ? 'categories' : type + 's';
}

async function showDetail(type, id) {
  showLoading();
  try {
    const entity = await apiGet(`/${plural(type)}/${id}`);
    const dialog = $('#detail-dialog');
    $('#detail-title').textContent = entity.title || entity.name || type;
    const body = $('#detail-body');
    let html = '<div class="detail-grid">';
    html += `<div class="detail-row"><span class="label">ID</span><span class="value">${entity.id}</span></div>`;
    html += `<div class="detail-row"><span class="label">Title</span><span class="value">${esc(entity.title||'')}</span></div>`;
    html += `<div class="detail-row"><span class="label">Status</span><span class="value">${statusBadge(entity.status||'')}</span></div>`;
    if (entity.description) html += `<div class="detail-row"><span class="label">Description</span><div class="detail-md">${renderMarkdown(entity.description)}</div></div>`;
    if (entity.acceptance_criteria) html += `<div class="detail-row"><span class="label">Acceptance Criteria</span><div class="detail-ac">${renderMarkdown(entity.acceptance_criteria)}</div></div>`;
    if (entity.capabilities) html += `<div class="detail-row"><span class="label">Capabilities</span><span class="value">${esc(entity.capabilities)}</span></div>`;
    if (entity.role_name) html += `<div class="detail-row"><span class="label">Role</span><span class="value"><span class="tag" style="background:var(--primary-ghost);color:var(--primary)">${esc(entity.role_name)}</span></span></div>`;
    if (entity.severity) html += `<div class="detail-row"><span class="label">Severity</span><span class="value" style="color:${SEVERITY_COLORS[entity.severity]||'inherit'};font-weight:600">${SEVERITY_LABELS[entity.severity]||entity.severity}</span></div>`;
    if (entity.created_at) html += `<div class="detail-row"><span class="label">Created</span><span class="value">${formatDate(entity.created_at)}</span></div>`;
    if (entity.updated_at) html += `<div class="detail-row"><span class="label">Updated</span><span class="value">${formatDate(entity.updated_at)}</span></div>`;
    const transitions = { epic: ['Backlog','Planned','In Progress','In Review','Done','Cancelled'], story: ['Backlog','Planned','In Progress','In Review','In QA','UAT','Done','Cancelled'], task: ['Todo','In Progress','In Review','In QA','Done','Cancelled'], subtask: ['Todo','In Progress','UT','Done','Cancelled'], bug: ['New','In Progress','In Review','Resolved','Closed'] };
    const allowed = transitions[type] || [];
    const terminalStates = ['Done', 'Resolved', 'Closed'];
    const cancelStates = ['Cancelled', 'Closed'];
    const backwardStates = ['Backlog', 'Planned', 'Todo', 'New'];
    html += `<div class="detail-transitions"><h4>Transition Status</h4><div class="transition-btns">`;
    for (const st of allowed) {
      if (st === entity.status) continue;
      let cls = 'outline small';
      if (terminalStates.includes(st)) cls += ' btn-done';
      else if (cancelStates.includes(st) && !terminalStates.includes(st)) cls += ' btn-cancelled';
      else if (backwardStates.includes(st)) cls += ' btn-backward';
      html += `<button class="${cls}" onclick="doTransition('${type}',${entity.id},'${st}')">${st}</button>`;
    }
    if (allowed.filter(s => s !== entity.status).length === 0) html += `<span style="font-size:var(--text-8);color:var(--muted-foreground)">No other transitions available</span>`;
    html += `</div></div>`;
    // Show delete button in dialog header
    const deleteBtn = $('#detail-delete-btn');
    if (deleteBtn) {
      deleteBtn.style.display = 'inline-block';
      deleteBtn.onclick = () => confirmDelete(type, entity.id, entity.title || entity.name || type);
    }
    if (type === 'epic' && entity.id) html += await renderChildren('epic', entity.id);
    if (type === 'story' && entity.id) html += await renderChildren('story', entity.id);
    if (type === 'task' && entity.id) html += await renderChildren('task', entity.id);
    // Comments section
    html += renderCommentsSection(type, entity.id, entity.comments || []);
    html += '</div>';
    body.innerHTML = html;
    dialog.showModal();
  } catch (e) { console.error('Detail:', e); ot.toast('Error loading detail', '', { variant: 'danger' }); }
  finally { hideLoading(); }
}

function statusBadge(status) {
  const s = status || '';
  if (s === 'Done') return `<span class="badge" data-variant="success">${esc(s)}</span>`;
  if (s === 'Cancelled') return `<span class="badge" data-variant="danger">${esc(s)}</span>`;
  if (s === 'In Progress') return `<span class="badge" data-variant="warning">${esc(s)}</span>`;
  if (s === 'Backlog' || s === 'Todo') return `<span class="badge" data-variant="secondary">${esc(s)}</span>`;
  const key = s.toLowerCase().replace(/ /g, '-');
  return `<span class="badge badge-${key}">${esc(s)}</span>`;
}

function agentBadge(agentId) {
  if (!agentId) return '';
  const name = agentsMap[agentId];
  if (!name) return '';
  const initials = name.split(' ').map(w => w[0]).join('').toUpperCase().slice(0, 2);
  return `<span class="agent-badge" title="${esc(name)}">${esc(initials)}</span>`;
}

async function renderChildren(parentType, parentId) {
  try {
    if (parentType === 'epic') {
      const stories = await apiGet(`/projects/${currentProject}/stories`).catch(() => []);
      const mine = stories.filter(s => s.epic_id === parentId);
      if (!mine.length) return '';
      let h = '<div class="children-section"><h4>Stories</h4>';
      for (const s of mine) h += `<div class="child-item" onclick="showDetail('story',${s.id})"><span class="child-title">${esc(s.title)}</span>${statusBadge(s.status)}</div>`;
      h += '</div>'; return h;
    }
    if (parentType === 'story') {
      const tasks = await apiGet(`/projects/${currentProject}/tasks`).catch(() => []);
      const mine = tasks.filter(t => t.story_id === parentId);
      if (!mine.length) return '';
      let h = '<div class="children-section"><h4>Tasks</h4>';
      for (const t of mine) h += `<div class="child-item" onclick="showDetail('task',${t.id})"><span class="child-title">${esc(t.title)}</span>${statusBadge(t.status)}</div>`;
      h += `<button class="outline small" style="margin-top:var(--space-2)" onclick="showNewTaskForm(${parentId})">+ Add Task</button></div>`;
      return h;
    }
    if (parentType === 'task') {
      const subtasks = await apiGet(`/subtasks?task_id=${parentId}`).catch(() => []);
      if (!subtasks.length) return '<div class="children-section"><h4>Subtasks</h4><p style="color:var(--muted-foreground);font-size:var(--text-8)">No subtasks yet.</p><button class="outline small" onclick="showNewSubtaskForm('+parentId+')">+ Add Subtask</button></div>';
      let h = '<div class="children-section"><h4>Subtasks</h4>';
      for (const st of subtasks) h += `<div class="child-item" onclick="showDetail('subtask',${st.id})"><span class="child-title">${esc(st.title)}</span>${statusBadge(st.status)}</div>`;
      h += `<button class="outline small" style="margin-top:var(--space-2)" onclick="showNewSubtaskForm(${parentId})">+ Add Subtask</button></div>`;
      return h;
    }
    return '';
  } catch (e) { return ''; }
}

// ─── Comments ───

function renderCommentsSection(entityType, entityId, comments) {
  let h = '<div class="comments-section"><h4>Comments</h4>';
  if (comments.length > 0) {
    for (const c of comments) {
      h += `<div class="comment-card" data-comment-id="${c.id}">`;
      h += `<div class="comment-header">`;
      const authorBadge = c.author_type === 'agent'
        ? `<span class="badge" data-variant="secondary" style="font-size:var(--text-9)">agent</span>`
        : `<span class="badge" data-variant="success" style="font-size:var(--text-9)">human</span>`;
      h += `<span class="comment-author">${authorBadge} ${esc(c.author_name)}</span>`;
      h += `<span class="comment-time">${formatDate(c.created_at)}</span>`;
      h += `</div>`;
      h += `<div class="comment-content">${renderMarkdown(c.content)}</div>`;
      h += `<div class="comment-actions">`;
      h += `<button class="outline small" onclick="editComment(${c.id}, '${entityType}', ${entityId})">Edit</button>`;
      h += `<button class="outline small" style="color:var(--danger);border-color:var(--danger)" onclick="deleteComment(${c.id}, '${entityType}', ${entityId})">Delete</button>`;
      h += `</div></div>`;
    }
  } else {
    h += '<p style="color:var(--muted-foreground);font-size:var(--text-8)">No comments yet. Be the first to add one.</p>';
  }
  h += `<div class="comment-form"><textarea id="comment-input" placeholder="Add a comment... (supports markdown, @AgentName to mention)" rows="3"></textarea>`;
  h += `<div style="display:flex;justify-content:flex-end;gap:var(--space-2);margin-top:var(--space-2)">`;
  h += `<button class="primary small" onclick="addComment('${entityType}', ${entityId})">Add Comment</button>`;
  h += `</div></div></div>`;
  return h;
}

async function addComment(entityType, entityId) {
  const input = $('#comment-input');
  if (!input) return;
  const content = input.value.trim();
  if (content.length < 5) { ot.toast('Comment must be at least 5 characters', '', { variant: 'warning' }); return; }
  try {
    await apiPost('/comments', { entity_type: entityType, entity_id: entityId, content, author_name: 'Admin' });
    ot.toast('Comment added', '', { variant: 'success' });
    // Reload the detail view
    const card = document.querySelector('[data-card-type]');
    if (card) showDetail(entityType, entityId);
  } catch (e) { ot.toast('Failed to add comment: ' + e.message, '', { variant: 'danger' }); }
}

async function editComment(commentId, entityType, entityId) {
  // Fetch current comment content
  try {
    const comments = await apiGet('/comments').catch(() => []);
    const comment = comments.find(c => c.id === commentId);
    const currentContent = comment ? comment.content : '';
    openModal('Edit Comment', `
      <div data-field><label>Comment</label><textarea id="f-edit-comment" rows="4" placeholder="Edit your comment...">${esc(currentContent)}</textarea></div>
    `, 'Save', async () => {
      const newContent = $('#f-edit-comment').value.trim();
      if (newContent.length < 5) { ot.toast('Comment must be at least 5 characters', '', { variant: 'warning' }); return; }
      try {
        await apiPut(`/comments/${commentId}`, { content: newContent });
        ot.toast('Comment updated', '', { variant: 'success' });
        showDetail(entityType, entityId);
      } catch (e) { ot.toast('Failed to update comment: ' + e.message, '', { variant: 'danger' }); }
    });
  } catch (e) { ot.toast('Failed to load comment: ' + e.message, '', { variant: 'danger' }); }
}

async function deleteComment(commentId, entityType, entityId) {
  openModal('Delete Comment', `<p>Are you sure you want to delete this comment?</p><p style="color:var(--danger);font-size:var(--text-8)">This action cannot be undone.</p>`, 'Delete', async () => {
    try {
      await apiDel(`/comments/${commentId}`);
      ot.toast('Comment deleted', '', { variant: 'success' });
      showDetail(entityType, entityId);
    } catch (e) { ot.toast('Failed to delete comment: ' + e.message, '', { variant: 'danger' }); }
  });
}

async function doTransition(type, id, status) {
  showLoading();
  try {
    await apiPost(`/${plural(type)}/${id}/transition`, { status });
    ot.toast(`Transitioned to ${status}`, '', { variant: 'success' });
    $('#detail-dialog').close(); loadBoard();
  } catch (e) { ot.toast('Transition failed: ' + e.message, '', { variant: 'danger' }); }
  finally { hideLoading(); }
}

function confirmDelete(type, id, title) {
  openModal('Confirm Delete', `<p>Are you sure you want to delete <strong>${esc(title)}</strong>?</p><p style="color:var(--danger);font-size:var(--text-8)">This action cannot be undone.</p>`, 'Delete', async () => { await doDelete(type, id); });
}

async function doDelete(type, id) {
  try {
    await apiDel(`/${plural(type)}/${id}`);
    ot.toast('Deleted successfully', '', { variant: 'success' });
    $('#detail-dialog').close();
    if (currentView === 'board') loadBoard();
    if (currentView === 'dashboard') loadDashboard();
  } catch (e) { ot.toast('Delete failed: ' + e.message, '', { variant: 'danger' }); }
}

// ─── Wiki ───
async function loadWiki() {
  if (!currentProject) { $('#wiki-content').innerHTML = '<div class="empty-state"><p>Select a project to view wiki pages.</p></div>'; $('#wiki-sidebar').innerHTML = ''; return; }
  try {
    wikiPages = await apiGet(`/projects/${currentProject}/wiki`).catch(() => []);
    renderWikiSidebar();
    if (wikiPages.length) showWikiPage(wikiPages[0].id);
    else $('#wiki-content').innerHTML = '<div class="empty-state"><p>No wiki pages yet. Create one to document your project.</p></div>';
  } catch (e) { console.error('Wiki:', e); }
}

function showNewBugForm() {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  openModal('New Bug', `<div data-field><label>Title *</label><input type="text" id="f-b-title" placeholder="Bug title" required></div><div data-field><label>Severity *</label><select id="f-b-severity" required><option value="">Select severity...</option><option value="critical">Critical</option><option value="high">High</option><option value="medium">Medium</option><option value="low">Low</option></select></div><div data-field><label>Description *</label><textarea id="f-b-desc" rows="4" placeholder="Describe the bug" required></textarea></div>`, 'Create', async () => {
    const title = $('#f-b-title').value.trim();
    const severity = $('#f-b-severity').value;
    const description = $('#f-b-desc').value.trim();
    if (!title) { ot.toast('Title is required', '', { variant: 'danger' }); return; }
    if (!severity) { ot.toast('Severity is required', '', { variant: 'danger' }); return; }
    if (!description) { ot.toast('Description is required', '', { variant: 'danger' }); return; }
    await apiPost('/bugs', { project_id: currentProject, title, severity, description });
    ot.toast('Bug created', '', { variant: 'success' }); loadBoard();
  });
}

function renderWikiSidebar() {
  const sb = $('#wiki-sidebar');
  if (!sb) return;
  const cats = [...new Set(wikiPages.map(p => p.category))];
  sb.innerHTML = cats.map(c => `<div class="wiki-cat"><h4>${esc(c)}</h4>${wikiPages.filter(p => p.category === c).map(p => `<div class="wiki-item" onclick="showWikiPage(${p.id})">${esc(p.title)}</div>`).join('')}</div>`).join('');
}

async function showWikiPage(pageId) {
  try {
    const page = await apiGet(`/wiki/${pageId}`);
    const content = $('#wiki-content');
    content.innerHTML = `<div class="wiki-page"><h2>${esc(page.title)}</h2><div class="wiki-meta"><span class="badge" data-variant="secondary">${esc(page.category)}</span><span>v${page.version||1}</span></div><div class="wiki-body">${renderMarkdown(page.content||'')}</div><div class="wiki-actions"><button class="outline small" onclick="editWikiPage(${page.id})">Edit</button></div></div>`;
    renderWikiSidebar();
  } catch (e) { console.error('Wiki page:', e); }
}

async function editWikiPage(pageId) {
  try {
    const page = await apiGet(`/wiki/${pageId}`);
    openModal('Edit Wiki Page', `<div data-field><label>Content</label><textarea id="f-wiki-content" rows="10">${esc(page.content||'')}</textarea></div>`, 'Save', async () => {
      const content = $('#f-wiki-content').value;
      if (!content.trim()) { ot.toast('Content is required', '', { variant: 'danger' }); return; }
      await apiPut(`/wiki/${pageId}`, { content });
      ot.toast('Wiki page updated', '', { variant: 'success' }); showWikiPage(pageId);
    });
  } catch (e) { console.error('Edit wiki:', e); }
}

// ─── Agents ───
async function loadAgents() {
  try {
    agents = await apiGet('/agents').catch(() => []);
    // Build agent name map for badges
    agentsMap = {};
    agents.forEach(a => { agentsMap[a.id] = a.name; });
    renderAgents();
  } catch (e) { console.error('Agents:', e); }
}

function renderAgents() {
  const c = $('#agent-list');
  if (!c) return;
  if (!agents.length) { c.innerHTML = '<div class="empty-state"><p>No agent profiles. Create one to track agent capabilities.</p></div>'; return; }
  const $btn = $('#btn-new-agent');
  $btn.onclick = showNewAgentForm;
  c.innerHTML = agents.map(a => `
    <article class="card card-agent" onclick="showEditAgent(${a.id})">
      <h3>${esc(a.name)}</h3>
      <p class="meta">${esc(a.description||'')}</p>
      <div class="agent-capabilities">${(a.capabilities||'').split(',').map(c => `<span class="tag">${esc(c.trim())}</span>`).join('')}</div>
      ${a.role_name ? `<div style="margin-top:var(--space-1)"><span class="tag" style="background:var(--primary-ghost);color:var(--primary)">${esc(a.role_name)}</span></div>` : ''}
    </article>
  `).join('');
}

function showEditAgent(id) {
  const agent = agents.find(a => a.id === id);
  if (!agent) return;
  openModal('Edit Agent', `
    <div data-field><label>Name *</label><input type="text" id="f-ea-name" value="${esc(agent.name)}" required></div>
    <div data-field><label>Capabilities *</label><input type="text" id="f-ea-cap" value="${esc(agent.capabilities||'')}" placeholder="architect,coder,reviewer,qa" required></div>
    <div data-field><label>Description</label><textarea id="f-ea-desc" rows="2">${esc(agent.description||'')}</textarea></div>
    <div data-field><label>Role</label><select id="f-ea-role"><option value="">— None —</option></select></div>
  `, 'Save', async () => {
    const name = $('#f-ea-name').value.trim();
    const capabilities = $('#f-ea-cap').value.trim();
    if (!name) { ot.toast('Name is required', '', { variant: 'danger' }); return; }
    if (!capabilities) { ot.toast('Capabilities are required', '', { variant: 'danger' }); return; }
    const roleId = $('#f-ea-role').value ? Number($('#f-ea-role').value) : null;
    await apiPut(`/agents/${id}`, { name, capabilities, description: $('#f-ea-desc').value.trim()||null, role_id: roleId });
    ot.toast('Agent updated', '', { variant: 'success' });
    loadAgents();
  });
  // Populate role dropdown with current selection
  populateAgentRoleDropdown('f-ea-role', agent.role_name || '');
}

// ─── Memories ───
let memories = [];
const MEMORY_IMPORTANCE_LABELS = { 1: 'Low', 2: 'Medium', 3: 'High', 4: 'Critical' };
const MEMORY_IMPORTANCE_COLORS = { 1: '#6b7280', 2: '#eab308', 3: '#3b82f6', 4: '#ef4444' };

async function loadMemories() {
  try {
    memories = await apiGet('/memories').catch(() => []);
    renderMemories();
    setupMemoryFilters();
  } catch (e) { console.error('Memories:', e); }
}

function renderMemories() {
  const c = $('#memory-list');
  if (!c) return;
  const scopeFilter = $('#memory-scope-filter')?.value || '';
  const categoryFilter = $('#memory-category-filter')?.value || '';
  let filtered = memories;
  if (scopeFilter) filtered = filtered.filter(m => m.scope === scopeFilter);
  if (categoryFilter) filtered = filtered.filter(m => m.category === categoryFilter);
  if (!filtered.length) {
    c.innerHTML = '<div class="empty-state"><p>No memories yet. Save project decisions, patterns, and learnings here.</p></div>';
    return;
  }
  const $btn = $('#btn-new-memory');
  if ($btn) $btn.onclick = showNewMemoryForm;
  c.innerHTML = filtered.map(m => `
    <article class="card memory-card" onclick="showMemoryDetail(${m.id})">
      <div class="memory-header">
        <span class="tag scope-badge">${esc(m.scope)}</span>
        <span class="tag category-badge">${esc(m.category)}</span>
        <span class="importance-indicator" style="color:${MEMORY_IMPORTANCE_COLORS[m.importance]||'#6b7280'}">● ${MEMORY_IMPORTANCE_LABELS[m.importance]||''}</span>
      </div>
      <h3>${esc(m.title)}</h3>
      <p class="meta">${m.role_name ? `<span class="tag role-badge">${esc(m.role_name)}</span>` : '<span class="tag" style="background:var(--muted)">shared</span>'} · ${formatDate(m.created_at)}</p>
    </article>
  `).join('');
}

function setupMemoryFilters() {
  const scopeFilter = $('#memory-scope-filter');
  const categoryFilter = $('#memory-category-filter');
  if (scopeFilter) scopeFilter.onchange = renderMemories;
  if (categoryFilter) categoryFilter.onchange = renderMemories;
}

function showMemoryDetail(id) {
  const mem = memories.find(m => m.id === id);
  if (!mem) return;
  const detailBody = $('#detail-body');
  const detailTitle = $('#detail-title');
  const deleteBtn = $('#detail-delete-btn');
  detailTitle.textContent = mem.title;
  deleteBtn.style.display = 'inline-flex';
  deleteBtn.onclick = () => deleteMemory(id);
  detailBody.innerHTML = `
    <div style="display:flex;gap:var(--space-2);margin-bottom:var(--space-3);flex-wrap:wrap">
      <span class="tag scope-badge">${esc(mem.scope)}</span>
      <span class="tag category-badge">${esc(mem.category)}</span>
      <span class="importance-indicator" style="color:${MEMORY_IMPORTANCE_COLORS[mem.importance]||'#6b7280'}">● ${MEMORY_IMPORTANCE_LABELS[mem.importance]||''}</span>
      ${mem.role_name ? `<span class="tag role-badge">${esc(mem.role_name)}</span>` : '<span class="tag" style="background:var(--muted)">shared</span>'}
    </div>
    <div class="memory-content">${renderCommentMarkdown(mem.content||'')}</div>
    ${mem.summary ? `<div style="margin-top:var(--space-3);padding:var(--space-2);background:var(--muted);border-radius:var(--radius-sm)"><strong>Summary:</strong><br>${renderCommentMarkdown(mem.summary)}</div>` : ''}
    ${mem.tags ? `<div style="margin-top:var(--space-2)">${(mem.tags).split(',').map(t => `<span class="tag">${esc(t.trim())}</span>`).join('')}</div>` : ''}
    <p class="meta" style="margin-top:var(--space-3)">Created: ${formatDate(mem.created_at)} · Updated: ${formatDate(mem.updated_at)} · Accesses: ${mem.access_count||0}</p>
  `;
  $('#detail-dialog').showModal();
}

async function deleteMemory(id) {
  if (!confirm('Delete this memory?')) return;
  await apiDelete(`/memories/${id}`);
  ot.toast('Memory deleted', '', { variant: 'success' });
  loadMemories();
}

function showNewMemoryForm() {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  openModal('New Memory', `
    <div data-field><label>Scope *</label><select id="f-m-scope" required><option value="project">Project</option><option value="epic">Epic</option><option value="story">Story</option><option value="task">Task</option><option value="bug">Bug</option><option value="wiki">Wiki</option></select></div>
    <div data-field><label>Category *</label><select id="f-m-category" required><option value="decision">Decision</option><option value="blocker">Blocker</option><option value="pattern">Pattern</option><option value="outcome">Outcome</option><option value="note">Note</option><option value="learning">Learning</option></select></div>
    <div data-field><label>Title *</label><input type="text" id="f-m-title" placeholder="Memory title" required></div>
    <div data-field><label>Content *</label><textarea id="f-m-content" rows="4" placeholder="Full memory content" required></textarea></div>
    <div data-field><label>Summary</label><textarea id="f-m-summary" rows="2" placeholder="Brief summary"></textarea></div>
    <div data-field><label>Tags</label><input type="text" id="f-m-tags" placeholder="auth, jwt, security"></div>
    <div data-field><label>Importance</label><select id="f-m-importance"><option value="3">High</option><option value="1">Low</option><option value="2">Medium</option><option value="4">Critical</option></select></div>
  `, 'Save', async () => {
    const title = $('#f-m-title').value.trim();
    const content = $('#f-m-content').value.trim();
    if (!title) { ot.toast('Title is required', '', { variant: 'danger' }); return; }
    if (!content) { ot.toast('Content is required', '', { variant: 'danger' }); return; }
    await apiPost('/memories', {
      project_id: currentProject,
      scope: $('#f-m-scope').value,
      category: $('#f-m-category').value,
      title,
      content,
      summary: $('#f-m-summary').value.trim() || null,
      tags: $('#f-m-tags').value.trim() || null,
      importance: $('#f-m-importance').value,
    });
    ot.toast('Memory saved', '', { variant: 'success' });
    loadMemories();
  });
}

// ─── Modal Dialog ───
function openModal(title, html, submitLabel, callback) {
  const dialog = $('#modal-dialog');
  $('#modal-title').textContent = title;
  $('#modal-body').innerHTML = html;
  $('#modal-submit').textContent = submitLabel;
  modalCallback = callback;
  dialog.showModal();
}

function closeModal() {
  $('#modal-dialog').close();
  modalCallback = null;
}

async function handleModalSubmit() {
  if (modalCallback) {
    try {
      await modalCallback();
      closeModal();
    } catch (e) { ot.toast('Error: ' + e.message, '', { variant: 'danger' }); }
  }
}

// ─── CRUD Forms ───
function showNewProjectForm() {
  openModal('New Project', `
    <div data-field><label>Name *</label><input type="text" id="f-p-name" placeholder="My Project" required></div>
    <div data-field><label>Root Path *</label><input type="text" id="f-p-path" placeholder="/path/to/project" required></div>
    <div data-field><label>Description</label><textarea id="f-p-desc" rows="2" placeholder="Optional description"></textarea></div>
  `, 'Create', async () => {
    const name = $('#f-p-name').value.trim();
    const root_path = $('#f-p-path').value.trim();
    if (!name) { ot.toast('Name is required', '', { variant: 'danger' }); return; }
    if (!root_path) { ot.toast('Root path is required', '', { variant: 'danger' }); return; }
    await apiPost('/projects', { name, root_path, description: $('#f-p-desc').value.trim()||null });
    ot.toast('Project created', '', { variant: 'success' });
    loadDashboard();
  });
}

function showNewEpicForm() {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  openModal('New Epic', `
    <div data-field><label>Title *</label><input type="text" id="f-e-title" placeholder="Epic title" required></div>
    <div data-field><label>Description *</label><textarea id="f-e-desc" rows="3" placeholder="Describe the epic" required></textarea></div>
  `, 'Create', async () => {
    const title = $('#f-e-title').value.trim();
    const description = $('#f-e-desc').value.trim();
    if (!title) { ot.toast('Title is required', '', { variant: 'danger' }); return; }
    if (!description) { ot.toast('Description is required', '', { variant: 'danger' }); return; }
    await apiPost('/epics', { project_id: currentProject, title, description });
    ot.toast('Epic created', '', { variant: 'success' });
    loadBoard();
  });
}

function showNewStoryForm(epicId) {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  const eid = epicId || (epics.length === 1 ? epics[0].id : '');
  openModal('New Story', `
    <div data-field><label>Epic</label><select id="f-s-epic">${epics.map(e => `<option value="${e.id}" ${e.id===eid?'selected':''}>${esc(e.title)}</option>`).join('')}</select></div>
    <div data-field><label>Title *</label><input type="text" id="f-s-title" placeholder="Story title" required></div>
    <div data-field><label>Description *</label><textarea id="f-s-desc" rows="3" placeholder="Describe the story" required></textarea></div>
    <div data-field><label>Acceptance Criteria *</label><textarea id="f-s-ac" rows="4" placeholder="- AC 1&#10;- AC 2&#10;- AC 3" required></textarea></div>
  `, 'Create', async () => {
    const epic_id = Number($('#f-s-epic').value);
    const title = $('#f-s-title').value.trim();
    const description = $('#f-s-desc').value.trim();
    const ac = $('#f-s-ac').value.trim();
    if (!title) { ot.toast('Title is required', '', { variant: 'danger' }); return; }
    if (!description) { ot.toast('Description is required', '', { variant: 'danger' }); return; }
    if (!ac) { ot.toast('Acceptance criteria is required', '', { variant: 'danger' }); return; }
    await apiPost('/stories', { project_id: currentProject, epic_id, title, description, acceptance_criteria: ac });
    ot.toast('Story created', '', { variant: 'success' });
    loadBoard();
  });
}

function showNewTaskForm(storyId) {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  const storyField = storyId
    ? `<input type="hidden" id="f-t-story" value="${storyId}">`
    : `<div data-field><label>Story *</label><select id="f-t-story" required>${stories.map(s => `<option value="${s.id}">${esc(s.title)}</option>`).join('')}</select></div>`;
  openModal('New Task', `
    ${storyField}
    <div data-field><label>Title *</label><input type="text" id="f-t-title" placeholder="Task title" required></div>
    <div data-field><label>Description *</label><textarea id="f-t-desc" rows="3" placeholder="Describe the task" required></textarea></div>
  `, 'Create', async () => {
    const sid = Number($('#f-t-story').value);
    const title = $('#f-t-title').value.trim();
    const description = $('#f-t-desc').value.trim();
    if (!sid) { ot.toast('Story is required', '', { variant: 'danger' }); return; }
    if (!title) { ot.toast('Title is required', '', { variant: 'danger' }); return; }
    if (!description) { ot.toast('Description is required', '', { variant: 'danger' }); return; }
    await apiPost('/tasks', { project_id: currentProject, story_id: sid, title, description });
    ot.toast('Task created', '', { variant: 'success' });
    loadBoard();
  });
}

function showNewSubtaskForm(taskId) {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  openModal('New Subtask', `
    <div data-field><label>Title *</label><input type="text" id="f-st-title" placeholder="Subtask title" required></div>
    <div data-field><label>Description *</label><textarea id="f-st-desc" rows="3" placeholder="Describe the subtask" required></textarea></div>
  `, 'Create', async () => {
    const title = $('#f-st-title').value.trim();
    const description = $('#f-st-desc').value.trim();
    if (!title) { ot.toast('Title is required', '', { variant: 'danger' }); return; }
    if (!description) { ot.toast('Description is required', '', { variant: 'danger' }); return; }
    await apiPost('/subtasks', { project_id: currentProject, task_id: taskId, title, description });
    ot.toast('Subtask created', '', { variant: 'success' });
    loadBoard();
  });
}

function showNewWikiForm() {
  if (!currentProject) { ot.toast('Select a project first', '', { variant: 'danger' }); return; }
  openModal('New Wiki Page', `
    <div data-field><label>Title *</label><input type="text" id="f-w-title" placeholder="Page title" required></div>
    <div data-field><label>Category *</label><input type="text" id="f-w-cat" placeholder="e.g. Architecture, API, Setup" required></div>
    <div data-field><label>Content *</label><textarea id="f-w-body" rows="8" placeholder="Markdown content..." required></textarea></div>
  `, 'Create', async () => {
    const title = $('#f-w-title').value.trim();
    const category = $('#f-w-cat').value.trim();
    const content = $('#f-w-body').value.trim();
    if (!title) { ot.toast('Title is required', '', { variant: 'danger' }); return; }
    if (!category) { ot.toast('Category is required', '', { variant: 'danger' }); return; }
    if (!content) { ot.toast('Content is required', '', { variant: 'danger' }); return; }
    await apiPost('/wiki', { project_id: currentProject, category, title, content });
    ot.toast('Wiki page created', '', { variant: 'success' });
    loadWiki();
  });
}

function showNewAgentForm() {
  openModal('New Agent Profile', `
    <div data-field><label>Name *</label><input type="text" id="f-a-name" placeholder="Agent name" required></div>
    <div data-field><label>Capabilities *</label><input type="text" id="f-a-cap" placeholder="architect,coder,reviewer,qa" required></div>
    <div data-field><label>Description</label><textarea id="f-a-desc" rows="2" placeholder="Optional description"></textarea></div>
    <div data-field><label>Role</label><select id="f-a-role"><option value="">— None —</option></select></div>
  `, 'Create', async () => {
    const name = $('#f-a-name').value.trim();
    const capabilities = $('#f-a-cap').value.trim();
    if (!name) { ot.toast('Name is required', '', { variant: 'danger' }); return; }
    if (!capabilities) { ot.toast('Capabilities are required', '', { variant: 'danger' }); return; }
    const roleId = $('#f-a-role').value ? Number($('#f-a-role').value) : null;
    await apiPost('/agents', { name, capabilities, description: $('#f-a-desc').value.trim()||null, role_id: roleId });
    ot.toast('Agent created', '', { variant: 'success' });
    loadAgents();
  });
  // Populate role dropdown
  populateAgentRoleDropdown();
}

async function populateAgentRoleDropdown(selectId = 'f-a-role', selectedRoleName = null) {
  const sel = $('#' + selectId);
  if (!sel) return;
  if (!currentProject) return;
  try {
    const roles = await apiGet(`/projects/${currentProject}/roles`).catch(() => []);
    sel.innerHTML = '<option value="">— None —</option>' + roles.map(r =>
      `<option value="${r.id}"${selectedRoleName === r.name ? ' selected' : ''}>${esc(r.name)}</option>`
    ).join('');
  } catch (e) { /* roles unavailable */ }
}

// ─── Init ───
document.addEventListener('DOMContentLoaded', () => {
  initNavigation();

  $('#modal-submit').addEventListener('click', handleModalSubmit);

  $('#btn-new-project').addEventListener('click', showNewProjectForm);
  $('#btn-new-epic').addEventListener('click', showNewEpicForm);
  $('#btn-new-page').addEventListener('click', showNewWikiForm);
  $('#btn-new-agent').addEventListener('click', showNewAgentForm);
  $('#btn-new-bug').addEventListener('click', showNewBugForm);
  $('#btn-new-story').addEventListener('click', () => showNewStoryForm());
  $('#btn-new-task').addEventListener('click', () => showNewTaskForm());

  // Bulk action bar
  $('#bulk-transition').addEventListener('click', () => {
    const status = $('#bulk-status-select').value;
    if (!status) { ot.toast('Select a status', '', { variant: 'warning' }); return; }
    bulkTransition(status);
  });
  $('#bulk-delete').addEventListener('click', bulkDelete);
  $('#bulk-clear').addEventListener('click', () => {
    selectedCards.clear();
    $$('#board-columns input[type="checkbox"]').forEach(cb => cb.checked = false);
    updateBulkBar();
  });

  loadDashboard();

  // Restore persisted view after dashboard loads
  if (currentView && currentView !== 'dashboard') {
    setTimeout(() => switchView(currentView), 100);
  }

  // Initialize drag-drop and bulk selection
  initDragDrop();
  initBulkSelection();

  // Refresh board when detail dialog closes (transitions may have happened)
  $('#detail-dialog').addEventListener('close', () => {
    const deleteBtn = $('#detail-delete-btn');
    if (deleteBtn) { deleteBtn.style.display = 'none'; deleteBtn.onclick = null; }
    if (currentView === 'board') setTimeout(loadBoard, 100);
  });

  // Keyboard shortcuts
  document.addEventListener('keydown', (e) => {
    // Don't trigger shortcuts when typing in inputs
    const tag = e.target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (e.target.isContentEditable) return;

    switch (e.key) {
      case 'Escape':
        $('#detail-dialog').close();
        closeModal();
        break;
      case '1': switchView('dashboard'); break;
      case '2': switchView('board'); break;
      case '3': switchView('wiki'); break;
      case '4': switchView('agents'); break;
      case 'r':
        if (currentView === 'dashboard') loadDashboard();
        if (currentView === 'board') loadBoard();
        if (currentView === 'wiki') loadWiki();
        if (currentView === 'agents') loadAgents();
        break;
    }
  });
});
