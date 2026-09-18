import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createPrivateNotifier } from "../../bridge/private-notifier.mjs";

test("generic notification hides task data, deduplicates and survives restart", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "watch-notify-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const configPath = path.join(dir, "config.json");
  const journalPath = path.join(dir, "journal.json");
  const calls = [];
  const options = { configPath, journalPath, fetchImpl: async (url, request) => {
    calls.push({ url, request }); return { ok: true, json: async () => ({ code: 200 }) };
  } };
  const notify = createPrivateNotifier(options);
  const message = { event: "task-complete", eventID: "private-task-id", body: "secret reply", title: "secret project", text: "token" };
  assert.equal(await notify(message), false);
  fs.writeFileSync(configPath, JSON.stringify({ enabled: true, deviceKey: "test-device-key", language: "zh-Hans" }), { mode: 0o600 });
  assert.equal(await notify({ event: "thinking", eventID: "live" }), false);
  await Promise.all([notify(message), notify(message)]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.day.app/push");
  assert.equal(calls[0].request.redirect, "error");
  assert.deepEqual(JSON.parse(calls[0].request.body), { device_key: "test-device-key", title: "Codex", body: "Codex 有新回复，请打开手表 Codex 查看。", level: "active", isArchive: "1" });
  assert.equal(await createPrivateNotifier(options)(message), false);
  fs.chmodSync(configPath, 0o644);
  assert.equal(await notify({ ...message, eventID: "second" }), false);
  assert.equal(calls.length, 1);
});

test("private notifications fall back to English for unsupported languages", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "watch-notify-en-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const configPath = path.join(dir, "config.json");
  const calls = [];
  fs.writeFileSync(configPath, JSON.stringify({ enabled: true, deviceKey: "test-device-key", language: "it" }), { mode: 0o600 });
  const notify = createPrivateNotifier({
    configPath,
    journalPath: path.join(dir, "journal.json"),
    fetchImpl: async (_url, request) => {
      calls.push(JSON.parse(request.body));
      return { ok: true, json: async () => ({ code: 200 }) };
    }
  });
  assert.equal(await notify({ event: "task-complete", eventID: "english-fallback" }), true);
  assert.equal(calls[0].body, "Codex has a new reply. Open Codex on Apple Watch to view it.");
});
