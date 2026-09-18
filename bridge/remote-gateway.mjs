// Prepared security boundary. Never publish the unauthenticated LAN bridge.
import http from "node:http";
import fs from "node:fs";
import crypto from "node:crypto";

const allowedTypes = new Set([
  "hello", "picker-opened", "selection-focus", "project-selected", "chat-selected",
  "mic-start", "mic-chunk", "mic-stop", "transcript-send", "approval-response",
  "input-response", "message-read", "transcribe-again", "ping", "voice-job", "voice-result", "voice-wait"
]);

export function deviceAuthenticator(registryPath) {
  return header => {
    // Store only hashes on the Mac. Reload on every request so revocation is
    // immediate, including already-open polling sessions.
    const stat = fs.lstatSync(registryPath);
    if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) || stat.uid !== process.getuid()) {
      throw new Error("Unsafe credential registry permissions");
    }
    const devices = JSON.parse(fs.readFileSync(registryPath, "utf8")).devices;
    const match = /^Bearer ([A-Za-z0-9_-]{43,128})$/.exec(header || "");
    if (!match || !Array.isArray(devices)) return null;
    const digest = crypto.createHash("sha256").update(match[1]).digest();
    for (const device of devices) {
      if (device.revoked || !/^[a-f0-9]{64}$/.test(device.sha256 || "") || !/^[a-zA-Z0-9_-]{1,64}$/.test(device.id || "")) continue;
      if (crypto.timingSafeEqual(digest, Buffer.from(device.sha256, "hex"))) return device.id;
    }
    return null;
  };
}

export function createRemoteGateway({ authenticate, upstream = "http://127.0.0.1:17842" }) {
  const target = new URL(upstream);
  if (target.hostname !== "127.0.0.1" || target.protocol !== "http:") throw new Error("Upstream must be loopback HTTP");
  const limits = new Map();
  const server = http.createServer(async (req, res) => {
    const reply = (status, error) => {
      res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
      res.end(JSON.stringify({ ok: false, error }));
    };
    try {
      if (req.headers.origin) return reply(403, "Forbidden");
      const owner = authenticate(req.headers.authorization);
      if (!owner) return reply(401, "Unauthorized");
      const url = new URL(req.url, "http://localhost");
      const post = req.method === "POST" && url.pathname === "/codex-watch/message";
      const poll = req.method === "GET" && url.pathname === "/codex-watch/poll";
      if (!post && !poll) return reply(404, "Not found");
      if ([...url.searchParams.keys()].some(key => key !== "client")) return reply(400, "Invalid query");
      const client = url.searchParams.get("client");
      if (!client || !/^[a-zA-Z0-9._:-]{1,80}$/.test(client)) return reply(400, "Invalid client");
      const now = Date.now();
      for (const [key, value] of limits) if (now - value.start > 60000) limits.delete(key);
      const limit = limits.get(owner) || { start: now, count: 0 };
      limits.set(owner, limit);
      if (++limit.count > 240) return reply(429, "Too many requests");
      let body;
      let upstreamTimeout = 10000;
      if (post) {
        if (!req.headers["content-type"]?.startsWith("application/json")) return reply(415, "JSON required");
        const chunks = [];
        let size = 0;
        for await (const chunk of req) {
          size += chunk.length;
          if (size > 64 * 1024 * 1024) return reply(413, "Request too large");
          chunks.push(chunk);
        }
        let message;
        try { message = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
        catch { return reply(400, "Invalid JSON"); }
        if (!message || !allowedTypes.has(message.type)) return reply(403, "Message type not permitted");
        if (message.type !== "voice-job" && size > 2 * 1024 * 1024) return reply(413, "Request too large");
        body = JSON.stringify(message);
        if (["voice-job", "voice-wait"].includes(message.type)) upstreamTimeout = 35000;
      }
      // The public client ID cannot select another device's internal queue.
      const isolatedClient = crypto.createHash("sha256").update(`${owner}:${client}`).digest("hex");
      const destination = new URL(url.pathname, target);
      destination.searchParams.set("client", `remote-${isolatedClient}`);
      const response = await fetch(destination, {
        method: req.method, body,
        headers: post ? { "Content-Type": "application/json" } : {},
        redirect: "error", signal: AbortSignal.timeout(upstreamTimeout)
      });
      res.writeHead(response.status, { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
      res.end(Buffer.from(await response.arrayBuffer()));
    } catch {
      // Fail closed; never send backend exceptions or credential material.
      if (!res.headersSent) reply(503, "Service unavailable");
      else res.destroy();
    }
  });
  server.headersTimeout = 10000;
  server.requestTimeout = 300000;
  server.on("upgrade", (_req, socket) => socket.destroy());
  return server;
}

// Deliberately no auto-start or Funnel configuration. Provision and test
// credentials on the watch before exposing this gateway on the internet.
