import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { createServer } from "net";
import { tmpdir } from "os";
import { join } from "path";

import plugin, {
  answerKeys,
  answersFromDecision,
  createV2Mapper,
  createV2Runtime,
  permissionReplyFromDecision,
  v2BridgeEnv,
  v2FormAnswer,
  v2IsSharedService,
  v2QuestionsFromForm,
  v2TerminalEnv,
  v2ToolName,
} from "../../Sources/CodeIsland/Resources/codeisland-opencode.js";

// Event shapes follow OpenCode 2.0.14 (anomalyco/opencode@v2.0.14):
// envelope {id, created, type, location?, data} — packages/schema/src/event.ts.
let nextId = 0;
const ev = (type: string, data: Record<string, unknown>) => ({ id: `evt_${++nextId}`, created: Date.now(), type, data });
const base = (sessionId: string, extra: Record<string, unknown>) => ({ session_id: sessionId, _source: "opencode", ...extra });
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

const questionForm = (fields: unknown[]) => ({
  id: "frm_1",
  sessionID: "ses_a",
  title: "Questions",
  metadata: { kind: "question", tool: { messageID: "msg_1", id: "call_1" } },
  fields,
});

describe("plugin module shape", () => {
  test("one default export serves both plugin APIs", () => {
    // v1 (readV1Plugin) calls server(); v2 (PluginModule) decodes {id, setup}
    // and would take an `effect` key over `setup`, so there must not be one.
    expect(plugin.id).toBe("codeisland");
    expect(typeof plugin.server).toBe("function");
    expect(typeof plugin.setup).toBe("function");
    expect("effect" in plugin).toBe(false);
  });
});

describe("answers", () => {
  const questions = [
    { question: "Pick one", options: [{ label: "A" }, { label: "B" }], multiSelect: false },
    { question: "Pick many", options: [{ label: "x, y" }, { label: "z" }], multiSelect: true },
    { question: "Pick one", options: [{ label: "C" }], multiSelect: false },
  ];

  test("answer keys mirror CodeIsland's duplicate suffixes", () => {
    expect(answerKeys(questions)).toEqual(["Pick one", "Pick many", "Pick one_2"]);
  });

  test("answers are matched by key, not by JSON key order", () => {
    const decision = {
      behavior: "allow",
      updatedInput: {
        // Swift dictionaries serialize in hash order; position means nothing.
        answers: { "Pick one_2": "C", "Pick many": "x, y, z", "Pick one": "B" },
        _codeislandAnswerDetails: { "Pick many": { selectedOptions: ["x, y", "z"] } },
      },
    };
    expect(answersFromDecision(questions, decision)).toEqual([["B"], ["x, y", "z"], ["C"]]);
  });

  test("custom input joins the selected labels; missing answers stay empty", () => {
    const decision = {
      updatedInput: {
        answers: { "Pick many": "z, typed" },
        _codeislandAnswerDetails: { "Pick many": { selectedOptions: ["z"], customInput: "typed" } },
      },
    };
    expect(answersFromDecision(questions, decision)).toEqual([[], ["z", "typed"], []]);
  });

  test("answers keyed some other way keep the old positional read", () => {
    const decision = { updatedInput: { answers: { Header: "B" } } };
    expect(answersFromDecision([questions[0]], decision)).toEqual([["B"]]);
  });

  test("permission decisions map to reply verbs", () => {
    expect(permissionReplyFromDecision({ behavior: "allow" })).toBe("once");
    expect(permissionReplyFromDecision({ behavior: "allow", updatedPermissions: [] })).toBe("always");
    expect(permissionReplyFromDecision({ behavior: "always" })).toBe("always");
    expect(permissionReplyFromDecision({ behavior: "deny" })).toBe("reject");
    expect(permissionReplyFromDecision(undefined)).toBeNull();
  });
});

describe("OpenCode 2 event mapping", () => {
  test("a full turn maps to CodeIsland hook events", () => {
    const map = createV2Mapper(base);
    expect(map(ev("session.created", { sessionID: "ses_a", location: { directory: "/p/app" }, projectID: "prj", slug: "s", version: "2.0.14" })))
      .toEqual({ session_id: "opencode-ses_a", _source: "opencode", hook_event_name: "SessionStart", cwd: "/p/app" });
    expect(map(ev("session.inbox.enqueued", { sessionID: "ses_a", inboxID: "msg_u", item: { type: "user", payload: { text: "fix it" }, delivery: "queue" } })))
      .toMatchObject({ hook_event_name: "UserPromptSubmit", prompt: "fix it", cwd: "/p/app" });
    expect(map(ev("session.tool.input.started", { sessionID: "ses_a", assistantMessageID: "msg_a", id: "call_1", name: "shell" }))).toBeNull();
    expect(map(ev("session.tool.called", { sessionID: "ses_a", assistantMessageID: "msg_a", id: "call_1", input: { command: "ls" }, executed: true })))
      .toMatchObject({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "ls" } });
    expect(map(ev("session.tool.success", { sessionID: "ses_a", assistantMessageID: "msg_a", id: "call_1", content: [], executed: true })))
      .toMatchObject({ hook_event_name: "PostToolUse", tool_name: "Bash" });
    expect(map(ev("session.tool.failed", { sessionID: "ses_a", assistantMessageID: "msg_a", id: "call_2", error: {}, executed: true })))
      .toMatchObject({ hook_event_name: "PostToolUseFailure", tool_name: "Tool" });
    expect(map(ev("session.renamed", { sessionID: "ses_a", title: "Fix the build" }))).toBeNull();
    expect(map(ev("session.text.ended", { sessionID: "ses_a", assistantMessageID: "msg_a", ordinal: 0, text: "Done." }))).toBeNull();
    expect(map(ev("session.status", { sessionID: "ses_a", status: { type: "idle" } })))
      .toMatchObject({ hook_event_name: "Stop", last_assistant_message: "Done.", codex_title: "Fix the build" });
    expect(map(ev("session.deleted", { sessionID: "ses_a" })))
      .toMatchObject({ session_id: "opencode-ses_a", hook_event_name: "SessionEnd" });
  });

  test("busy/retry status marks the session working", () => {
    const map = createV2Mapper(base);
    expect(map(ev("session.status", { sessionID: "ses_b", status: { type: "busy" } })))
      .toMatchObject({ hook_event_name: "UserPromptSubmit" });
    expect(map(ev("session.status", { sessionID: "ses_b", status: { type: "retry", attempt: 1, message: "", next: 1 } })))
      .toMatchObject({ hook_event_name: "UserPromptSubmit" });
  });

  test("permission.asked uses the v2 shape (action/resources), with v2 action names", () => {
    const map = createV2Mapper(base);
    const mapped = map(ev("permission.asked", {
      id: "per_1", sessionID: "ses_a", action: "shell", resources: ["rm -rf build"], message: "Delete build output",
    }));
    expect(mapped).toMatchObject({
      hook_event_name: "PermissionRequest",
      tool_name: "Bash",
      tool_input: { command: "rm -rf build", patterns: ["rm -rf build"], description: "Delete build output" },
      _opencode_request_id: "per_1",
      _opencode_session_id: "ses_a",
    });
    expect(map(ev("permission.asked", { id: "per_2", sessionID: "ses_a", action: "edit", resources: ["/p/a.ts"] })))
      .toMatchObject({ tool_name: "Edit", tool_input: { file_path: "/p/a.ts" } });
  });

  test("question forms become AskUserQuestion; other forms are ignored", () => {
    const map = createV2Mapper(base);
    const form = questionForm([
      { key: "q0", title: "Lang", description: "Which language?", type: "string", options: [{ value: "Go", label: "Go" }], custom: true },
      { key: "q1", title: "Targets", description: "Which targets?", type: "multiselect", options: [{ value: "mac", label: "mac", description: "macOS" }], custom: true },
    ]);
    const mapped = map(ev("form.created", { form }));
    expect(mapped).toMatchObject({
      session_id: "opencode-ses_a",
      hook_event_name: "PermissionRequest",
      tool_name: "AskUserQuestion",
      tool_input: {
        questions: [
          { question: "Which language?", header: "Lang", options: [{ label: "Go" }], multiSelect: false },
          { question: "Which targets?", header: "Targets", options: [{ label: "mac", description: "macOS" }], multiSelect: true },
        ],
      },
      _opencode_request_id: "frm_1",
    });
    expect(map(ev("form.created", { form: { ...form, metadata: { kind: "mcp.elicitation" } } }))).toBeNull();
  });

  test("v1-shaped events (properties, not data) are not mistaken for v2", () => {
    const map = createV2Mapper(base);
    expect(map({ type: "session.created", properties: { info: { id: "ses_x", directory: "/p" } } })).toBeNull();
  });

  test("tool name mapping keeps CodeIsland's special cases", () => {
    expect(v2ToolName("shell")).toBe("Bash");
    expect(v2ToolName("subagent")).toBe("Task");
    expect(v2ToolName("read")).toBe("Read");
    expect(v2ToolName(undefined)).toBe("Tool");
  });

  test("form answers: single choice is a string, multiselect an array, unanswered omitted", () => {
    const form = questionForm([
      { key: "q0", type: "string" },
      { key: "q1", type: "multiselect", options: [] },
      { key: "q2", type: "string" },
    ]);
    expect(v2FormAnswer(form, [["Go"], ["mac", "ios"], []])).toEqual({ q0: "Go", q1: ["mac", "ios"] });
  });

  test("questions come from question forms only", () => {
    expect(v2QuestionsFromForm(undefined)).toBeNull();
    expect(v2QuestionsFromForm({ metadata: { kind: "question" }, fields: [] })).toBeNull();
  });
});

describe("OpenCode 2 runtime round-trips", () => {
  function harness(opts: { answer?: unknown; canAnswerForms?: boolean } = {}) {
    const sent: any[] = [];
    const asked: any[] = [];
    const replies: any[] = [];
    let release: (value: unknown) => void = () => {};
    const handle = createV2Runtime({
      base,
      send: async (payload: unknown) => { sent.push(payload); return true; },
      ask: (payload: unknown) => {
        asked.push(payload);
        return opts.answer === undefined
          ? new Promise((resolve) => { release = resolve; })
          : Promise.resolve(opts.answer);
      },
      replyPermission: async (...args: unknown[]) => { replies.push(["permission", ...args]); },
      replyForm: async (...args: unknown[]) => { replies.push(["form", ...args]); return true; },
      cancelForm: async (...args: unknown[]) => { replies.push(["cancel", ...args]); return true; },
      canAnswerForms: () => opts.canAnswerForms ?? true,
    });
    return { handle, sent, asked, replies, release: (value: unknown) => release(value) };
  }
  test("approving in the notch replies through the v2 permission API", async () => {
    const h = harness({ answer: { hookSpecificOutput: { decision: { behavior: "allow", reason: "ok" } } } });
    await h.handle(ev("permission.asked", { id: "per_9", sessionID: "ses_p", action: "shell", resources: ["ls"] }));
    await settle();
    expect(h.asked).toHaveLength(1);
    expect(h.replies).toEqual([["permission", "ses_p", "per_9", "once", "ok"]]);
  });

  test("answering a question replies to the form; skipping cancels it", async () => {
    const form = questionForm([
      { key: "q0", title: "Lang", description: "Which language?", type: "string", options: [{ value: "Go", label: "Go" }] },
      { key: "q1", title: "Targets", description: "Which targets?", type: "multiselect", options: [{ value: "mac", label: "mac" }, { value: "ios", label: "ios" }] },
    ]);
    const answered = harness({
      answer: {
        hookSpecificOutput: {
          decision: {
            behavior: "allow",
            updatedInput: {
              answers: { "Which targets?": "mac, ios", "Which language?": "Go" },
              _codeislandAnswerDetails: { "Which targets?": { selectedOptions: ["mac", "ios"] } },
            },
          },
        },
      },
    });
    await answered.handle(ev("form.created", { form }));
    await settle();
    expect(answered.asked[0]).not.toHaveProperty("_opencode_form");
    expect(answered.replies).toEqual([["form", "ses_a", "frm_1", { q0: "Go", q1: ["mac", "ios"] }]]);

    const skipped = harness({ answer: { hookSpecificOutput: { decision: { behavior: "deny" } } } });
    await skipped.handle(ev("form.created", { form }));
    await settle();
    expect(skipped.replies).toEqual([["cancel", "ses_a", "frm_1"]]);
  });

  test("without a verified route back, a question is shown but not held", async () => {
    const h = harness({ canAnswerForms: false });
    await h.handle(ev("form.created", { form: questionForm([{ key: "q0", description: "Proceed?", type: "string" }]) }));
    expect(h.asked).toHaveLength(0);
    expect(h.sent[0]).toMatchObject({ hook_event_name: "Notification", message: "Proceed?" });
  });

  test("while a request is held, unrelated activity is suppressed but replies pass", async () => {
    const h = harness();
    await h.handle(ev("permission.asked", { id: "per_h", sessionID: "ses_h", action: "shell", resources: ["ls"] }));
    await h.handle(ev("session.tool.called", { sessionID: "ses_h", assistantMessageID: "m", id: "c", input: {}, executed: true }));
    await h.handle(ev("permission.replied", { sessionID: "ses_h", requestID: "per_h", reply: "once" }));
    expect(h.sent.map((p) => p.hook_event_name)).toEqual(["PostToolUse"]);
    h.release(null);
    await settle();
    expect(h.replies).toEqual([]);
  });

  test("a session created before the plugin started is looked up once for its directory", async () => {
    const sent: any[] = [];
    const lookups: string[] = [];
    const handle = createV2Runtime({
      base,
      send: async (payload: unknown) => { sent.push(payload); return true; },
      ask: async () => null,
      replyPermission: async () => {},
      replyForm: async () => true,
      cancelForm: async () => true,
      canAnswerForms: () => true,
      lookupSession: async (id: string) => {
        lookups.push(id);
        return { data: { id, location: { directory: "/p/late" }, title: "Earlier work" } };
      },
    });
    await handle(ev("session.status", { sessionID: "ses_late", status: { type: "busy" } }));
    await handle(ev("session.status", { sessionID: "ses_late", status: { type: "idle" } }));
    expect(lookups).toEqual(["ses_late"]);
    expect(sent[0]).toMatchObject({ hook_event_name: "UserPromptSubmit", cwd: "/p/late" });
    expect(sent[1]).toMatchObject({ hook_event_name: "Stop", cwd: "/p/late", codex_title: "Earlier work" });
  });

  test("an event seen by two plugin instances is handled once", async () => {
    const a = harness({ answer: null });
    const b = harness({ answer: null });
    const shared = ev("permission.asked", { id: "per_d", sessionID: "ses_d", action: "shell", resources: ["ls"] });
    await a.handle(shared);
    await b.handle(shared);
    expect(a.asked.length + b.asked.length).toBe(1);
  });
});

describe("OpenCode 2 server placement", () => {
  const env = { TERM_PROGRAM: "iTerm.app", ITERM_SESSION_ID: "w0t0p0:ABC", TMUX: "/tmp/tmux", ZELLIJ_PANE_ID: "3", PATH: "/usr/bin" };

  test("the shared service only reports app-level terminal hints", () => {
    expect(v2IsSharedService(["/Users/u/.opencode/bin/opencode", "serve", "--service"])).toBe(true);
    expect(v2TerminalEnv(env, true)).toEqual({ TERM_PROGRAM: "iTerm.app" });
    expect(v2BridgeEnv(env, true)).toEqual({ TERM_PROGRAM: "iTerm.app", PATH: "/usr/bin" });
  });

  test("any other server is its launcher's child and keeps tab-level hints", () => {
    for (const argv of [
      ["opencode", "serve", "--stdio", "--port", "0"],         // standalone client child
      ["opencode", "serve", "--hostname=127.0.0.1", "--port=0"], // spawned by T3 Code / by hand
    ]) {
      expect(v2IsSharedService(argv)).toBe(false);
    }
    expect(v2TerminalEnv(env, false)).toEqual({ TERM_PROGRAM: "iTerm.app", ITERM_SESSION_ID: "w0t0p0:ABC", TMUX: "/tmp/tmux" });
    expect(v2BridgeEnv(env, false)).toBeUndefined();
  });

  test("setup() returns without waiting for the event stream and stops it on cleanup", async () => {
    let signal: AbortSignal | undefined;
    const ctx = {
      event: {
        subscribe: (options: { signal: AbortSignal }) => {
          signal = options.signal;
          return {
            async *[Symbol.asyncIterator]() {
              await new Promise<void>((resolve) => options.signal.addEventListener("abort", () => resolve()));
            },
          };
        },
      },
      permission: { reply: async () => {} },
    };
    const cleanup = plugin.setup(ctx);
    expect(typeof cleanup).toBe("function");
    await settle();
    expect(signal?.aborted).toBe(false);
    cleanup();
    expect(signal?.aborted).toBe(true);
  });
});

// MiMo Code (XiaomiMiMo/MiMo-Code, an OpenCode 1.x fork) — and the Xiaomi MiMo
// desktop app, whose engine it is — loads this file through `server()` with the
// v1 event shapes (`{type, properties}`). CodeIsland installs it with the SOURCE
// line rewritten (ConfigInstaller.mimoPluginSource), exactly as done here (#355).
describe("MiMo Code copy", () => {
  const SOURCE_MARKER = 'const SOURCE = "opencode";';
  const pluginPath = join(import.meta.dir, "../../Sources/CodeIsland/Resources/codeisland-opencode.js");

  test("the shipped plugin carries the SOURCE line exactly once", () => {
    expect(readFileSync(pluginPath, "utf8").split(SOURCE_MARKER).length).toBe(2);
  });

  test("server() reports MiMo sessions as mimo, over CODEISLAND_SOCKET_PATH", async () => {
    const dir = mkdtempSync(join(tmpdir(), "codeisland-mimo-"));
    const file = join(dir, "codeisland.js");
    writeFileSync(file, readFileSync(pluginPath, "utf8").replace(SOURCE_MARKER, 'const SOURCE = "mimo";'));

    // A stand-in for CodeIsland's socket: never the real one.
    const socketPath = join(dir, "island.sock");
    const received: Record<string, unknown>[] = [];
    const island = createServer((sock) => {
      let buf = "";
      sock.on("data", (d) => { buf += d; });
      sock.on("end", () => { received.push(JSON.parse(buf)); });
    });
    await new Promise<void>((resolve) => island.listen(socketPath, resolve));
    const saved = process.env.CODEISLAND_SOCKET_PATH;
    process.env.CODEISLAND_SOCKET_PATH = socketPath;

    try {
      const mod = await import(file);
      // MiMo's in-process client (no network) and its placeholder server URL.
      const hooks = await mod.default.server({ client: {}, serverUrl: new URL("http://mimocode.internal") });
      const fire = (type: string, properties: Record<string, unknown>) => hooks.event({ event: { type, properties } });

      await fire("session.created", { info: { id: "ses_m1", directory: "/p/mimo" } });
      await fire("message.part.updated", {
        part: { type: "tool", sessionID: "ses_m1", tool: "bash", state: { status: "running", input: { command: "ls" } } },
      });
      await fire("session.status", { sessionID: "ses_m1", status: { type: "idle" } });

      for (let i = 0; i < 200 && received.length < 3; i++) await new Promise((r) => setTimeout(r, 10));
      const byEvent = (name: string) => received.find((p) => p.hook_event_name === name);

      expect(received.length).toBe(3);
      for (const payload of received) {
        expect(payload).toMatchObject({ session_id: "mimo-ses_m1", _source: "mimo", _ppid: process.pid });
      }
      expect(byEvent("SessionStart")).toMatchObject({ cwd: "/p/mimo" });
      expect(byEvent("PreToolUse")).toMatchObject({ tool_name: "Bash", tool_input: { command: "ls" }, cwd: "/p/mimo" });
      expect(byEvent("Stop")).toMatchObject({ cwd: "/p/mimo" });
    } finally {
      if (saved === undefined) delete process.env.CODEISLAND_SOCKET_PATH;
      else process.env.CODEISLAND_SOCKET_PATH = saved;
      await new Promise<void>((resolve) => island.close(() => resolve()));
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
