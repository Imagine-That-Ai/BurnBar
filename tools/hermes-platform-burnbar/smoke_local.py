#!/usr/bin/env python3
"""Local BurnBar/Hermes platform smoke harness.

Usage (paths shown relative to the Hermes repo, where this ships as
plugins/platforms/burnbar/smoke_local.py):
  python plugins/platforms/burnbar/smoke_local.py smoke --hermes-repo .
  python plugins/platforms/burnbar/smoke_local.py serve --port 8765

The smoke command copies this plugin into a local Hermes checkout and exercises
the real Hermes adapter, registry, send_message routing, HTTP client, event
polling, message send, typing, attachment init, signed upload, and standalone
cron-style delivery against an in-process fake BurnBar Gateway API.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib
import os
import json
import re
import shutil
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


TEST_TOKEN = "test-token"
DEFAULT_HOME = "dest-home"


class FakeBurnBarState:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []
        self.messages: list[dict[str, Any]] = []
        self.typing: list[dict[str, Any]] = []
        self.attachment_inits: list[dict[str, Any]] = []
        self.attachment_finalizes: list[dict[str, Any]] = []
        self.runtime: list[dict[str, Any]] = []
        self.uploads: dict[str, bytes] = {}
        self.uploaded_attachment_ids: set[str] = set()
        self.next_sequence = 1

    def enqueue(
        self,
        text: str,
        destination_id: str = DEFAULT_HOME,
        sender_id: str = "sender_1",
        *,
        kind: str = "message",
        model_id: str | None = None,
    ) -> dict[str, Any]:
        event = {
            "id": f"evt_{self.next_sequence}",
            "sequence": self.next_sequence,
            "kind": kind,
            "destinationId": destination_id,
            "senderId": sender_id,
            "senderDisplayName": "Local Tester",
            "threadId": "thread_1",
            "text": text,
        }
        if model_id:
            event["modelId"] = model_id
        self.next_sequence += 1
        self.events.append(event)
        return event

    def reset(self) -> None:
        self.__init__()


def make_handler(state: FakeBurnBarState):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _read_json(self) -> dict[str, Any]:
            size = int(self.headers.get("Content-Length", "0") or 0)
            if not size:
                return {}
            return json.loads(self.rfile.read(size).decode("utf-8"))

        def _json(self, status: int, payload: dict[str, Any]) -> None:
            data = json.dumps(payload, indent=2).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _authorized(self) -> bool:
            return self.headers.get("Authorization") == f"Bearer {TEST_TOKEN}"

        def do_GET(self) -> None:
            if self.path == "/__test/messages":
                self._json(200, {"messages": state.messages})
                return
            if self.path == "/__test/state":
                self._json(
                    200,
                    {
                        "events": state.events,
                        "messages": state.messages,
                        "typing": state.typing,
                        "attachmentInits": state.attachment_inits,
                        "runtime": state.runtime,
                        "uploads": {key: len(value) for key, value in state.uploads.items()},
                    },
                )
                return
            if not self._authorized():
                self._json(401, {"error": "bad_auth"})
                return
            if self.path.startswith("/v1/hermes-gateway/destinations"):
                self._json(200, {"destinations": [{"id": DEFAULT_HOME, "name": "Local BurnBar Home"}]})
                return
            if self.path.startswith("/v1/hermes-gateway/events"):
                cursor = 0
                if "cursor=" in self.path:
                    try:
                        cursor = int(self.path.split("cursor=", 1)[1].split("&", 1)[0])
                    except ValueError:
                        cursor = 0
                events = [event for event in state.events if int(event["sequence"]) > cursor]
                next_cursor = max([cursor, *[int(event["sequence"]) for event in events]])
                self._json(200, {"events": events[:50], "nextCursor": next_cursor})
                return
            self._json(404, {"error": "not_found"})

        def do_POST(self) -> None:
            if self.path == "/__test/enqueue":
                body = self._read_json()
                text = str(body.get("text") or "hello from fake BurnBar")
                event = state.enqueue(
                    text=text,
                    kind=str(body.get("kind") or "message"),
                    model_id=body.get("modelId"),
                )
                self._json(200, {"event": event})
                return
            if self.path == "/__test/reset":
                state.reset()
                self._json(200, {"ok": True})
                return
            if not self._authorized():
                self._json(401, {"error": "bad_auth"})
                return
            body = self._read_json()
            if self.path == "/v1/hermes-gateway/messages":
                missing = [
                    attachment_id
                    for attachment_id in body.get("attachmentIds", [])
                    if attachment_id not in state.uploaded_attachment_ids
                ]
                if missing:
                    self._json(400, {"error": "attachment_not_uploaded", "missing": missing})
                    return
                state.messages.append(body)
                self._json(200, {"message": {"id": f"msg_{len(state.messages)}", **body}})
                return
            if self.path == "/v1/hermes-gateway/typing":
                state.typing.append(body)
                self._json(200, {"success": True})
                return
            if self.path == "/v1/hermes-gateway/runtime":
                state.runtime.append(body)
                self._json(200, {"success": True})
                return
            if self.path == "/v1/hermes-gateway/attachments/init":
                attachment_id = f"att_{len(state.attachment_inits) + 1}"
                state.attachment_inits.append(body)
                self._json(
                    200,
                    {
                        "attachment": {"id": attachment_id, **body},
                        "uploadURL": f"http://127.0.0.1:{self.server.server_port}/upload/{attachment_id}",
                        "maxBytes": 25 * 1024 * 1024,
                    },
                )
                return
            if self.path == "/v1/hermes-gateway/attachments/finalize":
                attachment_id = body.get("attachmentId")
                if not attachment_id or f"/upload/{attachment_id}" not in state.uploads:
                    self._json(404, {"error": "attachment_object_missing"})
                    return
                expected = hashlib.sha256(state.uploads[f"/upload/{attachment_id}"]).hexdigest()
                if body.get("sha256") != expected:
                    self._json(409, {"error": "attachment_hash_mismatch"})
                    return
                state.attachment_finalizes.append(body)
                state.uploaded_attachment_ids.add(str(attachment_id))
                self._json(200, {"attachment": {"id": attachment_id, "status": "uploaded", "sha256": expected}})
                return
            self._json(404, {"error": "not_found"})

        def do_PUT(self) -> None:
            size = int(self.headers.get("Content-Length", "0") or 0)
            state.uploads[self.path] = self.rfile.read(size)
            self._json(200, {"ok": True})

        def log_message(self, fmt: str, *args: Any) -> None:
            return

    return Handler


def start_fake_server(port: int = 0) -> tuple[ThreadingHTTPServer, threading.Thread, FakeBurnBarState]:
    state = FakeBurnBarState()
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, state


def install_plugin(hermes_repo: Path) -> None:
    source_dir = Path(__file__).resolve().parent
    target_dir = hermes_repo / "plugins" / "platforms" / "burnbar"
    target_dir.mkdir(parents=True, exist_ok=True)
    for name in ("adapter.py", "__init__.py", "plugin.yaml", "README.md", "smoke_local.py"):
        shutil.copy2(source_dir / name, target_dir / name)


def load_hermes_plugin(hermes_repo: Path):
    install_plugin(hermes_repo)
    if str(hermes_repo) not in sys.path:
        sys.path.insert(0, str(hermes_repo))
    module = importlib.import_module("plugins.platforms.burnbar.adapter")

    class Context:
        def register_platform(self, **kwargs: Any) -> None:
            from gateway.platform_registry import PlatformEntry, platform_registry

            platform_registry.register(PlatformEntry(source="plugin", **kwargs))

    module.register(Context())
    return module


async def run_smoke(hermes_repo: Path) -> dict[str, Any]:
    # Test isolation: the legacy-path smoke must not read or write the developer's
    # REAL BurnBar pairing. ~/.hermes/.env carries BURNBAR_RELAY_E2E=1 + a pinned
    # peer key, so without this the routed standalone-send path correctly SEALS the
    # attachment (right behavior, but it breaks the legacy plaintext assertions and
    # makes the run depend on machine state). Sandbox the relay env vars for the run
    # and stub the env writer so the harness is hermetic.
    _relay_env_keys = (
        "BURNBAR_RELAY_E2E",
        "BURNBAR_RELAY_PEER_PUBLIC_KEY",
        "BURNBAR_RELAY_PRIVATE_KEY",
        "BURNBAR_RELAY_UID",
        "BURNBAR_RELAY_CLIENT_ID",
    )
    # A lazy ~/.hermes/.env reload (python-dotenv with override=True) runs later in
    # the shared-core import path and re-applies the developer's REAL pairing over
    # anything we set in os.environ. So point HOME at an empty temp dir for the run:
    # the override then reads a non-existent .env and the legacy path stays legacy.
    _home_sandbox = tempfile.TemporaryDirectory()
    _saved_home = os.environ.get("HOME")
    os.environ["HOME"] = _home_sandbox.name
    _saved_relay_env = {k: os.environ.get(k) for k in _relay_env_keys}
    for _k in _relay_env_keys:
        os.environ.pop(_k, None)
    if str(hermes_repo) not in sys.path:
        sys.path.insert(0, str(hermes_repo))
    try:
        import hermes_cli.config as _hcfg

        _orig_save_env = getattr(_hcfg, "save_env_value", None)
        _hcfg.save_env_value = lambda *a, **k: None  # never touch the real ~/.hermes/.env
    except Exception:
        _orig_save_env = None

    server = None
    thread = None
    cursor_dir = None

    try:
        module = load_hermes_plugin(hermes_repo)
        from gateway.config import Platform, PlatformConfig
        from tools.send_message_tool import _send_to_platform

        # MP-1: two-key (agent + phone) >=128-bit safety code; MP-22: "" on bad input.
        agent_key = module.relay_e2ee.generate_private_key().public_key_base64()
        phone_key = module.relay_e2ee.generate_private_key().public_key_base64()
        other_key = module.relay_e2ee.generate_private_key().public_key_base64()
        safety_code = module._relay_safety_code(agent_key, phone_key)
        assert re.fullmatch(r"(?:[0-9A-F]{4} ){7}[0-9A-F]{4}", safety_code)
        assert module._relay_safety_code(phone_key, agent_key) == safety_code
        assert module._relay_safety_code(agent_key, other_key) != safety_code
        assert module._relay_safety_code(other_key, phone_key) != safety_code
        assert module._relay_safety_code("not-base64", phone_key) == ""
        assert module._relay_safety_code(agent_key, "AQIDBAUGBwg=") == ""

        server, thread, state = start_fake_server()
        base_url = f"http://127.0.0.1:{server.server_port}/v1/hermes-gateway"
        state.enqueue("hello hermes")
        state.enqueue("/model minimax-m2.7-highspeed", kind="model_switch", model_id="minimax-m2.7-highspeed")
        cursor_dir = tempfile.TemporaryDirectory()
        module.CURSOR_FILE = Path(cursor_dir.name) / "burnbar_cursor.json"

        config = PlatformConfig(
            enabled=True,
            extra={
                "api_base_url": base_url,
                "access_token": TEST_TOKEN,
                "home_channel": DEFAULT_HOME,
            },
        )
        adapter = module.BurnBarAdapter(config)
        received = []

        async def capture(event):
            received.append(event)

        adapter.handle_message = capture
        connected = await adapter.connect()
        assert connected is True
        await asyncio.sleep(1.2)
        assert received and received[0].text == "hello hermes", [
            {"text": getattr(event, "text", None), "chat_id": getattr(event.source, "chat_id", None)}
            for event in received
        ]
        assert received[0].source.chat_id == DEFAULT_HOME
        assert any(event.text == "/model minimax-m2.7-highspeed" for event in received)

        sent = await adapter.send(DEFAULT_HOME, "adapter reply", metadata={"thread_id": "thread_1"})
        assert sent.success and sent.message_id == "msg_1"
        await adapter.send_typing(DEFAULT_HOME, metadata={"thread_id": "thread_1"})

        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "artifact.txt"
            artifact.write_text("artifact body", encoding="utf-8")

            doc = await adapter.send_document(DEFAULT_HOME, str(artifact), caption="adapter file")
            assert doc.success and doc.message_id == "msg_2"

            standalone = await module._standalone_send(
                config,
                None,
                "standalone file",
                thread_id="thread_2",
                media_files=[(str(artifact), False)],
            )
            assert standalone["success"] is True
            assert standalone["message_id"] == "msg_3"

            routed = await _send_to_platform(
                Platform("burnbar"),
                config,
                DEFAULT_HOME,
                "",
                media_files=[(str(artifact), False)],
            )
            assert routed["success"] is True
            assert routed["message_id"] == "msg_4"

        await adapter.disconnect()

        assert len(state.messages) == 4, state.messages
        assert state.messages[1]["attachmentIds"] == ["att_1"]
        assert state.messages[2]["attachmentIds"] == ["att_2"]
        assert state.messages[3]["attachmentIds"] == ["att_3"]
        assert state.uploads["/upload/att_1"] == b"artifact body"
        assert state.uploads["/upload/att_2"] == b"artifact body"
        assert state.uploads["/upload/att_3"] == b"artifact body"
        assert [item["attachmentId"] for item in state.attachment_finalizes] == ["att_1", "att_2", "att_3"]
        for item in state.attachment_finalizes:
            assert item["sha256"] == hashlib.sha256(state.uploads[f"/upload/{item['attachmentId']}"]).hexdigest()
        assert state.typing == [{"destinationId": DEFAULT_HOME, "threadId": "thread_1"}]
        assert state.runtime, "adapter did not publish runtime model status"

        return {
            "ok": True,
            "fakeGateway": base_url,
            "eventsReceived": len(received),
            "messagesSent": len(state.messages),
            "attachmentUploads": len(state.uploads),
            "attachmentFinalizes": len(state.attachment_finalizes),
            "typingEvents": len(state.typing),
        }
    finally:
        if server is not None:
            server.shutdown()
        if thread is not None:
            thread.join(timeout=2)
        if cursor_dir is not None:
            cursor_dir.cleanup()
        # Restore the sandboxed HOME + relay env + the real env writer.
        if _saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = _saved_home
        _home_sandbox.cleanup()
        for _k, _v in _saved_relay_env.items():
            if _v is None:
                os.environ.pop(_k, None)
            else:
                os.environ[_k] = _v
        try:
            if _orig_save_env is not None:
                import hermes_cli.config as _hcfg2

                _hcfg2.save_env_value = _orig_save_env
        except Exception:
            pass


def cmd_smoke(args: argparse.Namespace) -> None:
    hermes_repo = Path(args.hermes_repo).expanduser().resolve()
    if not (hermes_repo / "gateway" / "config.py").is_file():
        raise SystemExit(f"Not a Hermes repo: {hermes_repo}")
    result = asyncio.run(run_smoke(hermes_repo))
    print(json.dumps(result, indent=2))


def cmd_serve(args: argparse.Namespace) -> None:
    server, thread, _state = start_fake_server(args.port)
    base_url = f"http://127.0.0.1:{server.server_port}/v1/hermes-gateway"
    print("Fake BurnBar Gateway running")
    print(f"  BURNBAR_API_BASE_URL={base_url}")
    print(f"  BURNBAR_ACCESS_TOKEN={TEST_TOKEN}")
    print(f"  BURNBAR_HOME_CHANNEL={DEFAULT_HOME}")
    print()
    print("Inject a fake inbound BurnBar message:")
    print(
        f"  curl -s -X POST http://127.0.0.1:{server.server_port}/__test/enqueue "
        "-H 'Content-Type: application/json' -d '{\"text\":\"say PONG\"}'"
    )
    print()
    print("Read Hermes replies:")
    print(f"  curl -s http://127.0.0.1:{server.server_port}/__test/messages | python3 -m json.tool")
    print()
    try:
        thread.join()
    except KeyboardInterrupt:
        server.shutdown()
        thread.join(timeout=2)


def main() -> None:
    parser = argparse.ArgumentParser(description="BurnBar Hermes local smoke harness")
    sub = parser.add_subparsers(dest="command", required=True)

    smoke = sub.add_parser("smoke", help="Run deterministic adapter/tool smoke test")
    smoke.add_argument("--hermes-repo", required=True, help="Path to a local Hermes Agent checkout")
    smoke.set_defaults(func=cmd_smoke)

    serve = sub.add_parser("serve", help="Run fake BurnBar Gateway API for manual Hermes testing")
    serve.add_argument("--port", type=int, default=8765)
    serve.set_defaults(func=cmd_serve)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
