import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createVoiceJobs } from "../../bridge/voice-jobs.mjs";

test("empty transcription is a terminal result instead of a retry loop", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "voice-empty-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  let calls = 0;
  const store = createVoiceJobs(dir, async () => { calls++; return "  "; });
  const message = { type: "voice-job", requestID: "empty-123", data: "AAAAAA==", encoding: "pcm-f32le", sampleRate: 48000, channels: 1 };
  assert.equal((await store.wait("watch", message)).type, "voice-empty");
  assert.equal(store.handle("watch", message).type, "voice-empty");
  assert.equal(calls, 1);
});

test("recording survives disconnect, duplicate upload and server restart", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "voice-jobs-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  let finish; let calls = 0;
  const store = createVoiceJobs(dir, () => { calls++; return new Promise(resolve => { finish = resolve; }); });
  const message = { type: "voice-job", requestID: "recording-123", data: "AAAAAA==", encoding: "pcm-f32le", sampleRate: 48000, channels: 1 };
  assert.equal(store.handle("watch", message).type, "voice-pending");
  store.handle("watch", message);
  assert.equal(calls, 1);
  finish("完整文字");
  await new Promise(resolve => setImmediate(resolve));
  const restored = createVoiceJobs(dir, () => assert.fail("must not retranscribe"));
  assert.equal(restored.handle("watch", { ...message, type: "voice-result" }).text, "完整文字");
  assert.equal(restored.handle("another-watch", { ...message, type: "voice-result" }).type, "voice-missing");
});

test("background response waits for persisted text without foreground polling", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "voice-wait-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  let finish; let calls = 0;
  const store = createVoiceJobs(dir, () => { calls++; return new Promise(resolve => { finish = resolve; }); });
  const message = { type: "voice-job", requestID: "background-123", data: "AAAAAA==", encoding: "pcm-f32le", sampleRate: 48000, channels: 1 };
  const response = store.wait("watch", message, 1000);
  assert.equal((await store.wait("other", { type: "voice-wait", requestID: message.requestID }, 0)).type, "voice-missing");
  assert.equal((await store.wait("watch", { type: "voice-wait", requestID: message.requestID }, 0)).type, "voice-pending");
  finish("熄屏后的文字");
  assert.equal((await response).text, "熄屏后的文字");
  assert.equal((await store.wait("watch", { type: "voice-wait", requestID: message.requestID })).text, "熄屏后的文字");
  assert.equal(calls, 1);
});

test("background failure preserves recording and never resubmits without explicit upload", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "voice-failure-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  let calls = 0;
  const store = createVoiceJobs(dir, async () => { calls++; throw new Error("offline"); });
  const message = { type: "voice-job", requestID: "failure-123", data: "AAAAAA==", encoding: "pcm-f32le", sampleRate: 48000, channels: 1 };
  assert.equal((await store.wait("watch", message)).type, "voice-failed");
  assert.equal((await store.wait("watch", { type: "voice-wait", requestID: message.requestID })).type, "voice-failed");
  assert.equal(calls, 1);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, fs.readdirSync(dir)[0]), "utf8")).message.data, message.data);
});
