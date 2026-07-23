import { describe, expect, test } from "bun:test";

// The module reads HOME while loading; dynamic import isolates the no-bridge boundary.
const originalHome = process.env.HOME;
process.env.HOME = "/tmp/codeisland-omp-extension-tests-no-bridge";
const {
  default: codeislandExtension,
  createAskRaceSettlement,
  classifyCodeIslandAskResponse,
  mapAskQuestionsToCodeIsland,
} = await import("../../Sources/CodeIsland/Resources/codeisland-omp?race-tests");
if (originalHome === undefined) {
  delete process.env.HOME;
} else {
  process.env.HOME = originalHome;
}

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

describe("OMP Ask racing settlement", () => {
  test.each([
    ["island", "tui"],
    ["tui", "island"],
  ] as const)(
    "%s wins when both answers settle in adjacent microtasks",
    async (firstSource, secondSource) => {
      const gate = createAskRaceSettlement<string>();
      const cancellations: string[] = [];
      const settlementResults: boolean[] = [];

      queueMicrotask(() => {
        settlementResults.push(gate.settle(firstSource, () => {
          cancellations.push(secondSource);
          throw new Error("loser cancellation must not escape");
        }));
      });
      queueMicrotask(() => {
        settlementResults.push(gate.settle(secondSource, () => {
          cancellations.push(firstSource);
        }));
      });

      await expect(gate.promise).resolves.toBe(firstSource);
      await Promise.resolve();

      expect(settlementResults).toEqual([true, false]);
      expect(cancellations).toEqual([secondSource]);
    },
  );

  test("distinguishes unavailable bridge, explicit deny, and allow", () => {
    expect(classifyCodeIslandAskResponse(null)).toEqual({
      kind: "unavailable",
    });
    expect(classifyCodeIslandAskResponse({
      hookSpecificOutput: {
        decision: { behavior: "deny" },
      },
    })).toEqual({
      kind: "denied",
    });
    expect(classifyCodeIslandAskResponse({
      hookSpecificOutput: {
        decision: {
          behavior: "allow",
          updatedInput: { answers: { choice: "Beta" } },
        },
      },
    })).toEqual({
      kind: "allowed",
      updatedInput: { answers: { choice: "Beta" } },
    });
  });

  test("treats allow without an answers object as unavailable", () => {
    expect(classifyCodeIslandAskResponse({
      hookSpecificOutput: {
        decision: { behavior: "allow" },
      },
    })).toEqual({
      kind: "unavailable",
    });
    expect(classifyCodeIslandAskResponse({
      hookSpecificOutput: {
        decision: {
          behavior: "allow",
          updatedInput: { answers: null },
        },
      },
    })).toEqual({
      kind: "unavailable",
    });
  });

  test("rejects wrong, partial, and malformed answer entries", () => {
    const response = (answers: Record<string, unknown>) => ({
      hookSpecificOutput: {
        decision: {
          behavior: "allow",
          updatedInput: { answers },
        },
      },
    });

    expect(classifyCodeIslandAskResponse(
      response({ wrong: "yes" }),
      ["expected"],
    )).toEqual({ kind: "unavailable" });
    expect(classifyCodeIslandAskResponse(
      response({ first: "yes" }),
      ["first", "second"],
    )).toEqual({ kind: "unavailable" });
    expect(classifyCodeIslandAskResponse(
      response({ first: ["yes", 2] }),
      ["first"],
    )).toEqual({ kind: "unavailable" });
  });

  test("falls back to the OMP question id when header is absent", () => {
    expect(mapAskQuestionsToCodeIsland([
      {
        id: "scope",
        question: "Choose the scope",
        options: [{ label: "Small" }],
      },
      {
        id: "quality",
        question: "Choose the quality",
        header: "Quality",
        multi: true,
        options: [{ label: "High", description: "More detailed" }],
      },
    ])).toEqual([
      {
        question: "Choose the scope",
        header: "scope",
        multiSelect: false,
        options: [{ label: "Small" }],
      },
      {
        question: "Choose the quality",
        header: "Quality",
        multiSelect: true,
        options: [{ label: "High", description: "More detailed" }],
      },
    ]);
  });

  test("executes native Ask when CodeIsland bridge is unavailable", async () => {
    const nativeResult = {
      content: [{ type: "text", text: "User selected: Beta" }],
      details: {
        question: "PR candidate smoke?",
        selectedOptions: ["Beta"],
      },
    };
    let registeredTool: {
      execute: (...args: unknown[]) => Promise<unknown>;
    } | undefined;
    let contextAborted = false;

    class FakeAskTool {
      readonly name = "ask";
      readonly label = "Ask";
      readonly description = "Native Ask";
      readonly parameters = fakeSchema();
      readonly strict = true;
      readonly approval = "read";
      readonly concurrency = "exclusive";

      constructor(_session: unknown) {}

      async execute(): Promise<typeof nativeResult> {
        return nativeResult;
      }
    }

    const renderer = {
      mergeCallAndResult: true,
      renderCall: () => null,
      renderResult: () => null,
    };
    const zod = {
      string: fakeSchema,
      number: fakeSchema,
      boolean: fakeSchema,
      array: fakeSchema,
      object: fakeSchema,
    };
    const extensionApi = {
      zod,
      pi: {
        AskTool: FakeAskTool,
        askToolRenderer: renderer,
        settings: {},
      },
      getSessionName: () => undefined,
      registerTool: (tool: typeof registeredTool) => {
        registeredTool = tool;
      },
      on: () => undefined,
    };
    codeislandExtension(extensionApi as never);

    expect(registeredTool).toBeDefined();
    const result = await registeredTool!.execute(
      "ask-fallback-smoke",
      {
        questions: [{
          id: "choice",
          question: "PR candidate smoke?",
          options: [{ label: "Alpha" }, { label: "Beta" }],
        }],
      },
      undefined,
      undefined,
      {
        cwd: "/tmp",
        hasUI: true,
        sessionManager: {
          getSessionId: () => "ask-fallback-smoke-session",
          getSessionFile: () => null,
          getEntries: () => [],
        },
        isIdle: () => true,
        hasPendingMessages: () => false,
        abort: () => {
          contextAborted = true;
        },
        ui: {},
      },
    );

    expect(result).toBe(nativeResult);
    expect(contextAborted).toBe(false);
  });
});
