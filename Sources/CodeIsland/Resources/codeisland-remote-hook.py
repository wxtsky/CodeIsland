#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys

VERSION = "0.1.0"
SOCKET_PATH = os.environ.get("CODEISLAND_SOCKET_PATH", "/tmp/codeisland.sock")
REMOTE_HOST_ID = os.environ.get("CODEISLAND_REMOTE_HOST_ID", "")
REMOTE_HOST_NAME = os.environ.get("CODEISLAND_REMOTE_HOST_NAME", "")
SOURCE = os.environ.get("CODEISLAND_SOURCE", "")
TIMEOUT_SECONDS = 300


def _claude_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".claude", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codebuddy_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".codebuddy", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


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

                msg_type = payload.get("type")
                role = payload.get("role")
                content = payload.get("content")
                if not isinstance(content, str) or not content.strip():
                    continue

                if msg_type == "summary" and not summary:
                    summary = content
                if role == "user":
                    if not first_user:
                        first_user = content
                    last_user = content
                elif role == "assistant":
                    last_assistant = content
    except Exception:
        return {}

    return {
        "session_title": summary or first_user,
        "last_user_message": last_user,
        "last_assistant_message": last_assistant,
    }


def _scan_claude_jsonl(session_id, cwd):
    return _scan_session_jsonl(_claude_jsonl_path(session_id, cwd))


def _scan_codebuddy_jsonl(session_id, cwd):
    return _scan_session_jsonl(_codebuddy_jsonl_path(session_id, cwd))


def _read_stdin_json():
    try:
        return json.load(sys.stdin)
    except Exception:
        return None


def _send_event(payload, expects_response):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT_SECONDS)
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

    payload = dict(data)
    payload["hook_event_name"] = event_name
    payload["session_id"] = session_id
    payload["cwd"] = cwd
    payload["_source"] = payload.get("_source") or SOURCE
    payload["_remote_host_id"] = REMOTE_HOST_ID
    payload["_remote_host_name"] = REMOTE_HOST_NAME
    payload["_tty"] = payload.get("_tty") or _get_tty()

    if SOURCE == "claude":
        extras = _scan_claude_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if event_name == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    if SOURCE == "codebuddy":
        extras = _scan_codebuddy_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if event_name == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    expects_response = event_name == "PermissionRequest"
    response = _send_event(payload, expects_response)
    if response:
        print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
