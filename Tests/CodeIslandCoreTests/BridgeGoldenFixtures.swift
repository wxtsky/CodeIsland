import Foundation

/// Every kind of hook codeisland-bridge serves, as its agent runs it. Their
/// recorded output (``BridgeGoldenExpectations``) was taken from the bridge
/// before its interpretation moved into ``HookIntake``; the bridge, and
/// HookIntake on the same facts, must keep producing it.
enum BridgeGoldenFixtures {
    typealias Fixture = BridgeGoldenFixture
    typealias Ancestor = BridgeGoldenFixture.Ancestor

    static let allowReply = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
    static let denyReply = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied on the island"}}}"#
    static let alwaysReply = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"always"}}}"#

    static let iTermEnvironment = [
        "TERM_PROGRAM": "iTerm.app",
        "ITERM_SESSION_ID": "w0t1p0:6A1B2C3D-0000-4000-8000-ABCDEF012345",
        "__CFBundleIdentifier": "com.googlecode.iterm2",
    ]

    /// A Cursor hook input: one per step, for every hook of the step (#377).
    static func cursorStdin(event: String, extra: String = "") -> String {
        #"{"conversation_id":"e1247fd5-d9a0-48ef-8457-0304606b1833","generation_id":"gen-1","session_id":"e1247fd5-d9a0-48ef-8457-0304606b1833","model":"composer-2.5","hook_event_name":""#
            + event
            + #"","cursor_version":"3.25.9","workspace_roots":["/Users/golden/project"],"user_email":null,"transcript_path":"/Users/golden/.cursor/projects/Users-golden-project/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl""#
            + extra
            + "}"
    }

    static let claudeNative = Ancestor(path: "home/.local/share/claude/versions/2.1.294")
    static let codexDesktopApp = "Applications/ChatGPT.app"
    static let codexDesktopBinary = codexDesktopApp + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    static let cursorAgent = Ancestor(path: "home/.local/share/cursor-agent/versions/2026.10.01-1a2b3c4/cursor-agent")
    static let node = Ancestor(path: "usr-local/bin/node")

    static let all: [Fixture] = claude + codex + cursor + others + plugins + terminals + drops

    // MARK: - Claude Code (codeisland-hook.sh execs the bridge without --source)

    static let claude: [Fixture] = [
        Fixture(
            name: "claude-native-session-start",
            environment: iTermEnvironment,
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000001","transcript_path":"/Users/golden/.claude/projects/-Users-golden-project/c1a0de00-0000-4000-8000-000000000001.jsonl","cwd":"/Users/golden/project","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-4-5"}"#,
            ancestors: [claudeNative]
        ),
        Fixture(
            name: "claude-homebrew-permission-allow",
            environment: ["TERM_PROGRAM": "Apple_Terminal", "__CFBundleIdentifier": "com.apple.Terminal"],
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000002","transcript_path":"/Users/golden/.claude/projects/-Users-golden-project/c1a0de00-0000-4000-8000-000000000002.jsonl","cwd":"/Users/golden/project","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"swift test","description":"Run the tests"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"swift test:*"}],"behavior":"allow","destination":"localSettings"}]}"#,
            ancestors: [Ancestor(path: "opt/homebrew/bin/claude")],
            reply: allowReply
        ),
        Fixture(
            name: "claude-permission-deny",
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000003","cwd":"/Users/golden/project","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"/etc/hosts","content":"x"}}"#,
            ancestors: [claudeNative],
            reply: denyReply
        ),
        Fixture(
            name: "claude-permission-empty-reply",
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000004","cwd":"/Users/golden/project","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
            ancestors: [claudeNative],
            reply: ""
        ),
        Fixture(
            name: "claude-notification-question",
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000005","cwd":"/Users/golden/project","hook_event_name":"Notification","message":"Claude needs your input","question":"Which branch should I use?","options":["main","dev"]}"#,
            ancestors: [claudeNative],
            reply: #"{"answer":"main"}"#
        ),
        Fixture(
            name: "claude-notification-plain",
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000006","cwd":"/Users/golden/project","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#,
            ancestors: [claudeNative],
            reply: #"{"ignored":true}"#
        ),
        Fixture(
            name: "claude-notification-non-string-question",
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000007","cwd":"/Users/golden/project","hook_event_name":"Notification","question":{"text":"not a string"}}"#,
            ancestors: [claudeNative],
            reply: #"{"ignored":true}"#
        ),
        Fixture(
            name: "claude-in-tmux-pretooluse",
            environment: [
                "TERM_PROGRAM": "tmux",
                "TMUX": "/tmp/ci-golden-no-tmux/tmux-501/default,4242,0",
                "TMUX_PANE": "%7",
            ],
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000008","cwd":"/Users/golden/project","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/Users/golden/project/README.md"},"tool_use_id":"toolu_01"}"#,
            ancestors: [Ancestor(path: "home/.local/bin/claude")]
        ),
        Fixture(
            name: "claude-tmux-without-pane",
            environment: ["TMUX": "/tmp/ci-golden-no-tmux/tmux-501/default,4242,0"],
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-000000000009","cwd":"/Users/golden/project","hook_event_name":"PostToolUse","tool_name":"Read"}"#,
            ancestors: [claudeNative]
        ),
        Fixture(
            name: "claude-desktop-code-tab",
            environment: [
                "CLAUDE_CODE_HOST_SESSION_ID": "local_0f3c2a1b-1111-4222-8333-944455556666",
                "__CFBundleIdentifier": "com.anthropic.claudefordesktop",
            ],
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-00000000000a","cwd":"/Users/golden/project","hook_event_name":"UserPromptSubmit","prompt":"Add a test"}"#,
            ancestors: [Ancestor(path: "Applications/Claude.app/Contents/Resources/app/claude-code/claude")]
        ),
        Fixture(
            name: "claude-as-node-script",
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-00000000000b","cwd":"/Users/golden/project","hook_event_name":"Stop","stop_hook_active":false}"#,
            ancestors: [node]
        ),
        Fixture(
            name: "claude-inside-cursor-terminal",
            stdin: #"{"session_id":"c1a0de00-0000-4000-8000-00000000000c","cwd":"/Users/golden/project","hook_event_name":"UserPromptSubmit","prompt":"hello"}"#,
            ancestors: [
                claudeNative,
                Ancestor(path: "bin/zsh"),
                Ancestor(path: "Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
                Ancestor(path: "Applications/Cursor.app/Contents/MacOS/Cursor"),
            ]
        ),
        Fixture(
            name: "omo-opencode-fires-claude-hook",
            stdin: #"{"session_id":"omo-ses-1","cwd":"/Users/golden/project","hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"ls"}}"#,
            ancestors: [Ancestor(path: "home/.opencode/bin/opencode")]
        ),
        Fixture(
            name: "camelcase-fork",
            stdin: #"{"hookEventName":"PreToolUse","sessionId":"fork-session-1","toolName":"Read","toolInput":{"path":"a.txt"}}"#
        ),
        Fixture(
            name: "nested-payload-session-and-event-name",
            stdin: #"{"eventName":"Stop","payload":{"sessionId":"nested-session-1"},"cwd":"/Users/golden/project"}"#
        ),
        Fixture(
            name: "nested-data-session-and-event",
            stdin: #"{"event":"SessionEnd","data":{"session_id":"nested-session-2"}}"#
        ),
        Fixture(
            name: "unsupported-payload-source-inferred-claude",
            stdin: #"{"session_id":"weird-1","cwd":"/Users/golden/project","hook_event_name":"Stop","_source":"not-a-real-agent"}"#,
            ancestors: [claudeNative]
        ),
    ]

    // MARK: - Codex

    static let codex: [Fixture] = [
        Fixture(
            name: "codex-cli-pretooluse",
            arguments: ["--source", "codex"],
            environment: ["TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.mitchellh.ghostty"],
            stdin: #"{"session_id":"019a0000-0000-7000-8000-000000000001","transcript_path":"/Users/golden/.codex/sessions/2026/10/22/rollout-2026-10-22T08-00-00-019a0000-0000-7000-8000-000000000001.jsonl","cwd":"/Users/golden/project","hook_event_name":"PreToolUse","model":"gpt-5.5-codex","tool_name":"shell","tool_input":{"command":["bash","-lc","ls"]},"turn_id":"t-1"}"#,
            ancestors: [Ancestor(path: "opt/homebrew/bin/codex")]
        ),
        Fixture(
            name: "codex-desktop-app-server",
            arguments: ["--source", "codex"],
            stdin: #"{"session_id":"019a0000-0000-7000-8000-000000000002","cwd":"/Users/golden/project","hook_event_name":"UserPromptSubmit","prompt":"Ship it"}"#,
            ancestors: [
                Ancestor(path: codexDesktopBinary, arguments: ["app-server", "--analytics-default-enabled"]),
                Ancestor(path: codexDesktopApp + "/Contents/MacOS/ChatGPT"),
            ],
            bundleIdentifiers: [codexDesktopApp: "com.openai.codex"]
        ),
        Fixture(
            name: "codex-desktop-config-flags",
            arguments: ["--source", "codex"],
            stdin: #"{"session_id":"019a0000-0000-7000-8000-000000000003","cwd":"/Users/golden/project","hook_event_name":"Stop"}"#,
            ancestors: [
                Ancestor(path: codexDesktopBinary, arguments: ["-c", "model=\"gpt-5.5\"", "app-server"]),
                Ancestor(path: codexDesktopApp + "/Contents/MacOS/ChatGPT"),
            ],
            bundleIdentifiers: [codexDesktopApp: "com.openai.codex"]
        ),
        Fixture(
            name: "codex-chatgpt-terminal-exec",
            arguments: ["--source", "codex"],
            stdin: #"{"session_id":"019a0000-0000-7000-8000-000000000004","cwd":"/Users/golden/project","hook_event_name":"Stop"}"#,
            ancestors: [
                Ancestor(path: codexDesktopBinary, arguments: ["exec", "ls"]),
                Ancestor(path: codexDesktopApp + "/Contents/MacOS/ChatGPT"),
            ],
            bundleIdentifiers: [codexDesktopApp: "com.openai.codex"]
        ),
        Fixture(
            name: "codex-app-server-under-other-host",
            arguments: ["--source", "codex"],
            stdin: #"{"session_id":"019a0000-0000-7000-8000-000000000005","cwd":"/Users/golden/project","hook_event_name":"Stop"}"#,
            ancestors: [
                Ancestor(path: codexDesktopBinary, arguments: ["app-server"]),
                Ancestor(path: codexDesktopApp + "/Contents/Resources/helper"),
            ],
            bundleIdentifiers: [codexDesktopApp: "com.openai.codex"]
        ),
        Fixture(
            name: "codex-desktop-with-bundle-env",
            arguments: ["--source", "codex"],
            environment: ["__CFBundleIdentifier": "com.openai.codex"],
            stdin: #"{"session_id":"019a0000-0000-7000-8000-000000000006","cwd":"/Users/golden/project","hook_event_name":"SessionStart","source":"startup"}"#,
            ancestors: [
                Ancestor(path: codexDesktopBinary, arguments: ["app-server"]),
                Ancestor(path: codexDesktopApp + "/Contents/MacOS/ChatGPT"),
            ],
            bundleIdentifiers: [codexDesktopApp: "com.openai.codex"]
        ),
        Fixture(
            name: "codex-permission-request-deny",
            arguments: ["--source", "codex"],
            stdin: #"{"session_id":"019a0000-0000-7000-8000-000000000007","cwd":"/Users/golden/project","hook_event_name":"PermissionRequest","tool_name":"shell","tool_input":{"command":["rm","-rf","build"]}}"#,
            ancestors: [Ancestor(path: "opt/homebrew/bin/codex")],
            reply: denyReply
        ),
    ]

    // MARK: - Cursor

    static let cursor: [Fixture] = [
        Fixture(
            name: "cursor-native-before-shell",
            arguments: ["--source", "cursor", "--event", "beforeShellExecution"],
            stdin: cursorStdin(event: "beforeShellExecution", extra: #","command":"swift test","cwd":"""#),
            ancestors: [
                Ancestor(path: "Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
                Ancestor(path: "Applications/Cursor.app/Contents/MacOS/Cursor"),
            ]
        ),
        Fixture(
            name: "cursor-imported-claude-stop",
            stdin: cursorStdin(event: "stop", extra: #","status":"completed","loop_count":0"#),
            ancestors: [Ancestor(path: "Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")]
        ),
        Fixture(
            name: "cursor-imported-claude-permission-never-held",
            stdin: cursorStdin(event: "PermissionRequest", extra: #","tool_name":"Shell","question":"Run swift test?""#),
            reply: allowReply
        ),
        Fixture(
            name: "cursor-agent-hooks-json",
            arguments: ["--source", "cursor", "--event", "afterFileEdit"],
            stdin: cursorStdin(event: "afterFileEdit", extra: #","file_path":"/Users/golden/project/a.swift","edits":[]"#),
            ancestors: [cursorAgent]
        ),
        Fixture(
            name: "cursor-agent-imported-claude",
            stdin: cursorStdin(event: "beforeSubmitPrompt", extra: #","prompt":"Fix it""#),
            ancestors: [Ancestor(path: "bin/sh"), cursorAgent]
        ),
        Fixture(
            name: "cursor-without-version",
            arguments: ["--source", "cursor", "--event", "beforeSubmitPrompt"],
            stdin: #"{"conversation_id":"conv-old","generation_id":"g","hook_event_name":"beforeSubmitPrompt","prompt":"hi","cursor_version":"  ","workspace_roots":["/Users/golden/project"]}"#
        ),
    ]

    // MARK: - Other agents' own hooks

    static let others: [Fixture] = [
        Fixture(
            name: "cline-pretooluse",
            arguments: ["--source", "cline"],
            stdin: #"{"clineVersion":"3.40.0","hookName":"PreToolUse","timestamp":"1761120000000","taskId":"1761120000000","workspaceRoots":["/Users/golden/project"],"userId":"u","preToolUse":{"toolName":"execute_command","parameters":{"command":"ls -la","requires_approval":"false"}}}"#,
            ancestors: [Ancestor(path: "bin/bash")]
        ),
        Fixture(
            name: "cline-posttooluse",
            arguments: ["--source", "cline"],
            stdin: #"{"hookName":"PostToolUse","taskId":"1761120000001","postToolUse":{"toolName":"read_file","parameters":{"path":"a.txt"},"result":"ok","success":true}}"#
        ),
        Fixture(
            name: "cline-task-start",
            arguments: ["--source", "cline"],
            stdin: #"{"hookName":"TaskStart","taskId":"1761120000002","taskStart":{"taskMetadata":{"taskId":"1761120000002"}}}"#
        ),
        Fixture(
            name: "hermes-post-llm-call",
            arguments: ["--source", "hermes"],
            environment: ["HERMES_HOME": "~/.hermes/profiles/work"],
            stdin: #"{"hook_event_name":"post_llm_call","tool_name":null,"tool_input":null,"session_id":"20261009_101151_eafbd0","cwd":"/Users/golden/project","profile":"work","extra":{"user_message":"Fix the login bug","assistant_response":"Fixed.","conversation_history":[{"role":"user","content":"SECRET-EARLIER-TURN"}],"model":"hermes-4","platform":"cli"}}"#,
            ancestors: [Ancestor(path: "home/.local/bin/hermes")]
        ),
        Fixture(
            name: "hermes-absolute-home",
            arguments: ["--source", "hermes"],
            environment: ["HERMES_HOME": "  /srv/hermes  "],
            stdin: #"{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":{"command":"ls"},"session_id":"20261009_101151_eafbd1","cwd":"/Users/golden/project","extra":{}}"#
        ),
        Fixture(
            name: "hermes-no-home",
            arguments: ["--source", "hermes"],
            stdin: #"{"hook_event_name":"on_session_end","session_id":"20261009_101151_eafbd2","cwd":"/Users/golden/project","extra":{"completed":true,"platform":"telegram"}}"#
        ),
        Fixture(
            name: "gemini-beforetool-allow",
            arguments: ["--source", "gemini", "--event", "BeforeTool"],
            stdin: #"{"session_id":"gemini-1","transcript_path":"/Users/golden/.gemini/tmp/x/chats/session.json","hook_event_name":"BeforeTool","timestamp":"2026-10-22T08:00:00Z","tool_name":"run_shell_command","tool_input":{"command":"ls"}}"#,
            ancestors: [Ancestor(path: "opt/homebrew/bin/gemini")],
            reply: allowReply
        ),
        Fixture(
            name: "gemini-beforetool-unparsable-deny",
            arguments: ["--source", "gemini", "--event", "BeforeTool"],
            stdin: #"{"session_id":"gemini-2","hook_event_name":"BeforeTool","tool_name":"write_file","tool_input":{"file_path":"x"}}"#,
            reply: #"not json but "behavior":"deny" anyway"#
        ),
        Fixture(
            name: "gemini-beforetool-unparsable-always",
            arguments: ["--source", "gemini", "--event", "BeforeTool"],
            stdin: #"{"session_id":"gemini-3","hook_event_name":"BeforeTool","tool_name":"write_file"}"#,
            reply: #"{"hookSpecificOutput":{"decision":"behavior"},"x":"\"behavior\":\"always\""}"#
        ),
        Fixture(
            name: "gemini-beforetool-raw-reply",
            arguments: ["--source", "gemini", "--event", "BeforeTool"],
            stdin: #"{"session_id":"gemini-4","hook_event_name":"BeforeTool","tool_name":"write_file"}"#,
            reply: "{}"
        ),
        Fixture(
            name: "gemini-aftertool",
            arguments: ["--source", "gemini", "--event", "AfterTool"],
            stdin: #"{"session_id":"gemini-5","hook_event_name":"AfterTool","tool_name":"run_shell_command","tool_response":{"output":"ok"}}"#,
            reply: allowReply
        ),
        Fixture(
            name: "gemini-pretooluse-is-antigravity",
            arguments: ["--source", "gemini", "--event", "PreToolUse"],
            stdin: #"{"conversationId":"agy-conv-0","stepIdx":2,"toolCall":{"name":"view_file","args":{"AbsolutePath":"/Users/golden/project/a.txt"}}}"#
        ),
        Fixture(
            name: "agy-pretooluse",
            arguments: ["--source", "google-antigravity", "--event", "PreToolUse"],
            stdin: #"{"conversationId":"agy-conv-1","stepIdx":1,"toolCall":{"name":"run_command","args":{"CommandLine":"npm test"}},"transcriptPath":"/Users/golden/.gemini/antigravity/brain/agy-conv-1/transcript.jsonl"}"#,
            ancestors: [Ancestor(path: "home/.local/bin/agy")]
        ),
        Fixture(
            name: "agy-event-on-stdin",
            arguments: ["--source", "google-antigravity"],
            stdin: #"{"hook_event_name":"PreToolUse","conversationId":"agy-conv-2","toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}"#
        ),
        Fixture(
            name: "agy-permission-always",
            arguments: ["--source", "google-antigravity", "--event", "PermissionRequest"],
            stdin: #"{"conversationId":"agy-conv-3","toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf dist"}}}"#,
            reply: alwaysReply
        ),
        Fixture(
            name: "agy-agent-alias-permission-deny",
            arguments: ["--source", "agy", "--event", "PermissionRequest"],
            stdin: #"{"conversationId":"agy-conv-4","toolCall":{"name":"run_command"}}"#,
            reply: denyReply
        ),
        Fixture(
            name: "agy-pretooluse-skip",
            arguments: ["--source", "google-antigravity", "--event", "PreToolUse"],
            environment: ["CODEISLAND_SKIP": "1"],
            stdin: #"{"conversationId":"agy-conv-5"}"#
        ),
        Fixture(
            name: "agy-pretooluse-island-not-running",
            arguments: ["--source", "google-antigravity", "--event", "PreToolUse"],
            stdin: #"{"conversationId":"agy-conv-6"}"#,
            hasSocket: false
        ),
        Fixture(
            name: "copilot-pretooluse-fallback-session",
            arguments: ["--source", "copilot", "--event", "preToolUse"],
            stdin: #"{"timestamp":1761120000000,"cwd":"/Users/golden/project","toolName":"bash","toolArgs":"{\"command\":\"ls -la\",\"description\":\"List\"}"}"#,
            ancestors: [
                node,
                Ancestor(path: "home/.npm-global/lib/node_modules/@github/copilot"),
                Ancestor(path: "bin/zsh"),
                Ancestor(path: "home/.npm-global/bin/copilot"),
            ]
        ),
        Fixture(
            name: "copilot-session-start-with-id",
            arguments: ["--source", "copilot", "--event", "sessionStart"],
            stdin: #"{"sessionId":"copilot-sess-1","timestamp":1761120000000,"cwd":"/Users/golden/project","source":"new","initialPrompt":"hi","toolArgs":"not json"}"#
        ),
        Fixture(
            name: "qoder-ide-stop",
            arguments: ["--source", "qoder"],
            stdin: #"{"session_id":"qoder-1","cwd":"/Users/golden/project","hook_event_name":"Stop"}"#,
            ancestors: [Ancestor(path: "Applications/Qoder.app/Contents/MacOS/Electron")]
        ),
        Fixture(
            name: "qoder-cli-promoted",
            arguments: ["--source", "qoder"],
            stdin: #"{"session_id":"qoder-2","cwd":"/Users/golden/project","hook_event_name":"PreToolUse","tool_name":"Bash"}"#,
            ancestors: [Ancestor(path: "opt/homebrew/bin/qodercli")]
        ),
        Fixture(
            name: "qoder-cn-cli",
            arguments: ["--source", "qoder-cli"],
            stdin: #"{"session_id":"qoder-3","cwd":"/Users/golden/project","hook_event_name":"UserPromptSubmit","prompt":"你好"}"#,
            ancestors: [Ancestor(path: "home/.qoder-cn/bin/qoderclicn-1.1.5")]
        ),
        Fixture(
            name: "kimi-user-prompt",
            arguments: ["--source", "kimi"],
            stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"session_kimi_1","cwd":"/Users/golden/project","prompt":[{"type":"text","text":"Explain this"}]}"#,
            ancestors: [Ancestor(path: "home/.kimi-code/bin/kimi")]
        ),
        Fixture(
            name: "trae-ide-before-submit",
            arguments: ["--source", "trae", "--event", "beforeSubmitPrompt"],
            stdin: #"{"session_id":"trae-1","prompt":"first task","workspace_roots":["/Users/golden/project"]}"#,
            ancestors: [Ancestor(path: "Applications/Trae.app/Contents/MacOS/Electron")]
        ),
        Fixture(
            name: "traecn-runs-hooks-through-bash",
            arguments: ["--source", "traecn", "--event", "beforeShellExecution"],
            stdin: #"{"session_id":"traecn-1","command":"ls","cwd":"/Users/golden/project"}"#,
            ancestors: [
                Ancestor(path: "bin/bash"),
                Ancestor(path: "Applications/Trae CN.app/Contents/MacOS/Electron"),
            ]
        ),
        Fixture(
            name: "traecli-pre-tool-use",
            arguments: ["--source", "traecli", "--event", "pre_tool_use"],
            stdin: #"{"session_id":"traecli-1","hook_event_name":"pre_tool_use","tool_name":"RunCommand","tool_input":{"command":"ls"},"cwd":"/Users/golden/project","agent_id":"a1"}"#,
            ancestors: [Ancestor(path: "home/.local/bin/coco")]
        ),
        Fixture(
            name: "minimax-pretooluse",
            arguments: ["--source", "minimax"],
            stdin: #"{"session_id":"mm-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/Users/golden/project"}"#,
            ancestors: [Ancestor(path: "home/.npm/lib/node_modules/@minimax-ai/code/bin/minimax-code")]
        ),
        Fixture(
            name: "grok-managed-hook",
            arguments: ["--source", "grok"],
            environment: [
                "GROK_SESSION_ID": "grok-sess-1",
                "GROK_HOOK_EVENT": "PreToolUse",
                "GROK_WORKSPACE_ROOT": "/Users/golden/other",
                "GROK_HOME": "$ROOT/grokhome",
            ],
            stdin: #"{"hookEventName":"PreToolUse","sessionId":"grok-sess-1","workspaceRoot":"/Users/golden/project","toolName":"bash","toolInput":{"command":"ls"}}"#,
            ancestors: [Ancestor(path: "home/.grok/downloads/grok-0.2.106-macos-aarch64")],
            files: ["grokhome/sessions/%2FUsers%2Fgolden%2Fproject/grok-sess-1/chat_history.jsonl": "{}\n"]
        ),
        Fixture(
            name: "grok-env-only",
            arguments: ["--source", "grok"],
            environment: [
                "GROK_SESSION_ID": "grok-sess-2",
                "GROK_HOOK_EVENT": "Stop",
                "GROK_WORKSPACE_ROOT": "/Users/golden/project",
                "GROK_HOME": "$ROOT/grokhome",
            ],
            stdin: #"{"toolName":"bash"}"#
        ),
        Fixture(
            name: "grok-transcript-not-written-yet",
            arguments: ["--source", "grok"],
            environment: ["GROK_SESSION_ID": "grok-sess-3", "GROK_HOME": "$ROOT/grokhome"],
            stdin: #"{"hookEventName":"SessionStart","sessionId":"grok-sess-3","cwd":"/Users/golden/project"}"#
        ),
        Fixture(
            name: "grok-runs-imported-claude-hook",
            environment: ["GROK_SESSION_ID": "grok-sess-4", "GROK_HOOK_EVENT": "Stop"],
            stdin: #"{"hook_event_name":"Stop","session_id":"grok-sess-4","cwd":"/Users/golden/project"}"#
        ),
        Fixture(
            name: "zcode-tool",
            arguments: ["--source", "zcode"],
            stdin: #"{"hookEventName":"PreToolUse","sessionId":"zc-session-1","toolCallId":"call-1","toolName":"bash","toolInput":{"command":"ls"},"cwd":"/Users/golden/project"}"#
        ),
        Fixture(
            name: "kiro-agent-spawn-fallback-session",
            arguments: ["--source", "kiro"],
            stdin: #"{"hook_event_name":"agentSpawn","cwd":"/Users/golden/project"}"#,
            ancestors: [Ancestor(path: "home/.local/bin/kiro-cli")]
        ),
        Fixture(
            name: "droid-session-start",
            arguments: ["--source", "droid"],
            stdin: #"{"session_id":"droid-1","cwd":"/Users/golden/project","hook_event_name":"SessionStart","source":"startup"}"#,
            ancestors: [Ancestor(path: "home/.local/bin/droid")]
        ),
        Fixture(
            name: "codebuddy-permission",
            arguments: ["--source", "codebuddy"],
            stdin: #"{"session_id":"cb-1","cwd":"/Users/golden/project","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make"}}"#,
            reply: allowReply
        ),
        Fixture(
            name: "qwen-event-from-flag",
            arguments: ["--source", "qwen", "--event", "Stop"],
            stdin: #"{"session_id":"qwen-1"}"#
        ),
        Fixture(
            name: "custom-source-fallback-session",
            arguments: ["--source", "mycli"],
            stdin: #"{"hook_event_name":"Stop"}"#,
            ancestors: [Ancestor(path: "usr-local/bin/mycli")]
        ),
    ]

    // MARK: - Plugins' blocking requests (piped into the bridge without --source)

    static let plugins: [Fixture] = [
        Fixture(
            name: "opencode-plugin-permission",
            stdin: #"{"hook_event_name":"PermissionRequest","session_id":"opencode-ses_1","_source":"opencode","_ppid":4242,"_env":{"TERM_PROGRAM":"ghostty"},"_tty":"/dev/ttys009","_server_port":4096,"cwd":"/Users/golden/project","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#,
            ancestors: [Ancestor(path: "home/.opencode/bin/opencode")],
            reply: allowReply
        ),
        Fixture(
            name: "opencode2-shared-service-question",
            stdin: #"{"hook_event_name":"Notification","session_id":"opencode-ses_2","_source":"opencode","_untracked_process":true,"cwd":"/Users/golden/project","question":"Pick one","options":["a","b"]}"#,
            ancestors: [Ancestor(path: "home/.opencode/bin/opencode")],
            reply: #"{"answers":{"Pick one":"a"}}"#
        ),
        Fixture(
            name: "mimo-plugin-permission",
            stdin: #"{"hook_event_name":"PermissionRequest","session_id":"mimo-ses_1","_source":"mimo","_ppid":4343,"cwd":"/Users/golden/project","tool_name":"Edit"}"#,
            ancestors: [Ancestor(path: "home/.mimocode/bin/mimo")],
            reply: denyReply
        ),
        Fixture(
            name: "pi-plugin-permission",
            environment: ["HERDR_ENV": "1", "HERDR_PANE_ID": "p-3", "HERDR_SOCKET_PATH": "/tmp/herdr-golden.sock"],
            stdin: #"{"session_id":"pi-0193","_source":"pi","_ppid":5151,"_env":{"HERDR_ENV":"1","HERDR_PANE_ID":"p-3","HERDR_SOCKET_PATH":"/tmp/herdr-golden.sock"},"_herdr_pane_id":"p-3","_herdr_socket_path":"/tmp/herdr-golden.sock","_tty":null,"_server_port":0,"cwd":"/Users/golden/project","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"_pi_tool_call_id":"call_1"}"#,
            ancestors: [node],
            reply: allowReply
        ),
        Fixture(
            name: "omp-plugin-question",
            stdin: #"{"session_id":"omp-77","_source":"pi","_ppid":6161,"cwd":"/Users/golden/project","hook_event_name":"Notification","question":"Continue?","options":["Yes","No"]}"#,
            ancestors: [Ancestor(path: "home/.bun/bin/bun")],
            reply: #"{"answer":"Yes"}"#
        ),
        Fixture(
            name: "openclaw-plugin-permission",
            stdin: #"{"session_id":"openclaw-agent:main","_source":"openclaw","_ppid":7171,"_env":{},"_tty":null,"cwd":"/Users/golden/project","hook_event_name":"PermissionRequest","tool_name":"exec","tool_input":{"command":"ls"}}"#,
            ancestors: [Ancestor(path: "opt/homebrew/bin/openclaw")],
            reply: allowReply
        ),
        Fixture(
            name: "plugin-source-alias-normalized",
            stdin: #"{"session_id":"ag-1","_source":"Anti-Gravity","cwd":"/Users/golden/project","hook_event_name":"Stop"}"#,
            ancestors: [claudeNative]
        ),
    ]

    // MARK: - Terminal context

    static let terminals: [Fixture] = [
        Fixture(
            name: "terminal-env-everything",
            arguments: ["--source", "codex"],
            environment: [
                "TERM_PROGRAM": "WezTerm",
                "__CFBundleIdentifier": "com.github.wez.wezterm",
                "ITERM_SESSION_ID": "no-colon-guid",
                "KITTY_WINDOW_ID": "3",
                "KITTY_LISTEN_ON": "unix:/tmp/kitty-77",
                "CMUX_SURFACE_ID": "surface-1",
                "CMUX_WORKSPACE_ID": "workspace-1",
                "ZELLIJ": "0",
                "ZELLIJ_PANE_ID": "5",
                "ZELLIJ_SESSION_NAME": "main",
                "WEZTERM_PANE": "12",
                "HERDR_ENV": "1",
                "HERDR_PANE_ID": " p-1 ",
                "HERDR_SOCKET_PATH": " /tmp/herdr.sock ",
                "HERDR_BIN_PATH": "/opt/herdr/bin/herdr",
                "SUPERSET_WORKSPACE_ID": "sw-1",
                "SUPERSET_TERMINAL_ID": "st-1",
                "ORCA_TERMINAL_HANDLE": "orca-1",
                "ORCA_WORKTREE_ID": "wt-1",
                "CLAUDE_CODE_HOST_SESSION_ID": "local_x",
                "UNRELATED_SECRET": "must-not-leak",
            ],
            stdin: #"{"session_id":"term-1","cwd":"/Users/golden/project","hook_event_name":"Stop"}"#,
            ancestors: [Ancestor(path: "opt/homebrew/bin/codex")]
        ),
        Fixture(
            name: "terminal-env-partial",
            environment: [
                "TERM_PROGRAM": "",
                "ZELLIJ_PANE_ID": "5",
                "HERDR_ENV": "1",
                "HERDR_PANE_ID": "p-2",
                "SUPERSET_PANE_ID": "sp-1",
                "SUPERSET_TERMINAL_ID": "st-2",
                "KITTY_WINDOW_ID": "",
                "KITTY_LISTEN_ON": "",
            ],
            stdin: #"{"session_id":"term-2","hook_event_name":"Stop"}"#,
            ancestors: [claudeNative]
        ),
    ]

    // MARK: - Nothing to forward

    static let drops: [Fixture] = [
        Fixture(name: "no-session-no-source", stdin: #"{"hook_event_name":"Stop","cwd":"/Users/golden/project"}"#),
        Fixture(name: "blank-session-no-source", stdin: #"{"hook_event_name":"Stop","session_id":"   ","sessionId":"","cwd":"/x"}"#),
        Fixture(name: "empty-stdin", arguments: ["--source", "codex"], stdin: ""),
        Fixture(name: "invalid-json", arguments: ["--source", "codex"], stdin: "not json"),
        Fixture(name: "json-array", arguments: ["--source", "codex"], stdin: "[1,2]"),
        Fixture(
            name: "skip-env",
            arguments: ["--source", "codex"],
            environment: ["CODEISLAND_SKIP": "1"],
            stdin: #"{"session_id":"s","hook_event_name":"Stop"}"#
        ),
        Fixture(
            name: "island-not-running",
            arguments: ["--source", "codex"],
            stdin: #"{"session_id":"s","hook_event_name":"Stop"}"#,
            hasSocket: false
        ),
    ]
}
