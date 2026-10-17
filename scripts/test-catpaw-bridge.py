#!/usr/bin/env python3
"""Replay CatPaw hooks against a temporary socket; never starts or configures an agent.

Run after `swift build --product codeisland-bridge`:
    python3 scripts/test-catpaw-bridge.py
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

BRIDGE = Path(__file__).resolve().parent.parent / ".build/debug/codeisland-bridge"


class CatPawBridgeTests(unittest.TestCase):
    def replay(self, event, *, listening=True, source="catpaw", verify_ack_close=False, **extra):
        with tempfile.TemporaryDirectory(prefix="ci-catpaw-", dir="/tmp") as directory:
            root = Path(directory)
            received = []
            ack_closed = []
            server = socket.socket(socket.AF_UNIX)
            worker = None
            if listening:
                server.bind(str(root / "s"))
                server.listen(1)
                server.settimeout(1)

                def receive():
                    try:
                        conn, _ = server.accept()
                    except TimeoutError:
                        return
                    with conn:
                        conn.settimeout(3)
                        data = b""
                        while chunk := conn.recv(65536):
                            data += chunk
                        received.append(json.loads(data))
                        conn.sendall(b"{}")
                        if verify_ack_close:
                            conn.settimeout(0.5)
                            try:
                                ack_closed.append(conn.recv(1) == b"")
                            except TimeoutError:
                                ack_closed.append(False)

                worker = threading.Thread(target=receive)
                worker.start()
            raw = dict(hook_event_name=event, conversation_id="chat-1",
                       suggest_uuid="request-1", is_sub_agent=False,
                       workspace_roots=["/project"], mis="private-account")
            raw.update(extra)
            env = dict(os.environ, CODEISLAND_SOCKET_PATH=str(root / "s"),
                       CODEISLAND_BRIDGE_LOG=str(root / "general.log"))
            env.pop("CODEISLAND_SKIP", None)
            try:
                result = subprocess.run([str(BRIDGE), "--source", source, "--event", event],
                                        input=json.dumps(raw), text=True, capture_output=True,
                                        env=env, timeout=10)
                if worker:
                    worker.join(5)
                    self.assertFalse(worker.is_alive())
                if verify_ack_close:
                    self.assertEqual(ack_closed, [True], "Bridge must finish on ACK without waiting for server close")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {})
                general = (root / "general.log").read_text() if (root / "general.log").exists() else ""
                self.assertEqual(general, "", "CatPaw must not write bridge debug logs")
                return received
            finally:
                server.close()

    def test_shell_is_observation_not_permission(self):
        received = self.replay("beforeShellExecution", command="echo hello", cwd="/actual")
        self.assertEqual(len(received), 1)
        event = received[0]
        self.assertEqual(event["session_id"], "catpaw:chat-1")
        self.assertEqual(event["hook_event_name"], "beforeShellExecution")
        self.assertEqual(event["tool_name"], "Bash")
        self.assertEqual(event["tool_input"], {"command": "echo hello"})
        self.assertNotIn("tool_use_id", event)
        self.assertNotIn("mis", event)

    def test_idekit_keeps_its_own_identity_without_guessing_host(self):
        received = self.replay("beforeSubmitPrompt", source="catpaw-idekit", prompt="hello")
        self.assertEqual(received[0]["session_id"], "catpaw-idekit:chat-1")
        self.assertEqual(received[0]["_source"], "catpaw-idekit")
        # The test is not launched by IDEA; no arbitrary host may be selected.
        self.assertEqual(received[0]["_ppid"], 0)
        self.assertNotIn("_term_bundle", received[0])

    def test_idekit_stop_uses_guarded_lifecycle_event(self):
        received = self.replay("stop", source="catpaw-idekit", status="completed")
        self.assertEqual(received[0]["hook_event_name"], "CatPawStop")

    def test_mcp_keeps_tool_identity_without_parameters(self):
        received = self.replay("beforeMCPExecution", tool_name="lookup", tool_input='{"query":"hello"}')
        self.assertNotIn("tool_input", received[0])
        self.assertEqual(received[0]["tool_name"], "lookup")

    def test_response_is_metadata_only(self):
        received = self.replay("afterAgentResponse", text="hello")
        self.assertEqual(received[0]["hook_event_name"], "CatPawResponse")

    def test_stop_uses_guarded_lifecycle_event(self):
        received = self.replay("stop", status="completed", loop_count=0)
        self.assertEqual(received[0]["hook_event_name"], "CatPawStop")
        self.assertEqual(received[0]["status"], "completed")

    def test_ack_does_not_wait_for_server_to_close(self):
        self.replay("beforeSubmitPrompt", verify_ack_close=True)

    def test_main_short_previews_and_no_full_content(self):
        tail = "private-tail" * 10000
        received = self.replay("afterAgentResponse", text="0" * 30 + tail,
                                  prompt=tail, output=tail, attachments=[tail], future_content=tail)
        event = received[0]
        self.assertEqual(event["text"], "0" * 30 + "…")
        self.assertNotIn("private-tail", json.dumps(event))
        self.assertLess(len(json.dumps(event)), 2000)

    def test_subagent_strips_content_before_socket(self):
        received = self.replay("afterAgentResponse", is_sub_agent=True,
                                  text="private-reply", prompt="private-prompt", output="private-output")
        for key in ("text", "prompt", "output"):
            self.assertNotIn(key, received[0])
        self.assertEqual(received[0]["suggest_uuid"], "request-1")

    def test_subagent_forwards_with_its_own_identity(self):
        received = self.replay("beforeShellExecution", is_sub_agent=True, agent_name="child")
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0]["session_id"], "catpaw:chat-1")
        self.assertTrue(received[0]["is_sub_agent"])
        self.assertEqual(received[0]["agent_name"], "child")
        self.assertNotIn("agent_id", received[0])

    def test_unavailable_app_returns_neutral_result(self):
        received = self.replay("stop", listening=False, status="aborted")
        self.assertEqual(received, [])

    def test_unsupported_thought_is_not_forwarded(self):
        received = self.replay("afterAgentThought", text="private-thought")
        self.assertEqual(received, [])


if __name__ == "__main__":
    unittest.main()
