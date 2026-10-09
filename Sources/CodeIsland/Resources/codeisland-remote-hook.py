#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys

VERSION = "0.3.0"
# Per-user socket path (#193): CodeIsland injects CODEISLAND_SOCKET_PATH via the hook
# command, but fall back to a uid-scoped path so multiple users on a shared host never
# collide on a single /tmp/codeisland.sock.
SOCKET_PATH = os.environ.get("CODEISLAND_SOCKET_PATH") or f"/tmp/codeisland-{os.getuid()}.sock"
REMOTE_HOST_ID = os.environ.get("CODEISLAND_REMOTE_HOST_ID", "")
REMOTE_HOST_NAME = os.environ.get("CODEISLAND_REMOTE_HOST_NAME", "")
SOURCE = os.environ.get("CODEISLAND_SOURCE", "")
TIMEOUT_SECONDS = 300
# A blocking approval waits on a human, so it must not be capped at the
# fire-and-forget budget: the hook is registered with an 86400s timeout on the
# agent side, and a socket timeout of 5 minutes would silently drop the decision
# of anyone who stepped away (#306).
BLOCKING_TIMEOUT_SECONDS = 86400
TRANSCRIPT_TAIL_BYTES = 262144


def _normalize_event(name):
    """Best-effort normalization matching CodeIslandCore.EventNormalizer."""
    if not isinstance(name, str):
        return ""
    # Cursor (camelCase)
    if name == "beforeSubmitPrompt":
        return "UserPromptSubmit"
    if name == "beforeShellExecution":
        return "PreToolUse"
    if name == "afterShellExecution":
        return "PostToolUse"
    if name == "beforeReadFile":
        return "PreToolUse"
    if name == "afterFileEdit":
        return "PostToolUse"
    if name == "beforeMCPExecution":
        return "PreToolUse"
    if name == "afterMCPExecution":
        return "PostToolUse"
    if name == "afterAgentThought":
        return "Notification"
    if name == "afterAgentResponse":
        return "AfterAgentResponse"
    if name == "stop":
        return "Stop"
    # Gemini
    if name == "BeforeTool":
        return "PermissionRequest"
    if name == "AfterTool":
        return "PostToolUse"
    if name == "BeforeAgent":
        return "SubagentStart"
    if name == "AfterAgent":
        return "SubagentStop"
    # GitHub Copilot CLI
    if name == "sessionStart":
        return "SessionStart"
    if name == "sessionEnd":
        return "SessionEnd"
    if name == "userPromptSubmitted":
        return "UserPromptSubmit"
    if name == "preToolUse":
        return "PreToolUse"
    if name == "postToolUse":
        return "PostToolUse"
    if name == "errorOccurred":
        return "Notification"
    # TraeCli (snake_case)
    if name == "session_start":
        return "SessionStart"
    if name == "session_end":
        return "SessionEnd"
    if name == "user_prompt_submit":
        return "UserPromptSubmit"
    if name == "pre_tool_use":
        return "PreToolUse"
    if name == "post_tool_use":
        return "PostToolUse"
    if name == "post_tool_use_failure":
        return "PostToolUseFailure"
    if name == "permission_request":
        return "PermissionRequest"
    if name == "subagent_start":
        return "SubagentStart"
    if name == "subagent_stop":
        return "SubagentStop"
    if name == "pre_compact":
        return "PreCompact"
    if name == "post_compact":
        return "PostCompact"
    if name == "notification":
        return "Notification"
    # Hermes (Nous Research) — snake_case, diverged from Claude/Gemini (#226).
    # `subagent_stop` is already handled above.
    if name == "pre_tool_call":
        return "PreToolUse"
    if name == "post_tool_call":
        return "PostToolUse"
    if name == "pre_llm_call":
        return "UserPromptSubmit"
    if name == "post_llm_call":
        return "AgentTurnSettled"
    if name == "on_session_start":
        return "SessionStart"
    # Despite its name, Hermes fires on_session_end at the end of every turn.
    if name == "on_session_end":
        return "Stop"
    # The real end of a session (/new, quitting, gateway shutdown).
    if name == "on_session_finalize":
        return "SessionEnd"
    if name == "on_session_reset":
        return "SessionEnd"
    return name


def _claude_config_dir():
    """Claude Code's config dir: $CLAUDE_CONFIG_DIR when set, else ~/.claude (#271).

    The hook runs as a child of Claude Code, so the variable here is the one that
    Claude Code itself used — authoritative, with no fallback to ~/.claude when it
    is set. Same rules as _claude_config_dir() in the remote install script, and
    deliberately NO Unicode normalization: ext4/xfs are byte-preserving, so an
    NFC-normalized path can name a directory that does not exist.
    """
    raw = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip()
    if raw:
        expanded = os.path.expanduser(raw)
        if os.path.isabs(expanded) and expanded.strip("/") != "":
            return expanded
    return os.path.join(os.path.expanduser("~"), ".claude")


def _claude_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(_claude_config_dir(), "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codeisland_project_dir_encoded(cwd):
    return "".join("-" if ch == "/" or ch == " " or ord(ch) > 127 else ch for ch in cwd)


def _qoder_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = _codeisland_project_dir_encoded(cwd)
    path = os.path.join(home, ".qoder", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codebuddy_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".codebuddy", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _extract_text(content):
    """Mirror of the Mac-side JSONLTailer.extractText: a bare string (minus any
    <USER_REQUEST> wrapper), or every `text` block of a content array joined by
    newlines. tool_use / tool_result / thinking blocks carry no chat text."""
    if isinstance(content, str):
        text = content
        start = text.find("<USER_REQUEST>")
        if start != -1:
            end = text.find("</USER_REQUEST>", start + len("<USER_REQUEST>"))
            if end != -1:
                text = text[start + len("<USER_REQUEST>"):end]
        return text.strip() or None
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                text = block["text"].strip()
                if text:
                    parts.append(text)
        return "\n".join(parts) if parts else None
    return None


def _scan_session_jsonl(path):
    if not path:
        return {}

    summary = None
    first_user = None
    last_user = None
    last_assistant = None

    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except Exception:
                    continue
                # isMeta rows (local-command caveats etc.) are not chat — the Mac
                # side skips them too.
                if not isinstance(payload, dict) or payload.get("isMeta") is True:
                    continue

                # Current Claude Code (and Qoder) rows nest the chat message:
                # {"type":"assistant","message":{"role":"assistant","content":[...]}}.
                # The older top-level {"role":..,"content":".."} shape stays as the
                # fallback. Same resolution as the Mac-side Claude transcript reader.
                msg_type = payload.get("type")
                message = payload.get("message")
                nested = isinstance(message, dict)
                if not nested:
                    message = payload
                role = message.get("role") or msg_type
                role = role.lower() if isinstance(role, str) else None
                content = message.get("content")

                if not nested and isinstance(content, str) and content.strip():
                    # Legacy shape only, unchanged: its summary / first prompt
                    # titles the session. Nested Claude rows never do — the Mac
                    # titles Claude sessions from custom-title / ai-title records,
                    # never from the first prompt.
                    if msg_type == "summary" and not summary:
                        summary = content
                    if role == "user" and not first_user:
                        first_user = content

                if role == "user":
                    text = _extract_text(content)
                    if text:
                        last_user = text
                elif role == "assistant":
                    text = _extract_text(content)
                    if not text and isinstance(message.get("thinking"), str):
                        text = message["thinking"].strip() or None
                    if text:
                        last_assistant = text
    except Exception:
        return {}

    return {
        "session_title": summary or first_user,
        "last_user_message": last_user,
        "last_assistant_message": last_assistant,
    }


def _scan_claude_jsonl(session_id, cwd):
    return _scan_session_jsonl(_claude_jsonl_path(session_id, cwd))


def _scan_qoder_jsonl(session_id, cwd):
    return _scan_session_jsonl(_qoder_jsonl_path(session_id, cwd))


def _scan_codebuddy_jsonl(session_id, cwd):
    return _scan_session_jsonl(_codebuddy_jsonl_path(session_id, cwd))


def _codex_public_text(payload, allow_agent_message=False):
    """Return only Codex text that is intended for the user-facing transcript."""
    if not isinstance(payload, dict):
        return None

    item_type = payload.get("type")
    if allow_agent_message and item_type == "agent_message":
        message = payload.get("message")
        return message.strip() if isinstance(message, str) and message.strip() else None

    blocks = None
    accepted_types = set()
    if item_type == "message" and payload.get("role") == "assistant":
        blocks = payload.get("content")
        accepted_types = {"output_text"}
    if not isinstance(blocks, list):
        return None
    parts = []
    for block in blocks:
        if not isinstance(block, dict) or block.get("type") not in accepted_types:
            continue
        text = block.get("text")
        if isinstance(text, str) and text.strip():
            parts.append(text.strip())
    return "\n".join(parts) if parts else None


def _scan_codex_jsonl(path):
    """Read a bounded rollout tail and return the current turn's public output."""
    if not isinstance(path, str) or not path.strip():
        return {}
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        return {}

    event_user_indices = []
    fallback_user_indices = []
    public_messages = []
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - TRANSCRIPT_TAIL_BYTES)
            handle.seek(start)
            if start:
                handle.readline()  # discard a partial JSONL record
            lines = handle.read().decode("utf-8", errors="ignore").splitlines()

        for index, line in enumerate(lines):
            try:
                record = json.loads(line)
            except Exception:
                continue
            record_type = record.get("type")
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue

            payload_type = payload.get("type")
            if record_type == "event_msg" and payload_type == "user_message":
                event_user_indices.append(index)
            elif (record_type == "response_item" and payload_type == "message"
                  and payload.get("role") == "user"):
                fallback_user_indices.append(index)

            if record_type == "event_msg" and payload_type == "agent_message":
                text = _codex_public_text(payload, allow_agent_message=True)
            elif record_type == "response_item":
                text = _codex_public_text(payload)
            else:
                text = None
            if text:
                public_messages.append((index, text))
    except Exception:
        return {}

    if not public_messages:
        return {}
    last_user_index = max(event_user_indices + fallback_user_indices, default=-1)
    output_index, output = public_messages[-1]
    if output_index <= last_user_index:
        return {}
    return {"last_assistant_message": output[:4000]}


HERMES_STORE_MESSAGE_BYTES = 65536
HERMES_NON_TEXT_PARTS = ("image", "image_url", "input_image", "audio", "input_audio")
HERMES_CONTENT_JSON_PREFIX = "\x00json:"


def _hermes_home():
    # Hermes runs every hook with the firing profile's HERMES_HOME.
    raw = (os.environ.get("HERMES_HOME") or "").strip()
    if raw:
        return os.path.expanduser(os.path.expandvars(raw))
    return os.path.join(os.path.expanduser("~"), ".hermes")


def _hermes_visible_text(value):
    return value if isinstance(value, str) and value.strip() else None


def _hermes_text_part(part):
    if isinstance(part, str):
        return part
    if not isinstance(part, dict):
        return None
    if str(part.get("type") or "").strip().lower() in HERMES_NON_TEXT_PARTS:
        return None
    for key in ("text", "content", "input_text", "output_text", "summary_text"):
        if isinstance(part.get(key), str):
            return part[key]
    return None


def _hermes_stored_text(content):
    """Mirror of HermesSessionStore.text(fromStoredContent:): structured content
    is stored as a "\\x00json:" prefix + JSON, of which only text parts show."""
    if not content.startswith(HERMES_CONTENT_JSON_PREFIX):
        return _hermes_visible_text(content)
    try:
        value = json.loads(content[len(HERMES_CONTENT_JSON_PREFIX):])
    except Exception:
        return None
    if isinstance(value, list):
        texts = [text for text in (_hermes_text_part(part) for part in value) if text]
        value = "\n".join(texts) if texts else None
    elif not isinstance(value, str):
        value = _hermes_text_part(value)
    return _hermes_visible_text(value)


def _scan_hermes_store(session_id):
    """Mirror of HermesSessionStore.read on the Mac: the session title and the
    newest visible prompt / reply from $HERMES_HOME/state.db, which no hook
    carries in full. Hermes writes that database (WAL) while it runs, so it is
    opened read-only, waits on a lock only briefly, and an unexpected schema
    just yields nothing."""
    path = os.path.join(_hermes_home(), "state.db")
    if not session_id or not os.path.isfile(path):
        return None
    try:
        import sqlite3
        from urllib.parse import quote
        conn = sqlite3.connect("file:" + quote(path) + "?mode=ro", uri=True, timeout=0.15)
    except Exception:
        return None
    try:
        def columns(table):
            return {row[1] for row in conn.execute("PRAGMA table_info(%s)" % table)}

        store = {}
        if {"id", "title"} <= columns("sessions"):
            row = conn.execute("SELECT title FROM sessions WHERE id = ? LIMIT 1", (session_id,)).fetchone()
            title = _hermes_visible_text(row[0]) if row else None
            if title:
                store["title"] = title
        message_columns = columns("messages")
        if {"id", "session_id", "role", "content"} <= message_columns:
            filters = ""
            if "active" in message_columns:
                filters += " AND active = 1"
            if "display_kind" in message_columns:
                filters += " AND COALESCE(display_kind, '') NOT IN ('hidden', 'internal_notification')"
            if "_compressed_summary" in message_columns:
                filters += " AND _compressed_summary = 0"
            for role in ("user", "assistant"):
                row = conn.execute(
                    "SELECT id, substr(CAST(content AS BLOB), 1, ?) FROM messages"
                    " WHERE session_id = ? AND role = ? AND content IS NOT NULL AND content <> ''"
                    + filters + " ORDER BY id DESC LIMIT 1",
                    (HERMES_STORE_MESSAGE_BYTES, session_id, role),
                ).fetchone()
                if not row:
                    continue
                raw = row[1]
                content = raw.decode("utf-8", "ignore") if isinstance(raw, bytes) else raw
                text = _hermes_stored_text(content) if isinstance(content, str) else None
                if text:
                    store[role] = {"id": row[0], "text": text}
        return store or None
    except Exception:
        return None
    finally:
        conn.close()


def _read_stdin_json():
    try:
        return json.load(sys.stdin)
    except Exception:
        return None


def _send_event(payload, expects_response):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(BLOCKING_TIMEOUT_SECONDS if expects_response else TIMEOUT_SECONDS)
    try:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        if expects_response:
            response = sock.recv(65536)
            return response.decode("utf-8") if response else None
        return None
    except (OSError, socket.error):
        # Socket may not exist or server may have shut down — fail silently (#45)
        return None
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _get_tty():
    pid = os.getppid()
    for _ in range(20):
        if pid <= 1:
            break
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "tty=,ppid="],
                capture_output=True,
                text=True,
                timeout=2,
            )
            parts = result.stdout.strip().split()
            if not parts:
                break
            tty = parts[0]
            if tty and tty not in {"??", "-"}:
                return tty if tty.startswith("/dev/") else f"/dev/{tty}"
            if len(parts) >= 2:
                pid = int(parts[1])
            else:
                break
        except Exception:
            break
    return None


def main():
    if "--version" in sys.argv:
        print(VERSION)
        return 0

    data = _read_stdin_json()
    if not data:
        return 1

    event_name = data.get("hook_event_name") or data.get("event")
    session_id = data.get("session_id")
    cwd = data.get("cwd") or os.getcwd()
    if not event_name or not session_id:
        return 1

    normalized_event = _normalize_event(event_name)

    payload = dict(data)
    payload["hook_event_name"] = event_name
    payload["session_id"] = session_id
    payload["cwd"] = cwd
    payload["_source"] = payload.get("_source") or SOURCE
    payload["_remote_host_id"] = payload.get("_remote_host_id") or REMOTE_HOST_ID
    payload["_remote_host_name"] = payload.get("_remote_host_name") or REMOTE_HOST_NAME
    payload["_tty"] = payload.get("_tty") or _get_tty()

    if SOURCE == "claude":
        extras = _scan_claude_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    if SOURCE == "qoder":
        extras = _scan_qoder_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    if SOURCE == "codebuddy":
        extras = _scan_codebuddy_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    if SOURCE == "codex" and normalized_event not in {"SessionStart", "UserPromptSubmit"}:
        extras = _scan_codex_jsonl(payload.get("transcript_path"))
        if extras.get("last_assistant_message") and not payload.get("last_assistant_message"):
            payload["last_assistant_message"] = extras["last_assistant_message"]

    if SOURCE == "hermes":
        # The whole conversation rides along on every pre/post_llm_call; the
        # Mac never reads it, so it doesn't cross the SSH link.
        extra = payload.get("extra")
        if isinstance(extra, dict) and "conversation_history" in extra:
            payload["extra"] = {k: v for k, v in extra.items() if k != "conversation_history"}
        store = _scan_hermes_store(session_id)
        if store:
            payload["_hermes_store"] = store

    # Blocking events: permission prompts + question prompts
    expects_response = normalized_event == "PermissionRequest" or (
        normalized_event == "Notification" and payload.get("question")
    )
    response = _send_event(payload, expects_response)
    if response:
        if SOURCE == "google-antigravity" or SOURCE == "gemini":
            try:
                res_obj = json.loads(response)
                behavior = res_obj.get("hookSpecificOutput", {}).get("decision", {}).get("behavior")
                if behavior in ("allow", "always"):
                    print(json.dumps({"decision": "allow"}))
                else:
                    print(json.dumps({"decision": "deny"}))
            except Exception:
                if '"behavior":"allow"' in response or '"behavior":"always"' in response:
                    print(json.dumps({"decision": "allow"}))
                elif '"behavior":"deny"' in response:
                    print(json.dumps({"decision": "deny"}))
                else:
                    print(response)
        else:
            print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
