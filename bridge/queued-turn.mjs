// Queue acknowledgement is not completion. Follow the exact user-message ID
// into persisted turns, using read-only pagination (no second writer).
export async function withFreshReader(createReader, read) {
  const reader = createReader();
  try {
    return await read((method, params) => reader.request(method, params, { timeoutMs: 8000 }));
  } finally {
    reader.dispose();
  }
}

export async function readQueuedTurn(request, threadId, submission) {
  let cursor;
  do {
    const page = await request("thread/queue/list", { threadId, limit: 100, cursor });
    if (!Array.isArray(page?.data)) throw new Error("Invalid queue response");
    if (page.data.some(item => item.clientUserMessageId === submission.clientUserMessageId)) {
      return { state: "waiting", title: "已排队", body: "指令已送达，等待 Codex 处理" };
    }
    cursor = page.nextCursor;
  } while (cursor);

  cursor = undefined;
  // Bound each poll. Never mistake an unrelated newer turn for this message.
  for (let pageIndex = 0; pageIndex < 5; pageIndex++) {
    const page = await request("thread/turns/list", {
      threadId, limit: 20, itemsView: "summary", sortDirection: "desc", cursor
    });
    if (!Array.isArray(page?.data)) throw new Error("Invalid turn response");
    const turn = page.data.find(turn => turn.items?.some(item =>
      item.type === "userMessage" && item.clientId === submission.clientUserMessageId));
    if (turn) return queuedTurnState(threadId, turn);
    cursor = page.nextCursor;
    if (!cursor) break;
  }
  return { state: "thinking", title: "已出队，正在同步", body: "等待 Codex 返回处理状态" };
}

export function queuedTurnState(threadId, turn) {
  const messages = (turn.items || []).filter(item => item.type === "agentMessage" && item.text);
  const text = (messages.findLast(item => item.phase === "final_answer") || messages.at(-1))?.text || "";
  if (turn.status === "completed") return {
    state: "review", title: "Codex 已回复", body: text.slice(0, 240) || "任务已完成", text,
    event: "task-complete", eventID: `turn:${threadId}:${turn.id}:complete`, done: true
  };
  if (turn.status === "failed") return {
    state: "failed", title: "任务失败", body: turn.error?.message || "请查看 Codex 中的错误详情",
    event: "task-failed", eventID: `turn:${threadId}:${turn.id}:failed`, done: true
  };
  // A separate read-only app-server can label a live desktop turn interrupted;
  // do not turn that persisted snapshot into a false failure notification.
  return { state: "thinking", title: "Codex 正在处理", body: text.slice(0, 240) || "指令已接收，等待回复", text };
}
