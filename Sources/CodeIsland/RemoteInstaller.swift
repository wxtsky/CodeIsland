import Foundation

struct RemoteInstallResult: Sendable {
    let ok: Bool
    let message: String
}

private struct RemoteCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var ok: Bool { exitCode == 0 }
}

enum RemoteInstaller {
    private static let remoteHookVersion = "0.1.2"
    private static let remoteOpencodePluginVersion = "v2"

    static func installAll(host: RemoteHost) async -> RemoteInstallResult {
        guard let source = remoteHookSource() else {
            return RemoteInstallResult(ok: false, message: "Missing remote hook resource")
        }
        guard let opencodePlugin = remoteOpencodePluginSource() else {
            return RemoteInstallResult(ok: false, message: "Missing remote OpenCode plugin resource")
        }

        let upload = await uploadRemoteHook(source: source, host: host)
        guard upload.ok else {
            return RemoteInstallResult(ok: false, message: "Upload failed: \(upload.stderrSummary)")
        }

        let uploadOpencode = await uploadRemoteOpencodePlugin(source: opencodePlugin, host: host)
        guard uploadOpencode.ok else {
            return RemoteInstallResult(ok: false, message: "OpenCode plugin upload failed: \(uploadOpencode.stderrSummary)")
        }

        let configure = await configureRemoteHooks(host: host)
        guard configure.ok else {
            return RemoteInstallResult(ok: false, message: "Install failed: \(configure.stderrSummary)")
        }

        let summary = configure.stdoutSummary.isEmpty ? "Claude/Codex/CodeBuddy/Traecli/OpenCode remote hooks installed" : configure.stdoutSummary
        return RemoteInstallResult(ok: true, message: summary)
    }

    static func cleanupRemoteSocket(host: RemoteHost) async {
        _ = await runSSH(host: host, command: "rm -f \(shellSingleQuoted(host.remoteSocketPath))", timeout: 8)
    }

    private static func remoteHookSource() -> String? {
        if let url = Bundle.appModule.url(forResource: "codeisland-remote-hook", withExtension: "py", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) {
            return src
        }
        if let url = Bundle.appModule.url(forResource: "codeisland-remote-hook", withExtension: "py"),
           let src = try? String(contentsOf: url) {
            return src
        }
        return nil
    }

    private static func remoteOpencodePluginSource() -> String? {
        if let url = Bundle.appModule.url(forResource: "codeisland-opencode-remote", withExtension: "js", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) {
            return src
        }
        if let url = Bundle.appModule.url(forResource: "codeisland-opencode-remote", withExtension: "js"),
           let src = try? String(contentsOf: url) {
            return src
        }
        return nil
    }

    private static func uploadRemoteHook(source: String, host: RemoteHost) async -> RemoteCommandResult {
        let encoded = Data(source.utf8).base64EncodedString()
        let py = """
import base64, os, pathlib

target = pathlib.Path.home() / ".codeisland" / "codeisland-remote-hook.py"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(base64.b64decode('''\(encoded)'''))
os.chmod(target, 0o755)
print(target)
"""
        return await runSSH(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeout: 25)
    }

    private static func uploadRemoteOpencodePlugin(source: String, host: RemoteHost) async -> RemoteCommandResult {
        let configuredSource = remoteOpencodePluginForInstall(source: source, host: host)
        let encoded = Data(configuredSource.utf8).base64EncodedString()
        let py = """
import base64, os, pathlib

target = pathlib.Path.home() / ".codeisland" / "codeisland-opencode-remote.js"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(base64.b64decode('''\(encoded)'''))
os.chmod(target, 0o644)
print(target)
"""
        return await runSSH(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeout: 25)
    }

    private static func configureRemoteHooks(host: RemoteHost) async -> RemoteCommandResult {
        let py = configureRemoteHooksScript(host: host)
        // Run via the remote user's login shell so ~/.zprofile / ~/.bash_profile etc. are
        // sourced — that's how $CODEX_HOME (and similar) reach a non-interactive ssh session.
        // base64 keeps the script intact regardless of shell quoting.
        let encoded = Data(py.utf8).base64EncodedString()
        let inner = "echo '\(encoded)' | base64 -d | python3"
        let command = "\"${SHELL:-/bin/bash}\" -lc \"\(inner)\""
        return await runSSH(host: host, command: command, timeout: 30)
    }

    static func configureRemoteHooksScript(host: RemoteHost) -> String {
        let hostId = pythonStringLiteral(host.id)
        let hostName = pythonStringLiteral(host.name)
        let version = pythonStringLiteral(remoteHookVersion)
        let opencodePluginVersion = pythonStringLiteral(remoteOpencodePluginVersion)
        return """
import json
import pathlib
import shutil
import os
import re

home = pathlib.Path.home()
hook_path = home / ".codeisland" / "codeisland-remote-hook.py"
host_id = \(hostId)
host_name = \(hostName)
version = \(version)
opencode_plugin_version = \(opencodePluginVersion)

def _codex_home():
    raw = (os.environ.get("CODEX_HOME") or "").strip()
    if not raw:
        return home / ".codex"
    expanded = os.path.expanduser(raw)
    return pathlib.Path(expanded)

def ensure_json(path):
    if path.exists():
        try:
            return json.loads(path.read_text())
        except Exception:
            return {}
    return {}

def strip_json_comments(text):
    out = []
    i = 0
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            i += 2
            while i < len(text) and text[i] != "\\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)

def ensure_jsonc_object(path):
    if path.exists():
        try:
            data = json.loads(strip_json_comments(path.read_text()))
            return data if isinstance(data, dict) else None
        except Exception:
            return None
    return {}

def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\\n")

def write_text_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)

def write_opencode_config(path, data):
    write_json(path, data)

def command_for(source):
    return f"CODEISLAND_SOCKET_PATH=/tmp/codeisland.sock CODEISLAND_REMOTE_HOST_ID={json.dumps(host_id)} CODEISLAND_REMOTE_HOST_NAME={json.dumps(host_name)} CODEISLAND_SOURCE={source} python3 ~/.codeisland/codeisland-remote-hook.py"

def remove_our_hooks(hooks):
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        next_entries = []
        for entry in entries:
            if not isinstance(entry, dict):
                next_entries.append(entry)
                continue
            commands = []
            if isinstance(entry.get("hooks"), list):
                commands.extend([h.get("command", "") for h in entry["hooks"] if isinstance(h, dict)])
            if isinstance(entry.get("command"), str):
                commands.append(entry["command"])
            if isinstance(entry.get("bash"), str):
                commands.append(entry["bash"])
            if any("codeisland-remote-hook.py" in c for c in commands):
                continue
            next_entries.append(entry)
        if next_entries:
            hooks[event] = next_entries
        else:
            hooks.pop(event, None)

TRAECLI_EVENTS = [
    ("session_start", 5),
    ("session_end", 5),
    ("user_prompt_submit", 5),
    ("pre_tool_use", 5),
    ("post_tool_use", 5),
    ("post_tool_use_failure", 5),
    ("permission_request", 86400),
    ("notification", 86400),
    ("subagent_start", 5),
    ("subagent_stop", 5),
    ("stop", 5),
    ("pre_compact", 5),
    ("post_compact", 5),
]

def _normalize_traecli_hooks_list_indentation(contents):
    # Best-effort repair for invalid YAML produced by mixed indentation under top-level `hooks:`.
    #
    # Only normalize indentation of *hook items* ("- type:" / "- command:")
    # and shift the entire list item block left to match the smallest indent.
    normalized = contents.replace("\\r\\n", "\\n")
    lines = normalized.split("\\n")

    hooks_index = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if line != stripped:
            continue
        if stripped.startswith("hooks:"):
            hooks_index = i
            break
    if hooks_index is None:
        return normalized

    def _is_top_level_key(line):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return False
        if line != stripped:
            return False
        return ":" in stripped and not stripped.startswith("hooks:")

    # Find the smallest indent among hook items.
    indents = []
    i = hooks_index + 1
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if _is_top_level_key(line):
            break
        if stripped.startswith("- type:") or stripped.startswith("- command:"):
            indents.append(len(line) - len(line.lstrip(" ")))
        i += 1
    if not indents:
        return normalized
    base_indent = min(indents)

    out = list(lines)
    i = hooks_index + 1
    while i < len(out):
        line = out[i]
        stripped = line.strip()
        if not stripped:
            i += 1
            continue
        if _is_top_level_key(line):
            break
        if stripped.startswith("- type:") or stripped.startswith("- command:"):
            indent = len(line) - len(line.lstrip(" "))
            if indent > base_indent:
                delta = indent - base_indent
                j = i
                while j < len(out):
                    nxt = out[j]
                    nxt_stripped = nxt.strip()
                    nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                    if j != i:
                        if nxt_indent == indent and nxt_stripped.startswith("- "):
                            break
                        if nxt_indent < indent and nxt_stripped != "":
                            break
                    if nxt.startswith(" " * delta):
                        out[j] = nxt[delta:]
                    j += 1
                i = j
                continue
        i += 1

    return "\\n".join(out)

def _detect_traecli_hook_item_indent(lines, hooks_index):
    def _is_top_level_key(line):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return False
        if line != stripped:
            return False
        return ":" in stripped and not stripped.startswith("hooks:")

    indents = []
    i = hooks_index + 1
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if _is_top_level_key(line):
            break
        if stripped.startswith("- type:") or stripped.startswith("- command:"):
            indents.append(len(line) - len(line.lstrip(" ")))
        i += 1
    return min(indents) if indents else 2

def _render_managed_traecli_hooks(cmd, indent=2):
    # Escape single quotes for YAML single-quoted string
    escaped = cmd.replace("'", "''")
    timeout = max([t for (_, t) in TRAECLI_EVENTS] or [5])
    pad = " " * indent
    pad2 = " " * (indent + 2)
    pad4 = " " * (indent + 4)
    lines = [f"{pad}- type: command"]
    lines.append(f"{pad2}command: '{escaped}'")
    lines.append(f"{pad2}timeout: '{timeout}s'")
    lines.append(f"{pad2}matchers:")
    for (event, _) in TRAECLI_EVENTS:
        lines.append(f"{pad4}- event: {event}")
    return "\\n".join(lines)

def _remove_managed_traecli_hooks(contents):
    normalized = _normalize_traecli_hooks_list_indentation(contents)
    lines = normalized.split("\\n")
    result = []

    # Legacy compatibility: previous versions could leave extra comment lines around our hook.
    # We do NOT key off any marker token. Instead, when removing a hook by command match,
    # we also remove contiguous same-indent comment lines adjacent to that hook.

    def _parse_scalar(raw):
        raw = raw.strip()
        if raw.startswith("'") and raw.endswith("'") and len(raw) >= 2:
            return raw[1:-1].replace("''", "'")
        if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
            inner = raw[1:-1]
            bs = chr(92)
            return inner.replace(bs + bs, bs).replace(bs + '"', '"')
        return raw

    def _normalize_cmd(cmd):
        s = " ".join((cmd or "").strip().split())
        if not s:
            return s
        # Normalize first token: allow quoted executable path.
        if s.startswith('"'):
            end = s.find('"', 1)
            if end != -1:
                first = s[1:end]
                rest = s[end+1:].strip()
                s = first + (" " + rest if rest else "")
        parts = s.split(" ", 1)
        first = parts[0]
        rest = parts[1] if len(parts) > 1 else ""
        if first.startswith("~/"):
            first = str(home) + "/" + first[2:]
        return first + (" " + rest if rest else "")

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        prefix = "- type: command"
        if stripped.startswith(prefix) and (stripped == prefix or stripped[len(prefix):].startswith((" ", "\t", "#"))):
            indent = len(line) - len(line.lstrip(" "))
            j = i + 1
            cmd_value = None
            while j < len(lines):
                nxt = lines[j]
                nxt_stripped = nxt.strip()
                nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                if nxt_indent == indent and nxt_stripped.startswith("- "):
                    break
                if nxt_indent < indent and nxt_stripped != "":
                    break
                if nxt_stripped.startswith("command:"):
                    cmd_value = _parse_scalar(nxt_stripped.split(":", 1)[1])
                j += 1

            if cmd_value and _normalize_cmd(cmd_value) == _normalize_cmd(command_for("traecli")):
                # Remove adjacent same-indent comment lines already appended.
                while result:
                    prev = result[-1]
                    prev_stripped = prev.strip()
                    prev_indent = len(prev) - len(prev.lstrip(" "))
                    if prev_indent == indent and prev_stripped.startswith("#"):
                        result.pop()
                        continue
                    break

                # Skip forward adjacent same-indent comment lines.
                k = j
                while k < len(lines):
                    nxt = lines[k]
                    nxt_stripped = nxt.strip()
                    nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                    if nxt_indent == indent and nxt_stripped.startswith("#"):
                        k += 1
                        continue
                    break

                i = k
                continue

            result.extend(lines[i:j])
            i = j
            continue

        result.append(line)
        i += 1
    # Trim trailing empty lines (keep one newline at end)
    while len(result) >= 2 and (result[-1] == "") and (result[-2] == ""):
        result.pop()
    return "\\n".join(result)

def _merge_traecli_hooks(contents, cmd):
    normalized = _normalize_traecli_hooks_list_indentation(contents)
    cleaned = _remove_managed_traecli_hooks(normalized)
    lines = cleaned.split("\\n")
    hooks_index = None
    hooks_scalar = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if line != stripped:
            continue
        if not stripped.startswith("hooks:"):
            continue
        tail = stripped[len("hooks:"):]
        before_comment = tail.split("#", 1)[0].strip()
        if before_comment in ("", "[]", "{}", "null", "~"):
            hooks_index = i
            hooks_scalar = before_comment
            break
    if hooks_index is not None:
        indent = _detect_traecli_hook_item_indent(lines, hooks_index)
        managed_lines = _render_managed_traecli_hooks(cmd, indent=indent).split("\\n")
        if hooks_scalar and hooks_scalar != "":
            lines[hooks_index] = "hooks:"
        lines[hooks_index+1:hooks_index+1] = managed_lines
    else:
        managed_lines = _render_managed_traecli_hooks(cmd, indent=2).split("\\n")
        while lines and lines[-1] == "":
            lines.pop()
        if lines:
            lines.append("")
        lines.append("hooks:")
        lines.extend(managed_lines)
    merged = "\\n".join(lines)
    if not merged.endswith("\\n"):
        merged += "\\n"
    return merged

def install_claude():
    claude_root = home / ".claude"
    if not claude_root.exists() and shutil.which("claude") is None:
        return "Claude skipped"

    settings_path = claude_root / "settings.json"
    data = ensure_json(settings_path)
    hooks = data.get("hooks") or {}
    remove_our_hooks(hooks)

    cmd = command_for("claude")
    without_matcher = [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_matcher = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_long_timeout = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 86400}]}]
    precompact = [
        {"matcher": "auto", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
        {"matcher": "manual", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
    ]
    hooks["UserPromptSubmit"] = without_matcher
    hooks["PermissionRequest"] = with_long_timeout
    hooks["Notification"] = with_matcher
    hooks["Stop"] = without_matcher
    hooks["SessionStart"] = without_matcher
    hooks["SessionEnd"] = without_matcher
    hooks["PreCompact"] = precompact
    data["hooks"] = hooks
    write_json(settings_path, data)
    return "Claude ok"

def ensure_toml_codex_hooks(path):
    content = path.read_text() if path.exists() else ""
    if re.search(r"(?m)^\\s*hooks\\s*=\\s*true\\s*$", content):
        return
    if re.search(r"(?m)^\\s*hooks\\s*=\\s*false\\s*$", content):
        content = re.sub(r"(?m)^\\s*hooks\\s*=\\s*false\\s*$", "hooks = true", content)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content.rstrip() + "\\n")
        return
    if re.search(r"(?m)^\\s*codex_hooks\\s*=\\s*(true|false)\\s*$", content):
        content = re.sub(r"(?m)^\\s*codex_hooks\\s*=\\s*(true|false)\\s*$", "hooks = true", content)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content.rstrip() + "\\n")
        return
    lines = content.splitlines()
    try:
        idx = next(i for i, line in enumerate(lines) if line.strip() == "[features]")
        lines.insert(idx + 1, "hooks = true")
    except StopIteration:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend(["[features]", "hooks = true"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\\n".join(lines).rstrip() + "\\n")

def install_codex():
    codex_root = _codex_home()
    if not codex_root.exists() and shutil.which("codex") is None:
        return "Codex skipped"

    hooks_path = codex_root / "hooks.json"
    data = ensure_json(hooks_path)
    hooks = data.get("hooks") or {}
    remove_our_hooks(hooks)

    cmd = command_for("codex")
    entry = [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    hooks["SessionStart"] = entry
    hooks["UserPromptSubmit"] = entry
    hooks["Stop"] = entry
    data["hooks"] = hooks
    write_json(hooks_path, data)
    ensure_toml_codex_hooks(codex_root / "config.toml")
    return "Codex ok"

def install_codebuddy():
    codebuddy_root = home / ".codebuddy"
    if not codebuddy_root.exists() and shutil.which("codebuddy") is None:
        return "CodeBuddy skipped"

    settings_path = codebuddy_root / "settings.json"
    data = ensure_json(settings_path)
    hooks = data.get("hooks") or {}
    remove_our_hooks(hooks)

    cmd = command_for("codebuddy")
    without_matcher = [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_matcher = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_long_timeout = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 86400}]}]
    precompact = [
        {"matcher": "auto", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
        {"matcher": "manual", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
    ]
    hooks["UserPromptSubmit"] = without_matcher
    hooks["PermissionRequest"] = with_long_timeout
    hooks["Notification"] = with_matcher
    hooks["Stop"] = without_matcher
    hooks["SessionStart"] = without_matcher
    hooks["SessionEnd"] = without_matcher
    hooks["PreCompact"] = precompact
    data["hooks"] = hooks
    write_json(settings_path, data)
    return "CodeBuddy ok"

def install_traecli():
    traecli_root = home / ".trae"
    if not traecli_root.exists() and shutil.which("traecli") is None:
        return "Traecli skipped"

    config_path = traecli_root / "traecli.yaml"
    try:
        original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    except Exception:
        return "Traecli read failed"
    cmd = command_for("traecli")
    merged = _merge_traecli_hooks(original, cmd)
    write_text_atomic(config_path, merged)
    return "Traecli ok"

def install_opencode():
    opencode_root = home / ".config" / "opencode"
    if not opencode_root.exists() and shutil.which("opencode") is None:
        return "OpenCode skipped"

    plugin_path = home / ".codeisland" / "codeisland-opencode-remote.js"
    if not plugin_path.exists():
        return "OpenCode plugin missing"

    target_path = opencode_root / "opencode.jsonc"
    if not target_path.exists():
        target_path = opencode_root / "opencode.json"
    data = ensure_jsonc_object(target_path)
    if data is None:
        return "OpenCode config unreadable"

    plugin_ref = "file://" + str(plugin_path)
    plugins = data.get("plugin")
    if not isinstance(plugins, list):
        plugins = []
    plugins = [
        p for p in plugins
        if not (isinstance(p, str) and ("vibe-island" in p or "codeisland" in p))
    ]
    plugins.append(plugin_ref)
    data["plugin"] = plugins
    data.setdefault("$schema", "https://opencode.ai/config.json")
    write_opencode_config(target_path, data)

    legacy_path = opencode_root / "config.json"
    if legacy_path.exists():
        legacy = ensure_jsonc_object(legacy_path)
        if isinstance(legacy, dict) and isinstance(legacy.get("plugin"), list):
            cleaned = [p for p in legacy["plugin"] if not (isinstance(p, str) and ("vibe-island" in p or "codeisland" in p))]
            if cleaned != legacy["plugin"]:
                if cleaned:
                    legacy["plugin"] = cleaned
                else:
                    legacy.pop("plugin", None)
                write_opencode_config(legacy_path, legacy)
    return "OpenCode ok"

parts = [install_claude(), install_codex(), install_codebuddy(), install_traecli(), install_opencode()]
print(" · ".join(parts))
"""
    }

    private static func runSSH(host: RemoteHost, command: String, timeout: TimeInterval) async -> RemoteCommandResult {
        guard !host.sshTarget.isEmpty else {
            return RemoteCommandResult(stdout: "", stderr: "invalid host", exitCode: -1)
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments(host: host) + [command]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(returning: RemoteCommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
                return
            }

            let timeoutTask = Task.detached {
                let ns = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if process.isRunning {
                    process.terminate()
                }
            }

            Task.detached {
                process.waitUntilExit()
                timeoutTask.cancel()
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: RemoteCommandResult(stdout: out, stderr: err, exitCode: process.terminationStatus))
            }
        }
    }

    private static func sshArguments(host: RemoteHost) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
        ]
        if let port = host.port {
            args += ["-p", String(port)]
        }
        let trimmedIdentity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args += ["-i", trimmedIdentity]
        }
        args.append(host.sshTarget)
        return args
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    static func remoteOpencodePluginForInstall(source: String, host: RemoteHost) -> String {
        source
            .replacingOccurrences(
                of: #"const SOCKET_PATH = process.env.CODEISLAND_SOCKET_PATH || "/tmp/codeisland.sock";"#,
                with: #"const SOCKET_PATH = \#(jsonStringLiteral(host.remoteSocketPath));"#
            )
            .replacingOccurrences(
                of: #"const REMOTE_HOST_ID = process.env.CODEISLAND_REMOTE_HOST_ID || "";"#,
                with: #"const REMOTE_HOST_ID = \#(jsonStringLiteral(host.id));"#
            )
            .replacingOccurrences(
                of: #"const REMOTE_HOST_NAME = process.env.CODEISLAND_REMOTE_HOST_NAME || "";"#,
                with: #"const REMOTE_HOST_NAME = \#(jsonStringLiteral(host.name));"#
            )
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        let escaped = value.reduce(into: "") { result, ch in
            switch ch {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                result.append(ch)
            }
        }
        return "\"\(escaped)\""
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension RemoteCommandResult {
    var stderrSummary: String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown error" : trimmed
    }

    var stdoutSummary: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
