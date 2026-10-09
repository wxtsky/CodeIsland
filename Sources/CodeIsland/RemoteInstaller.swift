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
    private static let remoteHookVersion = "0.3.0"
    private static let remoteOpencodePluginVersion = "v3"

    static func installAll(host: RemoteHost, remoteSocketPath: String) async -> RemoteInstallResult {
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

        let uploadOpencode = await uploadRemoteOpencodePlugin(source: opencodePlugin, host: host, remoteSocketPath: remoteSocketPath)
        guard uploadOpencode.ok else {
            return RemoteInstallResult(ok: false, message: "OpenCode plugin upload failed: \(uploadOpencode.stderrSummary)")
        }

        let configure = await configureRemoteHooks(host: host, remoteSocketPath: remoteSocketPath)
        guard configure.ok else {
            return RemoteInstallResult(ok: false, message: "Install failed: \(configure.stderrSummary)")
        }

        let summary = configure.stdoutSummary.isEmpty ? "Claude/Qoder/Codex/CodeBuddy/Traecli/OpenCode remote hooks installed" : configure.stdoutSummary
        return RemoteInstallResult(ok: true, message: summary)
    }

    /// Probe the remote user's UID and return a per-user socket path so that multiple
    /// OS users on a shared host don't collide on a single `/tmp/codeisland.sock` (#193).
    /// Falls back to the legacy shared path when the probe fails (older / restricted host).
    static func prepareRemoteSocketPath(host: RemoteHost) async -> String {
        // `id -u` is a bare external command, so it returns the remote uid identically
        // under any login shell (bash / zsh / fish / csh). A fancier `$(...)` pipeline
        // would break under non-POSIX login shells like fish and silently fall back.
        let probe = await runSSH(host: host, command: "id -u", timeout: 8)
        let uid = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if probe.ok, !uid.isEmpty, uid.allSatisfy({ $0.isNumber }) {
            return "/tmp/codeisland-\(uid).sock"
        }
        // Probe failed (old / restricted host) — fall back to the legacy shared path.
        // StreamLocalBindUnlink=yes on the forward already clears any stale socket, so
        // we avoid a second SSH round-trip here (it would just add latency on a host
        // that's likely failing to connect anyway).
        return host.remoteSocketPath
    }

    static func remoteHookSource() -> String? {
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

    private static func uploadRemoteOpencodePlugin(source: String, host: RemoteHost, remoteSocketPath: String) async -> RemoteCommandResult {
        let configuredSource = remoteOpencodePluginForInstall(source: source, host: host, remoteSocketPath: remoteSocketPath)
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

    private static func configureRemoteHooks(host: RemoteHost, remoteSocketPath: String) async -> RemoteCommandResult {
        let py = configureRemoteHooksScript(host: host, remoteSocketPath: remoteSocketPath)
        // Run via the remote user's login shell so ~/.zprofile / ~/.bash_profile etc. are
        // sourced — that's how $CODEX_HOME / $CLAUDE_CONFIG_DIR (and similar) reach a
        // non-interactive ssh session. Interactive-only rc files (.bashrc/.zshrc) are not.
        // base64 keeps the script intact regardless of shell quoting.
        let encoded = Data(py.utf8).base64EncodedString()
        let inner = "echo '\(encoded)' | base64 -d | python3"
        let command = "\"${SHELL:-/bin/bash}\" -lc \"\(inner)\""
        return await runSSH(host: host, command: command, timeout: 30)
    }

    static func configureRemoteHooksScript(
        host: RemoteHost,
        remoteSocketPath: String? = nil,
        customCLIs: [CLIConfig] = ConfigInstaller.customCLIs()
    ) -> String {
        let hostId = pythonStringLiteral(host.id)
        let hostName = pythonStringLiteral(host.name)
        let version = pythonStringLiteral(remoteHookVersion)
        let opencodePluginVersion = pythonStringLiteral(remoteOpencodePluginVersion)
        let socketPath = pythonStringLiteral(remoteSocketPath ?? host.remoteSocketPath)
        let customCLIsLiteral = remoteCustomCLIsLiteral(customCLIs)
        let unsupportedCustomCLIsLiteral = "[" + customCLIs
            .filter { !isRemoteSupportedCustomFormat($0.format) }
            .map { pythonStringLiteral($0.name) }
            .joined(separator: ", ") + "]"
        return """
import json
import pathlib
import shlex
import shutil
import os
import re

home = pathlib.Path.home()
hook_path = home / ".codeisland" / "codeisland-remote-hook.py"
host_id = \(hostId)
host_name = \(hostName)
version = \(version)
opencode_plugin_version = \(opencodePluginVersion)
socket_path = \(socketPath)
custom_clis = \(customCLIsLiteral)
unsupported_custom_clis = \(unsupportedCustomCLIsLiteral)

def _codex_home():
    raw = (os.environ.get("CODEX_HOME") or "").strip()
    if not raw:
        return home / ".codex"
    expanded = os.path.expanduser(raw)
    return pathlib.Path(expanded)

def _claude_config_dir():
    # Claude Code reads $CLAUDE_CONFIG_DIR as one verbatim path, else ~/.claude (#271).
    # None means "unset" and the caller keeps the ~/.claude default. Same rules as the
    # Mac-side ClaudeConfigPaths.normalized() (trim, expand ~, absolute only) EXCEPT
    # Unicode normalization: ext4/xfs are byte-preserving, so an NFC-normalized path
    # can name a directory that does not exist. Never normalize here. Mirrored in
    # codeisland-remote-hook.py, which must resolve the same dir.
    raw = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip()
    if not raw:
        return None
    expanded = os.path.expanduser(raw)
    if not os.path.isabs(expanded) or expanded.strip("/") == "":
        return None
    return pathlib.Path(expanded)

def _display_path(path):
    # Remote-home-relative form for the status line, so a skip reason names the
    # exact directory that was checked on the remote host.
    try:
        rel = str(path.relative_to(home))
    except ValueError:
        return str(path)
    return "~" if rel == "." else "~/" + rel

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
    return f"CODEISLAND_SOCKET_PATH={socket_path} CODEISLAND_REMOTE_HOST_ID={json.dumps(host_id)} CODEISLAND_REMOTE_HOST_NAME={json.dumps(host_name)} CODEISLAND_SOURCE={source} python3 ~/.codeisland/codeisland-remote-hook.py"

def append_our_hooks(hooks, event, entries):
    # Preserve user-authored entries (#242): remove_our_hooks() already dropped our
    # stale entries, so append the fresh managed ones AFTER whatever the user has,
    # mirroring the local ConfigInstaller merge semantics. Never replace the event key.
    existing = hooks.get(event)
    if not isinstance(existing, list):
        existing = []
    hooks[event] = existing + entries

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
    configured_root = _claude_config_dir()
    claude_root = configured_root or home / ".claude"
    # One guard for both cases, no early return: with $CLAUDE_CONFIG_DIR set, a host
    # where Claude Code is on PATH but has never run has no config dir yet, and it
    # must still get hooks (#271).
    if not claude_root.exists() and shutil.which("claude") is None:
        if configured_root is None:
            return "Claude skipped"
        return "Claude skipped (config dir not found: " + _display_path(claude_root) + ")"

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
    append_our_hooks(hooks, "UserPromptSubmit", without_matcher)
    append_our_hooks(hooks, "PermissionRequest", with_long_timeout)
    append_our_hooks(hooks, "Notification", with_matcher)
    append_our_hooks(hooks, "Stop", without_matcher)
    append_our_hooks(hooks, "SessionStart", without_matcher)
    append_our_hooks(hooks, "SessionEnd", without_matcher)
    append_our_hooks(hooks, "PreCompact", precompact)
    data["hooks"] = hooks
    write_json(settings_path, data)
    if configured_root is None:
        return "Claude ok"
    # Name the dir: it is the only way to see that $CLAUDE_CONFIG_DIR actually
    # reached the non-interactive login shell this script runs in.
    return "Claude ok (" + _display_path(claude_root) + ")"

def install_qoder():
    qoder_root = home / ".qoder"
    if not qoder_root.exists() and shutil.which("qodercli") is None and shutil.which("qoder") is None:
        return "Qoder skipped"

    settings_path = qoder_root / "settings.json"
    data = ensure_json(settings_path)
    hooks = data.get("hooks") or {}
    remove_our_hooks(hooks)

    cmd = command_for("qoder")
    without_matcher = [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_matcher = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_long_timeout = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 86400}]}]
    precompact = [
        {"matcher": "auto", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
        {"matcher": "manual", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
    ]
    append_our_hooks(hooks, "UserPromptSubmit", without_matcher)
    append_our_hooks(hooks, "PermissionRequest", with_long_timeout)
    append_our_hooks(hooks, "Notification", with_matcher)
    append_our_hooks(hooks, "Stop", without_matcher)
    append_our_hooks(hooks, "SessionStart", without_matcher)
    append_our_hooks(hooks, "SessionEnd", without_matcher)
    append_our_hooks(hooks, "PreCompact", precompact)
    data["hooks"] = hooks
    write_json(settings_path, data)
    return "Qoder ok"

# Hermes (Nous Research) is NOT a Claude Code fork. It reads shell hooks from
# ~/.hermes/config.yaml under a `hooks:` MAP keyed by snake_case event names whose
# values are lists of { command, timeout }. settings.json is never parsed (#226).
def hermes_command():
    # Hermes runs a hook command without a shell: shlex.split, then exec
    # (agent/shell_hooks.py). command_for()'s `VAR=value python3 ~/...` form was
    # taken for a program named `CODEISLAND_SOCKET_PATH=...` and never ran, and
    # `~` is never expanded. `env` sets the variables; the hook path is absolute.
    args = [
        "env",
        "CODEISLAND_SOCKET_PATH=" + socket_path,
        "CODEISLAND_REMOTE_HOST_ID=" + host_id,
        "CODEISLAND_REMOTE_HOST_NAME=" + host_name,
        "CODEISLAND_SOURCE=hermes",
        "python3",
        str(hook_path),
    ]
    return " ".join(shlex.quote(a) for a in args)

def _is_managed_hermes_cmd(c, target_cmd):
    # Ours in either form: the current one, or the shell form earlier installs wrote.
    if _normalize_hook_cmd(c) == target_cmd:
        return True
    s = c or ""
    return "codeisland-remote-hook.py" in s and "CODEISLAND_SOURCE=hermes" in s

HERMES_EVENTS = [
    ("pre_tool_call", 5),
    ("post_tool_call", 5),
    ("pre_llm_call", 5),
    ("post_llm_call", 5),
    ("on_session_start", 5),
    ("on_session_end", 5),
    ("subagent_stop", 5),
]

def _parse_yaml_scalar(raw):
    raw = raw.strip()
    if raw.startswith("'") and raw.endswith("'") and len(raw) >= 2:
        return raw[1:-1].replace("''", "'")
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        inner = raw[1:-1]
        bs = chr(92)
        return inner.replace(bs + bs, bs).replace(bs + '"', '"')
    return raw

def _normalize_hook_cmd(c):
    s = " ".join((c or "").strip().split())
    if not s:
        return s
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

def _merge_hermes_hooks(contents, cmd):
    # Event-key-aware merge for Hermes' nested `hooks:` MAP. We parse the existing
    # map into an ordered {event: [item-blocks]} structure, drop our prior managed
    # entries (matched by command), prepend a fresh managed entry under each of our
    # status events, then re-emit a single `hooks:` block. This is idempotent and
    # never produces duplicate event keys (#226).
    normalized = contents.replace("\\r\\n", "\\n")
    lines = normalized.split("\\n")
    target_cmd = _normalize_hook_cmd(cmd)

    def _is_top_level_key(line):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return False
        if line != stripped:
            return False
        return ":" in stripped

    # Locate a top-level `hooks:` mapping key (empty scalar or block-mapping).
    hooks_index = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if line != stripped:
            continue
        if stripped == "hooks:" or stripped.startswith("hooks:"):
            tail = stripped[len("hooks:"):].split("#", 1)[0].strip()
            if tail in ("", "{}", "null", "~"):
                hooks_index = i
                break

    # Ordered list of (event, [item_blocks]); item_block is a list of raw lines
    # for one `- ...` list entry, re-indented to 4 spaces on emit.
    order = []
    events = {}

    def _ensure_event(ev):
        if ev not in events:
            events[ev] = []
            order.append(ev)

    head_lines = []
    tail_lines = []
    if hooks_index is not None:
        head_lines = lines[:hooks_index]
        j = hooks_index + 1
        current_event = None
        while j < len(lines):
            line = lines[j]
            stripped = line.strip()
            if stripped and _is_top_level_key(line):
                break  # left the hooks: block
            if stripped == "" or stripped.startswith("#"):
                j += 1
                continue
            indent = len(line) - len(line.lstrip(" "))
            # An event sub-key like "  pre_tool_call:".
            if not stripped.startswith("- ") and stripped.endswith(":") and indent >= 1:
                current_event = stripped[:-1].strip()
                _ensure_event(current_event)
                j += 1
                continue
            # A list item under the current event.
            if stripped.startswith("- ") and current_event is not None:
                item_indent = indent
                k = j + 1
                while k < len(lines):
                    nxt = lines[k]
                    nxt_stripped = nxt.strip()
                    nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                    if nxt_stripped == "":
                        k += 1
                        continue
                    if nxt_indent <= item_indent:
                        break
                    k += 1
                raw_block = [bl for bl in lines[j:k] if bl.strip() != ""]
                cmd_value = None
                for bl in raw_block:
                    bstr = bl.strip()
                    key = bstr[2:].strip() if bstr.startswith("- ") else bstr
                    if key.startswith("command:"):
                        cmd_value = _parse_yaml_scalar(key.split(":", 1)[1])
                        break
                # Re-indent the user item to a canonical 4-space list indent so it
                # composes with our managed entries (avoids mixed-indent YAML).
                base = min(len(bl) - len(bl.lstrip(" ")) for bl in raw_block)
                block = []
                for bl in raw_block:
                    cur = len(bl) - len(bl.lstrip(" "))
                    block.append(" " * (4 + (cur - base)) + bl.lstrip(" "))
                # Drop our prior managed entries; keep user entries.
                if not (cmd_value is not None and _is_managed_hermes_cmd(cmd_value, target_cmd)):
                    events[current_event].append(block)
                j = k
                continue
            j += 1
        tail_lines = lines[j:]
    else:
        head_lines = list(lines)
        while head_lines and head_lines[-1] == "":
            head_lines.pop()

    # Prepend our managed entry under each status event.
    escaped = cmd.replace("'", "''")
    for (event, timeout) in HERMES_EVENTS:
        _ensure_event(event)
        managed_item = [
            f"    - command: '{escaped}'",
            f"      timeout: {timeout}",
        ]
        events[event].insert(0, managed_item)

    out = list(head_lines)
    if out and out[-1].strip() != "":
        out.append("")
    out.append("hooks:")
    for event in order:
        out.append(f"  {event}:")
        for block in events[event]:
            out.extend(block)
    out.extend(tail_lines)

    merged = "\\n".join(out)
    if not merged.endswith("\\n"):
        merged += "\\n"
    return merged

def install_hermes():
    hermes_root = home / ".hermes"
    if not hermes_root.exists() and shutil.which("hermes") is None:
        return "Hermes skipped"

    config_path = hermes_root / "config.yaml"
    try:
        original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    except Exception:
        return "Hermes read failed"
    cmd = hermes_command()
    merged = _merge_hermes_hooks(original, cmd)
    write_text_atomic(config_path, merged)
    return "Hermes ok"

# Codex TOML editing (#354).
def _codex_toml_string(text, i, allow_multiline=False):
    quote = text[i]
    triple = text.startswith(quote * 3, i)
    if triple and not allow_multiline:
        raise ValueError("multiline key")
    i += 3 if triple else 1
    out = []
    escapes = {'b': '\\b', 't': '\\t', 'n': '\\n', 'f': '\\f', 'r': '\\r', '"': '"', '\\\\': '\\\\'}
    while i < len(text):
        ch = text[i]
        if ch == quote:
            end = i + 1
            if triple:
                while end < len(text) and text[end] == quote:
                    end += 1
                count = end - i
                if count < 3:
                    out.append(quote * count)
                    i = end
                    continue
                if count > 5:
                    raise ValueError("quote run")
                out.append(quote * (count - 3))
            return end, ''.join(out)
        if ch == '\\\\' and quote == '"':
            i += 1
            if i == len(text):
                break
            ch = text[i]
            if triple and ch in ' \\t\\r\\n':
                end = i
                while end < len(text) and text[end] in ' \\t\\r\\n':
                    if text[end] == '\\r' and not text.startswith('\\r\\n', end):
                        raise ValueError("bare carriage return")
                    end += 1
                if '\\n' not in text[i:end]:
                    raise ValueError("invalid continuation")
                i = end
                continue
            if ch in escapes:
                out.append(escapes[ch])
                i += 1
                continue
            if ch in ('u', 'U'):
                end = i + (5 if ch == 'u' else 9)
                digits = text[i + 1:end]
                if len(digits) != end - i - 1 or any(c not in '0123456789abcdefABCDEF' for c in digits):
                    raise ValueError("unicode escape")
                value = int(digits, 16)
                if value > 0x10ffff or 0xd800 <= value <= 0xdfff:
                    raise ValueError("unicode scalar")
                out.append(chr(value))
                i = end
                continue
            raise ValueError("escape")
        if ch in '\\r\\n' and not triple:
            raise ValueError("newline in ordinary string")
        if ch == '\\r' and not text.startswith('\\r\\n', i):
            raise ValueError("bare carriage return")
        if (ord(ch) < 32 and ch not in '\\t\\r\\n') or ord(ch) == 127:
            raise ValueError("control character")
        out.append(ch)
        i += 1
    raise ValueError("unclosed string")

def _codex_toml_statements(text):
    # Source ranges include their newline. This is a lexer, not a TOML serializer.
    ranges, stack = [], []
    start = i = 0
    while i < len(text):
        ch = text[i]
        if ch in ('"', "'"):
            i, _ = _codex_toml_string(text, i, True)
            continue
        if ch == '#':
            end = text.find('\\n', i)
            i = len(text) if end < 0 else end
            continue
        if ch in '[{':
            stack.append(ch)
        elif ch in ']}':
            if not stack or stack.pop() != ('[' if ch == ']' else '{'):
                raise ValueError("mismatched delimiter")
        elif ch == '\\r' and not text.startswith('\\r\\n', i):
            raise ValueError("bare carriage return")
        elif (ord(ch) < 32 and ch not in '\\t\\r\\n') or ord(ch) == 127:
            raise ValueError("control character")
        if ch == '\\n' and not stack:
            ranges.append((start, i + 1))
            start = i + 1
        i += 1
    if stack:
        raise ValueError("unclosed delimiter")
    if start < len(text):
        ranges.append((start, len(text)))
    return ranges

def _codex_toml_key(text, i):
    path = []
    while True:
        i += len(text[i:]) - len(text[i:].lstrip(' \\t'))
        if i == len(text):
            raise ValueError("missing key")
        if text[i] in ('"', "'"):
            i, name = _codex_toml_string(text, i)
        else:
            start = i
            while i < len(text) and text[i] in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-':
                i += 1
            if i == start:
                raise ValueError("invalid key")
            name = text[start:i]
        path.append(name)
        key_end = i
        i += len(text[i:]) - len(text[i:].lstrip(' \\t'))
        if i == len(text) or text[i] != '.':
            return tuple(path), key_end, i
        i += 1

def _codex_toml_tail(text, i):
    tail = text[i:].lstrip(' \\t\\r\\n')
    return not tail or tail.startswith('#')

def _codex_is_features_header(text):
    i = len(text) - len(text.lstrip(' \\t'))
    if text.startswith('[[', i):
        return False
    key, _, pos = _codex_toml_key(text, i + 1)
    return key == ('features',) and text.startswith(']', pos)

def _codex_without_appended_features(content, ranges):
    # CodeIsland 1.0.35 and earlier appended [features] + hooks = true at EOF
    # whenever its line regex missed the flag or the header, even when root dotted
    # features.* keys or a spelling such as "[features] # note" already defined
    # that table: a duplicate key that stops Codex from starting (#354). Drop
    # exactly that trailing block and the blank line before it; else None.
    features_defined, last_header = False, None
    for index, (start, end) in enumerate(ranges):
        text = content[start:end]
        i = len(text) - len(text.lstrip(' \\t'))
        if i == len(text) or text[i] in '#\\r\\n':
            continue
        if text[i] == '[':
            # Every header but the final one may be the earlier definition.
            if last_header is not None and _codex_is_features_header(content[ranges[last_header][0]:ranges[last_header][1]]):
                features_defined = True
            last_header = index
        elif last_header is None:
            key = _codex_toml_key(text, i)[0]
            if len(key) > 1 and key[0] == 'features':
                features_defined = True
    if not features_defined or last_header is None:
        return None
    start, end = ranges[last_header]
    text = content[start:end]
    i = len(text) - len(text.lstrip(' \\t'))
    if not text.startswith('[features]', i) or text[i + 10:].strip(' \\t\\r\\n'):
        return None
    flags = 0
    for body_start, body_end in ranges[last_header + 1:]:
        text = content[body_start:body_end]
        if not text.strip(' \\t\\r\\n'):
            continue
        i = len(text) - len(text.lstrip(' \\t'))
        if text[i] == '#':
            return None
        key, _, pos = _codex_toml_key(text, i)
        if key != ('hooks',) or not text.startswith('=', pos):
            return None
        pos += 1
        pos += len(text[pos:]) - len(text[pos:].lstrip(' \\t'))
        if not any(text.startswith(v, pos) and not text[pos + len(v):].strip(' \\t\\r\\n') for v in ('true', 'false')):
            return None
        flags += 1
    if flags != 1:
        return None
    if last_header > 0:
        blank_start, blank_end = ranges[last_header - 1]
        if not content[blank_start:blank_end].strip(' \\t\\r\\n'):
            start = blank_start
    return content[:start]

def _codex_hooks_toml(content, heal=True):
    # Narrow source editor: root features.hooks only; opaque values stay verbatim.
    # tomllib, when available, validates both documents. Older Python still gets
    # lexical, key/scope and conflicting-layout guards, not a full TOML parser.
    try:
        import tomllib
    except ImportError:
        tomllib = None
    try:
        if heal:
            healed = _codex_without_appended_features(content, _codex_toml_statements(content))
            if healed is not None:
                return _codex_hooks_toml(healed, False)
        if tomllib is not None:
            tomllib.loads(content)
        scope = ()
        current = legacy = features_header = first_table = None
        root_dotted = False
        for start, end in _codex_toml_statements(content):
            text = content[start:end]
            i = len(text) - len(text.lstrip(' \\t'))
            if i == len(text) or text[i] in '#\\r\\n':
                continue
            if text[i] == '[':
                array = text.startswith('[[', i)
                scope, _, pos = _codex_toml_key(text, i + (2 if array else 1))
                closing = ']]' if array else ']'
                if not text.startswith(closing, pos) or not _codex_toml_tail(text, pos + len(closing)):
                    return None
                if scope[:2] == ('features', 'hooks') or (array and scope == ('features',)):
                    return None
                if first_table is None:
                    first_table = start
                if scope == ('features',):
                    if features_header is not None:
                        return None
                    features_header = end
                continue
            key_start = i
            key, key_end, pos = _codex_toml_key(text, i)
            if pos == len(text) or text[pos] != '=':
                return None
            pos += 1
            pos += len(text[pos:]) - len(text[pos:].lstrip(' \\t'))
            if pos == len(text) or text[pos] in '#\\r\\n':
                return None
            if not scope and len(key) > 1 and key[0] == 'features':
                root_dotted = True
            absolute = scope + key
            if absolute == ('features',) or (absolute[:2] == ('features', 'hooks') and len(absolute) > 2):
                return None
            if absolute not in (('features', 'hooks'), ('features', 'codex_hooks')):
                continue
            value = next((v for v in ('true', 'false') if text.startswith(v, pos) and _codex_toml_tail(text, pos + len(v))), None)
            if value is None:
                return None
            flag = (start, end, start + key_start, start + key_end, start + pos, start + pos + len(value), len(key))
            if absolute == ('features', 'hooks'):
                if current is not None:
                    return None
                current = flag
            else:
                if legacy is not None:
                    return None
                legacy = flag
        # Root dotted features.* keys already define the table; an explicit
        # [features] header too is a duplicate key Codex refuses to load.
        if features_header is not None and root_dotted:
            return None
        edits = []
        if current is not None:
            edits.append((current[4], current[5], 'true'))
            if legacy is not None:
                edits.append((legacy[0], legacy[1], ''))
        elif legacy is not None:
            name = 'hooks' if legacy[6] == 1 else 'features.hooks'
            edits.extend([(legacy[2], legacy[3], name), (legacy[4], legacy[5], 'true')])
        else:
            newline = '\\r\\n' if '\\r\\n' in content else '\\n'
            if features_header is not None:
                pos = features_header
                addition = ('' if content[:pos].endswith('\\n') else newline) + 'hooks = true' + newline
            elif first_table is not None:
                pos = first_table
                addition = 'features.hooks = true' + newline
            else:
                pos = len(content)
                addition = (newline if content and not content.endswith('\\n') else '') + 'features.hooks = true' + newline
            edits.append((pos, pos, addition))
        candidate = content
        for start, end, replacement in sorted(edits, reverse=True):
            candidate = candidate[:start] + replacement + candidate[end:]
        if tomllib is not None:
            features = tomllib.loads(candidate).get('features')
            if not isinstance(features, dict) or features.get('hooks') is not True:
                return None
        return candidate
    except (ValueError, TypeError):
        return None

def _write_codex_toml(path, content):
    import stat
    import tempfile
    # A unique sibling avoids collisions and pre-existing .tmp symlinks. Keep
    # private configs private, including when the config path itself is a link.
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

def ensure_toml_codex_hooks(path):
    try:
        # newline='' avoids read_text's universal-newline normalization.
        with path.open('r', encoding='utf-8', newline='') as stream:
            content = stream.read()
    except FileNotFoundError:
        content = ''
    except (OSError, UnicodeError):
        return False
    result = _codex_hooks_toml(content)
    if result is None:
        return False
    if result != content:
        try:
            _write_codex_toml(path, result)
        except (OSError, UnicodeError, RuntimeError):
            return False
    return True

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
    # PermissionRequest blocks on a human, so it receives the long timeout. The
    # other entries mirror Codex's complete public lifecycle surface, keeping
    # remote status fidelity identical to local sessions.
    blocking_entry = [{"hooks": [{"type": "command", "command": cmd, "timeout": 86400}]}]
    # Codex caps SessionEnd / Interrupt hooks at 3 s and warns about any
    # longer configured timeout, so match the local installer's 3 s there.
    teardown_entry = [{"hooks": [{"type": "command", "command": cmd, "timeout": 3}]}]
    for event in [
        "PreToolUse", "PostToolUse", "PreCompact", "PostCompact",
        "SessionStart", "SubagentStart", "SubagentStop",
        "UserPromptSubmit", "Stop",
    ]:
        append_our_hooks(hooks, event, entry)
    append_our_hooks(hooks, "PermissionRequest", blocking_entry)
    append_our_hooks(hooks, "SessionEnd", teardown_entry)
    append_our_hooks(hooks, "Interrupt", teardown_entry)
    data["hooks"] = hooks
    write_json(hooks_path, data)
    if not ensure_toml_codex_hooks(codex_root / "config.toml"):
        return "Codex config update failed"
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
    append_our_hooks(hooks, "UserPromptSubmit", without_matcher)
    append_our_hooks(hooks, "PermissionRequest", with_long_timeout)
    append_our_hooks(hooks, "Notification", with_matcher)
    append_our_hooks(hooks, "Stop", without_matcher)
    append_our_hooks(hooks, "SessionStart", without_matcher)
    append_our_hooks(hooks, "SessionEnd", without_matcher)
    append_our_hooks(hooks, "PreCompact", precompact)
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

def install_custom():
    results = []
    for cli in custom_clis:
        source = cli["source"]
        # config_path arrives home-relative (or absolute) — the Mac side already
        # stripped `~/` and its own home prefix so this resolves against the REMOTE
        # $HOME (#342).
        config_path = home / cli["config_path"]
        if not config_path.parent.exists() and shutil.which(source) is None:
            results.append(cli["name"] + " skipped (config dir not found: " + _display_path(config_path.parent) + ")")
            continue
        data = ensure_json(config_path)
        if not isinstance(data, dict):
            data = {}
        hooks = data.get(cli["config_key"])
        if not isinstance(hooks, dict):
            hooks = {}
        remove_our_hooks(hooks)
        cmd = command_for(source)
        for ev in cli["events"]:
            event = ev[0]
            timeout = ev[1]
            if cli["format"] == "claude":
                append_our_hooks(hooks, event, [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}])
            else:
                append_our_hooks(hooks, event, [{"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}])
        data[cli["config_key"]] = hooks
        write_json(config_path, data)
        results.append(cli["name"] + " ok")
    for name in unsupported_custom_clis:
        results.append(name + " skipped (template not supported remotely)")
    return results

parts = [install_claude(), install_qoder(), install_hermes(), install_codex(), install_codebuddy(), install_traecli(), install_opencode()] + install_custom()
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

    /// Only `.claude` / `.nested` custom CLIs can be installed remotely — their stdin
    /// carries `hook_event_name`, so the remote hook handles them with no `--event`
    /// flag. Other formats (flat/Cursor, traecli, copilot, kimi, …) are not (#192);
    /// they are listed in the status line as skipped instead of vanishing (#342).
    private static func isRemoteSupportedCustomFormat(_ format: HookFormat) -> Bool {
        format == .claude || format == .nested
    }

    /// A custom CLI's config path is typed on the Mac, where `~/x`, `x` and
    /// `<Mac home>/x` all mean "under my home". The remote script joins it onto the
    /// REMOTE `$HOME` with pathlib, which neither expands `~` (`~/x` became the
    /// literal `$HOME/~/x`) nor knows the Mac home (`/Users/me/x` does not exist on a
    /// Linux host) — so the config dir never existed and the CLI was always
    /// "skipped" (#342). Rewrite both to home-relative; any other absolute path is
    /// kept verbatim.
    static func remoteCustomConfigPath(_ configPath: String, localHome: String = NSHomeDirectory()) -> String {
        let path = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var relative: Substring
        if path.hasPrefix("~/") {
            relative = path.dropFirst(2)
        } else if !localHome.isEmpty, localHome != "/", path.hasPrefix(localHome + "/") {
            relative = path.dropFirst(localHome.count + 1)
        } else {
            return path
        }
        while relative.hasPrefix("/") { relative = relative.dropFirst() }
        return String(relative)
    }

    /// Serialize the remotely installable custom CLI configs into a Python list
    /// literal for the remote install script.
    private static func remoteCustomCLIsLiteral(_ clis: [CLIConfig]) -> String {
        let supported = clis.filter { isRemoteSupportedCustomFormat($0.format) }
        let entries = supported.map { cli -> String in
            let fmt = cli.format == .claude ? "claude" : "nested"
            let events = cli.events
                .map { "[\(pythonStringLiteral($0.0)), \($0.1)]" }
                .joined(separator: ", ")
            return "{"
                + "\"name\": \(pythonStringLiteral(cli.name)), "
                + "\"source\": \(pythonStringLiteral(cli.source)), "
                + "\"config_path\": \(pythonStringLiteral(remoteCustomConfigPath(cli.configPath))), "
                + "\"config_key\": \(pythonStringLiteral(cli.configKey)), "
                + "\"format\": \(pythonStringLiteral(fmt)), "
                + "\"events\": [\(events)]"
                + "}"
        }
        return "[\(entries.joined(separator: ", "))]"
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    static func remoteOpencodePluginForInstall(source: String, host: RemoteHost, remoteSocketPath: String? = nil) -> String {
        let socketPath = remoteSocketPath ?? host.remoteSocketPath
        return source
            .replacingOccurrences(
                of: #"const SOCKET_PATH = process.env.CODEISLAND_SOCKET_PATH || "/tmp/codeisland.sock";"#,
                with: #"const SOCKET_PATH = \#(jsonStringLiteral(socketPath));"#
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
