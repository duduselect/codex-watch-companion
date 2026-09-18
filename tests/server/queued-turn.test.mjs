import assert from "node:assert/strict";
import { test } from "node:test";
import { readQueuedTurn, withFreshReader } from "../../bridge/queued-turn.mjs";

test("each observation refreshes a cached active snapshot and closes its reader", async () => {
  let persistedStatus = "inProgress";
  let created = 0;
  let disposed = 0;
  const create = () => {
    created++;
    const snapshot = persistedStatus;
    return {
      request: async method => ({ data: method === "thread/queue/list" ? [] : [{
        id: "turn", status: snapshot, items: [
          { type: "userMessage", clientId: "receipt" },
          { type: "agentMessage", phase: "final_answer", text: "reply" }
        ]
      }] }),
      dispose: () => disposed++
    };
  };
  const observe = () => withFreshReader(create, request => readQueuedTurn(request, "thread", { clientUserMessageId: "receipt" }));
  assert.equal((await observe()).state, "thinking");
  persistedStatus = "completed";
  assert.equal((await observe()).event, "task-complete");
  assert.equal(created, 2);
  assert.equal(disposed, 2);
});

test("failed observation also closes the reader", async () => {
  let disposed = false;
  await assert.rejects(withFreshReader(() => ({ dispose() { disposed = true; } }), async () => { throw new Error("read failed"); }));
  assert.equal(disposed, true);
});

test("queue consumption tracks its own reply, not an unrelated completed turn", async () => {
  const submission = { clientUserMessageId: "watch-message" };
  let queued = true;
  let status = "inProgress";
  const request = async method => method === "thread/queue/list"
    ? { data: queued ? [submission] : [] }
    : { data: [
      { id: "unrelated", status: "completed", items: [] },
      { id: "watch-turn", status, items: [
        { type: "userMessage", clientId: "watch-message" },
        { type: "agentMessage", phase: "final_answer", text: "已收到手表测试" }
      ] }
    ] };
  assert.equal((await readQueuedTurn(request, "thread", submission)).state, "waiting");
  queued = false;
  assert.equal((await readQueuedTurn(request, "thread", submission)).event, undefined);
  status = "completed";
  const result = await readQueuedTurn(request, "thread", submission);
  assert.equal(result.event, "task-complete");
  assert.equal(result.eventID, "turn:thread:watch-turn:complete");
  assert.equal(result.text, "已收到手表测试");
});

test("empty queue is not by itself proof of completion", async () => {
  const result = await readQueuedTurn(async () => ({ data: [] }), "thread", { clientUserMessageId: "missing" });
  assert.equal(result.done, undefined);
  assert.equal(result.event, undefined);
  assert.equal(result.state, "thinking");
});

test("finds queued receipt beyond the first queue page", async () => {
  const receipt = { clientUserMessageId: "later" };
  const result = await readQueuedTurn(async (method, params) => {
    assert.equal(method, "thread/queue/list");
    return params.cursor ? { data: [receipt] } : { data: [], nextCursor: "page2" };
  }, "thread", receipt);
  assert.equal(result.state, "waiting");
});
