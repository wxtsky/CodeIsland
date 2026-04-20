/**
 * @fileoverview CodeIsland Integration Extension.
 *
 * Bridges the running pi session to the CodeIsland macOS floating-window app
 * (https://github.com/wxtsky/CodeIsland) by forwarding lifecycle events over
 * the Unix domain socket CodeIsland listens on.
 *
 * Architecture:
 *   pi (this extension)  ──→  /tmp/codeisland-{uid}.sock  ──→  CodeIsland.app
 *
 * The extension is a socket CLIENT — no server is started. If CodeIsland is not
 * running the socket does not exist and all send calls fail silently.
 *
 * Event mapping:
 *   session_start          →  SessionStart
 *   session_shutdown       →  SessionEnd
 *   before_agent_start     →  UserPromptSubmit
 *   tool_call              →  PreToolUse  (or PermissionRequest for dangerous bash)
 *   tool_result            →  PostToolUse
 *   agent_end              →  Stop
 *   session_before_compact →  PreCompact
 *   session_compact        →  PostCompact
 *
 * Permission handling:
 *   Dangerous bash commands (`rm -rf`, `sudo`, `chmod 777`) are intercepted and
 *   sent as a blocking PermissionRequest via the codeisland-bridge binary. The
 *   extension waits for CodeIsland's decision and returns allow/block accordingly.
 *   This replaces the built-in permission-gate.ts when CodeIsland is active.
 *
 * Installation:
 *   Drop this file in ~/.pi/agent/extensions/ — it is auto-discovered.
 *
 * Requirements:
 *   - CodeIsland.app running on the same machine
 *   - "pi" added to CodeIsland's supported sources (see PR instructions)
 */

import { connect } from "net";
import { execFileSync, execFile } from "child_process";
import { existsSync } from "fs";
import { homedir } from "os";
import { getuid } from "process";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import type { AssistantMessage } from "@mariozechner/pi-ai";

// ── Socket / bridge constants ─────────────────────────────────────────────────

/** Unix socket path CodeIsland listens on (user-scoped). */
const SOCKET_PATH = `/tmp/codeisland-${getuid()}.sock`;

/**
 * Bridge binary path. Used for blocking permission requests because Node's
 * half-close (`sock.end()`) causes NWConnection to close before the response
 * arrives on macOS; the bridge uses POSIX `shutdown(SHUT_WR)` which works.
 */
const BRIDGE_PATH = `${homedir()}/.codeisland/codeisland-bridge`;

/** Environment variable keys forwarded to CodeIsland for terminal detection. */
const ENV_KEYS = [
  "TERM_PROGRAM",
  "ITERM_SESSION_ID",
  "TERM_SESSION_ID",
  "TMUX",
  "TMUX_PANE",
  "KITTY_WINDOW_ID",
  "__CFBundleIdentifier",
] as const;

// ── Dangerous bash patterns (mirrors permission-gate.ts) ──────────────────────

const DANGEROUS_PATTERNS: RegExp[] = [
  /\brm\s+(-rf?|--recursive)/i,
  /\bsudo\b/i,
  /\b(chmod|chown)\b.*777/i,
];

function isDangerous(command: string): boolean {
  return DANGEROUS_PATTERNS.some((p) => p.test(command));
}

// ── Environment / TTY helpers ─────────────────────────────────────────────────

/** Collects relevant terminal environment variables. */
function collectEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const key of ENV_KEYS) {
    if (process.env[key]) env[key] = process.env[key]!;
  }
  return env;
}

/**
 * Walks the process tree upward to find the controlling TTY.
 * Cached at startup — pi's TTY does not change during a session.
 */
function detectTty(): string | null {
  try {
    let pid = process.pid;
    for (let i = 0; i < 8; i++) {
      const out = execFileSync("ps", ["-o", "tty=,ppid=", "-p", String(pid)], {
        timeout: 1000,
      })
        .toString()
        .trim();
      const [tty, ppidStr] = out.split(/\s+/);
      if (tty && tty !== "??" && tty !== "?") {
        return tty.startsWith("/dev/") ? tty : `/dev/${tty}`;
      }
      const ppid = parseInt(ppidStr ?? "0", 10);
      if (!ppid || ppid <= 1) break;
      pid = ppid;
    }
  } catch {}
  return null;
}

// ── Socket communication ──────────────────────────────────────────────────────

/**
 * Sends a JSON payload to the CodeIsland socket (fire-and-forget).
 * Returns `false` silently when CodeIsland is not running.
 *
 * @param payload - Event object to serialise and send.
 * @returns `true` on successful delivery, `false` otherwise.
 */
function sendToSocket(payload: object): Promise<boolean> {
  return new Promise((resolve) => {
    try {
      const sock = connect({ path: SOCKET_PATH }, () => {
        sock.write(JSON.stringify(payload));
        sock.end();
        resolve(true);
      });
      sock.on("error", () => resolve(false));
      sock.setTimeout(3_000, () => {
        sock.destroy();
        resolve(false);
      });
    } catch {
      resolve(false);
    }
  });
}

/**
 * Sends a JSON payload via the bridge binary and waits for CodeIsland's response.
 * Used exclusively for blocking permission/question requests.
 *
 * @param payload    - Blocking request object.
 * @param timeoutMs  - Maximum wait time in milliseconds (default 30 s).
 * @returns Parsed response JSON, or `null` on error / timeout.
 */
function sendAndWaitResponse(
  payload: object,
  timeoutMs = 30_000,
): Promise<Record<string, unknown> | null> {
  return new Promise((resolve) => {
    if (!existsSync(BRIDGE_PATH)) {
      resolve(null);
      return;
    }
    try {
      const child = execFile(
        BRIDGE_PATH,
        [],
        { timeout: timeoutMs, maxBuffer: 1_048_576 },
        (error, stdout) => {
          if (error) {
            resolve(null);
            return;
          }
          try {
            resolve(JSON.parse(stdout));
          } catch {
            resolve(null);
          }
        },
      );
      child.stdin!.write(JSON.stringify(payload));
      child.stdin!.end();
    } catch {
      resolve(null);
    }
  });
}

// ── Event builders ────────────────────────────────────────────────────────────

/**
 * Builds the base fields required on every CodeIsland event payload.
 *
 * @param sessionId - Pi session UUID (prefixed with `"pi-"`).
 * @param cwd       - Current working directory.
 * @param extra     - Event-specific fields merged into the base.
 * @returns Complete event payload ready for `sendToSocket`.
 */
function base(
  sessionId: string,
  cwd: string,
  extra: Record<string, unknown>,
  tty: string | null,
): Record<string, unknown> {
  return {
    session_id: `pi-${sessionId}`,
    _source: "pi",
    _ppid: process.pid,
    _env: collectEnv(),
    _tty: tty,
    _server_port: 0,
    cwd,
    ...extra,
  };
}

/** Capitalises the first character of a tool name for display. */
function displayToolName(name: string): string {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

/** Extracts plain text from the last assistant message in an event.messages array. */
function extractLastAssistantText(
  messages: readonly unknown[],
): string {
  const assistants = messages.filter(
    (m): m is AssistantMessage =>
      !!m &&
      typeof m === "object" &&
      (m as { role?: string }).role === "assistant",
  );
  const last = assistants.at(-1);
  if (!last) return "";
  const content = last.content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((c): c is { type: "text"; text: string } => c?.type === "text")
    .map((c) => c.text)
    .join("")
    .trim();
}

// ── Extension ─────────────────────────────────────────────────────────────────

export default function codeislandExtension(pi: ExtensionAPI) {
  /** TTY path detected once at startup. */
  const tty = detectTty();

  /**
   * Session IDs for which a blocking PermissionRequest is currently in flight.
   * Non-lifecycle events for these sessions are suppressed to prevent CodeIsland's
   * "answered externally" heuristic from auto-denying while the card is visible.
   */
  const pendingPermissionSessions = new Set<string>();

  // ── Session lifecycle ──────────────────────────────────────────────────────

  pi.on("session_start", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sessionName = pi.getSessionName();
    await sendToSocket(
      base(sessionId, ctx.cwd, {
        hook_event_name: "SessionStart",
        ...(sessionName ? { session_title: sessionName } : {}),
      }, tty),
    );
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "SessionEnd" }, tty),
    );
  });

  // ── Agent lifecycle ────────────────────────────────────────────────────────

  pi.on("before_agent_start", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;

    if (pendingPermissionSessions.has(sid)) return;

    const prompt = event.prompt ?? "";
    await sendToSocket(
      base(sessionId, ctx.cwd, {
        hook_event_name: "UserPromptSubmit",
        prompt,
      }, tty),
    );
  });

  pi.on("agent_end", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;

    if (pendingPermissionSessions.has(sid)) return;

    const lastAssistantMessage = extractLastAssistantText(event.messages);
    const sessionName = pi.getSessionName();

    await sendToSocket(
      base(sessionId, ctx.cwd, {
        hook_event_name: "Stop",
        last_assistant_message: lastAssistantMessage || undefined,
        ...(sessionName ? { codex_title: sessionName } : {}),
      }, tty),
    );
  });

  // ── Tool calls ─────────────────────────────────────────────────────────────

  pi.on("tool_call", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;
    const toolName = displayToolName(event.toolName);

    // Build a tool_input object appropriate for the tool type.
    const toolInput: Record<string, unknown> = { ...event.input };
    if (event.toolName === "bash") {
      const command = event.input.command as string | undefined;
      if (command) toolInput.patterns = [command];
    }
    if (event.toolName === "edit" || event.toolName === "write") {
      const path = event.input.path as string | undefined;
      if (path) toolInput.file_path = path;
    }

    // Dangerous bash → send blocking PermissionRequest via bridge.
    if (
      event.toolName === "bash" &&
      typeof event.input.command === "string" &&
      isDangerous(event.input.command)
    ) {
      pendingPermissionSessions.add(sid);

      const payload = base(sessionId, ctx.cwd, {
        hook_event_name: "PermissionRequest",
        tool_name: toolName,
        tool_input: toolInput,
        _pi_tool_call_id: event.toolCallId,
      }, tty);

      let response: Record<string, unknown> | null = null;
      try {
        response = await sendAndWaitResponse(payload);
      } finally {
        pendingPermissionSessions.delete(sid);
      }

      const behavior = (
        response?.hookSpecificOutput as Record<string, unknown> | undefined
      )?.decision as Record<string, unknown> | undefined;

      if (behavior?.behavior === "deny") {
        return { block: true, reason: "Blocked by CodeIsland" };
      }

      // Approved — fall through to normal PreToolUse event below.
    }

    // Non-blocking PreToolUse for all other tool calls.
    if (!pendingPermissionSessions.has(sid)) {
      await sendToSocket(
        base(sessionId, ctx.cwd, {
          hook_event_name: "PreToolUse",
          tool_name: toolName,
          tool_input: toolInput,
        }, tty),
      );
    }

    return undefined;
  });

  pi.on("tool_result", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;

    if (pendingPermissionSessions.has(sid)) return;

    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "PostToolUse" }, tty),
    );
  });

  // ── Compaction ─────────────────────────────────────────────────────────────

  pi.on("session_before_compact", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "PreCompact" }, tty),
    );
  });

  pi.on("session_compact", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "PostCompact" }, tty),
    );
  });
}
