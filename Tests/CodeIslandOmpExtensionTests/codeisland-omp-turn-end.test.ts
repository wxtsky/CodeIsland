import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { createServer } from "net";
import { tmpdir } from "os";
import { join } from "path";

// A stand-in for CodeIsland's socket — never the real one — and a HOME with
// no bridge, so nothing here can reach a running CodeIsland. The module reads
// both while loading, so they are set before the import.
const dir = mkdtempSync(join(tmpdir(), "codeisland-omp-turn-"));
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
};
process.env.CODEISLAND_SOCKET_PATH = socketPath;
process.env.HOME = dir;

const {
  default: codeislandExtension,
  interruptedByUser,
} = await import("../../Sources/CodeIsland/Resources/codeisland-omp?turn-end-tests");

afterAll(async () => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  await new Promise<void>((resolve) => island.close(() => resolve()));
  rmSync(dir, { recursive: true, force: true });
});

interface FakeSchema {
  optional: () => FakeSchema;
  describe: () => FakeSchema;
  refine: () => FakeSchema;
  min: () => FakeSchema;
}

function fakeSchema(): FakeSchema {
  const schema: FakeSchema = {
    optional: () => schema,
    describe: () => schema,
    refine: () => schema,
    min: () => schema,
  };
  return schema;
}

class FakeAskTool {
  readonly label = "Ask";
  readonly description = "Native Ask";
  constructor(_session: unknown) {}
}

type Handler = (event: unknown, ctx: unknown) => unknown;

/** One OMP session with this extension bound to it; returns a way to fire its events. */
function session(sessionId: string, agent?: Record<string, unknown>) {
  const handlers = new Map<string, Handler>();
  codeislandExtension({
    zod: {
      string: fakeSchema,
      number: fakeSchema,
      boolean: fakeSchema,
      array: fakeSchema,
      object: fakeSchema,
    },
    pi: { AskTool: FakeAskTool, settings: {} },
    getSessionName: () => "Fix the build",
    registerTool: () => undefined,
    on: (name: string, handler: Handler) => {
      handlers.set(name, handler);
    },
  } as never);
  const ctx = {
    cwd: "/repo",
    hasUI: false,
    sessionManager: {
      getSessionId: () => sessionId,
      getSessionFile: () => null,
      getEntries: () => [],
    },
    ...(agent ? { agent } : {}),
  };
  return async (name: string, event: Record<string, unknown> = {}) => {
    await handlers.get(name)?.({ type: name, ...event }, ctx);
  };
}

/** Payloads for one session, once `count` have arrived and a moment more, for any extra. */
async function payloadsFor(sessionId: string, count: number) {
  const mine = () => received.filter((p) => p.session_id === sessionId);
  for (let i = 0; i < 300 && mine().length < count; i++) {
    await new Promise((r) => setTimeout(r, 10));
  }
  await new Promise((r) => setTimeout(r, 100));
  return mine();
}

const eventNames = (payloads: Record<string, unknown>[]) => payloads.map((p) => p.hook_event_name);
const user = (text: string) => ({ role: "user", content: [{ type: "text", text }] });
const reply = (text: string, extra: Record<string, unknown> = {}) => ({
  role: "assistant",
  content: [{ type: "text", text }],
  stopReason: "stop",
  ...extra,
});
const failed = { role: "assistant", content: [], stopReason: "error", errorMessage: "overloaded" };
const interrupted = (text: string) =>
  reply(text, { stopReason: "aborted", errorMessage: "Interrupted by user" });

// OMP's agent_end carries the session's whole context, so each run's messages
// extend the last's.
describe("a turn ends once, at the agent_end OMP does not go on from (#386)", () => {
  test("a retried run rings nothing; the run that ends the turn sends its one Stop", async () => {
    const fire = session("turn-1");
    const runs = [user("fix the build"), failed];

    await fire("session_start");
    await fire("before_agent_start", { prompt: "fix the build" });
    await fire("agent_end", { messages: runs, willContinue: true });
    expect(eventNames(await payloadsFor("pi-turn-1", 2))).toEqual(["SessionStart", "UserPromptSubmit"]);

    await fire("agent_end", { messages: [...runs, reply("Fixed.")] });
    const payloads = await payloadsFor("pi-turn-1", 3);
    expect(eventNames(payloads)).toEqual(["SessionStart", "UserPromptSubmit", "Stop"]);
    expect(payloads[2]).toMatchObject({
      last_assistant_message: "Fixed.",
      session_title: "Fix the build",
    });
    expect("stop_reason" in payloads[2]).toBe(false);
  });

  test("a wait on background jobs is not the end of the turn either", async () => {
    const fire = session("turn-2");
    const started = [user("run the suite in the background"), reply("Started; I'll report back.")];

    await fire("before_agent_start", { prompt: "run the suite in the background" });
    await fire("agent_end", { messages: started, willContinue: true, awaitingAsyncWork: true });
    await fire("agent_end", {
      messages: [...started, user("async result: passed"), reply("The suite passed.")],
    });

    const payloads = await payloadsFor("pi-turn-2", 3);
    expect(eventNames(payloads)).toEqual(["SessionStart", "UserPromptSubmit", "Stop"]);
    expect(payloads[2]).toMatchObject({ last_assistant_message: "The suite passed." });
  });

  test("a last run with no reply keeps the turn's latest one", async () => {
    const fire = session("turn-3");

    await fire("agent_end", { messages: [reply("Answer.")], willContinue: true });
    await fire("agent_end", { messages: [reply("Answer."), failed] });

    const payloads = await payloadsFor("pi-turn-3", 2);
    expect(eventNames(payloads)).toEqual(["SessionStart", "Stop"]);
    expect(payloads[1]).toMatchObject({ last_assistant_message: "Answer." });
  });

  test("a turn the user interrupted ends interrupted, which CodeIsland ends without the chime", async () => {
    const fire = session("turn-esc");
    await fire("agent_end", { messages: [user("go"), interrupted("Starting with")] });

    const [, stop] = await payloadsFor("pi-turn-esc", 2);
    expect(stop).toMatchObject({
      hook_event_name: "Stop",
      stop_reason: "interrupted",
      last_assistant_message: "Starting with",
    });
  });

  test("only the user's interrupt counts: OMP's own aborts end a turn as before", () => {
    expect(interruptedByUser([user("go"), interrupted("Half")])).toBe(true);
    // A subagent's final `yield`, or any abort with no reason.
    expect(interruptedByUser([reply("Done", { stopReason: "aborted", errorMessage: "Request was aborted" })]))
      .toBe(false);
    expect(interruptedByUser([interrupted("Half"), reply("Then finished.")])).toBe(false);
    expect(interruptedByUser([reply("Done.")])).toBe(false);
    expect(interruptedByUser([user("go")])).toBe(false);
    expect(interruptedByUser([])).toBe(false);
  });

  test("an OMP before willContinue ends a turn at every agent_end, as before", async () => {
    const fire = session("legacy-1");

    await fire("agent_end", { messages: [user("go"), failed] });
    await fire("agent_end", { messages: [user("go"), failed, reply("Recovered.")] });

    const payloads = await payloadsFor("pi-legacy-1", 3);
    expect(eventNames(payloads)).toEqual(["SessionStart", "Stop", "Stop"]);
    expect(payloads[2]).toMatchObject({ last_assistant_message: "Recovered." });
  });

  test("a subagent's turn ends the same way, still under its parent", async () => {
    const parent = session("main-1", { kind: "main", id: "Main", name: "main", depth: 0 });
    const child = session("sub-1", { kind: "sub", id: "0-Explore", name: "explore", depth: 1, parentId: "Main" });

    await parent("session_start");
    await child("session_start");
    await child("agent_end", { messages: [user("look"), failed], willContinue: true });
    await child("agent_end", { messages: [user("look"), failed, reply("found")] });

    const payloads = await payloadsFor("pi-sub-1", 2);
    expect(eventNames(payloads)).toEqual(["SessionStart", "Stop"]);
    for (const payload of payloads) {
      expect(payload).toMatchObject({ _parent_session_id: "pi-main-1", agent_type: "explore" });
    }
    expect(payloads[1]).toMatchObject({ last_assistant_message: "found" });
  });
});
