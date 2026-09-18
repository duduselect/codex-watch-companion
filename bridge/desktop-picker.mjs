import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

// Read-only compatibility adapter for the installed desktop's local index.
// Never read full rollouts for a menu, and never write to Codex's database.
export function loadDesktopPickerItems(codexHome) {
  const database = path.join(codexHome, "state_5.sqlite");
  if (!fs.existsSync(database)) return null;
  const rows = JSON.parse(execFileSync("/usr/bin/sqlite3", ["-readonly", "-json", database,
    `SELECT id,cwd,COALESCE(NULLIF(name,''),NULLIF(title,''),id) AS name,
      updated_at,project_id,is_pinned FROM threads
      WHERE archived=0 AND source IN ('cli','vscode','appServer')
      ORDER BY recency_at_ms DESC LIMIT 1000`
  ], { encoding: "utf8", timeout: 5000, maxBuffer: 4 * 1024 * 1024 }) || "[]");
  let state = {};
  try { state = JSON.parse(fs.readFileSync(path.join(codexHome, ".codex-global-state.json"), "utf8")); }
  catch { /* Task names still work if desktop project metadata is unavailable. */ }
  return desktopPickerItems(rows, state);
}

export function desktopPickerItems(rows, state) {
  const items = [];
  const projectsByID = new Map();
  const migratedIDs = Object.assign({}, ...Object.values(state["app-server-project-id-by-legacy-project-id-by-host"] || {}));
  const labels = state["electron-workspace-root-labels"] || {};
  for (const project of Object.values(state["local-projects"] || {})) {
    if (project.id?.startsWith("g-p-")) continue; // Cloud ChatGPT projects are not local Codex projects.
    const root = project.rootPaths?.[0];
    if (!root || !path.isAbsolute(root)) continue;
    const projectIndex = items.length;
    const item = { id: `project:${root}`, project: `project:${root}`,
      title: project.name || labels[root] || path.basename(root),
      kind: "project", section: "projects", projectIndex };
    items.push(item);
    projectsByID.set(project.id, item);
    if (migratedIDs[project.id]) projectsByID.set(migratedIDs[project.id], item);
  }
  rows.forEach((row, chatIndex) => {
    if (!row.id || !row.cwd) return;
    const project = projectsByID.get(row.project_id);
    items.push({ id: row.id, chat: row.id, title: row.name || row.id,
      kind: "chat", section: row.is_pinned ? "pinned" : "chats",
      pinned: Boolean(row.is_pinned),
      project: project?.project || `project:${row.cwd}`,
      projectIndex: project?.projectIndex, chatIndex });
  });
  return items;
}
