import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pendingMonitorStore } from "../../bridge/pending-monitors.mjs";

test("pending task monitors survive restart without a connected watch", t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "watch-monitor-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "pending.json");
  const record = { threadId: "thread", submission: { clientUserMessageId: "message" }, selection: { chat: "thread" } };
  pendingMonitorStore(file).put(record);
  const restored = pendingMonitorStore(file);
  assert.deepEqual(restored.list(), [record]);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  restored.remove("thread:message");
  assert.deepEqual(pendingMonitorStore(file).list(), []);
});
