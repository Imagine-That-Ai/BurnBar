"""A loopback stand-in for the daemon gateway: records every request, replies with canned JSON."""

from __future__ import annotations

import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from collections.abc import Callable
from typing import Any


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class FakeGateway:
    """`responder(path, body) -> (status, payload)`; `requests` keeps (path, headers, body) in order."""

    def __init__(self, responder: Callable[[str, dict[str, Any]], tuple[int, dict[str, Any]]]) -> None:
        self.requests: list[tuple[str, dict[str, str], dict[str, Any]]] = []
        self.port = reserve_port()
        gateway = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):  # noqa: A002
                pass

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
                gateway.requests.append((self.path, {k.lower(): v for k, v in self.headers.items()}, body))
                status, payload = responder(self.path, body)
                raw = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def __enter__(self) -> FakeGateway:
        self.thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()

    def bodies(self) -> str:
        return json.dumps([body for _, _, body in self.requests])


def chat_reply(content: dict[str, Any], *, usage: dict[str, int] | None = None) -> tuple[int, dict[str, Any]]:
    return 200, {
        "choices": [{"message": {"role": "assistant", "content": json.dumps(content)}}],
        "usage": usage or {"prompt_tokens": 10, "completion_tokens": 5},
    }


def embed_reply(vectors: list[list[float]]) -> tuple[int, dict[str, Any]]:
    return 200, {"data": [{"index": i, "embedding": v} for i, v in enumerate(vectors)]}


def error_reply(status: int, code: str) -> tuple[int, dict[str, Any]]:
    return status, {"error": {"code": code, "message": code.lower().replace("_", " ")}}
