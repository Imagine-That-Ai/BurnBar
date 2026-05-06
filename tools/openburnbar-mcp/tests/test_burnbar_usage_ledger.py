#!/usr/bin/env python3
"""
Stdlib-only tests for `burnbar_usage_ledger` and `hermes_proxy`.

Run from the repo root with:
    python3 -m unittest tools.openburnbar-mcp.tests.test_burnbar_usage_ledger

Or directly:
    python3 tools/openburnbar-mcp/tests/test_burnbar_usage_ledger.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import sys
import threading
import time
import unittest
from typing import Any  # noqa: F401  — re-imported for clarity at top level
from datetime import datetime, timezone
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))


def _load_module(name: str, filename: str):
    """Load a sibling module by file path, dodging the hyphenated package
    directory (`openburnbar-mcp/`) which is not a valid Python identifier."""
    spec = importlib.util.spec_from_file_location(name, str(_PARENT / filename))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    # Register before exec so `@dataclass` (which inspects `cls.__module__`)
    # can resolve typing-related references via `sys.modules`.
    sys.modules[name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


ledger_mod = _load_module("burnbar_usage_ledger_under_test", "burnbar_usage_ledger.py")
proxy_mod = _load_module("hermes_proxy_under_test", "hermes_proxy.py")


class UsageLedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.ledger_path = Path(self._tmp.name) / "usage-events.jsonl"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _event(self, **overrides) -> "ledger_mod.UsageEvent":
        kwargs = dict(
            provider_id="hermes",
            model_id="minimax-m2.7-highspeed",
            input_tokens=300,
            output_tokens=110,
            cost=0.012,
            recorded_at=datetime(2025, 6, 1, 12, 0, tzinfo=timezone.utc),
            session_id="session-1",
            project_name="Hermes (proxy)",
            confidence="exact",
        )
        kwargs.update(overrides)
        return ledger_mod.UsageEvent(**kwargs)

    def test_append_writes_record(self) -> None:
        result = ledger_mod.append_usage_record(
            event=self._event(),
            idempotency_key="key-1",
            ledger_path=self.ledger_path,
            prefer_daemon=False,
        )
        self.assertTrue(result["inserted"])
        self.assertEqual(result["idempotencyKey"], "key-1")
        self.assertEqual(result["event"]["providerID"], "hermes")
        self.assertEqual(result["event"]["confidence"], "exact")
        self.assertTrue(self.ledger_path.is_file())

        contents = self.ledger_path.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(contents), 1)
        loaded = json.loads(contents[0])
        self.assertEqual(loaded["idempotencyKey"], "key-1")
        self.assertEqual(loaded["event"]["sessionID"], "session-1")
        self.assertEqual(loaded["event"]["projectName"], "Hermes (proxy)")
        # `recordedAt` must be Apple reference-date seconds (Swift's default
        # JSONDecoder rejects ISO strings as `Double` mismatches), and must
        # match `unix_seconds - 978_307_200` for 2025-06-01T12:00:00Z.
        self.assertIsInstance(loaded["event"]["recordedAt"], (int, float))
        unix_seconds = datetime(2025, 6, 1, 12, 0, tzinfo=timezone.utc).timestamp()
        self.assertAlmostEqual(
            loaded["event"]["recordedAt"],
            unix_seconds - ledger_mod.APPLE_REFERENCE_DATE_OFFSET,
            places=3,
        )

    def test_append_is_idempotent(self) -> None:
        first = ledger_mod.append_usage_record(
            event=self._event(),
            idempotency_key="key-1",
            ledger_path=self.ledger_path,
            prefer_daemon=False,
        )
        second = ledger_mod.append_usage_record(
            event=self._event(input_tokens=999),  # different payload, same key
            idempotency_key="key-1",
            ledger_path=self.ledger_path,
            prefer_daemon=False,
        )
        self.assertTrue(first["inserted"])
        self.assertFalse(second["inserted"])

        lines = self.ledger_path.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0])["event"]["inputTokens"], 300)

    def test_rejects_unknown_provider(self) -> None:
        with self.assertRaises(ValueError):
            ledger_mod.append_usage_record(
                event=self._event(provider_id="not-a-provider"),
                idempotency_key="key-bad-provider",
                ledger_path=self.ledger_path,
                prefer_daemon=False,
            )

    def test_rejects_unknown_confidence(self) -> None:
        with self.assertRaises(ValueError):
            ledger_mod.append_usage_record(
                event=self._event(confidence="totally_fine"),
                idempotency_key="key-bad-confidence",
                ledger_path=self.ledger_path,
                prefer_daemon=False,
            )

    def test_rejects_negative_tokens(self) -> None:
        with self.assertRaises(ValueError):
            ledger_mod.append_usage_record(
                event=self._event(input_tokens=-1),
                idempotency_key="key-neg",
                ledger_path=self.ledger_path,
                prefer_daemon=False,
            )

    def test_derive_idempotency_key_is_stable(self) -> None:
        when = datetime(2025, 6, 1, 12, 0, tzinfo=timezone.utc)
        key1 = ledger_mod.derive_idempotency_key(
            provider_id="hermes",
            model_id="minimax-m2.7-highspeed",
            session_id="abc",
            recorded_at=when,
        )
        key2 = ledger_mod.derive_idempotency_key(
            provider_id="hermes",
            model_id="minimax-m2.7-highspeed",
            session_id="abc",
            recorded_at=when,
        )
        self.assertEqual(key1, key2)
        self.assertTrue(key1.startswith("hermes-"))

    def test_default_path_honours_env_override(self) -> None:
        custom = self.ledger_path.with_name("custom-ledger.jsonl")
        try:
            os.environ["OPENBURNBAR_USAGE_LEDGER_PATH"] = str(custom)
            self.assertEqual(ledger_mod.default_ledger_path(), custom.resolve())
        finally:
            os.environ.pop("OPENBURNBAR_USAGE_LEDGER_PATH", None)


class DaemonSocketRoutingTests(unittest.TestCase):
    """When the daemon socket is available, the writer must prefer it over a
    direct ledger append so the daemon's in-memory key cache stays consistent.
    """

    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.ledger_path = Path(self._tmp.name) / "usage-events.jsonl"
        self.socket_path = Path(self._tmp.name) / "openburnbar-daemon.sock"
        self._server_thread, self._stop_event, self.captured = self._start_fake_daemon(
            self.socket_path
        )
        # Point the writer at our fake socket without leaning on the user's
        # real `~/Library/Application Support/OpenBurnBar` directory.
        os.environ["OPENBURNBAR_DAEMON_SOCKET_PATH"] = str(self.socket_path)
        os.environ["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"] = "test-token"

    def tearDown(self) -> None:
        self._stop_event.set()
        try:
            # Unblock any pending accept() by connecting once.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as poke:
                poke.settimeout(0.5)
                try:
                    poke.connect(str(self.socket_path))
                except OSError:
                    pass
        except Exception:
            pass
        self._server_thread.join(timeout=2)
        os.environ.pop("OPENBURNBAR_DAEMON_SOCKET_PATH", None)
        os.environ.pop("OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN", None)
        self._tmp.cleanup()

    @staticmethod
    def _start_fake_daemon(path: Path):
        captured: dict[str, Any] = {}
        stop_event = threading.Event()

        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if path.exists():
            path.unlink()
        srv.bind(str(path))
        srv.listen(4)
        srv.settimeout(0.5)

        def serve() -> None:
            try:
                while not stop_event.is_set():
                    try:
                        client, _ = srv.accept()
                    except socket.timeout:
                        continue
                    except OSError:
                        return
                    with client:
                        client.settimeout(2.0)
                        buf = b""
                        try:
                            while not buf.endswith(b"\n"):
                                chunk = client.recv(4096)
                                if not chunk:
                                    break
                                buf += chunk
                        except OSError:
                            continue
                        if not buf:
                            continue
                        try:
                            request = json.loads(buf.decode("utf-8").rstrip("\n"))
                        except (UnicodeDecodeError, json.JSONDecodeError):
                            continue
                        captured["last_request"] = request
                        params = request.get("params") or {}
                        envelope = {
                            "id": request.get("id"),
                            "protocolVersion": 1,
                            "result": {
                                "idempotencyKey": params.get("idempotencyKey"),
                                "inserted": True,
                                "event": params.get("event"),
                            },
                        }
                        client.sendall((json.dumps(envelope) + "\n").encode("utf-8"))
            finally:
                srv.close()
                if path.exists():
                    try:
                        path.unlink()
                    except OSError:
                        pass

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        return thread, stop_event, captured

    def test_writer_uses_daemon_socket_when_available(self) -> None:
        result = ledger_mod.append_usage_record(
            event=ledger_mod.UsageEvent(
                provider_id="hermes",
                model_id="minimax-m2.7-highspeed",
                input_tokens=10,
                output_tokens=5,
                cost=0.001,
            ),
            idempotency_key="daemon-key-1",
            ledger_path=self.ledger_path,
            prefer_daemon=True,
        )
        self.assertEqual(result["via"], "daemon")
        self.assertTrue(result["inserted"])
        self.assertEqual(result["idempotencyKey"], "daemon-key-1")
        self.assertEqual(Path(result["socketPath"]).resolve(), self.socket_path.resolve())
        # Critical: nothing was written to the local ledger file when the
        # daemon path was used; the daemon owns the append.
        self.assertFalse(self.ledger_path.is_file())

        last_request = self.captured.get("last_request") or {}
        self.assertEqual(last_request.get("method"), "daemon.usage.record")
        self.assertEqual(last_request.get("authToken"), "test-token")
        params = last_request.get("params") or {}
        self.assertEqual(params.get("idempotencyKey"), "daemon-key-1")
        self.assertEqual(params.get("event", {}).get("providerID"), "hermes")


class HermesProxyTests(unittest.TestCase):
    """End-to-end tests that spin up a fake upstream Hermes and verify the proxy
    forwards traffic and writes a ledger row."""

    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.ledger_path = Path(self._tmp.name) / "usage-events.jsonl"
        os.environ["OPENBURNBAR_USAGE_LEDGER_PATH"] = str(self.ledger_path)
        # Force the writer onto its file path so a real daemon running on the
        # test machine cannot intercept the proxy's records.
        os.environ["OPENBURNBAR_DAEMON_SOCKET_PATH"] = str(
            self.ledger_path.with_name("nonexistent-daemon.sock")
        )
        self._upstream_port = self._reserve_port()
        self._proxy_port = self._reserve_port()
        self._upstream = self._start_fake_hermes(self._upstream_port)
        self._proxy_thread, self._proxy_server = self._start_proxy(
            self._proxy_port, self._upstream_port
        )

    def tearDown(self) -> None:
        self._proxy_server.shutdown()
        self._proxy_thread.join(timeout=2)
        self._proxy_server.server_close()
        self._upstream.shutdown()
        self._upstream.server_close()
        os.environ.pop("OPENBURNBAR_USAGE_LEDGER_PATH", None)
        os.environ.pop("OPENBURNBAR_DAEMON_SOCKET_PATH", None)
        self._tmp.cleanup()

    @staticmethod
    def _reserve_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]

    @staticmethod
    def _start_fake_hermes(port: int, *, stream: bool = False) -> ThreadingHTTPServer:
        captured: dict[str, Any] = {}

        class FakeHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):  # noqa: A002
                pass

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length) if length > 0 else b""
                captured["last_body"] = body
                if stream:
                    chunks = [
                        {
                            "id": "chatcmpl-fake-stream",
                            "object": "chat.completion.chunk",
                            "model": "minimax-m2.7-highspeed",
                            "choices": [
                                {"index": 0, "delta": {"role": "assistant", "content": "Hello"}}
                            ],
                        },
                        {
                            "id": "chatcmpl-fake-stream",
                            "object": "chat.completion.chunk",
                            "model": "minimax-m2.7-highspeed",
                            "choices": [
                                {"index": 0, "delta": {"content": " from"}}
                            ],
                        },
                        {
                            "id": "chatcmpl-fake-stream",
                            "object": "chat.completion.chunk",
                            "model": "minimax-m2.7-highspeed",
                            "choices": [
                                {"index": 0, "delta": {"content": " stream."}, "finish_reason": "stop"}
                            ],
                            "usage": {
                                "prompt_tokens": 11,
                                "completion_tokens": 7,
                                "total_tokens": 18,
                                "completion_tokens_details": {"reasoning_tokens": 1},
                            },
                        },
                    ]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("X-Request-Id", "req-fake-stream")
                    self.end_headers()
                    for chunk in chunks:
                        line = f"data: {json.dumps(chunk)}\n\n".encode("utf-8")
                        try:
                            self.wfile.write(line)
                            self.wfile.flush()
                        except (BrokenPipeError, ConnectionResetError):
                            return
                    try:
                        self.wfile.write(b"data: [DONE]\n\n")
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        return
                    return
                response = {
                    "id": "chatcmpl-fake-1",
                    "object": "chat.completion",
                    "model": "minimax-m2.7-highspeed",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "Hello from the fake upstream.",
                            },
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 42,
                        "completion_tokens": 17,
                        "total_tokens": 59,
                        "completion_tokens_details": {"reasoning_tokens": 4},
                    },
                }
                payload = json.dumps(response).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("X-Request-Id", "req-fake-1")
                self.end_headers()
                self.wfile.write(payload)

        server = ThreadingHTTPServer(("127.0.0.1", port), FakeHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        # ThreadingHTTPServer is ready immediately after the socket binds, but
        # we still wait for the first connection to succeed defensively.
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.02)
        return server

    def _start_proxy(self, listen_port: int, upstream_port: int):
        config = proxy_mod.ProxyConfig(
            listen_host="127.0.0.1",
            listen_port=listen_port,
            upstream_host="127.0.0.1",
            upstream_port=upstream_port,
            upstream_scheme="http",
            provider_id="hermes",
            session_id="proxy-test-session",
            project_name="Hermes (test)",
            confidence="exact",
            estimate_when_missing=True,
        )
        handler = proxy_mod._make_handler(config)
        server = ThreadingHTTPServer(("127.0.0.1", listen_port), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", listen_port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.02)
        return thread, server

    def test_proxy_forwards_streaming_and_records_usage(self) -> None:
        # Tear down the non-streaming upstream and replace with a streaming one.
        self._upstream.shutdown()
        self._upstream.server_close()
        self._upstream = self._start_fake_hermes(self._upstream_port, stream=True)

        body = json.dumps(
            {
                "model": "minimax-m2.7-highspeed",
                "stream": True,
                "messages": [{"role": "user", "content": "Stream me a hello."}],
            }
        ).encode("utf-8")

        conn = HTTPConnection("127.0.0.1", self._proxy_port, timeout=5)
        conn.request(
            "POST",
            "/v1/chat/completions",
            body=body,
            headers={"Content-Type": "application/json"},
        )
        response = conn.getresponse()
        body_bytes = response.read()
        conn.close()
        self.assertEqual(response.status, 200)
        # SSE bytes should round-trip end-to-end.
        self.assertIn(b"data:", body_bytes)
        self.assertIn(b"[DONE]", body_bytes)

        deadline = time.time() + 3.0
        while time.time() < deadline:
            if self.ledger_path.is_file() and self.ledger_path.read_text():
                break
            time.sleep(0.05)

        self.assertTrue(self.ledger_path.is_file())
        record = json.loads(self.ledger_path.read_text(encoding="utf-8").strip().splitlines()[0])
        # Exact usage should be lifted from the final streaming chunk's
        # `usage` block, not estimated.
        self.assertEqual(record["event"]["inputTokens"], 11)
        self.assertEqual(record["event"]["outputTokens"], 7)
        self.assertEqual(record["event"]["reasoningTokens"], 1)
        self.assertEqual(record["event"]["confidence"], "exact")

    def test_proxy_forwards_and_records_usage(self) -> None:
        body = json.dumps(
            {
                "model": "minimax-m2.7-highspeed",
                "messages": [
                    {"role": "user", "content": "Hi"},
                ],
            }
        ).encode("utf-8")

        conn = HTTPConnection("127.0.0.1", self._proxy_port, timeout=5)
        conn.request(
            "POST",
            "/v1/chat/completions",
            body=body,
            headers={"Content-Type": "application/json"},
        )
        response = conn.getresponse()
        payload = response.read()
        self.assertEqual(response.status, 200)
        decoded = json.loads(payload)
        self.assertEqual(decoded["choices"][0]["message"]["role"], "assistant")
        conn.close()

        # Allow the proxy thread to flush the ledger write.
        deadline = time.time() + 3.0
        while time.time() < deadline:
            if self.ledger_path.is_file() and self.ledger_path.read_text():
                break
            time.sleep(0.05)

        self.assertTrue(self.ledger_path.is_file(), "ledger should exist")
        lines = self.ledger_path.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 1)
        record = json.loads(lines[0])
        self.assertEqual(record["event"]["providerID"], "hermes")
        self.assertEqual(record["event"]["modelID"], "minimax-m2.7-highspeed")
        self.assertEqual(record["event"]["inputTokens"], 42)
        self.assertEqual(record["event"]["outputTokens"], 17)
        self.assertEqual(record["event"]["reasoningTokens"], 4)
        self.assertEqual(record["event"]["sessionID"], "proxy-test-session")
        self.assertEqual(record["event"]["projectName"], "Hermes (test)")
        self.assertEqual(record["event"]["confidence"], "exact")
        self.assertTrue(record["idempotencyKey"].startswith("hermes-"))


if __name__ == "__main__":
    unittest.main()
