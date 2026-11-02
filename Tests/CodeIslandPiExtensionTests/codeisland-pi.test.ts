import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { createServer } from "net";
import { tmpdir } from "os";
import { join } from "path";

// A stand-in for CodeIsland's socket — never the real one — and a HOME with
// no bridge, so nothing here can reach a running CodeIsland. The module reads
// both while loading, so they are set before the import.
const dir = mkdtempSync(join(tmpdir(), "codeisland-pi-"));
const socketPath = join(dir, "island.sock");
const received: Record<string, unknown>[] = [];
const island = createServer((sock) => {
  let buf = "";
  sock.on("data", (d) => {
    buf += d;
  });
  sock.on("end", () => {
    received.push(JSON.parse(buf));
  });
});
await new Promise<void>((resolve) => island.listen(socketPath, resolve));

const saved = {
  CODEISLAND_SOCKET_PATH: process.env.CODEISLAND_SOCKET_PATH,
  HOME: process.env.HOME,
  PI_SUBAGENT_PARENT_SESSION: process.env.PI_SUBAGENT_PARENT_SESSION,
};
process.env.CODEISLAND_SOCKET_PATH = socketPath;
process.env.HOME = dir;
delete process.env.PI_SUBAGENT_PARENT_SESSION;

const {
  default: codeislandExtension,
  subagentAgentName,
  subagentParentSessionId,
} = await import("../../Sources/CodeIsland/Resources/codeisland-pi?pi-subagent-tests");

afterAll(async () => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  await new Promise<void>((resolve) => island.close(() => resolve()));
  rmSync(dir, { recursive: true, force: true });
});

type Handler = (event: unknown, ctx: unknown) => unknown;

/**
 * Loads the extension against a fake pi and returns a way to fire its events.
 * `settles` makes it a pi 0.80.4+, which emits agent_settled (#386).
 */
function loadExtension(
  sessionId: string,
  sessionName: () => string | undefined,
  { settles = false } = {},
) {
  const handlers = new Map<string, Handler>();
  codeislandExtension({
    on: (name: string, handler: Handler) => {
      handlers.set(name, handler);
    },
    getSessionName: sessionName,
    ...(settles ? { registerEntryRenderer: () => undefined } : {}),
  } as never);
  const ctx = { cwd: "/repo", sessionManager: { getSessionId: () => sessionId } };
  return async (name: string, event: Record<string, unknown> = {}) => {
    await handlers.get(name)?.({ type: name, ...event }, ctx);
  };
}

/** Payloads for one session, once `count` of them have arrived. */
async function payloadsFor(sessionId: string, count: number) {
  const mine = () => received.filter((p) => p.session_id === sessionId);
  for (let i = 0; i < 300 && mine().length < count; i++) {
    await new Promise((r) => setTimeout(r, 10));
  }
  return mine();
}

/** Payloads for one session, once `count` have arrived and a moment more, for any extra. */
async function allPayloadsFor(sessionId: string, count: number) {
  await payloadsFor(sessionId, count);
  await new Promise((r) => setTimeout(r, 100));
  return received.filter((p) => p.session_id === sessionId);
}

const eventNames = (payloads: Record<string, unknown>[]) => payloads.map((p) => p.hook_event_name);
const user = (text: string) => ({ role: "user", content: [{ type: "text", text }] });
const reply = (text: string, stopReason = "stop") => ({
  role: "assistant",
  content: [{ type: "text", text }],
  stopReason,
});
const failed = { role: "assistant", content: [], stopReason: "error", errorMessage: "overloaded" };

describe("pi-subagents children (#378)", () => {
  test("a child names its parent's card and its agent on every payload", async () => {
    process.env.PI_SUBAGENT_PARENT_SESSION = " 01a15910-e6c0-75af-93e2-e9c1825affc1 ";
    let name: string | undefined;
    const fire = loadExtension("child-1", () => name);
    delete process.env.PI_SUBAGENT_PARENT_SESSION;

    // Announced with its first prompt, not at session_start: by then
    // pi-subagents has named the session and the agent is known.
    await fire("session_start", { reason: "startup" });
    name = "worker: sleep 4";
    await fire("before_agent_start", {
      prompt: "Task: sleep 4",
      systemPrompt: '<active_agent name="worker"/>\n\nYou are a worker.',
    });
    await fire("tool_call", { toolName: "bash", toolCallId: "call-1", input: { command: "sleep 4" } });
    await fire("tool_result", { toolName: "bash", toolCallId: "call-1" });
    await fire("agent_end", {
      messages: [{ role: "assistant", content: [{ type: "text", text: "done" }] }],
    });
    await fire("session_shutdown", {});

    const payloads = await payloadsFor("pi-child-1", 6);
    expect(payloads.map((p) => p.hook_event_name)).toEqual([
      "SessionStart",
      "UserPromptSubmit",
      "PreToolUse",
      "PostToolUse",
      "Stop",
      "SessionEnd",
    ]);
    for (const payload of payloads) {
      expect(payload).toMatchObject({
        _source: "pi",
        _parent_session_id: "pi-01a15910-e6c0-75af-93e2-e9c1825affc1",
        agent_type: "worker",
      });
    }
    expect(payloads[0]).toMatchObject({ session_title: "worker: sleep 4" });
    expect(payloads[1]).toMatchObject({ prompt: "Task: sleep 4" });
    expect(payloads[4]).toMatchObject({ last_assistant_message: "done" });
  });

  test("a child whose agent is unknown is still a child", async () => {
    process.env.PI_SUBAGENT_PARENT_SESSION = "parent-2";
    const fire = loadExtension("child-2", () => undefined);
    delete process.env.PI_SUBAGENT_PARENT_SESSION;

    await fire("before_agent_start", { prompt: "Task", systemPrompt: "No tag here." });
    const payloads = await payloadsFor("pi-child-2", 2);
    expect(payloads.length).toBe(2);
    for (const payload of payloads) {
      expect(payload).toMatchObject({ _parent_session_id: "pi-parent-2", agent_type: "subagent" });
    }
  });

  test("a top-level session is unchanged", async () => {
    const fire = loadExtension("top-1", () => "My session");

    await fire("session_start", { reason: "startup" });
    await fire("agent_end", { messages: [] });

    const payloads = await payloadsFor("pi-top-1", 2);
    expect(payloads.map((p) => p.hook_event_name)).toEqual(["SessionStart", "Stop"]);
    for (const payload of payloads) {
      expect("_parent_session_id" in payload).toBe(false);
      expect("agent_type" in payload).toBe(false);
    }
  });

  test("reads the parent from PI_SUBAGENT_PARENT_SESSION", () => {
    expect(subagentParentSessionId({ PI_SUBAGENT_PARENT_SESSION: "abc" })).toBe("abc");
    expect(subagentParentSessionId({ PI_SUBAGENT_PARENT_SESSION: "  " })).toBeUndefined();
    expect(subagentParentSessionId({})).toBeUndefined();
  });

  test("reads the agent from pi-subagents' system prompt tag", () => {
    expect(subagentAgentName('<active_agent name="scout"/>\n\nRecon.')).toBe("scout");
    expect(subagentAgentName('<active_agent name="a&amp;b &quot;c&quot;"/>')).toBe('a&b "c"');
    expect(subagentAgentName("You are pi.")).toBeUndefined();
    expect(subagentAgentName(undefined)).toBeUndefined();
  });
});

describe("a turn ends once, at agent_settled (#386)", () => {
  test("a prompt's Stop waits for agent_settled and carries its reply", async () => {
    const fire = loadExtension("turn-1", () => "Fix the build", { settles: true });

    await fire("session_start", { reason: "startup" });
    await fire("before_agent_start", { prompt: "fix the build" });
    await fire("agent_end", { messages: [user("fix the build"), reply("Fixed.")] });
    expect(eventNames(await allPayloadsFor("pi-turn-1", 2))).toEqual([
      "SessionStart",
      "UserPromptSubmit",
    ]);

    await fire("agent_settled", { aborted: false });
    const payloads = await allPayloadsFor("pi-turn-1", 3);
    expect(eventNames(payloads)).toEqual(["SessionStart", "UserPromptSubmit", "Stop"]);
    expect(payloads[2]).toMatchObject({
      last_assistant_message: "Fixed.",
      session_title: "Fix the build",
    });
    expect("stop_reason" in payloads[2]).toBe(false);
  });

  test("a parent yielding to its subagent rings once, with its final reply", async () => {
    // The issue's capture: the parent's run ends on the subagent call, and
    // the subagent's result starts the run that answers.
    const fire = loadExtension("turn-2", () => undefined, { settles: true });
    const delegating = {
      role: "assistant",
      content: [{ type: "toolCall", id: "call-1", name: "subagent", arguments: {} }],
      stopReason: "toolUse",
    };
    const result = { role: "custom", customType: "subagent-notify", content: "worker: completed" };

    await fire("before_agent_start", { prompt: "delegate to one subagent, then reply done" });
    await fire("tool_call", { toolName: "subagent", toolCallId: "call-1", input: { agent: "worker" } });
    await fire("tool_result", { toolName: "subagent", toolCallId: "call-1" });
    await fire("agent_end", { messages: [user("delegate to one subagent, then reply done"), delegating] });
    await fire("agent_end", { messages: [result, reply("done")] });
    await fire("agent_settled", { aborted: false });

    const payloads = await allPayloadsFor("pi-turn-2", 5);
    expect(eventNames(payloads)).toEqual([
      "SessionStart",
      "UserPromptSubmit",
      "PreToolUse",
      "PostToolUse",
      "Stop",
    ]);
    expect(payloads[4]).toMatchObject({ last_assistant_message: "done" });
  });

  test.each([
    ["a retried error", "retry", [[failed], [reply("Recovered.")]], "Recovered."],
    ["a queued follow-up", "queued", [[reply("First.")], [user("and then?"), reply("Second.")]], "Second."],
    ["a last run with no reply", "no-reply", [[reply("Answer.")], [failed]], "Answer."],
  ])("%s starts another run, and the turn still ends once", async (_, id, runs, last) => {
    const fire = loadExtension(`turn-${id}`, () => undefined, { settles: true });

    await fire("before_agent_start", { prompt: "go" });
    for (const messages of runs) await fire("agent_end", { messages });
    await fire("agent_settled", { aborted: false });

    const payloads = await allPayloadsFor(`pi-turn-${id}`, 3);
    expect(eventNames(payloads)).toEqual(["SessionStart", "UserPromptSubmit", "Stop"]);
    expect(payloads[2]).toMatchObject({ last_assistant_message: last });
  });

  test("compaction between runs is still one turn", async () => {
    const fire = loadExtension("turn-compact", () => undefined, { settles: true });

    await fire("before_agent_start", { prompt: "go" });
    await fire("agent_end", { messages: [user("go"), failed] });
    await fire("session_before_compact", {});
    await fire("session_compact", {});
    await fire("agent_end", { messages: [reply("Done after compacting.")] });
    await fire("agent_settled", { aborted: false });

    const payloads = await allPayloadsFor("pi-turn-compact", 5);
    expect(eventNames(payloads)).toEqual([
      "SessionStart",
      "UserPromptSubmit",
      "PreCompact",
      "PostCompact",
      "Stop",
    ]);
    expect(payloads[4]).toMatchObject({ last_assistant_message: "Done after compacting." });
  });

  test("a turn the user aborted ends interrupted, which CodeIsland ends without the chime", async () => {
    const fire = loadExtension("turn-esc", () => undefined, { settles: true });

    await fire("before_agent_start", { prompt: "go" });
    await fire("agent_end", { messages: [user("go"), reply("Starting with", "aborted")] });
    await fire("agent_settled", { aborted: true });

    const payloads = await allPayloadsFor("pi-turn-esc", 3);
    expect(eventNames(payloads)).toEqual(["SessionStart", "UserPromptSubmit", "Stop"]);
    expect(payloads[2]).toMatchObject({
      stop_reason: "interrupted",
      last_assistant_message: "Starting with",
    });
  });

  test("before pi 1.1.0, agent_settled has no aborted flag: the turn's last run tells", async () => {
    const stopped = loadExtension("settled-esc", () => undefined, { settles: true });
    await stopped("agent_end", { messages: [reply("Half", "aborted")] });
    await stopped("agent_settled");
    const finished = loadExtension("settled-done", () => undefined, { settles: true });
    await finished("agent_end", { messages: [reply("Whole.")] });
    await finished("agent_settled");

    const [, esc] = await allPayloadsFor("pi-settled-esc", 2);
    const [, done] = await allPayloadsFor("pi-settled-done", 2);
    expect(esc).toMatchObject({ hook_event_name: "Stop", stop_reason: "interrupted" });
    expect(done).toMatchObject({ hook_event_name: "Stop", last_assistant_message: "Whole." });
    expect("stop_reason" in done).toBe(false);
  });

  test("a pi without agent_settled ends a turn at every agent_end, as before", async () => {
    const fire = loadExtension("legacy-1", () => undefined);

    await fire("before_agent_start", { prompt: "go" });
    await fire("agent_end", { messages: [user("go"), failed] });
    await fire("agent_end", { messages: [reply("Recovered.")] });
    await fire("before_agent_start", { prompt: "again" });
    await fire("agent_end", { messages: [user("again"), reply("Half", "aborted")] });

    const payloads = await allPayloadsFor("pi-legacy-1", 6);
    expect(eventNames(payloads)).toEqual([
      "SessionStart",
      "UserPromptSubmit",
      "Stop",
      "Stop",
      "UserPromptSubmit",
      "Stop",
    ]);
    expect(payloads[3]).toMatchObject({ last_assistant_message: "Recovered." });
    expect("stop_reason" in payloads[3]).toBe(false);
    expect(payloads[5]).toMatchObject({ stop_reason: "interrupted" });
  });

  test("a pi that settles without registerEntryRenderer switches at its first agent_settled", async () => {
    const fire = loadExtension("legacy-2", () => undefined);

    await fire("agent_end", { messages: [reply("One.")] });
    await fire("agent_settled", { aborted: false });
    await fire("agent_end", { messages: [reply("Two, part one.")] });
    await fire("agent_end", { messages: [reply("Two.")] });
    await fire("agent_settled", { aborted: false });

    const payloads = await allPayloadsFor("pi-legacy-2", 3);
    expect(eventNames(payloads)).toEqual(["SessionStart", "Stop", "Stop"]);
    expect(payloads[1]).toMatchObject({ last_assistant_message: "One." });
    expect(payloads[2]).toMatchObject({ last_assistant_message: "Two." });
  });

  test("a pi-subagents child's turn ends there too, still under its parent", async () => {
    process.env.PI_SUBAGENT_PARENT_SESSION = "parent-3";
    const fire = loadExtension("child-3", () => "worker: build", { settles: true });
    delete process.env.PI_SUBAGENT_PARENT_SESSION;

    await fire("session_start", { reason: "startup" });
    await fire("before_agent_start", {
      prompt: "Task: build",
      systemPrompt: '<active_agent name="worker"/>\n\nYou are a worker.',
    });
    await fire("agent_end", { messages: [user("Task: build"), failed] });
    await fire("agent_end", { messages: [reply("built")] });
    await fire("agent_settled", { aborted: false });
    await fire("session_shutdown", {});

    const payloads = await allPayloadsFor("pi-child-3", 4);
    expect(eventNames(payloads)).toEqual(["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]);
    for (const payload of payloads) {
      expect(payload).toMatchObject({ _parent_session_id: "pi-parent-3", agent_type: "worker" });
    }
    expect(payloads[2]).toMatchObject({ last_assistant_message: "built" });
  });
});
