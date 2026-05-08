#!/usr/bin/env python3
"""
OpenBurnBar Hermes proxy — OpenAI-compatible sidecar.

This is a small stdlib-only HTTP server that sits in front of `hermes gateway
run` (default `127.0.0.1:8642`) and:

  1. Forwards `/v1/...` requests to Hermes verbatim — including streamed SSE
     chat completions.
  2. Watches every response for token-usage payloads.
  3. Appends an idempotent row to OpenBurnBar's daemon usage ledger so the
     macOS app picks the spend up on its next refresh — even when the Mac app
     is not running and the daemon is asleep.

Why a separate process:
    Hermes itself does not know about OpenBurnBar's ledger contract, and we do
    not want to require the macOS app/daemon to be up for mobile/iPad clients
    to record exact token usage. This proxy bridges the two without
    duplicating the SQLite schema.

Usage:
    python3 tools/openburnbar-mcp/hermes_proxy.py \\
        --listen 127.0.0.1:8643 \\
        --upstream http://127.0.0.1:8642 \\
        --provider-id hermes \\
        --session-id local-dev \\
        --project-name "Hermes (proxy)"

Then point OpenBurnBar mobile/desktop at `http://<your-mac-ip>:8643/v1` instead
of Hermes directly. All other behaviour (auth, models, tool calls, streaming)
is unchanged.

Stdlib-only on purpose: this script ships next to `setup.sh` and must run
without an extra `pip install`.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import socket
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable, Optional
from urllib.parse import urlparse

# When invoked as a script the parent dir is on sys.path; when imported as a
# module from tests we still need the sibling import to resolve.
_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

from burnbar_usage_ledger import (  # noqa: E402  — sibling import after sys.path tweak
    KNOWN_CONFIDENCE,
    UsageEvent,
    append_usage_record,
    derive_idempotency_key,
)

logger = logging.getLogger("openburnbar.hermes_proxy")

DEFAULT_LISTEN = "127.0.0.1:8643"
DEFAULT_UPSTREAM = "http://127.0.0.1:8642"
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}
ALLOWED_UPSTREAM_PATH_PREFIXES = ("/v1/", "/health", "/ready")


@dataclass(frozen=True)
class ProxyConfig:
    listen_host: str
    listen_port: int
    upstream_host: str
    upstream_port: int
    upstream_scheme: str
    provider_id: str
    session_id: Optional[str]
    project_name: Optional[str]
    confidence: str
    estimate_when_missing: bool


def _split_host_port(value: str, default_port: int) -> tuple[str, int]:
    if "://" in value:
        parsed = urlparse(value)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or default_port
        return host, port
    if ":" in value:
        host, port_str = value.rsplit(":", 1)
        return host, int(port_str)
    return value, default_port


def _scheme_for(value: str) -> str:
    if "://" in value:
        return urlparse(value).scheme or "http"
    return "http"


def _filter_response_headers(headers: Iterable[tuple[str, str]]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for k, v in headers:
        if k.lower() in HOP_BY_HOP_HEADERS or _contains_header_ctl(k) or _contains_header_ctl(v):
            continue
        out.append((k, v))
    return out


def _contains_header_ctl(value: str) -> bool:
    return any(ch in value for ch in ("\r", "\n", "\x00"))


def _origin_form_path(raw_path: str) -> Optional[str]:
    if not raw_path.startswith("/") or raw_path.startswith("//"):
        return None
    parsed = urlparse(raw_path)
    if parsed.scheme or parsed.netloc or not parsed.path:
        return None
    if not parsed.path.startswith(ALLOWED_UPSTREAM_PATH_PREFIXES):
        return None
    normalized = parsed.path
    if parsed.query:
        normalized = f"{normalized}?{parsed.query}"
    return normalized


def _safe_log_value(value: str, limit: int = 160) -> str:
    sanitized = "".join(ch if ch.isprintable() and ch not in "\r\n\t" else "?" for ch in value)
    return sanitized[:limit]


def _coerce_int(value: Any) -> int:
    try:
        if value is None:
            return 0
        return int(value)
    except (TypeError, ValueError):
        return 0


def _coerce_float(value: Any) -> float:
    try:
        if value is None:
            return 0.0
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def extract_usage(payload: dict[str, Any]) -> Optional[dict[str, Any]]:
    """Extract OpenAI-style `usage` from a chat/completions JSON body."""
    if not isinstance(payload, dict):
        return None
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        return None
    return usage


def _model_id_from_payload(payload: dict[str, Any], fallback: str) -> str:
    if isinstance(payload, dict):
        model = payload.get("model")
        if isinstance(model, str) and model.strip():
            return model.strip()
    return fallback


def _request_model_id(body: dict[str, Any]) -> str:
    if isinstance(body, dict):
        model = body.get("model")
        if isinstance(model, str) and model.strip():
            return model.strip()
    return "unknown"


def _estimate_tokens_for_text(text: str) -> int:
    if not isinstance(text, str) or not text:
        return 0
    # Cheap, conservative ~4-chars-per-token heuristic; flagged as
    # `low_confidence_estimate` when used.
    return max(1, (len(text) + 3) // 4)


def _collect_request_text(body: dict[str, Any]) -> str:
    if not isinstance(body, dict):
        return ""
    messages = body.get("messages")
    out: list[str] = []
    if isinstance(messages, list):
        for msg in messages:
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if isinstance(content, str):
                out.append(content)
            elif isinstance(content, list):
                for part in content:
                    if isinstance(part, dict):
                        text = part.get("text")
                        if isinstance(text, str):
                            out.append(text)
    if not out:
        prompt = body.get("prompt")
        if isinstance(prompt, str):
            out.append(prompt)
        elif isinstance(prompt, list):
            for p in prompt:
                if isinstance(p, str):
                    out.append(p)
    return "\n".join(out)


def _collect_response_text(payload: dict[str, Any]) -> str:
    if not isinstance(payload, dict):
        return ""
    out: list[str] = []
    choices = payload.get("choices")
    if isinstance(choices, list):
        for choice in choices:
            if not isinstance(choice, dict):
                continue
            message = choice.get("message")
            if isinstance(message, dict):
                content = message.get("content")
                if isinstance(content, str):
                    out.append(content)
            text = choice.get("text")
            if isinstance(text, str):
                out.append(text)
    return "\n".join(out)


def _build_event(
    *,
    config: ProxyConfig,
    request_body: dict[str, Any],
    response_payload: dict[str, Any],
    accumulated_response_text: str,
    upstream_status: int,
    started_at: datetime,
) -> tuple[UsageEvent, str]:
    """Return `(UsageEvent, confidence)` for the recorded response."""
    confidence = config.confidence
    usage = extract_usage(response_payload) or {}
    input_tokens = _coerce_int(
        usage.get("prompt_tokens") or usage.get("input_tokens")
    )
    output_tokens = _coerce_int(
        usage.get("completion_tokens") or usage.get("output_tokens")
    )
    reasoning_tokens = 0
    details = usage.get("completion_tokens_details")
    if isinstance(details, dict):
        reasoning_tokens = _coerce_int(details.get("reasoning_tokens"))
    if reasoning_tokens == 0:
        reasoning_tokens = _coerce_int(usage.get("reasoning_tokens"))

    cache_creation = _coerce_int(usage.get("cache_creation_input_tokens"))
    cache_read = _coerce_int(usage.get("cache_read_input_tokens"))
    cost = _coerce_float(usage.get("cost") or usage.get("total_cost"))

    if input_tokens == 0 and output_tokens == 0:
        if not config.estimate_when_missing:
            raise ValueError(
                "Hermes response did not include `usage` and estimate_when_missing=False"
            )
        request_text = _collect_request_text(request_body)
        response_text = accumulated_response_text or _collect_response_text(
            response_payload
        )
        input_tokens = _estimate_tokens_for_text(request_text)
        output_tokens = _estimate_tokens_for_text(response_text)
        confidence = "low_confidence_estimate"

    model_id = _model_id_from_payload(response_payload, _request_model_id(request_body))

    event = UsageEvent(
        provider_id=config.provider_id,
        model_id=model_id,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_creation_tokens=cache_creation,
        cache_read_tokens=cache_read,
        reasoning_tokens=reasoning_tokens,
        cost=cost,
        recorded_at=started_at,
        session_id=config.session_id,
        project_name=config.project_name,
        confidence=confidence,
    )
    return event, confidence


def _record_usage(
    *,
    config: ProxyConfig,
    event: UsageEvent,
    upstream_request_id: Optional[str],
    extra_extra: Optional[str] = None,
) -> None:
    try:
        idempotency_key = derive_idempotency_key(
            provider_id=event.provider_id,
            model_id=event.model_id,
            session_id=event.session_id,
            recorded_at=event.recorded_at,
            extra=upstream_request_id or extra_extra,
        )
        result = append_usage_record(event=event, idempotency_key=idempotency_key)
        logger.info(
            "recorded usage %s tokens=%d/%d cost=$%.5f confidence=%s inserted=%s",
            event.model_id,
            event.input_tokens,
            event.output_tokens,
            event.cost,
            event.confidence,
            result["inserted"],
        )
    except (OSError, ValueError) as exc:
        logger.warning("failed to record usage: %s", exc)


def _parse_sse_data(line: bytes) -> Optional[dict[str, Any]]:
    if not line.startswith(b"data:"):
        return None
    body = line[len(b"data:") :].strip()
    if not body or body == b"[DONE]":
        return None
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def _accumulate_streaming_chunk(chunk: dict[str, Any], buf: list[str]) -> None:
    choices = chunk.get("choices")
    if not isinstance(choices, list):
        return
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        delta = choice.get("delta")
        if isinstance(delta, dict):
            content = delta.get("content")
            if isinstance(content, str):
                buf.append(content)
        else:
            message = choice.get("message")
            if isinstance(message, dict):
                content = message.get("content")
                if isinstance(content, str):
                    buf.append(content)


class HermesProxyHandler(BaseHTTPRequestHandler):
    config: ProxyConfig  # type: ignore[assignment]

    server_version = "OpenBurnBarHermesProxy/1.0"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 — stdlib API
        logger.debug("[%s] %s", self.address_string(), format % args)

    def _open_upstream(self) -> HTTPConnection:
        if self.config.upstream_scheme == "https":
            from http.client import HTTPSConnection  # local import: optional dep

            return HTTPSConnection(
                self.config.upstream_host, self.config.upstream_port, timeout=120
            )
        return HTTPConnection(
            self.config.upstream_host, self.config.upstream_port, timeout=120
        )

    def _request_body(self) -> bytes:
        length_header = self.headers.get("Content-Length")
        if not length_header:
            return b""
        try:
            length = int(length_header)
        except ValueError:
            return b""
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _do_proxy(self, method: str) -> None:
        body = self._request_body()
        path = _origin_form_path(self.path)
        if path is None:
            self.send_error(HTTPStatus.BAD_REQUEST, "Unsupported upstream path.")
            return
        try:
            parsed_body: dict[str, Any] = json.loads(body) if body else {}
        except json.JSONDecodeError:
            parsed_body = {}

        upstream = self._open_upstream()
        upstream_headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in HOP_BY_HOP_HEADERS and k.lower() != "host"
        }
        upstream_headers["Host"] = f"{self.config.upstream_host}:{self.config.upstream_port}"

        try:
            upstream.request(method, path, body=body, headers=upstream_headers)
            response = upstream.getresponse()
        except (OSError, ConnectionError) as exc:
            logger.warning("upstream connection failed: %s", exc)
            self.send_error(HTTPStatus.BAD_GATEWAY, str(exc))
            return

        try:
            self._relay_response(
                response,
                method=method,
                path=path,
                request_body=parsed_body,
            )
        finally:
            upstream.close()

    def _relay_response(
        self,
        response: Any,
        *,
        method: str,
        path: str,
        request_body: dict[str, Any],
    ) -> None:
        started_at = datetime.now(timezone.utc)
        upstream_status = response.status
        content_type = response.getheader("Content-Type", "") or ""
        is_sse = "text/event-stream" in content_type.lower()

        self.send_response(upstream_status)
        for k, v in _filter_response_headers(response.getheaders()):
            self.send_header(k, v)
        self.end_headers()

        if is_sse:
            self._stream_and_record(
                response,
                request_body=request_body,
                started_at=started_at,
                method=method,
                path=path,
                upstream_status=upstream_status,
            )
            return

        body_bytes = response.read()
        try:
            self.wfile.write(body_bytes)
        except (BrokenPipeError, ConnectionResetError):
            return

        if (
            method == "POST"
            and self._is_chat_or_completions_path(path)
            and "application/json" in content_type.lower()
        ):
            try:
                payload = json.loads(body_bytes.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                logger.debug("non-JSON response body for %s", _safe_log_value(path))
                return
            try:
                event, _ = _build_event(
                    config=self.config,
                    request_body=request_body,
                    response_payload=payload if isinstance(payload, dict) else {},
                    accumulated_response_text="",
                    upstream_status=upstream_status,
                    started_at=started_at,
                )
            except ValueError as exc:
                logger.debug("skipping usage record: %s", exc)
                return
            request_id = (
                response.getheader("X-Request-Id")
                or response.getheader("x-request-id")
                or (
                    payload.get("id") if isinstance(payload, dict) else None
                )
            )
            _record_usage(
                config=self.config,
                event=event,
                upstream_request_id=request_id,
            )

    def _stream_and_record(
        self,
        response: Any,
        *,
        request_body: dict[str, Any],
        started_at: datetime,
        method: str,
        path: str,
        upstream_status: int,
    ) -> None:
        accumulated_text: list[str] = []
        last_payload: dict[str, Any] = {}
        last_request_id: Optional[str] = None

        # Read the upstream stream line-by-line, mirror to the client
        # immediately, and capture usage when present.
        buf = b""
        while True:
            try:
                chunk = response.read(4096)
            except (OSError, ConnectionError):
                break
            if not chunk:
                break
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                # Client gave up; still consume the rest so we record usage.
                pass

            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                payload = _parse_sse_data(line.strip())
                if not payload:
                    continue
                last_payload = payload
                if "id" in payload and isinstance(payload["id"], str):
                    last_request_id = payload["id"]
                if extract_usage(payload):
                    # Hermes includes final `usage` on the last delta with
                    # `stream_options={"include_usage": true}`.
                    pass
                _accumulate_streaming_chunk(payload, accumulated_text)

        if not self._is_chat_or_completions_path(path):
            return

        try:
            event, _ = _build_event(
                config=self.config,
                request_body=request_body,
                response_payload=last_payload,
                accumulated_response_text="".join(accumulated_text),
                upstream_status=upstream_status,
                started_at=started_at,
            )
        except ValueError as exc:
            logger.debug("skipping streamed usage record: %s", exc)
            return
        _record_usage(
            config=self.config,
            event=event,
            upstream_request_id=last_request_id,
            extra_extra="stream",
        )

    @staticmethod
    def _is_chat_or_completions_path(path: str) -> bool:
        if not isinstance(path, str):
            return False
        lower = path.lower().split("?", 1)[0]
        return lower.endswith("/chat/completions") or lower.endswith("/completions")

    # HTTP method dispatchers. We forward GETs (e.g. `/v1/models`) verbatim
    # so the proxy is a drop-in replacement for `hermes gateway run`.
    def do_GET(self) -> None:  # noqa: N802 — http.server interface
        self._do_proxy("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._do_proxy("POST")

    def do_DELETE(self) -> None:  # noqa: N802
        self._do_proxy("DELETE")

    def do_PUT(self) -> None:  # noqa: N802
        self._do_proxy("PUT")

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._do_proxy("OPTIONS")


def _make_handler(config: ProxyConfig) -> type[HermesProxyHandler]:
    return type("BoundHermesProxyHandler", (HermesProxyHandler,), {"config": config})


def parse_args(argv: list[str]) -> ProxyConfig:
    parser = argparse.ArgumentParser(
        description="OpenAI-compatible Hermes → OpenBurnBar usage-recording proxy."
    )
    parser.add_argument(
        "--listen",
        default=DEFAULT_LISTEN,
        help="HOST:PORT to listen on (default: 127.0.0.1:8643).",
    )
    parser.add_argument(
        "--upstream",
        default=DEFAULT_UPSTREAM,
        help="Upstream Hermes gateway URL (default: http://127.0.0.1:8642).",
    )
    parser.add_argument(
        "--provider-id",
        default="hermes",
        help="OpenBurnBar provider id to use when recording usage (default: hermes).",
    )
    parser.add_argument(
        "--session-id",
        default=None,
        help="Optional session-id to attach to every recorded usage row.",
    )
    parser.add_argument(
        "--project-name",
        default="Hermes (proxy)",
        help="Project name to attribute spend to in OpenBurnBar (default: Hermes (proxy)).",
    )
    parser.add_argument(
        "--confidence",
        default="exact",
        choices=sorted(KNOWN_CONFIDENCE),
        help="Confidence label for exact provider responses (default: exact).",
    )
    parser.add_argument(
        "--no-estimate",
        action="store_true",
        help=(
            "Skip recording when the upstream response does not include `usage`. "
            "Default behaviour records a `low_confidence_estimate` row instead."
        ),
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="Increase logging verbosity (-v info, -vv debug).",
    )
    args = parser.parse_args(argv)

    listen_host, listen_port = _split_host_port(args.listen, default_port=8643)
    upstream_host, upstream_port = _split_host_port(args.upstream, default_port=8642)
    upstream_scheme = _scheme_for(args.upstream)

    level = logging.WARNING
    if args.verbose == 1:
        level = logging.INFO
    elif args.verbose >= 2:
        level = logging.DEBUG
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s :: %(message)s",
    )

    return ProxyConfig(
        listen_host=listen_host,
        listen_port=listen_port,
        upstream_host=upstream_host,
        upstream_port=upstream_port,
        upstream_scheme=upstream_scheme,
        provider_id=args.provider_id,
        session_id=args.session_id,
        project_name=args.project_name,
        confidence=args.confidence,
        estimate_when_missing=not args.no_estimate,
    )


def serve(config: ProxyConfig) -> None:
    handler_cls = _make_handler(config)
    server = ThreadingHTTPServer((config.listen_host, config.listen_port), handler_cls)
    addr_repr = f"{config.listen_host}:{config.listen_port}"
    logger.warning(
        "OpenBurnBar Hermes proxy listening on %s → %s://%s:%d",
        addr_repr,
        config.upstream_scheme,
        config.upstream_host,
        config.upstream_port,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.warning("shutdown via SIGINT")
    finally:
        server.server_close()


def main(argv: Optional[list[str]] = None) -> None:
    config = parse_args(list(argv if argv is not None else sys.argv[1:]))
    serve(config)


if __name__ == "__main__":
    main()
