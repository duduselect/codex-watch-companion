import fs from "node:fs";
import crypto from "node:crypto";

// No task names, IDs, reply text, URLs, or Codex credentials leave this module.
const bodies = {
  "task-complete": "Codex 有新回复，请打开手表 Codex 查看。",
  "task-failed": "Codex 任务需要查看，请打开手表 Codex。"
};

export function createPrivateNotifier({ configPath, journalPath, fetchImpl = fetch, report = () => {} }) {
  const pending = new Set();
  let delivered = new Set();
  try { delivered = new Set(JSON.parse(fs.readFileSync(journalPath, "utf8"))); } catch {}

  return async function notify(message) {
    if (!bodies[message.event] || !message.eventID) return false;
    const id = crypto.createHash("sha256").update(message.eventID).digest("hex");
    if (delivered.has(id) || pending.has(id)) return false;
    let config;
    try {
      const stat = fs.lstatSync(configPath);
      if (!stat.isFile() || (stat.mode & 0o077) || stat.uid !== process.getuid()) throw new Error();
      config = JSON.parse(fs.readFileSync(configPath, "utf8"));
      if (config.enabled !== true) return false;
      if (!/^[A-Za-z0-9_-]{8,256}$/.test(config.deviceKey)) throw new Error();
    } catch (error) {
      if (error.code !== "ENOENT") report("Notification configuration unavailable");
      return false;
    }
    pending.add(id);
    try {
      const response = await fetchImpl("https://api.day.app/push", {
        method: "POST", redirect: "error", signal: AbortSignal.timeout(10000),
        headers: { "Content-Type": "application/json" },
        // Match the wearer-confirmed ungrouped test. Ordinary active priority,
        // not critical/time-sensitive; system Focus settings still apply.
        body: JSON.stringify({ device_key: config.deviceKey, title: "Codex", body: bodies[message.event], level: "active", isArchive: "1" })
      });
      if (!response.ok || (await response.json()).code !== 200) throw new Error();
      delivered.add(id);
      delivered = new Set([...delivered].slice(-2048));
      fs.writeFileSync(journalPath, JSON.stringify([...delivered]), { mode: 0o600 });
      report("Generic Codex notification accepted by push service");
      return true;
    } catch {
      // Never log the request, response, URL key, or provider errors.
      report("Codex notification delivery failed");
      return false;
    } finally { pending.delete(id); }
  };
}
