import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRemoteGateway, deviceAuthenticator } from "../../bridge/remote-gateway.mjs";

test("remote gateway authenticates before forwarding, isolates sessions and rejects injection", async t => {
  const calls = [];
  const backend = http.createServer((req, res) => {
    calls.push({ url: req.url, authorization: req.headers.authorization });
    req.resume();
    res.end('{"ok":true,"messages":[]}');
  });
  await new Promise(resolve => backend.listen(0, "127.0.0.1", resolve));
  const gateway = createRemoteGateway({
    authenticate: value => value === "Bearer test-a" ? "device-a" : value === "Bearer test-b" ? "device-b" : null,
    upstream: `http://127.0.0.1:${backend.address().port}`
  });
  await new Promise(resolve => gateway.listen(0, "127.0.0.1", resolve));
  t.after(() => { gateway.closeAllConnections(); gateway.close(); backend.closeAllConnections(); backend.close(); });
  const base = `http://127.0.0.1:${gateway.address().port}`;
  assert.equal((await fetch(base + "/codex-watch/poll?client=same")).status, 401);
  assert.equal(calls.length, 0);
  for (const credential of ["test-a", "test-b"]) {
    assert.equal((await fetch(base + "/codex-watch/poll?client=same", { headers: { Authorization: `Bearer ${credential}` } })).status, 200);
  }
  assert.notEqual(calls[0].url, calls[1].url);
  assert.equal(calls[0].authorization, undefined);
  const headers = { Authorization: "Bearer test-a", "Content-Type": "application/json" };
  assert.equal((await fetch(base + "/codex-watch/message?client=same", { method: "POST", headers, body: '{"type":"state","state":"review"}' })).status, 403);
  assert.equal((await fetch(base + "/codex-watch/poll?client=same", { headers: { ...headers, Origin: "https://example.com" } })).status, 403);
  assert.equal(calls.length, 2);
  assert.equal((await fetch(base + "/codex-watch/message?client=same", { method: "POST", headers, body: '{"type":"hello"}' })).status, 200);
  assert.equal((await fetch(base + "/codex-watch/message?client=same", { method: "POST", headers, body: '{"type":"voice-wait","requestID":"background-123"}' })).status, 200);
  assert.equal((await fetch(base + "/codex-watch/message?client=same", { method: "POST", headers: { "Content-Type": "application/json" }, body: '{"type":"voice-wait","requestID":"background-123"}' })).status, 401);
});

test("credential hashes, immediate revocation, and registry failure are fail-closed", t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "watch-auth-test-"));
  const registry = path.join(dir, "devices.json");
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const token = crypto.randomBytes(32).toString("base64url");
  const device = { id: "watch", sha256: crypto.createHash("sha256").update(token).digest("hex") };
  fs.writeFileSync(registry, JSON.stringify({ devices: [device] }), { mode: 0o600 });
  const authenticate = deviceAuthenticator(registry);
  assert.equal(authenticate(`Bearer ${token}`), "watch");
  assert.equal(authenticate("Bearer incorrect"), null);
  fs.writeFileSync(registry, JSON.stringify({ devices: [{ ...device, revoked: true }] }));
  assert.equal(authenticate(`Bearer ${token}`), null);
  fs.chmodSync(registry, 0o644);
  assert.throws(() => authenticate(`Bearer ${token}`));
});
