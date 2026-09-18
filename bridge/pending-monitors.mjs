import fs from "node:fs";
import path from "node:path";

export function pendingMonitorStore(file) {
  const records = new Map();
  try {
    for (const record of JSON.parse(fs.readFileSync(file, "utf8"))) {
      if (typeof record.threadId === "string" && typeof record.submission?.clientUserMessageId === "string") {
        records.set(`${record.threadId}:${record.submission.clientUserMessageId}`, record);
      }
    }
  } catch (error) { if (error.code !== "ENOENT") throw error; }
  function save() {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const temp = file + ".tmp";
    fs.writeFileSync(temp, JSON.stringify([...records.values()]), { mode: 0o600 });
    fs.renameSync(temp, file);
  }
  return {
    list: () => [...records.values()],
    put(record) { records.set(`${record.threadId}:${record.submission.clientUserMessageId}`, record); save(); },
    remove(key) { records.delete(key); save(); }
  };
}
