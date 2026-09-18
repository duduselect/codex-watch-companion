import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const dir = path.join(os.homedir(), "Library/Application Support/CodexWatchRemote");
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
const status = JSON.parse(execFileSync("/Applications/Tailscale.app/Contents/MacOS/Tailscale", ["status", "--json"], { encoding: "utf8" }));
const host = status.Self?.DNSName?.replace(/\.$/, "");
if (status.BackendState !== "Running" || !host?.endsWith(".ts.net")) throw new Error("Tailscale not ready");
const registry = path.join(dir, "devices.json");
const provision = path.join(dir, "remote-connection.json");
if (fs.existsSync(registry) || fs.existsSync(provision)) throw new Error("Existing credentials preserved; use an explicit rotation workflow");
const token = crypto.randomBytes(32).toString("base64url");
fs.writeFileSync(provision, JSON.stringify({ url: `https://${host}/codex-watch`, token }), { mode: 0o600, flag: "wx" });
fs.writeFileSync(registry, JSON.stringify({ devices: [{ id: "personal-watch", sha256: crypto.createHash("sha256").update(token).digest("hex") }] }), { mode: 0o600, flag: "wx" });
console.log("Created private credential registry and device provisioning file; no secrets printed.");
