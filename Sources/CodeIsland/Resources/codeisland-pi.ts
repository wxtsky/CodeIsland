// CodeIsland pi extension
// version: v7

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
 * running the socket does not exist and all send calls fail silently. Nothing
 * is sent to a socket this user does not own (`socketIsOwnedByUser`).
 * `CODEISLAND_SOCKET_PATH` overrides the socket path, as it does for the app.
 *
 * Subagent children (pi-subagents):
 *   A background child runs as a pi session of its own inside a detached
 *   runner that loads this same extension, with the spawning session's id in
 *   PI_SUBAGENT_PARENT_SESSION. Its payloads carry `_parent_session_id` (the
 *   parent's CodeIsland session id) and `agent_type`, so CodeIsland can fold
 *   the child into the parent's card or hide it (Agent Sub-Sessions), and
 *   never rings the completion sound for a child's turn — only the parent's.
 *
 * Event mapping:
 *   session_start          →  SessionStart
 *   session_shutdown       →  SessionEnd
 *   before_agent_start     →  UserPromptSubmit
 *   tool_call              →  PreToolUse  (or PermissionRequest for dangerous bash)
 *   tool_result            →  PostToolUse
 *   agent_settled          →  Stop  (agent_end on a pi before 0.80.4)
 *   session_before_compact →  PreCompact
 *   session_compact        →  PostCompact
 *
 * Turn end (#386):
 *   `agent_end` ends one run, not the turn: a retry, error recovery,
 *   compaction, a queued message or a subagent's result can start another
 *   run after it. pi 0.80.4+ emits `agent_settled` once none is left, and the
 *   turn's Stop goes out there, with its latest reply. A turn the user
 *   aborted (Esc) is sent with `stop_reason: "interrupted"`, which CodeIsland
 *   ends without the completion chime.
 *
 * Permission handling:
 *   Dangerous bash commands (`rm -rf`, `sudo`, `chmod 777`) are intercepted and
 *   sent as a blocking PermissionRequest via the codeisland-bridge binary. The
 *   extension waits for CodeIsland's decision and returns allow/block accordingly.
 *
 *   On allow, it records the toolCallId on globalThis.__codeislandAllowedToolCalls
 *   so a co-installed permission-gate.ts can skip its terminal Yes/No dialog
 *   (avoids double confirmation). On timeout / unreachable CodeIsland, no marker
 *   is set and permission-gate remains the fallback prompt.
 *
 *   Note: pi runs every extension tool_call handler; only `{ block: true }` short-
 *   circuits. An island allow alone does not disable permission-gate — the marker
 *   is the coordination point. See companion skip check in permission-gate.ts.
 *
 * Installation:
 *   Drop this file in ~/.pi/agent/extensions/ — it is auto-discovered.
 *
 * Requirements:
 *   - CodeIsland.app running on the same machine
 */

import { execFile, execFileSync } from "node:child_process";
import { existsSync, lstatSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { getuid } from "node:process";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// ── Socket / bridge constants ─────────────────────────────────────────────────

/** Unix socket path CodeIsland listens on (user-scoped). */
const userId = getuid?.() ?? 0;
const SOCKET_PATH =
  process.env.CODEISLAND_SOCKET_PATH || `/tmp/codeisland-${userId}.sock`;

/**
 * Whether the socket at `path` is one this user owns. The default path is a
 * predictable name in /tmp, where any user can create a socket first: theirs
 * would be sent every event and could answer a permission request. `lstat`,
 * not `stat`: a symlink, even to our own socket, stays its owner's to repoint,
 * while a socket of ours in sticky /tmp is ours alone to remove.
 *
 * Exported for tests, which pass their own `lstat` and `uid`.
 */
export function socketIsOwnedByUser(
  path: string,
  lstat: (path: string) => { isSocket(): boolean; uid: number } = lstatSync,
  uid: number | undefined = getuid?.(),
): boolean {
  if (uid === undefined) return false;
  try {
    const stat = lstat(path);
    return stat.isSocket() && stat.uid === uid;
  } catch {
    return false;
  }
}

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
  "CMUX_SURFACE_ID",
  "CMUX_WORKSPACE_ID",
  "ZELLIJ_PANE_ID",
  "ZELLIJ_SESSION_NAME",
  "WEZTERM_PANE",
  "HERDR_ENV",
  "HERDR_PANE_ID",
  "HERDR_SOCKET_PATH",
  "HERDR_BIN_PATH",
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

function herdrMetadata(env: Record<string, string>): Record<string, string> {
  const pane = env.HERDR_PANE_ID?.trim();
  const socket = env.HERDR_SOCKET_PATH?.trim();
  if (env.HERDR_ENV !== "1" || !pane || !socket) return {};
  const binary = env.HERDR_BIN_PATH?.trim();
  return {
    _herdr_pane_id: pane,
    _herdr_socket_path: socket,
    ...(binary ? { _herdr_bin_path: binary } : {}),
  };
}

// ── Subagent children (pi-subagents) ─────────────────────────────────────────

/**
 * The spawning session's pi id when this session is a pi-subagents child.
 *
 * pi-subagents runs a background child as a pi session of its own inside a
 * detached runner, which carries the parent's `getSessionId()` in
 * PI_SUBAGENT_PARENT_SESSION (published for extensions such as
 * pi-permission-system). Every child the runner hosts shares that value, so
 * it is read once, when the extension starts for the child's session.
 */
export function subagentParentSessionId(
  env: Record<string, string | undefined> = process.env,
): string | undefined {
  const parent = env.PI_SUBAGENT_PARENT_SESSION?.trim();
  return parent ? parent : undefined;
}

/** Fallback `agent_type` for a child whose agent name is unknown. */
const DEFAULT_SUBAGENT_TYPE = "subagent";

/**
 * The agent a pi-subagents child runs, from the `<active_agent name="…"/>`
 * tag pi-subagents puts at the top of the child's system prompt.
 */
export function subagentAgentName(systemPrompt: unknown): string | undefined {
  if (typeof systemPrompt !== "string") return undefined;
  const match = /<active_agent name="([^"<>]{1,80})"\s*\/>/.exec(systemPrompt);
  const name = match?.[1]
    ?.replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .trim();
  return name ? name : undefined;
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
    if (!socketIsOwnedByUser(SOCKET_PATH)) {
      resolve(false);
      return;
    }
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
    if (!existsSync(BRIDGE_PATH) || !socketIsOwnedByUser(SOCKET_PATH)) {
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
  const env = collectEnv();
  return {
    session_id: `pi-${sessionId}`,
    _source: "pi",
    _ppid: process.pid,
    _env: env,
    ...herdrMetadata(env),
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

/** The last assistant message in an event.messages array. */
function lastAssistant(
  messages: readonly unknown[],
): AssistantMessage | undefined {
  return messages
    .filter(
      (m): m is AssistantMessage =>
        !!m &&
        typeof m === "object" &&
        (m as { role?: string }).role === "assistant",
    )
    .at(-1);
}

/** Extracts plain text from the last assistant message in an event.messages array. */
function extractLastAssistantText(
  messages: readonly unknown[],
): string {
  const content = lastAssistant(messages)?.content;
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

  /** Set when this pi session is a pi-subagents child (#378). */
  const parentSessionId = subagentParentSessionId();
  /** The child's agent, learned from its first prompt's system prompt. */
  let subagentType = DEFAULT_SUBAGENT_TYPE;

  /**
   * Session IDs for which a blocking PermissionRequest is currently in flight.
   * Non-lifecycle events for these sessions are suppressed to prevent CodeIsland's
   * "answered externally" heuristic from auto-denying while the card is visible.
   */
  const pendingPermissionSessions = new Set<string>();
  /** Sessions for which CodeIsland has already received SessionStart. */
  const startedSessions = new Set<string>();

  /**
   * Whether this pi emits `agent_settled` (0.80.4+), where a turn's Stop goes
   * out (#386). The extension API has no version to read; registerEntryRenderer
   * arrived in the same release, so its presence marks a pi that settles. An
   * older pi never settles and its turn ends at `agent_end`, as before. One
   * that settles without it is caught at its first `agent_settled`.
   */
  let settles =
    typeof (pi as { registerEntryRenderer?: unknown }).registerEntryRenderer === "function";
  /**
   * A turn `agent_settled` has yet to end, per session: its latest reply, and
   * whether its last run was aborted.
   */
  const unsettledTurns = new Map<string, { reply: string; aborted: boolean }>();

  /**
   * An event payload for this pi session. A pi-subagents child also names its
   * parent's CodeIsland session and its agent, so CodeIsland treats its turns
   * as part of the parent's (#378).
   */
  function payload(
    sessionId: string,
    cwd: string,
    extra: Record<string, unknown>,
  ): Record<string, unknown> {
    return base(sessionId, cwd, {
      ...(parentSessionId
        ? { _parent_session_id: `pi-${parentSessionId}`, agent_type: subagentType }
        : {}),
      ...extra,
    }, tty);
  }

  async function ensureSessionStarted(sessionId: string, cwd: string): Promise<void> {
    const sid = `pi-${sessionId}`;
    if (startedSessions.has(sid)) return;

    const sessionName = pi.getSessionName();
    await sendToSocket(
      payload(sessionId, cwd, {
        hook_event_name: "SessionStart",
        ...(sessionName ? { session_title: sessionName } : {}),
      }),
    );
    startedSessions.add(sid);
  }

  /** Ends the session's turn. One the user aborted ends without the completion chime. */
  async function sendStop(
    sessionId: string,
    cwd: string,
    reply: string,
    aborted: boolean,
  ): Promise<void> {
    const sessionName = pi.getSessionName();
    await sendToSocket(
      payload(sessionId, cwd, {
        hook_event_name: "Stop",
        last_assistant_message: reply || undefined,
        ...(aborted ? { stop_reason: "interrupted" } : {}),
        ...(sessionName ? { session_title: sessionName } : {}),
      }),
    );
  }


  /**
   * Forwards an `ask` tool call to CodeIsland as an AskUserQuestion and waits
   * for the user's on-island answer (#244).
   *
   * @returns A block result carrying the answers when the user answered in
   *          CodeIsland, or `null` when the question should fall through to
   *          OMP's own TUI dialog (skipped, denied, or CodeIsland not running).
   */
  async function forwardAskToCodeIsland(
    event: { input: Record<string, unknown>; toolCallId: string },
    ctx: { cwd: string },
    sessionId: string,
    sid: string,
  ): Promise<{ block: true; reason: string } | null> {
    const rawQuestions = Array.isArray(event.input.questions)
      ? (event.input.questions as Array<Record<string, unknown>>)
      : [];
    if (rawQuestions.length === 0) return null;

    // Map OMP's ask schema → Claude-style AskUserQuestion input.
    const questions = rawQuestions.map((q) => {
      const options = Array.isArray(q.options)
        ? (q.options as Array<Record<string, unknown>>)
            .map((o) => ({
              label: typeof o.label === "string" ? o.label : "",
              ...(typeof o.description === "string"
                ? { description: o.description }
                : {}),
            }))
            .filter((o) => o.label.length > 0)
        : [];
      return {
        question: typeof q.question === "string" ? q.question : "Question",
        ...(typeof q.id === "string" && q.id ? { header: q.id } : {}),
        multiSelect: q.multi === true,
        options,
      };
    });

    // CodeIsland keys answers by question text, deduping repeats with `_2`,
    // `_3`… suffixes — reproduce that here so we can translate back to ids.
    const usedKeys = new Set<string>();
    const answerKeys = questions.map(({ question }) => {
      let key = question;
      if (usedKeys.has(key)) {
        let suffix = 2;
        while (usedKeys.has(`${question}_${suffix}`)) suffix += 1;
        key = `${question}_${suffix}`;
      }
      usedKeys.add(key);
      return key;
    });

    pendingPermissionSessions.add(sid);
    let response: Record<string, unknown> | null = null;
    try {
      response = await sendAndWaitResponse(
        payload(sessionId, ctx.cwd, {
          hook_event_name: "PermissionRequest",
          tool_name: "AskUserQuestion",
          tool_input: { questions },
          _pi_tool_call_id: event.toolCallId,
        }),
        86_400_000, // waiting on a human — same 24h budget as PermissionRequest hooks
      );
    } finally {
      pendingPermissionSessions.delete(sid);
    }

    const decision = (
      response?.hookSpecificOutput as Record<string, unknown> | undefined
    )?.decision as Record<string, unknown> | undefined;
    if (decision?.behavior !== "allow") return null;

    const updatedInput = decision.updatedInput as
      | Record<string, unknown>
      | undefined;
    const answers = (updatedInput?.answers ?? {}) as Record<string, unknown>;

    const lines = rawQuestions.map((q, i) => {
      const id = typeof q.id === "string" && q.id ? q.id : `q${i + 1}`;
      const value = answers[answerKeys[i]];
      const text = Array.isArray(value)
        ? value.map(String).join(", ")
        : typeof value === "string"
          ? value
          : "";
      return `${id}: ${text || "(no answer)"}`;
    });

    return {
      block: true,
      reason:
        "The user already answered these questions through the CodeIsland desktop app. " +
        "Their answers:\n" +
        lines.join("\n") +
        "\nDo not ask again — proceed using these answers.",
    };
  }

  // ── Session lifecycle ──────────────────────────────────────────────────────

  pi.on("session_start", async (_event, ctx) => {
    // A child is announced with its first prompt (before_agent_start), once
    // pi-subagents has named it and its agent is known.
    if (parentSessionId) return;
    const sessionId = ctx.sessionManager.getSessionId();
    await ensureSessionStarted(sessionId, ctx.cwd);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await sendToSocket(
      payload(sessionId, ctx.cwd, { hook_event_name: "SessionEnd" }),
    );
    startedSessions.delete(`pi-${sessionId}`);
    unsettledTurns.delete(`pi-${sessionId}`);
  });

  // ── Agent lifecycle ────────────────────────────────────────────────────────

  pi.on("before_agent_start", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;
    if (parentSessionId) {
      subagentType = subagentAgentName(event.systemPrompt) ?? subagentType;
    }
    await ensureSessionStarted(sessionId, ctx.cwd);

    if (pendingPermissionSessions.has(sid)) return;

    const prompt = event.prompt ?? "";
    await sendToSocket(
      payload(sessionId, ctx.cwd, {
        hook_event_name: "UserPromptSubmit",
        prompt,
      }),
    );
  });

  pi.on("agent_end", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;
    const reply = extractLastAssistantText(event.messages);
    const aborted = lastAssistant(event.messages)?.stopReason === "aborted";

    if (settles) {
      // One run of the turn; agent_settled ends it. A run without a reply (a
      // retried error, a parent yielding to its subagent) keeps the last one.
      unsettledTurns.set(sid, {
        reply: reply || unsettledTurns.get(sid)?.reply || "",
        aborted,
      });
      return;
    }

    await ensureSessionStarted(sessionId, ctx.cwd);

    if (pendingPermissionSessions.has(sid)) return;

    await sendStop(sessionId, ctx.cwd, reply, aborted);
  });

  pi.on("agent_settled", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;
    const turn = unsettledTurns.get(sid);
    unsettledTurns.delete(sid);
    if (!settles) {
      // This turn's agent_end already ended it; from now on, this does.
      settles = true;
      return;
    }

    await ensureSessionStarted(sessionId, ctx.cwd);

    if (pendingPermissionSessions.has(sid)) return;

    // `aborted` arrived in pi 1.1.0; before it, the turn's last run tells.
    const aborted = typeof event.aborted === "boolean" ? event.aborted : turn?.aborted === true;
    await sendStop(sessionId, ctx.cwd, turn?.reply ?? "", aborted);
  });

  // ── Tool calls ─────────────────────────────────────────────────────────────

  pi.on("tool_call", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;
    await ensureSessionStarted(sessionId, ctx.cwd);
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

    // `ask` tool → mirror the question into CodeIsland's question UI (#244).
    // tool_call fires BEFORE the TUI dialog opens and OMP awaits this handler,
    // so we can hold the tool, let the user answer on the island (or watch/
    // phone), and feed the answers back by blocking the tool with a result
    // message. Skip/deny or an unreachable CodeIsland falls through to OMP's
    // own TUI dialog — graceful degradation, never a lost question.
    if (event.toolName === "ask") {
      const answered = await forwardAskToCodeIsland(event, ctx, sessionId, sid);
      if (answered) return answered;
      return undefined;
    }

    // Dangerous bash → send blocking PermissionRequest via bridge.
    if (
      event.toolName === "bash" &&
      typeof event.input.command === "string" &&
      isDangerous(event.input.command)
    ) {
      pendingPermissionSessions.add(sid);

      const request = payload(sessionId, ctx.cwd, {
        hook_event_name: "PermissionRequest",
        tool_name: toolName,
        tool_input: toolInput,
        _pi_tool_call_id: event.toolCallId,
      });

      let response: Record<string, unknown> | null = null;
      try {
        response = await sendAndWaitResponse(request);
      } finally {
        pendingPermissionSessions.delete(sid);
      }

      const behavior = (
        response?.hookSpecificOutput as Record<string, unknown> | undefined
      )?.decision as Record<string, unknown> | undefined;

      if (behavior?.behavior === "deny") {
        return { block: true, reason: "Blocked by CodeIsland" };
      }

      // Island allow: mark this tool call so permission-gate skips the TUI prompt.
      // Only mark explicit allow — timeout / null must still fall through to the gate.
      if (behavior?.behavior === "allow" && event.toolCallId) {
        const g = globalThis as typeof globalThis & {
          __codeislandAllowedToolCalls?: Set<string>;
        };
        if (!g.__codeislandAllowedToolCalls) {
          g.__codeislandAllowedToolCalls = new Set();
        }
        g.__codeislandAllowedToolCalls.add(event.toolCallId);
      }

      // Approved or unreachable — fall through to PreToolUse / permission-gate.
    }

    // Non-blocking PreToolUse for all other tool calls.
    if (!pendingPermissionSessions.has(sid)) {
      await sendToSocket(
        payload(sessionId, ctx.cwd, {
          hook_event_name: "PreToolUse",
          tool_name: toolName,
          tool_input: toolInput,
        }),
      );
    }

    return undefined;
  });

  pi.on("tool_result", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;
    await ensureSessionStarted(sessionId, ctx.cwd);

    if (pendingPermissionSessions.has(sid)) return;

    await sendToSocket(
      payload(sessionId, ctx.cwd, { hook_event_name: "PostToolUse" }),
    );
  });

  // ── Compaction ─────────────────────────────────────────────────────────────

  pi.on("session_before_compact", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await ensureSessionStarted(sessionId, ctx.cwd);
    await sendToSocket(
      payload(sessionId, ctx.cwd, { hook_event_name: "PreCompact" }),
    );
  });

  pi.on("session_compact", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await ensureSessionStarted(sessionId, ctx.cwd);
    await sendToSocket(
      payload(sessionId, ctx.cwd, { hook_event_name: "PostCompact" }),
    );
  });
}
