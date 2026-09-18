#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { execFile, execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadDesktopPickerItems } from "./desktop-picker.mjs";
import { readQueuedTurn, queuedTurnState, withFreshReader } from "./queued-turn.mjs";
import { createPrivateNotifier } from "./private-notifier.mjs";
import { pendingMonitorStore } from "./pending-monitors.mjs";
import { createVoiceJobs } from "./voice-jobs.mjs";

const notificationDirectory = path.join(os.homedir(), "Library", "Application Support", "CodexWatchRemote");
const notifyPrivate = process.env.CODEX_WATCH_MOCK_APP_SERVER === "1" || process.env.NODE_TEST_CONTEXT
  ? async () => false : createPrivateNotifier({
  configPath: path.join(notificationDirectory, "bark.json"),
  journalPath: path.join(notificationDirectory, "notification-deliveries.json"),
  report: message => console.log(message)
});

const port = Number(process.env.CODEX_WATCH_PORT || 17842);
const host = process.env.CODEX_WATCH_HOST || "::";
const runtimeDir = process.env.CODEX_WATCH_RUNTIME_DIR || path.join(process.cwd(), ".codex-watch");
const audioDir = path.join(runtimeDir, "audio");
const defaultCodexSessionsDir = path.join(os.homedir(), ".codex", "sessions");
const codexAPIBaseURL = (process.env.CODEX_WATCH_CODEX_API_BASE_URL || "https://chatgpt.com/backend-api")
  .replace(/\/+$/, "");
const defaultTranscriptionModel = "gpt-4o-mini-transcribe";
const showNetworkHints = process.env.CODEX_WATCH_SHOW_NETWORK_HINTS === "1";
const verboseBridgeLogging = process.env.CODEX_WATCH_VERBOSE === "1";
let codexAppServer = null;
let codexAppTools = null;
const queuedTurnMonitors = new Map();
const clients = new Set();
const httpClients = new Map();
const durableStateBySelection = new Map();
const readStateSignaturesBySelection = new Map();
let latestDurableState = null;
let monitorStore;
let voiceJobs;
function durableVoiceJobs() {
  return voiceJobs ??= createVoiceJobs(path.join(process.env.NODE_TEST_CONTEXT || process.env.CODEX_WATCH_MOCK_APP_SERVER === "1" ? runtimeDir : notificationDirectory, "voice-jobs"), async message => {
    const raw = path.join(audioDir, `job-${crypto.randomUUID()}.pcm-f32le.raw`);
    const wav = raw + ".wav";
    fs.writeFileSync(raw, Buffer.from(message.data, "base64"), { mode: 0o600 });
    writePCMFloat32Wav(raw, wav, message);
    const started = Date.now();
    console.log("voice job transcription started", new Date(started).toISOString());
    const text = await transcribeAudio(wav);
    console.log("voice job transcription finished", new Date().toISOString(), "milliseconds", Date.now() - started);
    return text;
  });
}

function savedMonitors() {
  return monitorStore ??= pendingMonitorStore(path.join(
    process.env.NODE_TEST_CONTEXT || process.env.CODEX_WATCH_MOCK_APP_SERVER === "1" ? runtimeDir : notificationDirectory,
    "pending-monitors.json"
  ));
}

export function createBridgeServer() {
  const server = http.createServer(async (request, response) => {
    const requestURL = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);

    if (requestURL.pathname === "/") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({
        ok: true,
        endpoint: "/codex-watch",
        clients: clients.size,
        port: boundPort(server)
      }));
      return;
    }

    if (requestURL.pathname === "/codex-watch/message" && request.method === "POST") {
      try {
        const client = getHTTPClient(clientIDFromURL(requestURL), request.socket);
        const message = JSON.parse(await readRequestBody(request));
        if (["voice-job", "voice-result", "voice-wait"].includes(message.type)) {
          const result = message.type === "voice-result"
            ? durableVoiceJobs().handle(client.id, message)
            : await durableVoiceJobs().wait(client.id, message);
          jsonResponse(response, 200, { ok: true, messages: [result] });
          return;
        }
        handleText(client, JSON.stringify(message));
        jsonResponse(response, 200, { ok: true, messages: drainQueuedMessages(client) });
      } catch (error) {
        jsonResponse(response, 400, { ok: false, error: error.message });
      }
      return;
    }

    if (requestURL.pathname === "/codex-watch/poll" && request.method === "GET") {
      const client = getHTTPClient(clientIDFromURL(requestURL), request.socket);
      jsonResponse(response, 200, { ok: true, messages: drainQueuedMessages(client) });
      return;
    }

    response.writeHead(404);
    response.end();
  });

  server.on("upgrade", (request, socket) => {
    if (request.url !== "/codex-watch") {
      socket.destroy();
      return;
    }

    const key = request.headers["sec-websocket-key"];
    if (typeof key !== "string") {
      socket.destroy();
      return;
    }

    const accept = crypto
      .createHash("sha1")
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");

    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      "",
      ""
    ].join("\r\n"));

    const client = {
      socket,
      buffer: Buffer.alloc(0),
      audioStream: null,
      audioPath: null,
      audioBytes: 0,
      audioSampleRate: 48000,
      audioChannels: 1,
      pet: "codex",
      capabilities: [],
      pendingServerRequests: new Map(),
      selection: {
        target: "chat",
        project: "project-1",
        chat: "chat-1",
        projectIndex: 0,
        chatIndex: 0,
        newChat: false
      },
      pickerItems: loadCodexPickerItems()
    };
    clients.add(client);
    logConnection("watch connected", socket);

    send(client, {
      type: "state",
      pet: "codex",
      state: "idle",
      title: "Codex",
      body: "Bridge linked",
      items: client.pickerItems
    });

    socket.on("data", chunk => {
      client.buffer = Buffer.concat([client.buffer, chunk]);
      drainFrames(client);
    });
    socket.on("close", () => closeClient(client));
    socket.on("error", () => closeClient(client));
  });

  return server;
}

export function startBridge({ port: listenPort = port, host: listenHost = host } = {}) {
  fs.mkdirSync(audioDir, { recursive: true });
  const server = createBridgeServer();
  server.listen(listenPort, listenHost, () => {
    durableVoiceJobs();
    for (const record of savedMonitors().list()) {
      watchQueuedTurn({ pet: record.pet || "codex", selection: record.selection }, record.threadId, record.submission);
    }
    const activePort = boundPort(server);
    console.log(`Codex Watch bridge listening on port ${activePort} at /codex-watch`);
    if (showNetworkHints) {
      console.log(`LAN URL: ws://${lanAddress()}:${activePort}/codex-watch`);
      console.log(`Hostname URL: ws://${localHostName()}.local:${activePort}/codex-watch`);
      console.log(`Simulator URL: ws://127.0.0.1:${activePort}/codex-watch`);
    } else {
      console.log("Set CODEX_WATCH_SHOW_NETWORK_HINTS=1 to print connection URLs.");
    }
  });
  return server;
}

if (isMainModule()) {
  startBridge();
}

function drainFrames(client) {
  while (client.buffer.length >= 2) {
    const first = client.buffer[0];
    const opcode = first & 0x0f;
    const second = client.buffer[1];
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let offset = 2;

    if (length === 126) {
      if (client.buffer.length < offset + 2) return;
      length = client.buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (client.buffer.length < offset + 8) return;
      const bigLength = client.buffer.readBigUInt64BE(offset);
      if (bigLength > BigInt(Number.MAX_SAFE_INTEGER)) {
        client.socket.destroy();
        return;
      }
      length = Number(bigLength);
      offset += 8;
    }

    let maskKey = null;
    if (masked) {
      maskKey = client.buffer.subarray(offset, offset + 4);
      offset += 4;
    }
    if (client.buffer.length < offset + length) return;

    let payload = client.buffer.subarray(offset, offset + length);
    client.buffer = client.buffer.subarray(offset + length);

    if (maskKey) {
      const unmasked = Buffer.alloc(payload.length);
      for (let index = 0; index < payload.length; index += 1) {
        unmasked[index] = payload[index] ^ maskKey[index % 4];
      }
      payload = unmasked;
    }

    if (opcode === 0x8) {
      closeClient(client, { replyClose: true });
      return;
    }
    if (opcode === 0x1) {
      handleText(client, payload.toString("utf8"));
    }
  }
}

function handleText(client, text) {
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    send(client, { type: "error", body: "Invalid JSON" });
    return;
  }
  if (typeof message.pet === "string" && message.pet.length > 0) {
    client.pet = message.pet;
  }
  updateClientSelection(client, message);
  if (Array.isArray(message.capabilities)) {
    client.capabilities = message.capabilities.filter(value => typeof value === "string");
  }

  switch (message.type) {
    case "hello":
      console.log("hello", client.pet, client.capabilities.join(",") || "no-capabilities");
      logVerbose("hello selection", JSON.stringify(client.selection));
      maybeOpenCodex();
      send(client, replayStateForClient(client) ?? {
        type: "state",
        pet: client.pet,
        state: "idle",
        title: "Codex",
        body: "Bridge ready",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...(isPlaceholderSelectionID(client.selection.chat, "chat") ? {} : client.selection)
      });
      refreshClientStateFromCodex(client).catch(error => {
        warnBridge("state refresh failed", error);
      });
      break;
    case "state":
    case "pet-selected":
      console.log(message.type, client.pet, message.state || "idle");
      broadcast({
        type: "state",
        pet: client.pet,
        state: message.state || "idle",
        title: typeof message.title === "string" ? message.title : "Codex",
        body: typeof message.body === "string" ? message.body : "Pet synced",
        text: typeof message.text === "string" ? message.text : undefined,
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "picker-items":
      updateClientPickerItems(client, message);
      broadcast({
        type: "picker-items",
        pet: client.pet,
        state: message.state || "idle",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "picker-opened":
      console.log("picker-opened", client.selection.target);
      client.pickerItems = loadCodexPickerItems();
      send(client, {
        type: "picker-items",
        pet: client.pet,
        state: message.state || "idle",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "selection-focus":
    case "project-selected":
    case "chat-selected":
      handleSelection(client, message);
      if (message.type === "chat-selected") {
        refreshClientStateFromCodex(client).catch(error => {
          warnBridge("selected task refresh failed", error);
        });
      }
      break;
    case "mic-start":
      console.log("mic-start", client.pet);
      startAudio(client, message);
      break;
    case "mic-chunk":
      appendAudio(client, message);
      break;
    case "mic-stop":
      console.log("mic-stop");
      stopAudio(client);
      break;
    case "transcript":
      console.log("transcript", `${String(message.text || message.body || "").length} chars`);
      broadcast({
        type: "transcript",
        pet: client.pet,
        state: "review",
        title: typeof message.title === "string" ? message.title : "Transcript",
        body: typeof message.body === "string" ? message.body : message.text,
        text: typeof message.text === "string" ? message.text : message.body,
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "transcript-send":
      handleTranscriptSend(client, message);
      break;
    case "approval-response":
    case "input-response":
      handleServerRequestResponse(client, message);
      break;
    case "message-read":
      clearDurableStateForClient(client);
      break;
    case "transcribe-again":
      console.log("transcribe-again");
      sendTranscribingState(client, {
        bytes: Number.isInteger(message.bytes) ? message.bytes : 0,
        savedPath: null
      });
      break;
    case "ping":
      send(client, { type: "pong" });
      break;
    default:
      send(client, { type: "error", body: `Unknown message type: ${message.type}` });
  }
}

function startAudio(client, message) {
  if (client.audioStream) {
    stopAudio(client);
  }

  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const rawPath = path.join(audioDir, `${stamp}.pcm-f32le.raw`);
  const metaPath = path.join(audioDir, `${stamp}.json`);
  fs.writeFileSync(metaPath, JSON.stringify({
    createdAt: new Date().toISOString(),
    sampleRate: message.sampleRate || null,
    channels: message.channels || null,
    encoding: "pcm-f32le"
  }, null, 2));

  client.audioPath = rawPath;
  client.audioBytes = 0;
  client.audioSampleRate = Number(message.sampleRate) || 48000;
  client.audioChannels = Number(message.channels) || 1;
  client.audioStream = fs.createWriteStream(rawPath);
  broadcast({
    type: "state",
    pet: client.pet,
    state: "running",
    title: "Listening",
    body: "Audio streaming",
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

function appendAudio(client, message) {
  if (!client.audioStream || typeof message.data !== "string") {
    return;
  }
  if (Number(message.sampleRate) > 0) {
    client.audioSampleRate = Number(message.sampleRate);
  }
  if (Number.isInteger(message.channels) && message.channels > 0) {
    client.audioChannels = message.channels;
  }
  const chunk = Buffer.from(message.data, "base64");
  client.audioBytes += chunk.length;
  client.audioStream.write(chunk);
}

function stopAudio(client) {
  if (!client.audioStream) {
    return;
  }
  const stream = client.audioStream;
  const savedPath = client.audioPath;
  const bytes = client.audioBytes;
  const sampleRate = client.audioSampleRate || 48000;
  const channels = client.audioChannels || 1;

  client.audioStream = null;
  client.audioPath = null;
  client.audioBytes = 0;
  client.audioSampleRate = 48000;
  client.audioChannels = 1;
  stream.end(() => {
    sendTranscribingState(client, { bytes, savedPath });
    transcribeSavedAudio(client, { bytes, savedPath, sampleRate, channels }).catch(error => {
      errorBridge("transcription failed", error);
      sendTranscriptionFailure(client, error);
    });
  });
}

function sendTranscribingState(client, { bytes, savedPath }) {
  send(client, {
    type: "state",
    pet: client.pet,
    state: "running",
    title: "Transcribing",
    body: "Processing audio",
    bytes,
    path: savedPath,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

async function transcribeSavedAudio(client, { bytes, savedPath, sampleRate, channels }) {
  const transcriptionStartedAt = Date.now();
  if (!savedPath || bytes <= 0) {
    throw new Error("No watch audio was received.");
  }

  const wavPath = savedPath.replace(/\.pcm-f32le\.raw$/, ".wav");
  writePCMFloat32Wav(savedPath, wavPath, { sampleRate, channels });
  const text = await transcribeAudio(wavPath);
  console.log("transcription timing", JSON.stringify({ inputBytes: bytes, elapsedMs: Date.now() - transcriptionStartedAt }));
  const trimmed = text.trim();
  if (!trimmed) {
    throw new Error("Transcription returned no text.");
  }

  send(client, {
    type: "transcript",
    pet: client.pet,
    state: "review",
    title: "Transcript",
    body: trimmed,
    text: trimmed,
    bytes,
    path: wavPath,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

function handleTranscriptSend(client, message) {
  const text = String(message.text || message.body || "").trim();
  console.log("transcript-send", `${text.length} chars`);

  if (!text) {
    sendTranscriptSendFailure(client, new Error("Transcript was empty."));
    return;
  }

  const target = resolveTranscriptTarget(client, message);
  if (!target) {
    sendTranscriptSendFailure(client, new Error("Pick a Codex chat before sending."));
    return;
  }

  send(client, {
    type: "state",
    pet: client.pet,
    state: "running",
    title: target.newChat ? "Starting chat" : "Sending",
    body: truncate(text, 140),
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });

  submitTranscriptToResolvedTarget(client, target, text).catch(error => {
    errorBridge("transcript send failed", error);
    sendTranscriptSendFailure(client, error);
  });
}

async function submitTranscriptToResolvedTarget(client, target, text) {
  let threadId = target.threadId;
  if (target.newChat) {
    threadId = await startNewCodexThread(target.project);
    applyTranscriptTargetSelection(client, target.item, threadId);
    send(client, {
      type: "state",
      pet: client.pet,
      state: "running",
      title: "Sending",
      body: truncate(text, 140),
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
  } else {
    applyTranscriptTargetSelection(client, target.item, target.threadId);
  }

  await submitTranscriptToCodex(client, threadId, text);
}

async function startNewCodexThread(projectID) {
  const cwd = cwdFromProjectID(projectID);
  if (!cwd) {
    throw new Error("Pick a Codex project before starting a new chat.");
  }
  if (!fs.existsSync(cwd)) {
    throw new Error(`Project path does not exist: ${cwd}`);
  }

  maybeOpenCodex();
  const response = await getCodexAppServer().request("thread/start", {
    cwd
  }, { timeoutMs: 30000 });
  const threadId = stringOrNull(response?.thread?.id)
    || stringOrNull(response?.threadId)
    || stringOrNull(response?.id);
  if (!threadId) {
    throw new Error("Codex did not return a new chat ID.");
  }
  return threadId;
}

async function submitTranscriptToCodex(client, threadId, text) {
  maybeOpenCodex();

  const input = [{
    type: "text",
    text,
    text_elements: []
  }];

  // The Codex desktop app already owns the writer for its open tasks. Use the
  // app's local tool pipe when it is available so a Watch message is delivered
  // through that owner instead of starting a second app-server writer.
  const desktopTools = getCodexAppTools();
  if (desktopTools) {
    try {
      await desktopTools.ensureReady();
    } catch (error) {
      warnBridge("Codex desktop app tools are unavailable; using app-server fallback", error);
      desktopTools.dispose();
    }

    if (desktopTools.isReady()) {
      let before = null;
      try {
        before = await desktopTools.readThread(threadId, {
          turnLimit: 3,
          includeOutputs: false,
          timeoutMs: 1000
        });
      } catch (error) {
        // An active desktop turn may temporarily refuse a read. Sending the
        // Watch command must not wait on that optional snapshot.
        logVerbose("Codex desktop thread snapshot before Watch send skipped", error.message);
      }

      // Do not catch a real send failure and silently retry through another
      // writer: the first request may have reached Codex even if its response
      // was interrupted. The direct app-server fallback is only used when the
      // desktop app-tools pipe could not be opened at all.
      await desktopTools.sendMessageToThread(threadId, text);
      watchCodexDesktopThread(client, threadId, before);
      send(client, {
        type: "state",
        pet: client.pet,
        state: "thinking",
        title: "Codex is thinking",
        body: "Working on it",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      return;
    }
  }

  const appServer = getCodexAppServer();
  const watcher = watchCodexTurn(client, threadId);

  try {
    const resume = await appServer.request("thread/resume", {
      threadId,
      excludeTurns: false,
      persistExtendedHistory: false
    }, { timeoutMs: 30000 });

    const activeTurn = activeTurnFromResume(resume);

    if (activeTurn) {
      await appServer.request("turn/steer", {
        threadId,
        input,
        expectedTurnId: activeTurn.id
      }, { timeoutMs: 30000 });
    } else {
      await appServer.request("turn/start", {
        threadId,
        input
      }, { timeoutMs: 30000 });
    }

    if (!watcher.isClosed()) {
      send(client, {
        type: "state",
        pet: client.pet,
        state: "thinking",
        title: "Codex is thinking",
        body: "Working on it",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
    }
  } catch (error) {
    if (isActiveWriterConflict(error)) {
      try {
        const receipt = await appServer.request("thread/queue/add", {
          threadId,
          clientUserMessageId: crypto.randomUUID(),
          input
        }, { timeoutMs: 30000 });
        watcher.stop();
        send(client, {
          type: "state",
          pet: client.pet,
          state: "waiting",
          title: "已排队",
          body: "电脑上的 Codex 正在处理，指令已排队",
          capabilities: client.capabilities,
          items: client.pickerItems,
          ...client.selection
        });
        watchQueuedTurn(client, threadId, receipt.queuedSubmission);
        return;
      } catch (queueError) {
        error = new Error(`${error.message}；自动排队也失败：${queueError.message}`);
      }
    }
    watcher.stop();
    throw error;
  }
}

function watchCodexTurn(client, threadId) {
  const appServer = getCodexAppServer();
  let turnId = null;
  let responseText = "";
  let lastPreviewMs = 0;
  let isClosed = false;
  const sendTurnState = ({
    state,
    title,
    body,
    text,
    event,
    eventID,
    requestID,
    requestMethod,
    command,
    reason,
    questionID,
    question
  }) => {
    send(client, {
      type: "state",
      pet: client.pet,
      state,
      title,
      body,
      text,
      event,
      eventID,
      requestID,
      requestMethod,
      command,
      reason,
      questionID,
      question,
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
  };

  const unsubscribeServerRequest = appServer.onServerRequest((requestID, method, params = {}) => {
    const requestThreadID = params.threadId || params.conversationId;
    if (requestThreadID && requestThreadID !== threadId) {
      return false;
    }

    const request = codexWatchServerRequestDescriptor(requestID, method, params, threadId);
    if (!request) {
      return false;
    }

    client.pendingServerRequests.set(String(requestID), {
      id: requestID,
      method,
      params,
      threadId
    });
    sendTurnState(request);
    return true;
  });

  const cleanupTimer = setTimeout(cleanup, 10 * 60 * 1000);
  cleanupTimer.unref();

  const unsubscribe = appServer.onNotification((method, params = {}) => {
    if (params.threadId !== threadId) {
      return;
    }

    if (method === "turn/started") {
      turnId = params.turn?.id || turnId;
      sendTurnState({
        state: "thinking",
        title: "Codex is thinking",
        body: "Working on it"
      });
      return;
    }

    const desktopState = method !== "item/agentMessage/delta" && method !== "turn/completed"
      ? codexDesktopStateFromNotification(method, params)
      : null;
    if (desktopState) {
      sendTurnState(desktopState);
      return;
    }

    if (method === "item/agentMessage/delta") {
      if (turnId && params.turnId && params.turnId !== turnId) {
        return;
      }
      if (typeof params.delta === "string") {
        responseText = appendAgentDelta(responseText, params.delta);
      }
      const now = Date.now();
      const trimmed = responseText.trim();
      if (trimmed && now - lastPreviewMs > 1500) {
        lastPreviewMs = now;
        sendTurnState({
          state: "running",
          title: "Codex is replying",
          body: truncate(trimmed, 180),
          text: trimmed
        });
      }
      return;
    }

    if (method === "turn/completed") {
      if (turnId && params.turn?.id && params.turn.id !== turnId) {
        return;
      }
      const status = params.turn?.status || "completed";
      void notifyPrivate({
        event: status === "failed" ? "task-failed" : "task-complete",
        eventID: turnEventID(threadId, params.turn?.id || turnId, status === "failed" ? "failed" : "complete")
      });
      if (status === "failed") {
        sendTurnState({
          state: "failed",
          title: "Codex failed",
          body: params.turn?.error?.message || "Open Codex for details",
          event: "task-failed",
          eventID: turnEventID(threadId, params.turn?.id || turnId, "failed")
        });
      } else {
        sendTurnState({
          state: "review",
          title: "Codex replied",
          body: truncate(responseText.trim() || "Open Codex to review", 240),
          text: responseText.trim(),
          event: "task-complete",
          eventID: turnEventID(threadId, params.turn?.id || turnId, "complete")
        });
      }
      cleanup();
    }
  });

  function cleanup() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    clearTimeout(cleanupTimer);
    unsubscribe();
    unsubscribeServerRequest();
  }

  return {
    stop: cleanup,
    isClosed: () => isClosed
  };
}

function turnEventID(threadId, turnId, event) {
  return `turn:${threadId}:${turnId || "unknown"}:${event}`;
}

function codexWatchServerRequestDescriptor(requestID, method, params = {}, threadId) {
  const eventID = `request:${threadId}:${String(requestID)}`;
  const common = {
    state: "review",
    event: "approval-needed",
    eventID,
    requestID: String(requestID),
    requestMethod: method
  };

  if (method === "item/commandExecution/requestApproval") {
    const command = typeof params.command === "string"
      ? params.command
      : commandTextFromActions(params.commandActions);
    return {
      ...common,
      title: "Approval needed",
      body: params.reason || (command ? `Codex wants to run: ${truncate(command, 180)}` : "Codex is waiting for approval"),
      text: command || undefined,
      command: command || undefined,
      reason: params.reason || undefined
    };
  }

  if (method === "item/fileChange/requestApproval") {
    return {
      ...common,
      title: "File change approval",
      body: params.reason || "Codex wants to apply file changes",
      reason: params.reason || undefined
    };
  }

  if (method === "item/permissions/requestApproval") {
    return {
      ...common,
      title: "Permission needed",
      body: params.reason || "Codex requests additional permissions",
      reason: params.reason || undefined
    };
  }

  if (method === "item/tool/requestUserInput") {
    const question = Array.isArray(params.questions) ? params.questions[0] : null;
    const questionText = typeof question?.question === "string" ? question.question : "Codex is waiting for your input";
    return {
      ...common,
      event: "input-needed",
      title: "Input needed",
      body: questionText,
      questionID: typeof question?.id === "string" ? question.id : undefined,
      question: questionText
    };
  }

  if (method === "applyPatchApproval" || method === "execCommandApproval") {
    return {
      ...common,
      title: "Approval needed",
      body: params.reason || "Codex is waiting for approval",
      command: Array.isArray(params.command) ? params.command.join(" ") : undefined,
      reason: params.reason || undefined
    };
  }

  return null;
}

function commandTextFromActions(actions) {
  if (!Array.isArray(actions)) {
    return "";
  }
  return actions
    .map(action => typeof action?.command === "string" ? action.command : "")
    .filter(Boolean)
    .join(" && ");
}

function handleServerRequestResponse(client, message) {
  const requestID = stringOrNull(message.requestID);
  const pending = requestID ? client.pendingServerRequests.get(requestID) : null;
  if (!pending) {
    send(client, { type: "error", body: "That Codex approval request is no longer active." });
    return;
  }

  const appServer = getCodexAppServer();
  let result;
  if (pending.method === "item/tool/requestUserInput") {
    const answer = String(message.answer || message.text || message.body || "").trim();
    const questionID = pending.params?.questions?.[0]?.id || message.questionID || "answer";
    result = {
      answers: {
        [questionID]: { answers: [answer] }
      }
    };
  } else if (pending.method === "item/permissions/requestApproval") {
    const decision = normalizedApprovalDecision(message.decision);
    result = ["accept", "acceptForSession"].includes(decision)
      ? {
          permissions: pending.params?.permissions || {},
          scope: decision === "acceptForSession" ? "session" : "turn"
        }
      : { permissions: {}, scope: "turn" };
  } else if (pending.method === "applyPatchApproval" || pending.method === "execCommandApproval") {
    result = { decision: legacyApprovalDecision(message.decision) };
  } else {
    result = { decision: normalizedApprovalDecision(message.decision) };
  }

  try {
    appServer.respondToServerRequest(pending.id, result);
    client.pendingServerRequests.delete(requestID);
    send(client, {
      type: "state",
      pet: client.pet,
      state: "thinking",
      title: "Approval received",
      body: "Codex is continuing",
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
  } catch (error) {
    send(client, { type: "error", body: error.message });
  }
}

function normalizedApprovalDecision(value) {
  const normalized = normalizeStatus(value);
  if (["accept", "approve", "approved", "yes", "continue", "allow"].includes(normalized)) {
    return "accept";
  }
  if (["session", "accept-for-session", "approved-for-session"].includes(normalized)) {
    return "acceptForSession";
  }
  if (["cancel", "abort", "stop"].includes(normalized)) {
    return "cancel";
  }
  return "decline";
}

function legacyApprovalDecision(value) {
  const normalized = normalizedApprovalDecision(value);
  if (normalized === "accept") return "approved";
  if (normalized === "acceptForSession") return "approved_for_session";
  if (normalized === "cancel") return "abort";
  return { denied: { rejection: "Declined from Codex Watch" } };
}

function codexDesktopStateFromNotification(method, params = {}) {
  const source = params.state
    ?? params.threadRuntimeStatus
    ?? params.runtimeStatus
    ?? params.thread?.status
    ?? params.turn?.status
    ?? params.status;
  const mapped = codexDesktopStateFromStatus(source);
  if (!mapped) {
    return null;
  }

  if (mapped.kind === "approval") {
    return {
      state: "review",
      title: "Approval needed",
      body: params.message || params.body || "Codex is waiting for approval"
    };
  }
  if (mapped.kind === "user-input") {
    return {
      state: "review",
      title: "Input needed",
      body: params.message || params.body || "Codex is waiting for input"
    };
  }

  return {
    state: mapped.state,
    title: params.title || desktopStateTitle(mapped.state, method),
    body: params.body || params.message || desktopStateBody(mapped.state)
  };
}

function codexDesktopStateFromStatus(status) {
  if (!status) {
    return null;
  }

  if (typeof status === "object") {
    const flags = Array.isArray(status.activeFlags) ? status.activeFlags : [];
    if (flags.includes("waitingOnApproval")) {
      return { state: "review", kind: "approval" };
    }
    if (flags.includes("waitingOnUserInput")) {
      return { state: "review", kind: "user-input" };
    }
    return codexDesktopStateFromStatus(status.type || status.status || status.state);
  }

  switch (normalizeStatus(status)) {
    case "idle":
      return { state: "idle" };
    case "running":
    case "running-left":
    case "running-right":
    case "thinking":
    case "waiting":
    case "review":
    case "failed":
    case "waving":
    case "jumping":
      return { state: normalizeStatus(status) };
    case "active":
    case "inprogress":
    case "in-progress":
    case "loading":
    case "working":
      return { state: "running" };
    case "reasoning":
    case "thinking-started":
    case "thinking-start":
      return { state: "thinking" };
    case "needs-resume":
    case "resuming":
    case "pending":
    case "queued":
      return { state: "waiting" };
    case "approval":
    case "waitingonapproval":
    case "waiting-on-approval":
      return { state: "review", kind: "approval" };
    case "response":
    case "waitingonuserinput":
    case "waiting-on-user-input":
      return { state: "review", kind: "user-input" };
    case "complete":
    case "completed":
    case "done":
    case "success":
    case "succeeded":
      return { state: "review" };
    case "error":
    case "failure":
    case "systemerror":
    case "system-error":
    case "cancelled":
    case "canceled":
      return { state: "failed" };
    default:
      return null;
  }
}

function normalizeStatus(status) {
  return String(status || "")
    .trim()
    .replace(/_/g, "-")
    .toLowerCase();
}

function desktopStateTitle(state, method) {
  switch (state) {
    case "failed":
      return "Codex failed";
    case "review":
      return "Codex replied";
    case "thinking":
      return "Codex is thinking";
    case "waiting":
      return "Codex waiting";
    case "running-left":
    case "running-right":
    case "running":
      return "Codex is working";
    default:
      return method || "Codex";
  }
}

function desktopStateBody(state) {
  switch (state) {
    case "failed":
      return "Open Codex for details";
    case "review":
      return "Open Codex to review";
    case "thinking":
      return "Working on it";
    case "waiting":
      return "Waiting for Codex";
    case "running-left":
    case "running-right":
    case "running":
      return "Working on it";
    default:
      return "Bridge ready";
  }
}

function activeTurnFromResume(resume) {
  const turns = resume?.thread?.turns;
  if (!Array.isArray(turns)) {
    return null;
  }
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    if (turns[index]?.status === "inProgress") {
      return turns[index];
    }
  }
  return null;
}

function isActiveWriterConflict(error) {
  return /active writer|thread[- ]store conflict|already has an active writer/i.test(
    error?.message || String(error || "")
  );
}

function turnsFromDesktopSnapshot(snapshot) {
  return Array.isArray(snapshot?.turns)
    ? snapshot.turns
    : Array.isArray(snapshot?.thread?.turns)
      ? snapshot.thread.turns
      : [];
}

function latestDesktopTurn(snapshot) {
  const turns = turnsFromDesktopSnapshot(snapshot);
  return turns.length > 0 ? turns[turns.length - 1] : null;
}

function activeTurnFromDesktopSnapshot(snapshot) {
  const turns = turnsFromDesktopSnapshot(snapshot);
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    if (["inProgress", "in-progress", "active", "running"].includes(turns[index]?.status)) {
      return turns[index];
    }
  }
  return null;
}

function latestAssistantTextFromDesktopSnapshot(snapshot) {
  const turns = turnsFromDesktopSnapshot(snapshot);
  for (let turnIndex = turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const items = Array.isArray(turns[turnIndex]?.items) ? turns[turnIndex].items : [];
    for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
      const text = assistantTextFromObject(items[itemIndex]);
      if (text) {
        return text;
      }
    }
  }
  return "";
}

function desktopSnapshotStatus(snapshot) {
  const activeTurn = activeTurnFromDesktopSnapshot(snapshot);
  if (activeTurn) {
    return codexDesktopStateFromNotification("thread/status/changed", {
      thread: snapshot?.thread,
      threadRuntimeStatus: snapshot?.thread?.status,
      turn: activeTurn
    });
  }
  return codexDesktopStateFromNotification("thread/status/changed", {
    thread: snapshot?.thread,
    threadRuntimeStatus: snapshot?.thread?.status
  });
}

function nativeStateMessage(client, state, title, body, extra = {}) {
  return {
    type: "state",
    pet: client.pet,
    state,
    title,
    body,
    ...extra,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  };
}

function watchCodexDesktopThread(client, threadId, baseline) {
  const desktopTools = getCodexAppTools();
  if (!desktopTools) {
    return;
  }

  const baselineTurns = turnsFromDesktopSnapshot(baseline);
  const baselineIDs = new Set(
    baselineTurns.map(turn => stringOrNull(turn?.id)).filter(Boolean)
  );
  const baselineLatest = latestDesktopTurn(baseline);
  const baselineWasActive = Boolean(activeTurnFromDesktopSnapshot(baseline));
  let stopped = false;
  let timer = null;
  let lastSignature = "";
  const startedAt = Date.now();

  const stop = () => {
    if (stopped) {
      return;
    }
    stopped = true;
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  };

  const emit = (message) => {
    const signature = durableStateSignature(message);
    if (signature === lastSignature && !message.event) {
      return;
    }
    lastSignature = signature;
    void notifyPrivate(message);
    send(client, message);
  };

  const schedule = () => {
    if (stopped || !clients.has(client)) {
      stop();
      return;
    }
    timer = setTimeout(() => {
      timer = null;
      void poll();
    }, 1200);
    timer.unref();
  };

  const poll = async () => {
    if (stopped || !clients.has(client)) {
      stop();
      return;
    }

    let snapshot;
    try {
      snapshot = await desktopTools.readThread(threadId, {
        turnLimit: 8,
        includeOutputs: false
      });
    } catch (error) {
      warnBridge("Codex desktop thread watcher read failed", error);
      schedule();
      return;
    }

    const turns = turnsFromDesktopSnapshot(snapshot);
    const latestTurn = latestDesktopTurn(snapshot);
    const latestTurnID = stringOrNull(latestTurn?.id);
    const isNewTurn = Boolean(latestTurnID && !baselineIDs.has(latestTurnID));
    const activeTurn = activeTurnFromDesktopSnapshot(snapshot);
    const snapshotState = desktopSnapshotStatus(snapshot);

    if (snapshotState?.kind === "approval") {
      emit(nativeStateMessage(
        client,
        "review",
        "Approval needed",
        "Codex is waiting for approval"
      ));
    } else if (snapshotState?.kind === "user-input") {
      emit(nativeStateMessage(
        client,
        "review",
        "Input needed",
        "Codex is waiting for input"
      ));
    } else if (activeTurn) {
      const preview = latestAssistantTextFromDesktopSnapshot(snapshot);
      emit(nativeStateMessage(
        client,
        preview ? "running" : "thinking",
        preview ? "Codex is replying" : "Codex is thinking",
        preview ? truncate(preview, 180) : "Working on it",
        preview ? { text: preview } : {}
      ));
    }

    const status = normalizeStatus(latestTurn?.status);
    const completed = ["completed", "complete", "done", "success", "succeeded"].includes(status);
    const failed = ["failed", "failure", "error", "cancelled", "canceled"].includes(status);
    const sameBaselineActiveTurnCompleted = Boolean(
      baselineWasActive
      && baselineLatest?.id
      && latestTurnID === baselineLatest.id
      && completed
      && Date.now() - startedAt > 1000
    );

    if (failed && (isNewTurn || sameBaselineActiveTurnCompleted)) {
      const errorText = latestTurn?.error?.message || "Open Codex for details";
      emit(nativeStateMessage(
        client,
        "failed",
        "Codex failed",
        errorText,
        {
          event: "task-failed",
          eventID: turnEventID(threadId, latestTurnID, "failed")
        }
      ));
      stop();
      return;
    }

    if (completed && (isNewTurn || sameBaselineActiveTurnCompleted)) {
      const replyText = latestAssistantTextFromDesktopSnapshot(snapshot)
        || latestAssistantTextForThread(threadId);
      emit(nativeStateMessage(
        client,
        "review",
        "Codex replied",
        truncate(replyText || "Open Codex to review", 240),
        {
          text: replyText || undefined,
          event: "task-complete",
          eventID: turnEventID(threadId, latestTurnID, "complete")
        }
      ));
      stop();
      return;
    }

    // A desktop task may briefly report the old completed turn before the new
    // queued turn is materialized. Keep polling instead of treating that old
    // reply as the Watch request's completion.
    if (Date.now() - startedAt > 10 * 60 * 1000) {
      warnBridge("Codex desktop thread watcher timed out", new Error(threadId));
      stop();
      return;
    }
    schedule();
  };

  void poll();
}

function readFreshCodexState(read) {
  if (process.env.CODEX_WATCH_MOCK_APP_SERVER === "1") {
    return read((method, params) => getCodexAppServer().request(method, params));
  }
  // Never reuse the command connection's hydrated task snapshot. The desktop
  // owns this task; read its persisted state through a short-lived reader.
  return withFreshReader(() => new CodexAppServerClient(), read);
}

function watchQueuedTurn(client, threadId, submission) {
  if (!submission?.clientUserMessageId) return;
  const key = `${threadId}:${submission.clientUserMessageId}`;
  if (queuedTurnMonitors.has(key)) return;
  const selection = { ...client.selection, chat: threadId };
  savedMonitors().put({ threadId, submission: { clientUserMessageId: submission.clientUserMessageId }, selection, pet: client.pet });
  let timer;
  let stopped = false;
  let signature = "";
  const stop = () => { stopped = true; clearTimeout(timer); queuedTurnMonitors.delete(key); };
  queuedTurnMonitors.set(key, stop);
  async function poll() {
    try {
      const { done, ...state } = await readFreshCodexState(request =>
        readQueuedTurn(request, threadId, submission));
      if (stopped) return;
      const nextSignature = JSON.stringify(state);
      if (nextSignature !== signature) {
        logVerbose("queue observation", new Date().toISOString(), threadId, submission.clientUserMessageId, state.state, "clients", clients.size);
        signature = nextSignature;
        const message = { type: "state", pet: client.pet, ...state, ...selection };
        await notifyPrivate(message);
        rememberDurableState(message);
        for (const recipient of clients) {
          if (recipient.selection.chat === threadId) send(recipient, message);
        }
      }
      if (done) { savedMonitors().remove(key); stop(); return; }
    } catch (error) { warnBridge("Queued turn status retry", error); }
    if (!stopped) { timer = setTimeout(poll, 2000); timer.unref(); }
  }
  timer = setTimeout(poll, 500);
  timer.unref();
}

async function refreshClientStateFromCodex(client) {
  if (client.selection.newChat || isPlaceholderSelectionID(client.selection.chat, "chat")) {
    return;
  }

  const target = resolveTranscriptTarget(client, {
    project: client.selection.project,
    chat: client.selection.chat,
    target: client.selection.target,
    newChat: false
  });
  if (!target?.threadId) {
    return;
  }

  // Recover the accepted queue state even after a bridge or phone restart.
  // Reading the queue does not acquire the desktop task's writer lock.
  try {
    const queued = await getCodexAppServer().request("thread/queue/list", {
      threadId: target.threadId, limit: 1
    }, { timeoutMs: 5000 });
    if (queued?.data?.length) {
      applyTranscriptTargetSelection(client, target.item, target.threadId);
      send(client, nativeStateMessage(client, "waiting", "已排队",
        "指令已送达，等待电脑上的 Codex 处理"));
      watchQueuedTurn(client, target.threadId, queued.data[0]);
      return;
    }
  } catch (error) {
    warnBridge("Queue state refresh unavailable", error);
  }

  // Recover a reply after reconnect without hydrating the entire task history.
  try {
    const page = await readFreshCodexState(request => request("thread/turns/list", {
      threadId: target.threadId, limit: 3, itemsView: "summary", sortDirection: "desc"
    }));
    const latest = page?.data?.[0];
    if (latest) {
      applyTranscriptTargetSelection(client, target.item, target.threadId);
      const { done, ...state } = queuedTurnState(target.threadId, latest);
      const message = { ...nativeStateMessage(client, state.state, state.title, state.body), ...state };
      if (readStateSignaturesBySelection.get(selectionKey(message)) !== durableStateSignature(message)) send(client, message);
      const clientUserMessageId = latest.items?.find(item => item.type === "userMessage" && item.clientId)?.clientId;
      if (!done && clientUserMessageId) watchQueuedTurn(client, target.threadId, { clientUserMessageId });
      return;
    }
  } catch (error) { warnBridge("Bounded reply refresh unavailable", error); }

  const desktopTools = getCodexAppTools();
  if (desktopTools) {
    try {
      await desktopTools.ensureReady();
      const snapshot = await desktopTools.readThread(target.threadId, {
        turnLimit: 8,
        includeOutputs: false
      });
      applyTranscriptTargetSelection(client, target.item, target.threadId);
      const activeTurn = activeTurnFromDesktopSnapshot(snapshot);
      const desktopState = desktopSnapshotStatus(snapshot);
      if (desktopState?.kind === "approval") {
        send(client, nativeStateMessage(
          client,
          "review",
          "Approval needed",
          "Codex is waiting for approval"
        ));
        return;
      }
      if (desktopState?.kind === "user-input") {
        send(client, nativeStateMessage(
          client,
          "review",
          "Input needed",
          "Codex is waiting for input"
        ));
        return;
      }
      if (activeTurn) {
        send(client, nativeStateMessage(
          client,
          "thinking",
          "Codex is thinking",
          "Working on it"
        ));
        return;
      }
      const replyText = latestAssistantTextFromDesktopSnapshot(snapshot)
        || latestAssistantTextForThread(target.threadId);
      if (replyText) {
        const message = nativeStateMessage(
          client,
          "review",
          "Codex replied",
          truncate(replyText, 240),
          { text: replyText }
        );
        if (readStateSignaturesBySelection.get(selectionKey(message)) === durableStateSignature(message)) {
          return;
        }
        send(client, message);
      }
      return;
    } catch (error) {
      warnBridge("Codex desktop thread state refresh failed; using app-server fallback", error);
      desktopTools.dispose();
    }
  }

  let resume = null;
  try {
    resume = await getCodexAppServer().request("thread/read", {
      threadId: target.threadId,
      includeTurns: false
    }, { timeoutMs: 12000 });
  } catch (error) {
    warnBridge("thread/read state refresh failed", error);
  }

  const activeTurn = activeTurnFromResume(resume);
  if (activeTurn) {
    applyTranscriptTargetSelection(client, target.item, target.threadId);
    send(client, {
      type: "state",
      pet: client.pet,
      state: "thinking",
      title: "Codex is thinking",
      body: "Working on it",
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
    return;
  }

  const desktopState = codexDesktopStateFromNotification("thread/status/changed", {
    threadId: target.threadId,
    thread: resume?.thread,
    threadRuntimeStatus: resume?.thread?.status
  });
  if (desktopState && desktopState.state !== "idle" && desktopState.state !== "review") {
    applyTranscriptTargetSelection(client, target.item, target.threadId);
    send(client, {
      type: "state",
      pet: client.pet,
      ...desktopState,
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
    return;
  }

  const replyText = latestAssistantTextFromResume(resume) || latestAssistantTextForThread(target.threadId);
  if (!replyText) {
    return;
  }

  applyTranscriptTargetSelection(client, target.item, target.threadId);
  const message = {
    type: "state",
    pet: client.pet,
    state: "review",
    title: "Codex replied",
    body: truncate(replyText, 240),
    text: replyText,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  };
  if (readStateSignaturesBySelection.get(selectionKey(message)) === durableStateSignature(message)) {
    return;
  }
  send(client, message);
}

function resolveTranscriptTarget(client, message) {
  if (!Array.isArray(client.pickerItems) || client.pickerItems.length === 0) {
    client.pickerItems = loadCodexPickerItems();
  }

  const explicitChat = stringOrNull(message.chat) || stringOrNull(client.selection.chat);
  const project = stringOrNull(message.project) || stringOrNull(client.selection.project);
  const wantsNewChat = message.newChat === true
    || client.selection.newChat === true
    || message.action === "new-chat"
    || isNewChatSelectionID(explicitChat);
  const chatItems = client.pickerItems.filter(item => stringOrNull(item.chat));
  if (wantsNewChat) {
    return {
      newChat: true,
      project,
      item: project
        ? client.pickerItems.find(item => item.kind === "project" && item.project === project) || null
        : null,
      threadId: null
    };
  }
  const exact = explicitChat
    ? chatItems.find(item => item.chat === explicitChat)
    : null;
  if (exact) {
    return { threadId: exact.chat, item: exact };
  }
  if (explicitChat && !isPlaceholderSelectionID(explicitChat, "chat")) {
    return { threadId: explicitChat, item: null };
  }

  const projectChat = project
    ? chatItems.find(item => item.project === project)
    : null;
  if (projectChat) {
    return { threadId: projectChat.chat, item: projectChat };
  }

  if (chatItems.length > 0) {
    return { threadId: chatItems[0].chat, item: chatItems[0] };
  }

  return null;
}

function applyTranscriptTargetSelection(client, item, threadId) {
  client.selection.target = "chat";
  client.selection.chat = threadId;
  client.selection.newChat = false;
  if (item?.project) {
    client.selection.project = item.project;
  }
  if (Number.isInteger(item?.projectIndex)) {
    client.selection.projectIndex = item.projectIndex;
  }
  if (Number.isInteger(item?.chatIndex)) {
    client.selection.chatIndex = item.chatIndex;
  }
}

function isPlaceholderSelectionID(value, prefix) {
  return new RegExp(`^${prefix}-\\d+$`).test(value);
}

function isNewChatSelectionID(value) {
  return typeof value === "string" && value.startsWith("new-chat:");
}

function latestAssistantTextFromResume(resume) {
  const turns = resume?.thread?.turns;
  if (!Array.isArray(turns)) {
    return "";
  }
  for (let turnIndex = turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const items = Array.isArray(turns[turnIndex]?.items) ? turns[turnIndex].items : [];
    for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
      const text = assistantTextFromObject(items[itemIndex]);
      if (text) {
        return text;
      }
    }
  }
  return "";
}

function latestAssistantTextForThread(threadId) {
  const file = sessionFileForThread(threadId);
  if (!file) {
    return "";
  }

  let finalAnswer = "";
  let latestAgentMessage = "";
  // Very long desktop tasks can have hundreds of MB of history. Only inspect
  // the tail for a recent reply, without blocking the phone's status refresh.
  const descriptor = fs.openSync(file, "r");
  let history;
  let offset;
  try {
    const size = fs.fstatSync(descriptor).size;
    const buffer = Buffer.alloc(Math.min(size, 4 * 1024 * 1024));
    offset = size - buffer.length;
    const length = fs.readSync(descriptor, buffer, 0, buffer.length, offset);
    history = buffer.subarray(0, length).toString("utf8");
  } finally {
    fs.closeSync(descriptor);
  }
  const lines = history.split("\n");
  if (offset > 0) lines.shift();
  for (const line of lines) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }

    const responseText = assistantTextFromObject(event.payload);
    if (responseText) {
      if (event.payload?.phase === "final_answer") {
        finalAnswer = responseText;
      }
      latestAgentMessage = responseText;
    }
    if (event.payload?.type === "agent_message" && typeof event.payload.message === "string") {
      if (event.payload.phase === "final_answer") {
        finalAnswer = event.payload.message.trim();
      }
      latestAgentMessage = event.payload.message.trim();
    }
  }

  return finalAnswer || latestAgentMessage;
}

function assistantTextFromObject(value) {
  if (!value || typeof value !== "object") {
    return "";
  }
  if (value.role === "assistant" && typeof value.message === "string") {
    return value.message.trim();
  }
  if (value.role === "assistant" && typeof value.text === "string") {
    return value.text.trim();
  }
  if (value.role === "assistant" && Array.isArray(value.content)) {
    return value.content
      .map(part => typeof part?.text === "string" ? part.text : "")
      .filter(Boolean)
      .join("\n")
      .trim();
  }
  if ((value.type === "agent_message" || value.type === "message")
    && typeof value.message === "string"
    && value.role !== "user") {
    return value.message.trim();
  }
  return "";
}

function sessionFileForThread(threadId) {
  if (!threadId) {
    return null;
  }
  const files = findSessionFiles(currentCodexSessionsDir());
  for (const file of files) {
    const lines = fs.readFileSync(file, "utf8").split("\n").slice(0, 20);
    for (const line of lines) {
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      if (event.type === "session_meta" && event.payload?.id === threadId) {
        return file;
      }
    }
  }
  return null;
}

function cwdFromProjectID(projectID) {
  if (typeof projectID !== "string" || !projectID.startsWith("project:")) {
    return null;
  }
  const cwd = projectID.slice("project:".length);
  return path.isAbsolute(cwd) ? cwd : null;
}

function sendTranscriptSendFailure(client, error) {
  send(client, {
    type: "state",
    pet: client.pet,
    state: "failed",
    title: "Send failed",
    body: error.message,
    event: "task-failed",
    eventID: `failure:${Date.now()}`,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

async function transcribeAudio(wavPath) {
  const provider = currentTranscriptionProvider();
  if (provider === "mock") {
    return process.env.CODEX_WATCH_MOCK_TRANSCRIPT || "Mock transcript from watch audio.";
  }

  const errors = [];
  if (provider !== "openai") {
    try {
      return await transcribeWithCodexDesktop(wavPath);
    } catch (error) {
      errors.push(`Codex desktop transcription failed: ${error.message}`);
      if (provider !== "auto") {
        throw new Error(errors[0]);
      }
    }
  }

  if (process.env.OPENAI_API_KEY) {
    try {
      return await transcribeWithOpenAI(wavPath);
    } catch (error) {
      errors.push(`OpenAI transcription failed: ${error.message}`);
    }
  } else if (provider === "openai") {
    errors.push("OPENAI_API_KEY is not set.");
  }

  throw new Error(errors.join(" "));
}

async function transcribeWithCodexDesktop(wavPath) {
  const audio = await fs.promises.readFile(wavPath);
  const { body, boundary } = createMultipartBody({
    file: {
      name: "file",
      filename: path.basename(wavPath),
      contentType: "audio/wav",
      data: audio
    }
  });

  return transcribeWithCodexDesktopBody(body, boundary, { refreshToken: false });
}

async function transcribeWithCodexDesktopBody(body, boundary, { refreshToken }) {
  const token = await getCodexAppServer().getAuthToken({ refreshToken });
  if (!token) {
    throw new Error("Codex is not signed in with ChatGPT auth.");
  }

  const headers = codexDesktopHeaders(token, {
    "content-type": `multipart/form-data; boundary=${boundary}`
  });
  const response = await fetch(`${codexAPIBaseURL}/transcribe`, {
    method: "POST",
    headers,
    body,
    signal: AbortSignal.timeout(60000)
  });
  if (response.status === 401 && !refreshToken) {
    return transcribeWithCodexDesktopBody(body, boundary, { refreshToken: true });
  }

  const text = await response.text();
  let payload = {};
  try {
    payload = JSON.parse(text);
  } catch {}
  if (!response.ok) {
    throw new Error(errorMessageFromCodexResponse(response, payload, text));
  }
  return typeof payload.text === "string" ? payload.text : "";
}

async function transcribeWithOpenAI(wavPath) {
  const audio = await fs.promises.readFile(wavPath);
  const form = new FormData();
  form.append("model", process.env.CODEX_WATCH_TRANSCRIBE_MODEL || defaultTranscriptionModel);
  form.append("file", new Blob([audio], { type: "audio/wav" }), path.basename(wavPath));

  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${process.env.OPENAI_API_KEY}`
    },
    body: form,
    signal: AbortSignal.timeout(60000)
  });
  const body = await response.text();
  let payload = {};
  try {
    payload = JSON.parse(body);
  } catch {}
  if (!response.ok) {
    throw new Error(payload.error?.message || body || `Transcription failed with ${response.status}`);
  }
  return typeof payload.text === "string" ? payload.text : "";
}

function getCodexAppServer() {
  if (process.env.CODEX_WATCH_MOCK_APP_SERVER === "1") {
    codexAppServer ??= new MockCodexAppServerClient();
    return codexAppServer;
  }

  codexAppServer ??= new CodexAppServerClient();
  return codexAppServer;
}

function getCodexAppTools() {
  if (process.env.CODEX_WATCH_MOCK_APP_SERVER === "1"
    || process.env.CODEX_WATCH_DISABLE_APP_TOOLS === "1") {
    return null;
  }
  codexAppTools ??= new CodexDesktopAppToolsClient();
  return codexAppTools;
}

function codexAppToolsPipeCandidates() {
  const candidates = [
    process.env.CODEX_WATCH_CODEX_APP_TOOLS_PIPE_PATH,
    process.env.CODEX_APP_TOOLS_PIPE_PATH
  ].filter(value => typeof value === "string" && value.trim());

  try {
    const processes = execFileSync("ps", ["eww", "-ax", "-o", "command="], {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024
    });
    for (const match of processes.matchAll(/CODEX_APP_TOOLS_PIPE_PATH=([^\s]+)/g)) {
      candidates.push(match[1]);
    }
  } catch (error) {
    warnBridge("Unable to inspect Codex app-tools processes", error);
  }

  return [...new Set(candidates.map(value => value.trim()))]
    .filter(value => value.length > 0 && fs.existsSync(value));
}

function codexAppToolsCallerThreadID() {
  const direct = [
    process.env.CODEX_WATCH_CALLER_THREAD_ID,
    process.env.CODEX_THREAD_ID,
    process.env.CODEX_SESSION_ID
  ].find(value => typeof value === "string" && value.trim());
  if (direct) {
    return direct.trim();
  }

  try {
    const processes = execFileSync("ps", ["eww", "-ax", "-o", "command="], {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024
    });
    const match = processes.match(/CODEX_(?:THREAD_ID|SESSION_ID)=([A-Za-z0-9-]+)/);
    return match?.[1] || null;
  } catch {
    return null;
  }
}

function appToolText(result) {
  if (!Array.isArray(result?.contentItems)) {
    return "";
  }
  return result.contentItems
    .filter(item => item?.type === "inputText" && typeof item.text === "string")
    .map(item => item.text)
    .join("\n")
    .trim();
}

function appToolJSON(result) {
  const text = appToolText(result);
  if (!text) {
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

const CODEX_APP_TOOLS_MAX_FRAME_BYTES = 8 * 1024 * 1024;

class CodexDesktopAppToolsClient {
  socket = null;
  pipePath = null;
  connecting = null;
  readyPromise = null;
  nextRequestID = 1;
  pending = new Map();
  pendingData = Buffer.alloc(0);
  availableTools = new Set();

  async ensureReady() {
    if (this.readyPromise) {
      return this.readyPromise;
    }

    const ready = (async () => {
      const errors = [];
      for (const pipePath of codexAppToolsPipeCandidates()) {
        try {
          logVerbose("Codex desktop app-tools trying pipe", pipePath);
          this.close();
          await this.connect(pipePath);
          const response = await this.requestRaw("tools/list", {
            threadStartKind: "all"
          }, { timeoutMs: 8000 });
          const tools = Array.isArray(response?.tools) ? response.tools : [];
          this.availableTools = new Set(tools.map(tool => tool?.name).filter(Boolean));
          if (!this.availableTools.has("send_message_to_thread")
            || !this.availableTools.has("read_thread")) {
            throw new Error("Codex desktop app-tools catalog is missing thread controls.");
          }
          logVerbose("Codex desktop app-tools connected", pipePath);
          return;
        } catch (error) {
          errors.push(`${pipePath}: ${error.message}`);
          this.close();
        }
      }
      throw new Error(
        errors.length > 0
          ? `Codex desktop app-tools pipe unavailable (${errors.join(" | ")})`
          : "Codex desktop app-tools pipe was not found."
      );
    })();

    this.readyPromise = ready.catch(error => {
      this.readyPromise = null;
      throw error;
    });
    return this.readyPromise;
  }

  isReady() {
    return Boolean(
      this.socket
      && !this.socket.destroyed
      && this.availableTools.has("send_message_to_thread")
      && this.availableTools.has("read_thread")
    );
  }

  async readThread(threadId, options = {}) {
    const result = await this.callTool("read_thread", {
      threadId,
      turnLimit: options.turnLimit ?? 8,
      includeOutputs: options.includeOutputs ?? false,
      maxOutputCharsPerItem: options.maxOutputCharsPerItem ?? 3000
    }, threadId, options.timeoutMs ?? 5000);
    return appToolJSON(result);
  }

  async sendMessageToThread(threadId, prompt) {
    return this.callTool("send_message_to_thread", {
      threadId,
      prompt
    }, threadId);
  }

  async callTool(tool, argumentsValue, targetThreadID, timeoutMs = 30000) {
    if (!this.isReady()) {
      await this.ensureReady();
    }
    const callerThreadID = codexAppToolsCallerThreadID() || targetThreadID || "codex-watch";
    const response = await this.requestRaw("tools/call", {
      namespace: "codex_app",
      tool,
      arguments: argumentsValue,
      callId: `codex-watch-${crypto.randomUUID()}`,
      threadId: callerThreadID,
      turnId: `codex-watch-${crypto.randomUUID()}`
    }, { timeoutMs });
    if (response?.success !== true) {
      throw new Error(appToolText(response) || `Codex app tool ${tool} failed.`);
    }
    return response;
  }

  async requestRaw(method, params = {}, { timeoutMs = 20000 } = {}) {
    if (!this.socket || this.socket.destroyed) {
      throw new Error("Codex desktop app-tools pipe is not connected.");
    }
    const socket = this.socket;
    const id = this.nextRequestID++;
    const message = Buffer.from(JSON.stringify({
      id,
      jsonrpc: "2.0",
      method,
      params
    }), "utf8");
    if (message.length > CODEX_APP_TOOLS_MAX_FRAME_BYTES) {
      throw new Error("Codex desktop app-tools request is too large.");
    }
    const frame = Buffer.alloc(message.length + 4);
    frame.writeUInt32LE(message.length, 0);
    message.copy(frame, 4);
    logVerbose("Codex desktop app-tools request", method, id);

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for Codex app-tools ${method}.`));
      }, timeoutMs);
      timeout.unref();
      this.pending.set(id, { resolve, reject, timeout });
      try {
        socket.write(frame);
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  connect(pipePath) {
    if (this.socket && !this.socket.destroyed && this.pipePath === pipePath) {
      return Promise.resolve();
    }
    if (this.connecting) {
      return this.connecting;
    }

    this.pipePath = pipePath;
    this.connecting = new Promise((resolve, reject) => {
      const socket = net.createConnection(pipePath);
      let settled = false;
      const timeout = setTimeout(() => {
        fail(new Error(`Timed out connecting to Codex app-tools pipe ${pipePath}.`));
      }, 5000);
      timeout.unref();
      const fail = (error) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeout);
        socket.destroy();
        reject(error);
      };
      socket.once("error", fail);
      socket.once("close", () => {
        if (!settled) {
          fail(new Error(`Codex app-tools pipe closed before connecting.`));
        }
      });
      socket.once("connect", () => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeout);
        socket.off("error", fail);
        this.socket = socket;
        this.pendingData = Buffer.alloc(0);
        logVerbose("Codex desktop app-tools pipe connected", pipePath);
        socket.on("data", chunk => this.handleData(socket, chunk));
        socket.on("error", error => this.handleDisconnect(socket, error));
        socket.on("close", () => this.handleDisconnect(socket, new Error("Codex app-tools pipe closed.")));
        resolve();
      });
    }).finally(() => {
      this.connecting = null;
    });
    return this.connecting;
  }

  handleData(socket, chunk) {
    if (this.socket !== socket) {
      return;
    }
    this.pendingData = Buffer.concat([this.pendingData, chunk]);
    while (this.pendingData.length >= 4) {
      const frameLength = this.pendingData.readUInt32LE(0);
      if (frameLength > CODEX_APP_TOOLS_MAX_FRAME_BYTES) {
        this.handleDisconnect(socket, new Error("Codex app-tools response was too large."));
        socket.destroy();
        return;
      }
      if (this.pendingData.length < frameLength + 4) {
        return;
      }
      const payload = this.pendingData.subarray(4, frameLength + 4);
      this.pendingData = this.pendingData.subarray(frameLength + 4);
      let message;
      try {
        message = JSON.parse(payload.toString("utf8"));
      } catch {
        this.handleDisconnect(socket, new Error("Codex app-tools returned invalid JSON."));
        socket.destroy();
        return;
      }
      const pending = this.pending.get(Number(message.id));
      if (!pending) {
        continue;
      }
      this.pending.delete(Number(message.id));
      clearTimeout(pending.timeout);
      if (message.error) {
        pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        pending.resolve(message.result);
      }
    }
  }

  handleDisconnect(socket, error) {
    if (this.socket !== socket) {
      return;
    }
    logVerbose("Codex desktop app-tools pipe disconnected", error?.message || "unknown");
    this.socket = null;
    this.pendingData = Buffer.alloc(0);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }

  close() {
    const socket = this.socket;
    logVerbose("Codex desktop app-tools close", Boolean(socket), this.readyPromise ? "ready-pending" : "no-ready-pending");
    this.socket = null;
    this.pendingData = Buffer.alloc(0);
    this.availableTools.clear();
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("Codex desktop app-tools connection closed."));
    }
    this.pending.clear();
    socket?.destroy();
  }

  dispose() {
    this.close();
    this.pipePath = null;
    this.readyPromise = null;
  }
}

class MockCodexAppServerClient {
  notificationHandlers = new Set();
  serverRequestHandlers = new Set();
  serverRequestContinuations = new Map();

  async getAuthToken() {
    return "mock-token";
  }

  async request(method, params = {}) {
    switch (method) {
      case "thread/resume":
        if (process.env.CODEX_WATCH_MOCK_ACTIVE_WRITER === "1") {
          throw new Error(`thread-store conflict: thread ${params.threadId} already has an active writer`);
        }
      case "thread/read":
        if (process.env.CODEX_WATCH_MOCK_RESUME_STATE === "thinking") {
          return {
            thread: {
              id: params.threadId,
              status: { type: "active" },
              turns: [{ id: "mock-active-turn", status: "inProgress", items: [] }]
            }
          };
        }
        if (process.env.CODEX_WATCH_MOCK_RESUME_REPLY) {
          return {
            thread: {
              id: params.threadId,
              status: { type: "idle" },
              turns: [{
                id: "mock-completed-turn",
                status: "completed",
                items: [{
                  type: "message",
                  role: "assistant",
                  content: [{ type: "output_text", text: process.env.CODEX_WATCH_MOCK_RESUME_REPLY }]
                }]
              }]
            }
          };
        }
        return {
          thread: {
            id: params.threadId,
            status: { type: "idle" },
            turns: []
          }
        };
      case "thread/queue/add":
        return {
          queuedSubmission: {
            threadId: params.threadId,
            clientUserMessageId: params.clientUserMessageId
          }
        };
      case "thread/start": {
        const threadId = `mock-new-thread-${Date.now()}`;
        queueMicrotask(() => {
          this.emitNotification("thread/started", {
            thread: { id: threadId, cwd: params.cwd, status: { type: "idle" } }
          });
        });
        return {
          thread: {
            id: threadId,
            cwd: params.cwd,
            status: { type: "idle" }
          }
        };
      }
      case "turn/start":
      case "turn/steer": {
        const turnId = `mock-turn-${Date.now()}`;
        const threadId = params.threadId;
        queueMicrotask(() => {
          this.emitNotification("turn/started", {
            threadId,
            turn: { id: turnId, status: "inProgress", items: [] }
          });
          const activeFlag = process.env.CODEX_WATCH_MOCK_ACTIVE_FLAG;
          if (activeFlag) {
            this.emitNotification("thread/status", {
              threadId,
              threadRuntimeStatus: {
                type: "active",
                activeFlags: [activeFlag]
              }
            });
          }
          const continueTurn = () => {
            for (const delta of mockReplyDeltas()) {
              this.emitNotification("item/agentMessage/delta", {
                threadId,
                turnId,
                itemId: "mock-agent-message",
                delta
              });
            }
            this.emitNotification("turn/completed", {
              threadId,
              turn: { id: turnId, status: "completed", items: [] }
            });
          };
          const requestMethod = process.env.CODEX_WATCH_MOCK_SERVER_REQUEST;
          if (requestMethod) {
            this.serverRequestContinuations.set("mock-request-1", continueTurn);
            this.emitServerRequest(
              "mock-request-1",
              requestMethod,
              mockServerRequestParams(requestMethod, threadId, turnId)
            );
            return;
          }
          continueTurn();
        });
        return {};
      }
      default:
        return {};
    }
  }

  onNotification(handler) {
    this.notificationHandlers.add(handler);
    return () => {
      this.notificationHandlers.delete(handler);
    };
  }

  onServerRequest(handler) {
    this.serverRequestHandlers.add(handler);
    return () => {
      this.serverRequestHandlers.delete(handler);
    };
  }

  respondToServerRequest(id, result) {
    if (!result) return;
    const continuation = this.serverRequestContinuations.get(String(id));
    if (!continuation) return;
    this.serverRequestContinuations.delete(String(id));
    queueMicrotask(continuation);
  }

  emitServerRequest(id, method, params) {
    for (const handler of this.serverRequestHandlers) {
      if (handler(id, method, params) === true) {
        return true;
      }
    }
    return false;
  }

  emitNotification(method, params) {
    for (const handler of this.notificationHandlers) {
      handler(method, params);
    }
  }
}

function mockServerRequestParams(method, threadId, turnId) {
  if (method === "item/commandExecution/requestApproval") {
    return {
      threadId,
      turnId,
      itemId: "mock-command-item",
      command: "echo approved",
      reason: "The mock command needs approval."
    };
  }
  if (method === "item/fileChange/requestApproval") {
    return {
      threadId,
      turnId,
      itemId: "mock-file-item",
      reason: "The mock file change needs approval."
    };
  }
  if (method === "item/tool/requestUserInput") {
    return {
      threadId,
      turnId,
      itemId: "mock-input-item",
      isBlocking: true,
      questions: [{ id: "answer", header: "Answer", question: "What should Codex do next?" }]
    };
  }
  return {
    threadId,
    turnId,
    itemId: "mock-request-item",
    reason: "The mock request needs approval."
  };
}

function appendAgentDelta(current, delta) {
  if (!delta) {
    return current;
  }
  if (!current) {
    return delta;
  }
  if (shouldInsertBoundarySpace(current, delta)) {
    return `${current} ${delta}`;
  }
  return current + delta;
}

function shouldInsertBoundarySpace(current, delta) {
  const last = current[current.length - 1];
  const first = delta[0];
  if (!last || !first || /\s/.test(last) || /\s/.test(first)) {
    return false;
  }
  return /[.!?]/.test(last) && /[A-Z"`'“‘(\[]/.test(first);
}

function mockReplyDeltas() {
  const rawChunks = process.env.CODEX_WATCH_MOCK_REPLY_CHUNKS;
  if (rawChunks) {
    try {
      const chunks = JSON.parse(rawChunks);
      if (Array.isArray(chunks)) {
        return chunks.map(String);
      }
    } catch {
      return rawChunks.split("|");
    }
  }
  return [process.env.CODEX_WATCH_MOCK_REPLY || "Mock **reply** with `inlineCode`."];
}

class CodexAppServerClient {
  proc = null;
  readyPromise = null;
  stdoutBuffer = "";
  nextRequestID = 1;
  pending = new Map();
  notificationHandlers = new Set();
  serverRequestHandlers = new Set();

  async getAuthToken({ refreshToken }) {
    const status = await this.request("getAuthStatus", {
      includeToken: true,
      refreshToken
    });
    return typeof status?.authToken === "string" && status.authToken.length > 0
      ? status.authToken
      : null;
  }

  async request(method, params = {}, { timeoutMs = 20000 } = {}) {
    await this.ensureReady();
    return this.sendRequest(method, params, { timeoutMs });
  }

  onNotification(handler) {
    this.notificationHandlers.add(handler);
    return () => {
      this.notificationHandlers.delete(handler);
    };
  }

  onServerRequest(handler) {
    this.serverRequestHandlers.add(handler);
    return () => {
      this.serverRequestHandlers.delete(handler);
    };
  }

  async ensureReady() {
    if (this.proc && this.readyPromise) {
      return this.readyPromise;
    }
    this.startProcess();
    this.readyPromise = this.sendRequest("initialize", {
      clientInfo: {
        name: "codex-watch-bridge",
        title: "Codex Watch Bridge",
        version: "0.1.0"
      },
      capabilities: {
        experimentalApi: true,
        requestAttestation: false
      }
    }, { timeoutMs: 20000 }).catch(error => {
      this.dispose();
      throw error;
    });
    return this.readyPromise;
  }

  startProcess() {
    const executable = resolveCodexCLIPath();
    if (!executable) {
      throw new Error("Unable to locate the Codex CLI/app-server binary.");
    }

    this.proc = spawn(executable, ["app-server", "--listen", "stdio://"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        LOG_FORMAT: "json",
        RUST_LOG: process.env.RUST_LOG || "warn",
        CODEX_INTERNAL_ORIGINATOR_OVERRIDE: "Codex Watch Bridge"
      }
    });
    this.stdoutBuffer = "";
    this.proc.stdout.on("data", chunk => this.handleStdout(chunk));
    this.proc.stderr.on("data", chunk => this.handleStderr(chunk));
    this.proc.on("exit", (code, signal) => {
      const reason = signal ? `signal ${signal}` : `exit code ${code}`;
      this.rejectPending(new Error(`Codex app-server exited with ${reason}.`));
      this.proc = null;
      this.readyPromise = null;
    });
    this.proc.on("error", error => {
      this.rejectPending(error);
      this.proc = null;
      this.readyPromise = null;
    });
  }

  sendRequest(method, params, { timeoutMs }) {
    if (!this.proc?.stdin || this.proc.stdin.destroyed) {
      throw new Error("Codex app-server is not running.");
    }

    const id = this.nextRequestID++;
    const message = { id, method, params };
    this.proc.stdin.write(`${JSON.stringify(message)}\n`);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for Codex app-server ${method}.`));
      }, timeoutMs);
      timeout.unref();
      this.pending.set(id, { resolve, reject, timeout });
    });
  }

  handleStdout(chunk) {
    this.stdoutBuffer += chunk.toString("utf8");
    let newlineIndex;
    while ((newlineIndex = this.stdoutBuffer.indexOf("\n")) >= 0) {
      const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
      if (line.length > 0) {
        this.handleMessageLine(line);
      }
    }
  }

  handleMessageLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      warnBridge("codex app-server emitted non-json output", new Error(line.slice(0, 160)));
      return;
    }

    if ("id" in message && ("result" in message || "error" in message)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timeout);
      if (message.error) {
        pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (typeof message.method === "string" && !("id" in message)) {
      this.emitNotification(message.method, message.params || {});
      return;
    }

    if ("id" in message && typeof message.method === "string") {
      const handled = this.emitServerRequest(message.id, message.method, message.params || {});
      if (!handled) {
        this.respondToServerRequest(message.id, undefined, {
          code: -32601,
          message: `Unsupported server request: ${message.method}`
        });
      }
    }
  }

  emitNotification(method, params) {
    for (const handler of this.notificationHandlers) {
      try {
        handler(method, params);
      } catch (error) {
        warnBridge("codex app-server notification handler failed", error);
      }
    }
  }

  emitServerRequest(id, method, params) {
    let handled = false;
    for (const handler of this.serverRequestHandlers) {
      try {
        handled = handler(id, method, params) === true || handled;
      } catch (error) {
        warnBridge("codex app-server server-request handler failed", error);
      }
    }
    return handled;
  }

  respondToServerRequest(id, result = {}, error) {
    try {
      const response = error ? { id, error } : { id, result };
      this.proc?.stdin?.write(`${JSON.stringify(response)}\n`);
    } catch {}
  }

  handleStderr(chunk) {
    for (const line of chunk.toString("utf8").split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const payload = JSON.parse(trimmed);
        const level = String(payload.level || "").toUpperCase();
        if (level === "ERROR") {
          errorBridge("codex app-server error", new Error(payload.fields?.message || trimmed));
        }
      } catch {
        warnBridge("codex app-server warning", new Error(trimmed));
      }
    }
  }

  rejectPending(error) {
    for (const { reject, timeout } of this.pending.values()) {
      clearTimeout(timeout);
      reject(error);
    }
    this.pending.clear();
  }

  dispose() {
    if (this.proc && !this.proc.killed) {
      this.proc.kill();
    }
    this.rejectPending(new Error("Codex app-server connection disposed."));
    this.proc = null;
    this.readyPromise = null;
    this.stdoutBuffer = "";
    this.serverRequestHandlers.clear();
  }
}

function resolveCodexCLIPath() {
  const candidates = [
    process.env.CODEX_CLI_PATH,
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex"
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  try {
    const found = execFileSync("which", ["codex"], { encoding: "utf8" }).trim();
    return found.length > 0 ? found : null;
  } catch {
    return null;
  }
}

function createMultipartBody({ file, fields = {} }) {
  const boundary = `----codex-watch-${crypto.randomUUID()}`;
  const chunks = [];
  for (const [name, value] of Object.entries(fields)) {
    chunks.push(Buffer.from(`--${boundary}\r\n`));
    chunks.push(Buffer.from(`Content-Disposition: form-data; name="${escapeMultipartValue(name)}"\r\n\r\n`));
    chunks.push(Buffer.from(String(value)));
    chunks.push(Buffer.from("\r\n"));
  }
  chunks.push(Buffer.from(`--${boundary}\r\n`));
  chunks.push(Buffer.from(
    `Content-Disposition: form-data; name="${escapeMultipartValue(file.name)}"; filename="${escapeMultipartValue(file.filename)}"\r\n`
  ));
  chunks.push(Buffer.from(`Content-Type: ${file.contentType}\r\n\r\n`));
  chunks.push(file.data);
  chunks.push(Buffer.from(`\r\n--${boundary}--\r\n`));
  return { body: Buffer.concat(chunks), boundary };
}

function escapeMultipartValue(value) {
  return String(value).replaceAll('"', "");
}

function codexDesktopHeaders(token, headers = {}) {
  const merged = {
    ...headers,
    authorization: `Bearer ${token}`,
    originator: "Codex Desktop",
    "user-agent": codexDesktopUserAgent()
  };
  const accountID = chatGPTAccountIDFromToken(token);
  if (accountID) {
    merged["chatgpt-account-id"] = accountID;
  }
  return merged;
}

let codexDesktopVersionCache = null;
function codexDesktopUserAgent() {
  codexDesktopVersionCache ??= readCodexDesktopVersion();
  const platform = process.platform === "darwin"
    ? "Macintosh; Intel Mac OS X"
    : process.platform;
  return `Codex Desktop/${codexDesktopVersionCache} (${platform}; ${process.arch})`;
}

function readCodexDesktopVersion() {
  try {
    return execFileSync("defaults", [
      "read",
      "/Applications/Codex.app/Contents/Info",
      "CFBundleShortVersionString"
    ], { encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

function chatGPTAccountIDFromToken(token) {
  const payload = token.split(".")[1];
  if (!payload) return null;
  try {
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    const auth = parsed["https://api.openai.com/auth"];
    return typeof auth?.chatgpt_account_id === "string"
      ? auth.chatgpt_account_id
      : null;
  } catch {
    return null;
  }
}

function errorMessageFromCodexResponse(response, payload, body) {
  if (typeof payload.detail === "string") {
    return payload.detail;
  }
  if (typeof payload.error === "string") {
    return payload.error;
  }
  if (typeof payload.error?.message === "string") {
    return payload.error.message;
  }
  return body || `Codex transcription failed with ${response.status}`;
}

function sendTranscriptionFailure(client, error) {
  send(client, {
    type: "state",
    pet: client.pet,
    state: "failed",
    title: "Transcription unavailable",
    body: error.message,
    event: "task-failed",
    eventID: `failure:${Date.now()}`,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

function writePCMFloat32Wav(rawPath, wavPath, { sampleRate, channels }) {
  const raw = fs.readFileSync(rawPath);
  const samples = Math.floor(raw.length / 4);
  const pcm = Buffer.alloc(samples * 2);

  for (let index = 0; index < samples; index += 1) {
    const sample = Math.max(-1, Math.min(1, raw.readFloatLE(index * 4)));
    const value = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
    pcm.writeInt16LE(Math.round(value), index * 2);
  }

  const header = Buffer.alloc(44);
  const byteRate = sampleRate * channels * 2;
  const blockAlign = channels * 2;
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);

  fs.writeFileSync(wavPath, Buffer.concat([header, pcm]));
}

function handleSelection(client, message) {
  updateClientSelection(client, message);
  logVerbose(
    message.type,
    client.selection.target,
    `project=${redactedSelectionID(client.selection.project)}`,
    `chat=${redactedSelectionID(client.selection.chat)}`,
    client.selection.newChat ? "new-chat" : "existing-chat",
    typeof message.delta === "number" ? `delta=${message.delta}` : "focus"
  );
  broadcast({
    type: "selection",
    pet: client.pet,
    state: message.state || "idle",
    body: "Digital Crown",
    capabilities: client.capabilities,
    items: client.pickerItems,
    action: message.action || null,
    delta: Number.isFinite(message.delta) ? message.delta : null,
    index: Number.isFinite(message.index) ? message.index : null,
    ...client.selection
  });
}

function updateClientPickerItems(client, message) {
  if (Array.isArray(message.items)) {
    client.pickerItems = normalizePickerItems(message.items);
  }
}

function normalizePickerItems(items) {
  return items
    .filter(item => item && typeof item === "object")
    .map((item, index) => {
      const project = stringOrNull(item.project);
      const chat = stringOrNull(item.chat);
      const id = stringOrNull(item.id) || chat || project || `picker-item-${index}`;
      return {
        id,
        title: stringOrNull(item.title) || id,
        subtitle: stringOrNull(item.subtitle),
        kind: stringOrNull(item.kind),
        section: stringOrNull(item.section),
        project,
        chat,
        projectIndex: integerOrNull(item.projectIndex),
        chatIndex: integerOrNull(item.chatIndex),
        unread: typeof item.unread === "boolean" ? item.unread : null,
        pinned: typeof item.pinned === "boolean" ? item.pinned : null
      };
    });
}

function loadCodexPickerItems() {
  try {
    if (!process.env.CODEX_SESSIONS_DIR) {
      const indexed = loadDesktopPickerItems(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"));
      if (indexed !== null) return indexed;
    }
    const sessionFiles = findSessionFiles(currentCodexSessionsDir())
      .map(file => ({ file, mtimeMs: fs.statSync(file).mtimeMs }))
      .filter(({ file }) => fs.statSync(file).size <= 8 * 1024 * 1024)
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .slice(0, Number(process.env.CODEX_WATCH_MAX_SESSIONS || 500));
    const sessions = sessionFiles
      .map(({ file, mtimeMs }) => {
        try { return readSessionSummary(file, mtimeMs); }
        catch { return null; }
      })
      .filter(Boolean);
    return buildPickerItems(sessions);
  } catch (error) {
    warnBridge("failed to load Codex sessions", error);
    return fallbackPickerItems();
  }
}

function currentCodexSessionsDir() {
  return process.env.CODEX_SESSIONS_DIR || defaultCodexSessionsDir;
}

function currentTranscriptionProvider() {
  return process.env.CODEX_WATCH_TRANSCRIBE_PROVIDER || "auto";
}

function findSessionFiles(directory) {
  if (!fs.existsSync(directory)) {
    return [];
  }
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...findSessionFiles(entryPath));
    } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      files.push(entryPath);
    }
  }
  return files;
}

function readSessionSummary(file, mtimeMs) {
  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
  let meta = null;
  const userTexts = [];
  for (const line of lines) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.type === "session_meta") {
      meta = event.payload;
      continue;
    }
    const text = userTextFromEvent(event);
    if (text) {
      userTexts.push(text);
    }
  }
  if (!meta?.id || !meta?.cwd) {
    return null;
  }
  return {
    id: meta.id,
    cwd: meta.cwd,
    timestamp: meta.timestamp || new Date(mtimeMs).toISOString(),
    title: summarizePrompt(userTexts) || shortSessionID(meta.id),
    source: meta.source || null,
    file,
    mtimeMs
  };
}

function userTextFromEvent(event) {
  const payload = event.payload || {};
  if (payload.role !== "user" && payload.type !== "user_message") {
    return null;
  }
  if (typeof payload.message === "string") {
    return cleanPromptText(payload.message);
  }
  if (Array.isArray(payload.content)) {
    const text = payload.content
      .map(part => typeof part?.text === "string" ? part.text : "")
      .filter(Boolean)
      .join("\n");
    return cleanPromptText(text);
  }
  return null;
}

function cleanPromptText(text) {
  const withoutContext = text
    .replace(/<environment_context>[\s\S]*?<\/environment_context>/g, "")
    .replace(/<permissions instructions>[\s\S]*?<\/permissions instructions>/g, "")
    .replace(/<apps_instructions>[\s\S]*?<\/apps_instructions>/g, "")
    .replace(/<skills_instructions>[\s\S]*?<\/skills_instructions>/g, "")
    .replace(/<plugins_instructions>[\s\S]*?<\/plugins_instructions>/g, "");
  const lines = withoutContext
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .filter(line => !line.startsWith("# AGENTS.md instructions"))
    .filter(line => !line.startsWith("<INSTRUCTIONS>"))
    .filter(line => !line.startsWith("</INSTRUCTIONS>"));
  const natural = lines.find(line => !line.startsWith("/") && !line.startsWith("<"));
  return natural || lines[0] || "";
}

function summarizePrompt(texts) {
  for (let index = texts.length - 1; index >= 0; index -= 1) {
    const text = texts[index]
      .replace(/\s+/g, " ")
      .trim();
    if (text.length > 0) {
      return truncate(text, 56);
    }
  }
  return "";
}

function buildPickerItems(sessions) {
  const projectMap = new Map();
  for (const session of sessions) {
    const projectID = projectIDForPath(session.cwd);
    if (!projectMap.has(projectID)) {
      projectMap.set(projectID, {
        id: projectID,
        cwd: session.cwd,
        latestMs: session.mtimeMs,
        sessions: []
      });
    }
    const project = projectMap.get(projectID);
    project.latestMs = Math.max(project.latestMs, session.mtimeMs);
    project.sessions.push(session);
  }

  const projects = [...projectMap.values()]
    .sort((left, right) => right.latestMs - left.latestMs)
    .slice(0, Number(process.env.CODEX_WATCH_MAX_PROJECTS || 80));
  const items = [];
  projects.forEach((project, projectIndex) => {
    const sortedSessions = project.sessions
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .slice(0, Number(process.env.CODEX_WATCH_MAX_CHATS_PER_PROJECT || 80));
    items.push({
      id: project.id,
      title: projectTitle(project.cwd),
      subtitle: compactPath(project.cwd),
      kind: "project",
      section: "projects",
      project: project.id,
      projectIndex
    });
    sortedSessions.forEach((session, chatIndex) => {
      items.push({
        id: session.id,
        title: session.title,
        subtitle: relativeTimeLabel(session.mtimeMs),
        kind: "chat",
        section: "chats",
        project: project.id,
        chat: session.id,
        projectIndex,
        chatIndex
      });
    });
  });

  return items.length > 0 ? items : fallbackPickerItems();
}

function fallbackPickerItems() {
  return [];
}

function projectIDForPath(value) {
  return `project:${value}`;
}

function projectTitle(value) {
  return path.basename(value) || value;
}

function compactPath(value) {
  const home = os.homedir();
  if (value === home) {
    return "~";
  }
  if (value.startsWith(`${home}${path.sep}`)) {
    return `~/${value.slice(home.length + 1)}`;
  }
  return value;
}

function shortSessionID(value) {
  return value.split("-").at(-1) || value;
}

function truncate(value, maxLength) {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 3)}...`;
}

function relativeTimeLabel(mtimeMs) {
  const deltaSeconds = Math.max(0, Math.round((Date.now() - mtimeMs) / 1000));
  if (deltaSeconds < 60) {
    return "Just now";
  }
  const deltaMinutes = Math.round(deltaSeconds / 60);
  if (deltaMinutes < 60) {
    return `${deltaMinutes}m ago`;
  }
  const deltaHours = Math.round(deltaMinutes / 60);
  if (deltaHours < 24) {
    return `${deltaHours}h ago`;
  }
  const deltaDays = Math.round(deltaHours / 24);
  if (deltaDays < 14) {
    return `${deltaDays}d ago`;
  }
  return new Date(mtimeMs).toLocaleDateString();
}

function stringOrNull(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function integerOrNull(value) {
  return Number.isInteger(value) ? value : null;
}

function updateClientSelection(client, message) {
  if (typeof message.target === "string" && ["project", "chat"].includes(message.target)) {
    client.selection.target = message.target;
  }
  if (typeof message.project === "string" && message.project.length > 0) {
    client.selection.project = message.project;
  }
  if (typeof message.chat === "string" && message.chat.length > 0) {
    client.selection.chat = message.chat;
  }
  if (message.newChat === true || message.action === "new-chat" || isNewChatSelectionID(message.chat)) {
    client.selection.newChat = true;
  } else if (message.newChat === false || (typeof message.chat === "string" && !isNewChatSelectionID(message.chat))) {
    client.selection.newChat = false;
  }
  if (Number.isInteger(message.projectIndex)) {
    client.selection.projectIndex = message.projectIndex;
  }
  if (Number.isInteger(message.chatIndex)) {
    client.selection.chatIndex = message.chatIndex;
  }
}

function rememberDurableState(message) {
  if (!message || message.type !== "state") {
    return;
  }
  // Voice transport progress belongs to one live recording, not a Codex
  // task. Replaying it after reconnect leaves the watch waiting forever.
  if (["Listening", "Transcribing"].includes(message.title)) {
    return;
  }
  const state = normalizeStatus(message.state);
  if (!isDurableWatchState(state)) {
    return;
  }

  const durableState = {
    ...message,
    state,
    capabilities: undefined,
    items: undefined
  };
  const key = selectionKey(durableState);
  const signature = durableStateSignature(durableState);
  if (readStateSignaturesBySelection.get(key) === signature) {
    return;
  }
  durableStateBySelection.set(key, durableState);
  readStateSignaturesBySelection.delete(key);
  latestDurableState = durableState;
}

function replayStateForClient(client) {
  const chat = client.selection.chat;
  const hasSelectedChat = chat && !isPlaceholderSelectionID(chat, "chat");
  const durableState = durableStateBySelection.get(selectionKey(client.selection))
    || (hasSelectedChat
      ? [...durableStateBySelection.values()].reverse().find(value => value.chat === chat)
      : latestDurableState);
  if (!durableState) {
    return null;
  }
  return {
    ...durableState,
    pet: client.pet,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...(hasSelectedChat ? client.selection : {})
  };
}

function clearDurableStateForClient(client) {
  const key = selectionKey(client.selection);
  const existing = durableStateBySelection.get(key);
  const signature = existing ? durableStateSignature(existing) : null;
  durableStateBySelection.delete(key);
  if (signature) {
    readStateSignaturesBySelection.set(key, signature);
  }
  if (latestDurableState && selectionKey(latestDurableState) === key && existing === latestDurableState) {
    latestDurableState = Array.from(durableStateBySelection.values()).at(-1) || null;
  }
}

function isDurableWatchState(state) {
  return [
    "waiting",
    "review",
    "thinking",
    "running",
    "running-left",
    "running-right"
  ].includes(state);
}

function selectionKey(value = {}) {
  return [
    value.project || "",
    value.chat || "",
    Number.isInteger(value.projectIndex) ? value.projectIndex : "",
    Number.isInteger(value.chatIndex) ? value.chatIndex : "",
    value.newChat === true ? "new" : "existing"
  ].join("\u001f");
}

function durableStateSignature(value = {}) {
  return [
    normalizeStatus(value.state),
    value.title || "",
    value.body || "",
    value.text || ""
  ].join("\u001f");
}

function send(client, message) {
  if (message.type === "state") logVerbose("state sent", new Date().toISOString(), message.state, message.title, message.chat);
  rememberDurableState(message);
  if (Array.isArray(client.queue)) {
    client.queue.push(message);
    return;
  }
  if (client.socket.destroyed) return;
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  const header = frameHeader(payload.length);
  client.socket.write(Buffer.concat([header, payload]));
}

function broadcast(message) {
  for (const client of clients) {
    send(client, message);
  }
}

function getHTTPClient(id, socket) {
  const existing = httpClients.get(id);
  if (existing) {
    return existing;
  }

  const client = {
    id,
    queue: [],
    audioStream: null,
    audioPath: null,
    audioBytes: 0,
    audioSampleRate: 48000,
    audioChannels: 1,
    pet: "codex",
    capabilities: [],
    pendingServerRequests: new Map(),
    selection: {
      target: "chat",
      project: "project-1",
      chat: "chat-1",
      projectIndex: 0,
      chatIndex: 0,
      newChat: false
    },
    pickerItems: loadCodexPickerItems()
  };
  httpClients.set(id, client);
  clients.add(client);
  logConnection("watch http connected", socket);
  return client;
}

function clientIDFromURL(requestURL) {
  const id = requestURL.searchParams.get("client");
  if (id && /^[A-Za-z0-9._:-]{1,80}$/.test(id)) {
    return id;
  }
  return "watch-http-default";
}

function drainQueuedMessages(client) {
  if (!Array.isArray(client.queue)) {
    return [];
  }
  return client.queue.splice(0, client.queue.length);
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", chunk => {
      size += chunk.length;
      if (size > 64 * 1024 * 1024) {
        reject(new Error("Request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function jsonResponse(response, status, payload) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function boundPort(server) {
  const address = server.address();
  return typeof address === "object" && address ? address.port : port;
}

function isMainModule() {
  return process.argv[1]
    ? path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
    : false;
}

export function resetBridgeStateForTests() {
  for (const stop of queuedTurnMonitors.values()) stop();
  for (const client of clients) {
    try {
      client.audioStream?.destroy();
      client.socket?.destroy();
    } catch {}
  }
  clients.clear();
  httpClients.clear();
  durableStateBySelection.clear();
  readStateSignaturesBySelection.clear();
  latestDurableState = null;
  codexAppTools?.dispose?.();
  codexAppTools = null;
  codexAppServer?.dispose?.();
  codexAppServer = null;
}

function frameHeader(length) {
  if (length < 126) {
    return Buffer.from([0x81, length]);
  }
  if (length < 65536) {
    const header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
    return header;
  }
  const header = Buffer.alloc(10);
  header[0] = 0x81;
  header[1] = 127;
  header.writeBigUInt64BE(BigInt(length), 2);
  return header;
}

function closeClient(client, options = {}) {
  const hadClient = clients.delete(client);
  stopAudio(client);
  if (options.replyClose && !client.socket.destroyed) {
    try {
      client.socket.write(Buffer.from([0x88, 0x00]));
    } catch {}
  }
  try {
    client.socket.end();
  } catch {}
  if (hadClient) {
    console.log(`watch disconnected (${clients.size} client${clients.size === 1 ? "" : "s"})`);
  }
}

function lanAddress() {
  const candidates = [];
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const entry of addresses || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        candidates.push(entry);
      }
    }
  }
  return candidates.find(entry => !entry.address.endsWith(".1"))?.address
    || candidates[0]?.address
    || "127.0.0.1";
}

function localHostName() {
  if (process.env.CODEX_WATCH_LOCAL_HOSTNAME) {
    return process.env.CODEX_WATCH_LOCAL_HOSTNAME;
  }
  try {
    return execFileSync("scutil", ["--get", "LocalHostName"], { encoding: "utf8" }).trim()
      || os.hostname().split(".")[0];
  } catch {
    return os.hostname().split(".")[0];
  }
}

function logConnection(label, socket) {
  const summary = `${label} (${clients.size} client${clients.size === 1 ? "" : "s"})`;
  if (verboseBridgeLogging) {
    console.log(summary, `from ${socket.remoteAddress || "unknown"}:${socket.remotePort || "?"}`);
  } else {
    console.log(summary);
  }
}

function logVerbose(...args) {
  if (verboseBridgeLogging) {
    console.log(...args);
  }
}

function warnBridge(message, error) {
  if (verboseBridgeLogging) {
    console.warn(message, error?.message || error);
  } else {
    console.warn(message);
  }
}

function errorBridge(message, error) {
  if (verboseBridgeLogging) {
    console.error(message, error?.message || error);
  } else {
    console.error(message);
  }
}

function redactedSelectionID(value) {
  if (typeof value !== "string" || value.length === 0) {
    return "none";
  }
  if (value.startsWith("project:")) {
    return "project";
  }
  if (value.startsWith("new-chat:")) {
    return "new-chat";
  }
  return value.length > 12 ? `${value.slice(0, 8)}...` : value;
}

function maybeOpenCodex() {
  if (process.env.CODEX_WATCH_OPEN_CODEX !== "1") {
    return;
  }
  execFile("open", ["-a", "Codex"], () => {});
}
