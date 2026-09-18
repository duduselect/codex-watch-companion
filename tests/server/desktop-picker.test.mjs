import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { desktopPickerItems, loadDesktopPickerItems } from "../../bridge/desktop-picker.mjs";

const state = {
  "local-projects": {
    old: { id: "old", name: "市场监控", rootPaths: ["/tmp/AI AGENT"] },
    cloud: { id: "g-p-cloud", name: "Cloud", rootPaths: ["/tmp/cloud"] }
  },
  "app-server-project-id-by-legacy-project-id-by-host": { local: { old: "new-id" } }
};

test("desktop project names and migrated memberships match the sidebar", () => {
  const items = desktopPickerItems([{ id: "t1", cwd: "/tmp/worktree", name: "用户重命名的任务", project_id: "new-id" }], state);
  assert.equal(items.length, 2);
  assert.equal(items[0].title, "市场监控");
  assert.equal(items[1].title, "用户重命名的任务");
  assert.equal(items[1].project, items[0].project);
});

test("projectless tasks do not create fake sidebar projects", () => {
  const items = desktopPickerItems([{ id: "t1", cwd: "/tmp/generated-slug", name: "真实任务名", project_id: null }], {});
  assert.equal(items.length, 1);
  assert.equal(items[0].kind, "chat");
  assert.equal(items[0].title, "真实任务名");
  assert.equal(items[0].project, "project:/tmp/generated-slug");
});

test("absent desktop database permits legacy compatibility", () => {
  assert.equal(loadDesktopPickerItems("/no-such-codex-watch-fixture"), null);
});

test("read-only index uses renamed tasks and excludes archived or subagent records", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "watch-index-test-"));
  try {
    const db = path.join(dir, "state_5.sqlite");
    execFileSync("/usr/bin/sqlite3", [db, `
      CREATE TABLE threads(id,cwd,name,title,updated_at,project_id,is_pinned,archived,source,recency_at_ms);
      INSERT INTO threads VALUES('t1','/tmp/demo','Renamed','Original prompt',1,NULL,0,0,'vscode',1);
      INSERT INTO threads VALUES('t2','/tmp/demo','Archived','Prompt',1,NULL,0,1,'vscode',1);
      INSERT INTO threads VALUES('t3','/tmp/demo','Worker','Prompt',1,NULL,0,0,'subagent',1);
    `]);
    const items = loadDesktopPickerItems(dir);
    assert.equal(items.length, 1);
    assert.equal(items[0].title, "Renamed");
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
