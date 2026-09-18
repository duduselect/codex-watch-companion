import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export function createVoiceJobs(directory, transcribe) {
  // Persist legacy wire fallbacks so an older installed Watch build can still
  // resume a job; current clients localize the phrases on-device.
  const active = new Set();
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  function file(owner, id) {
    if (!/^[a-zA-Z0-9-]{8,80}$/.test(id || "")) throw new Error("Invalid recording ID");
    return path.join(directory, crypto.createHash("sha256").update(owner + ":" + id).digest("hex") + ".json");
  }
  function save(p, value) {
    fs.writeFileSync(p + ".tmp", JSON.stringify(value), { mode: 0o600 });
    fs.renameSync(p + ".tmp", p);
  }
  async function run(p, record) {
    if (active.has(p) || record.result) return;
    active.add(p);
    try {
      const text = await transcribe(record.message);
      save(p, { result: { type: text.trim() ? "transcript" : "voice-empty", title: "已识别文字", text, requestID: record.message.requestID, chat: record.message.chat, project: record.message.project } });
    } catch {
      // Retain the recording. A later explicit retry can repeat transcription,
      // but this path can never submit a Codex instruction.
      save(p, { ...record, failed: true });
    } finally { active.delete(p); }
  }
  for (const name of fs.readdirSync(directory)) {
    if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
    const p = path.join(directory, name);
    try {
      const record = JSON.parse(fs.readFileSync(p, "utf8"));
      if (record.message && !record.result && !record.failed) void run(p, record);
    } catch {}
  }
  const store = {
    async wait(owner, message, timeoutMs = 25000) {
      const deadline = Date.now() + Math.min(25000, Math.max(0, timeoutMs));
      let result = store.handle(owner, message);
      while (result.type === "voice-pending" && Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, Math.min(100, deadline - Date.now())));
        result = store.handle(owner, { type: "voice-result", requestID: message.requestID });
      }
      return result;
    },
    handle(owner, message) {
      const p = file(owner, message.requestID);
      let record;
      try { record = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { if (e.code !== "ENOENT") throw e; }
      if (!record && message.type === "voice-job") {
        if (!message.data || message.encoding !== "pcm-f32le" || ![16000,24000,44100,48000].includes(message.sampleRate) || message.channels !== 1) throw new Error("Invalid recording format");
        record = { message };
        save(p, record);
      }
      if (!record) return { type: "voice-missing", requestID: message.requestID };
      if (record.result) return record.result;
      if (record.failed && message.type === "voice-job") {
        delete record.failed;
        save(p, record);
      }
      if (record.failed) return { type: "voice-failed", requestID: message.requestID, body: "录音已保存，转写暂未成功，请点击恢复转写。" };
      void run(p, record);
      return { type: "voice-pending", requestID: message.requestID };
    }
  };
  return store;
}
