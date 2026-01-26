/**
 * Codex bridge process:
 * - Reads newline-delimited JSON requests from stdin.
 * - Maintains one Codex thread per client session (sessionId -> thread).
 * - Streams Codex SDK events back to stdout as newline-delimited JSON messages.
 * - Serializes runs through a simple in-memory queue to avoid overlapping turns.
 */
import readline from "node:readline";
import process from "node:process";

import { Codex } from "@openai/codex-sdk";

const codexPathOverride = process.env.CODEX_PATH_OVERRIDE || undefined;
const baseUrl = process.env.OPENAI_BASE_URL || undefined;
const apiKey = process.env.CODEX_API_KEY || process.env.OPENAI_API_KEY || undefined;

const codex = new Codex({
  codexPathOverride,
  baseUrl,
  apiKey,
});

const threadsBySession = new Map();
const queue = [];
let running = false;

function send(message) {
  try {
    process.stdout.write(`${JSON.stringify(message)}\n`);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    process.stdout.write(`${JSON.stringify({ type: "bridge.error", message: detail })}\n`);
  }
}

function normalizeThreadOptions(request) {
  const threadOptions = { ...(request.threadOptions || {}) };
  if (request.cwd) {
    threadOptions.workingDirectory = request.cwd;
  }
  return threadOptions;
}

function getOrCreateThread(request) {
  const existing = threadsBySession.get(request.sessionId);
  if (existing) {
    return existing;
  }

  const threadOptions = normalizeThreadOptions(request);
  const thread = request.threadId
    ? codex.resumeThread(request.threadId, threadOptions)
    : codex.startThread(threadOptions);

  threadsBySession.set(request.sessionId, thread);
  return thread;
}

async function handleRun(request) {
  const thread = getOrCreateThread(request);
  const touchedFiles = new Set();
  let finalResponse = "";
  let threadId = thread.id || request.threadId || null;
  const runOptions = request.model ? { model: request.model } : {};

  try {
    const { events } = await thread.runStreamed(request.input, runOptions);
    for await (const event of events) {
      if (event.type === "thread.started") {
        threadId = event.thread_id;
        send({ type: "thread.started", sessionId: request.sessionId, threadId });
        continue;
      }

      if (event.type === "item.updated") {
        const item = event.item;
        if (item.type === "agent_message") {
          send({
            type: "assistant.delta",
            sessionId: request.sessionId,
            threadId,
            itemId: item.id,
            text: item.text || "",
          });
        }
        continue;
      }

      if (event.type === "item.completed") {
        const item = event.item;
        if (item.type === "agent_message") {
          finalResponse = item.text || "";
          send({
            type: "assistant.message",
            sessionId: request.sessionId,
            threadId,
            itemId: item.id,
            text: finalResponse,
          });
          continue;
        }

        if (item.type === "file_change") {
          for (const change of item.changes || []) {
            if (change.path) {
              touchedFiles.add(change.path);
            }
          }
          send({
            type: "files.touched",
            sessionId: request.sessionId,
            threadId,
            paths: Array.from(touchedFiles),
          });
          continue;
        }
      }

      if (event.type === "turn.completed") {
        send({
          type: "turn.completed",
          sessionId: request.sessionId,
          threadId,
          usage: event.usage || null,
        });
        continue;
      }

      if (event.type === "turn.failed") {
        const message = event.error?.message || "Codex turn failed";
        send({ type: "error", sessionId: request.sessionId, threadId, message });
        return;
      }

      if (event.type === "error") {
        send({ type: "error", sessionId: request.sessionId, threadId, message: event.message });
        return;
      }
    }

    threadId = thread.id || threadId;
    send({
      type: "done",
      sessionId: request.sessionId,
      threadId,
      finalResponse,
      touchedFiles: Array.from(touchedFiles),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    send({ type: "error", sessionId: request.sessionId, threadId, message });
  }
}

function pump() {
  if (running) {
    return;
  }
  const next = queue.shift();
  if (!next) {
    return;
  }
  running = true;
  handleRun(next)
    .catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      send({ type: "error", sessionId: next.sessionId, threadId: next.threadId || null, message });
    })
    .finally(() => {
      running = false;
      pump();
    });
}

function handleReset(request) {
  if (request.sessionId) {
    threadsBySession.delete(request.sessionId);
  }
  send({ type: "reset", sessionId: request.sessionId || null });
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (trimmed === "") {
    return;
  }

  let request;
  try {
    request = JSON.parse(trimmed);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    send({ type: "error", sessionId: null, threadId: null, message: `Invalid JSON: ${message}` });
    return;
  }

  if (request.type === "reset") {
    handleReset(request);
    return;
  }

  if (request.type !== "run") {
    send({ type: "error", sessionId: request.sessionId || null, threadId: request.threadId || null, message: `Unknown request type: ${request.type}` });
    return;
  }

  if (!request.sessionId) {
    send({ type: "error", sessionId: null, threadId: request.threadId || null, message: "Missing sessionId" });
    return;
  }

  queue.push(request);
  pump();
});

rl.on("close", () => {
  process.exit(0);
});
