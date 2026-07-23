// CodeIsland pi extension
// version: v6
// OMP-compatible install

/**
 * @fileoverview CodeIsland Integration Extension for Oh My Pi / OMP.
 *
 * This is the same socket bridge as codeisland-pi.ts, but imports OMP's
 * package scope so `omp` can load it from ~/.omp/agent/extensions.
 */

import { execFile, execFileSync } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { getuid } from "node:process";
import type {
  AgentToolContext,
  AgentToolResult,
} from "@oh-my-pi/pi-agent-core";
import type {
  ExtensionAPI,
  ExtensionContext,
  ToolDefinition,
} from "@oh-my-pi/pi-coding-agent/extensibility/extensions/types";
import type {
  AskToolDetails,
  QuestionResult,
} from "@oh-my-pi/pi-coding-agent/tools/ask";
import type { ToolSession } from "@oh-my-pi/pi-coding-agent/tools";

// ── Socket / bridge constants ─────────────────────────────────────────────────

/** Unix socket path CodeIsland listens on (user-scoped). */
const userId = getuid?.() ?? 0;
const SOCKET_PATH = `/tmp/codeisland-${userId}.sock`;

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

/** Result of a cancellable bridge call: the response promise plus a cancel handle. */
interface CancellableBridge {
  promise: Promise<Record<string, unknown> | null>;
  cancel: () => void;
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
  return sendAndWaitResponseCancellable(payload, timeoutMs).promise;
}

/**
 * Same as {@link sendAndWaitResponse} but exposes a `cancel()` that SIGKILLs
 * the bridge child process so the caller can abort a pending request when
 * the answer arrives from another source (e.g. the TUI dialog).
 */
function sendAndWaitResponseCancellable(
  payload: object,
  timeoutMs = 30_000,
): CancellableBridge {
  const { promise, resolve } = Promise.withResolvers<Record<string, unknown> | null>();

  if (!existsSync(BRIDGE_PATH)) {
    resolve(null);
    return { promise, cancel: () => {} };
  }

  let child: ChildProcess | undefined;
  try {
    child = execFile(
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

  const cancel = () => {
    if (child && child.pid) {
      try { child.kill("SIGKILL"); } catch { /* already dead */ }
    }
    resolve(null);
  };

  return { promise, cancel };
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
    (m): m is { role: "assistant"; content: unknown } =>
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

export interface AskRaceSettlement<T> {
  promise: Promise<T>;
  settle: (value: T, cancelLoser: () => void) => boolean;
}

/**
 * First-writer-wins settlement gate for the native Ask / CodeIsland race.
 *
 * JavaScript runs adjacent promise callbacks serially, so flipping the guard
 * before cancelling the loser makes settlement idempotent even when both
 * answers arrive in the same event-loop turn. Loser cancellation is best
 * effort: a cancellation cleanup failure must not replace the user's answer.
 */
export function createAskRaceSettlement<T>(): AskRaceSettlement<T> {
  const { promise, resolve } = Promise.withResolvers<T>();
  let isSettled = false;

  return {
    promise,
    settle(value, cancelLoser) {
      if (isSettled) return false;
      isSettled = true;
      try {
        cancelLoser();
      } catch {
        // Cancellation is cleanup; the winning answer remains authoritative.
      }
      resolve(value);
      return true;
    },
  };
}

interface RawQuestion {
  id: string;
  question: string;
  header?: string;
  options: { label: string; description?: string; preview?: string }[];
  multi?: boolean;
  recommended?: number;
}

export function mapAskQuestionsToCodeIsland(questions: RawQuestion[]) {
  return questions.map((question) => ({
    question: question.question,
    header: question.header || question.id,
    multiSelect: question.multi ?? false,
    options: question.options.map((option) => ({
      label: option.label,
      ...(option.description ? { description: option.description } : {}),
    })),
  }));
}

export type ClassifiedCodeIslandAskResponse =
  | { kind: "unavailable" }
  | { kind: "denied" }
  | { kind: "allowed"; updatedInput: Record<string, unknown> };

function isValidAnswerValue(value: unknown): boolean {
  if (typeof value === "string") return value.length > 0;
  return Array.isArray(value)
    && value.length > 0
    && value.every((item) => typeof item === "string" && item.length > 0);
}

export function classifyCodeIslandAskResponse(
  response: Record<string, unknown> | null,
  expectedAnswerKeys?: readonly string[],
): ClassifiedCodeIslandAskResponse {
  if (response === null) return { kind: "unavailable" };

  const decision = (
    response.hookSpecificOutput as Record<string, unknown> | undefined
  )?.decision as Record<string, unknown> | undefined;
  if (decision?.behavior === "deny") return { kind: "denied" };
  if (decision?.behavior !== "allow") return { kind: "unavailable" };

  const updatedInput = decision.updatedInput;
  if (!updatedInput || typeof updatedInput !== "object" || Array.isArray(updatedInput)) {
    return { kind: "unavailable" };
  }
  const answers = (updatedInput as Record<string, unknown>).answers;
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) {
    return { kind: "unavailable" };
  }
  const answerMap = answers as Record<string, unknown>;
  const answerValues = expectedAnswerKeys
    ? expectedAnswerKeys.map((key) => answerMap[key])
    : Object.values(answerMap);
  if (answerValues.length === 0 || answerValues.some((value) => !isValidAnswerValue(value))) {
    return { kind: "unavailable" };
  }
  return {
    kind: "allowed",
    updatedInput: updatedInput as Record<string, unknown>,
  };
}

// ── Extension ─────────────────────────────────────────────────────────────────

export default function codeislandExtension(pi: ExtensionAPI) {
  const askToolRenderer = pi.pi.askToolRenderer;

  class ToolAbortError extends Error {
    override name = "ToolAbortError";
  }
  /** TTY path detected once at startup. */
  const tty = detectTty();

  /**
   * Session IDs for which a blocking PermissionRequest is currently in flight.
   * Non-lifecycle events for these sessions are suppressed to prevent CodeIsland's
   * "answered externally" heuristic from auto-denying while the card is visible.
   */
  const pendingPermissionSessions = new Set<string>();
  /** Sessions for which CodeIsland has already received SessionStart. */
  const startedSessions = new Set<string>();

  async function ensureSessionStarted(sessionId: string, cwd: string): Promise<void> {
    const sid = `pi-${sessionId}`;
    if (startedSessions.has(sid)) return;

    const sessionName = pi.getSessionName();
    await sendToSocket(
      base(sessionId, cwd, {
        hook_event_name: "SessionStart",
        ...(sessionName ? { session_title: sessionName } : {}),
      }, tty),
    );
    startedSessions.add(sid);
  }


  // ── Shadow "ask" tool (#244 v3: native rendering + parallel answering) ─────
  //
  // Registers a custom "ask" that races CodeIsland against OMP's own AskTool.
  // Reusing AskTool keeps terminal rendering, navigation, timeout, speech, and
  // future OMP behavior in one implementation. The first real answer wins.

  type CompatibleQuestionResult = QuestionResult & { note?: string };
  type CompatibleAskToolDetails = AskToolDetails & {
    note?: string;
    chatRedirect?: boolean;
    questions?: string[];
    results?: CompatibleQuestionResult[];
  };

  function isPlanModeEnabled(ctx: ExtensionContext): boolean {
    const entries = ctx.sessionManager.getEntries();
    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const entry = entries[index];
      if (entry?.type === "mode_change") return entry.mode === "plan";
    }
    return false;
  }

  function createNativeAskTool(ctx?: ExtensionContext) {
    const session: ToolSession = {
      cwd: ctx?.cwd ?? process.cwd(),
      hasUI: ctx?.hasUI ?? true,
      getSessionFile: () => ctx?.sessionManager.getSessionFile() ?? null,
      getSessionSpawns: () => null,
      settings: pi.pi.settings,
      getPlanModeState: () => ({
        enabled: ctx ? isPlanModeEnabled(ctx) : false,
        planFilePath: "local://PLAN.md",
      }),
    };
    return new pi.pi.AskTool(session);
  }

  function createNativeAskContext(
    ctx: ExtensionContext,
    onAbort: () => void,
  ): AgentToolContext {
    return {
      sessionManager: ctx.sessionManager,
      modelRegistry: ctx.modelRegistry,
      model: ctx.model,
      isIdle: () => ctx.isIdle(),
      hasQueuedMessages: () => ctx.hasPendingMessages(),
      abort: onAbort,
      settings: pi.pi.settings,
      ui: ctx.ui,
      hasUI: ctx.hasUI,
    };
  }

  /**
   * CodeIsland deduplicates repeated question text with `_2`, `_3`… suffixes.
   * Reproduce that keying so we can translate answers back to OMP question ids.
   */
  function computeAnswerKeys(questions: { question: string }[]): string[] {
    const used: Record<string, true> = {};
    return questions.map(({ question }) => {
      let key = question;
      if (used[key]) {
        let suffix = 2;
        while (used[`${question}_${suffix}`]) suffix += 1;
        key = `${question}_${suffix}`;
      }
      used[key] = true;
      return key;
    });
  }

  /** Converts CodeIsland's answer map into typed question results. */
  function islandAnswersToResults(
    answers: Record<string, unknown>,
    answerDetails: Record<string, unknown>,
    answerKeys: string[],
    questions: RawQuestion[],
  ): CompatibleQuestionResult[] {
    return questions.map((q, i) => {
      const answerKey = answerKeys[i];
      const value = answers[answerKey];
      const optionLabels = q.options.map((o) => o.label);
      const rawDetails = answerDetails[answerKey];
      const details = rawDetails && typeof rawDetails === "object"
        ? rawDetails as Record<string, unknown>
        : undefined;
      const detailedSelected = Array.isArray(details?.selectedOptions)
        ? details.selectedOptions.map(String)
        : undefined;
      const detailedCustomInput = typeof details?.customInput === "string"
        ? details.customInput
        : undefined;
      const hasStructuredDetails = detailedSelected !== undefined
        || detailedCustomInput !== undefined;

      let selectedOptions: string[] = [];
      let customInput: string | undefined;
      if (hasStructuredDetails) {
        selectedOptions = detailedSelected ?? [];
        customInput = detailedCustomInput;
      } else if (Array.isArray(value)) {
        const values = value.map(String);
        selectedOptions = values.filter((candidate) => optionLabels.includes(candidate));
        const customValues = values.filter((candidate) => !optionLabels.includes(candidate));
        if (customValues.length > 0) customInput = customValues.join("\n");
      } else if (typeof value === "string") {
        if (optionLabels.includes(value) || q.multi) {
          // Legacy CodeIsland versions flatten multi-select values into one string.
          // Keep that value intact rather than guessing at comma boundaries.
          selectedOptions = [value];
        } else {
          customInput = value;
        }
      }

      return {
        id: q.id,
        question: q.question,
        options: optionLabels,
        multi: q.multi ?? false,
        selectedOptions,
        ...(customInput !== undefined ? { customInput } : {}),
      };
    });
  }

  /** Mirrors built-in AskTool.formatQuestionResult for CodeIsland answers. */
  function formatQuestionResult(result: CompatibleQuestionResult): string {
    const noteSuffix = result.note ? ` (note: ${result.note})` : "";
    if (result.customInput !== undefined) {
      return `${result.id}: "${result.customInput}"${noteSuffix}`;
    }
    if (result.selectedOptions.length > 0) {
      const suffix = `${result.timedOut ? " (auto-selected after timeout)" : ""}${noteSuffix}`;
      return result.multi
        ? `${result.id}: [${result.selectedOptions.join(", ")}]${suffix}`
        : `${result.id}: ${result.selectedOptions[0]}${suffix}`;
    }
    return `${result.id}: (cancelled)${noteSuffix}`;
  }

  /** Mirrors built-in AskTool.formatSingleQuestionResponse for CodeIsland answers. */
  function formatSingleQuestionResponse(result: CompatibleQuestionResult): string {
    const parts: string[] = [];
    if (result.selectedOptions.length > 0) {
      const selectedText = result.multi
        ? `User selected: ${result.selectedOptions.join(", ")}`
        : `User selected: ${result.selectedOptions[0]}`;
      parts.push(result.timedOut ? `${selectedText} (auto-selected after timeout)` : selectedText);
    }
    if (result.customInput !== undefined) {
      parts.push(
        result.customInput.includes("\n")
          ? `User provided custom input:\n${result.customInput.split("\n").map((l: string) => `  ${l}`).join("\n")}`
          : `User provided custom input: ${result.customInput}`,
      );
    }
    if (result.note) {
      parts.push(
        result.note.includes("\n")
          ? `User added note:\n${result.note.split("\n").map((l: string) => `  ${l}`).join("\n")}`
          : `User added note: ${result.note}`,
      );
    }
    return parts.length > 0 ? parts.join("\n") : "User cancelled the selection";
  }

  /** Builds an AskTool-compatible result for answers returned by CodeIsland. */
  function buildAskResult(
    results: CompatibleQuestionResult[],
  ): AgentToolResult<CompatibleAskToolDetails> {
    if (results.length === 1) {
      const r = results[0];
      return {
        content: [{ type: "text", text: formatSingleQuestionResponse(r) }],
        details: {
          question: r.question,
          options: r.options,
          multi: r.multi,
          selectedOptions: r.selectedOptions,
          ...(r.customInput !== undefined ? { customInput: r.customInput } : {}),
          ...(r.note !== undefined ? { note: r.note } : {}),
          ...(r.timedOut ? { timedOut: true } : {}),
        },
      };
    }
    return {
      content: [{ type: "text", text: `User answers:\n${results.map(formatQuestionResult).join("\n")}` }],
      details: { results },
    };
  }

  /** Gate outcome: a winning source, a genuine failure, or user cancellation. */
  type GateOutcome =
    | { source: "island" | "tui"; result: AgentToolResult<CompatibleAskToolDetails> }
    | { source: "error"; error: unknown }
    | { source: "cancel" };

  const reservedAskOptionLabels: Record<string, true> = {
    "Other (type your own)": true,
    "Chat about this": true,
    "Next →": true,
  };

  // Keep the v3 input additions for OMP 16.3.x, whose native Ask schema does
  // not yet expose header/preview even though its executor accepts the fields.
  const askOptionParameters = pi.zod.object({
    label: pi.zod.string(),
    description: pi.zod.string().optional(),
    preview: pi.zod.string().optional(),
  }).refine(
    (option) => reservedAskOptionLabels[option.label] !== true,
    { message: "Option label collides with a reserved Ask UI action" },
  );
  const askParameters = pi.zod.object({
    questions: pi.zod.array(
      pi.zod.object({
        id: pi.zod.string(),
        question: pi.zod.string(),
        header: pi.zod.string().optional(),
        options: pi.zod.array(askOptionParameters),
        multi: pi.zod.boolean().optional(),
        recommended: pi.zod.number().optional(),
      }),
    ).min(1),
  });

  // Reuse the native AskTool's LLM-facing label and description so the shadow
  // tool preserves OMP's behavioral guidance (default action, check existing
  // info first, only ask on major tradeoffs, never hand-write "Other", etc.).
  const nativeAskMetadata = createNativeAskTool();

  const askToolDefinition: ToolDefinition<
    typeof askParameters,
    CompatibleAskToolDetails
  > & {
    concurrency: "exclusive";
    mergeCallAndResult: boolean;
    strict: true;
    approval: "read";
  } = {
    name: "ask",
    label: nativeAskMetadata.label,
    description: nativeAskMetadata.description,
    parameters: askParameters,
    strict: true,
    approval: "read",
    concurrency: "exclusive",
    mergeCallAndResult: askToolRenderer.mergeCallAndResult,
    renderCall: askToolRenderer.renderCall,
    renderResult: askToolRenderer.renderResult,
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const sessionId = ctx.sessionManager.getSessionId();
      const sid = `pi-${sessionId}`;
      const questions = params.questions;

      if (!ctx.hasUI) {
        ctx.abort();
        throw new ToolAbortError("Ask tool requires interactive mode");
      }

      const islandQuestions = mapAskQuestionsToCodeIsland(questions);
      const answerKeys = computeAnswerKeys(questions);

      const tuiAbort = new AbortController();
      const race = createAskRaceSettlement<GateOutcome>();

      const islandBridge = sendAndWaitResponseCancellable(
        base(sessionId, ctx.cwd, {
          hook_event_name: "PermissionRequest",
          tool_name: "AskUserQuestion",
          tool_input: { questions: islandQuestions },
          _pi_tool_call_id: toolCallId,
          _codeisland_native_ask_racing: true,
        }, tty),
        86_400_000,
      );

      const handleExternalAbort = () => {
        race.settle({ source: "cancel" }, () => {
          islandBridge.cancel();
          tuiAbort.abort();
        });
      };
      if (signal?.aborted) {
        islandBridge.cancel();
        ctx.abort();
        throw new ToolAbortError("Ask tool was cancelled by the user");
      }
      signal?.addEventListener("abort", handleExternalAbort, { once: true });

      pendingPermissionSessions.add(sid);

      const islandPromise = islandBridge.promise.then(
        (response): CompatibleQuestionResult[] | null | undefined => {
          const classified = classifyCodeIslandAskResponse(response, answerKeys);
          if (classified.kind === "unavailable") return undefined;
          if (classified.kind === "denied") return null;

          const answers = (classified.updatedInput.answers ?? {}) as Record<string, unknown>;
          const answerDetails = (
            classified.updatedInput._codeislandAnswerDetails ?? {}
          ) as Record<string, unknown>;
          return islandAnswersToResults(
            answers,
            answerDetails,
            answerKeys,
            questions,
          );
        },
      );

      const nativeAsk = createNativeAskTool(ctx);
      const nativeContext = createNativeAskContext(ctx, () => undefined);
      const tuiPromise = nativeAsk.execute(
        toolCallId,
        params,
        tuiAbort.signal,
        onUpdate,
        nativeContext,
      ).catch((error: unknown): AgentToolResult<AskToolDetails> | null => {
        if (
          tuiAbort.signal.aborted
          || (error instanceof Error && error.name === "ToolAbortError")
        ) {
          return null;
        }
        throw error;
      });

      // A real answer, explicit deny, native failure, or cancellation settles
      // once and cancels the other side. Only an unavailable/invalid bridge is
      // a fallback signal that leaves OMP's native Ask UI alive.
      islandPromise.then(
        (results) => {
          if (results === null) {
            race.settle({ source: "cancel" }, () => tuiAbort.abort());
          } else if (results && results.length > 0) {
            race.settle(
              { source: "island", result: buildAskResult(results) },
              () => tuiAbort.abort(),
            );
          }
        },
        () => {
          // Bridge/parsing failure also falls back to OMP's native Ask UI.
        },
      );

      tuiPromise.then(
        (result) => {
          const outcome: GateOutcome = result
            ? { source: "tui", result }
            : { source: "cancel" };
          race.settle(outcome, () => islandBridge.cancel());
        },
        (error: unknown) => {
          race.settle({ source: "error", error }, () => islandBridge.cancel());
        },
      );

      try {
        const winner = await race.promise;
        if (winner.source === "error") throw winner.error;
        if (winner.source === "cancel") {
          ctx.abort();
          throw new ToolAbortError("Ask tool was cancelled by the user");
        }
        return winner.result;
      } finally {
        signal?.removeEventListener("abort", handleExternalAbort);
        pendingPermissionSessions.delete(sid);
      }
    },
  };
  pi.registerTool(askToolDefinition);

  // ── Session lifecycle ──────────────────────────────────────────────────────

  pi.on("session_start", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await ensureSessionStarted(sessionId, ctx.cwd);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "SessionEnd" }, tty),
    );
    startedSessions.delete(`pi-${sessionId}`);
  });

  // ── Agent lifecycle ────────────────────────────────────────────────────────

  pi.on("before_agent_start", async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const sid = `pi-${sessionId}`;
    await ensureSessionStarted(sessionId, ctx.cwd);

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
    await ensureSessionStarted(sessionId, ctx.cwd);

    if (pendingPermissionSessions.has(sid)) return;

    const lastAssistantMessage = extractLastAssistantText(event.messages);
    const sessionName = pi.getSessionName();

    await sendToSocket(
      base(sessionId, ctx.cwd, {
        hook_event_name: "Stop",
        last_assistant_message: lastAssistantMessage || undefined,
        ...(sessionName ? { session_title: sessionName } : {}),
      }, tty),
    );
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
    await ensureSessionStarted(sessionId, ctx.cwd);

    if (pendingPermissionSessions.has(sid)) return;

    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "PostToolUse" }, tty),
    );
  });

  // ── Compaction ─────────────────────────────────────────────────────────────

  pi.on("session_before_compact", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await ensureSessionStarted(sessionId, ctx.cwd);
    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "PreCompact" }, tty),
    );
  });

  pi.on("session_compact", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    await ensureSessionStarted(sessionId, ctx.cwd);
    await sendToSocket(
      base(sessionId, ctx.cwd, { hook_event_name: "PostCompact" }, tty),
    );
  });
}
