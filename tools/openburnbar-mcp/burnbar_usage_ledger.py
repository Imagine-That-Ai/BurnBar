#!/usr/bin/env python3
"""
Shared usage-ledger writer for the OpenBurnBar MCP server and Hermes proxy.

Goal:
    Hermes can record exact token usage rows for the macOS app to import — even
    when the app is not running and the daemon is not reachable — without ever
    touching the SQLite database directly. The single source of truth is the
    daemon's append-only JSON-Lines ledger at:

        ~/Library/Application Support/OpenBurnBar/usage-events.jsonl

    Each line is `{"idempotencyKey": str, "event": BurnBarUsageEvent}` and is
    re-imported by `OpenBurnBarDaemonUsageSyncService` when the app launches.

Why a separate module:
    1. The MCP `burnbar_record_hermes_usage` tool and the standalone
       `hermes_proxy.py` both need to write the same shape, with the same
       idempotency rules, and with the same fallback logic.
    2. Tests can import this module without bringing in `mcp.server.fastmcp`.
"""

from __future__ import annotations

import errno
import fcntl
import hashlib
import json
import os
import re
import socket
import subprocess
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Optional


# Seconds between Unix epoch (1970-01-01) and Apple reference date
# (2001-01-01). Swift's `JSONEncoder.dateEncodingStrategy = .deferredToDate`
# (the default) encodes `Date` as `timeIntervalSinceReferenceDate`. The daemon
# ledger uses that default, so all `recordedAt` values written by Hermes/MCP
# clients must be expressed as `unix_seconds - APPLE_REFERENCE_DATE_OFFSET`.
APPLE_REFERENCE_DATE_OFFSET: float = 978_307_200.0


KNOWN_PROVIDER_IDS: frozenset[str] = frozenset(
    {
        "zai",
        "minimax",
        "ollama",
        "openai",
        "anthropic",
        "google",
        "deepseek",
        "mistral",
        "meta",
        "cohere",
        "xai",
        "amazon",
        "alibaba",
        "moonshot",
        "hermes",
    }
)

KNOWN_CONFIDENCE: frozenset[str] = frozenset(
    {
        "exact",
        "derived_exact",
        "high_confidence_estimate",
        "low_confidence_estimate",
        "unknown",
    }
)


def default_ledger_path() -> Path:
    """Return the default usage-events ledger path, honouring the same env
    overrides the daemon supports."""
    override = (
        os.environ.get("OPENBURNBAR_USAGE_LEDGER_PATH")
        or os.environ.get("BURNBAR_USAGE_LEDGER_PATH")
        or ""
    ).strip()
    if override:
        return Path(override).expanduser().resolve()

    support_override = (
        os.environ.get("OPENBURNBAR_DAEMON_SUPPORT_DIR")
        or os.environ.get("BURNBAR_DAEMON_SUPPORT_DIR")
        or ""
    ).strip()
    if support_override:
        return Path(support_override).expanduser().resolve() / "usage-events.jsonl"

    return Path.home() / "Library" / "Application Support" / "OpenBurnBar" / "usage-events.jsonl"


def _validate_ledger_path(path: Path) -> Path:
    """Reject paths that obviously don't look like the daemon ledger."""
    if "\x00" in str(path):
        raise ValueError("Ledger path must not contain NUL bytes.")
    if not path.is_absolute():
        raise ValueError("Ledger path must resolve to an absolute path.")
    if path.suffix != ".jsonl":
        raise ValueError("Ledger filename must end in .jsonl")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", path.name):
        raise ValueError("Ledger filename must match [A-Za-z0-9._-]+")
    return path


@dataclass(frozen=True)
class UsageEvent:
    """Mirrors `BurnBarUsageEvent` in `OpenBurnBarCore`."""

    provider_id: str
    model_id: str
    input_tokens: int
    output_tokens: int
    cache_creation_tokens: int = 0
    cache_read_tokens: int = 0
    reasoning_tokens: int = 0
    cost: float = 0.0
    recorded_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    run_id: Optional[str] = None
    session_id: Optional[str] = None
    project_name: Optional[str] = None
    confidence: str = "exact"

    def to_event_payload(self) -> dict[str, Any]:
        if self.provider_id.lower() not in KNOWN_PROVIDER_IDS:
            raise ValueError(
                f"Unknown providerID '{self.provider_id}'. Expected one of: "
                + ", ".join(sorted(KNOWN_PROVIDER_IDS))
            )
        if self.confidence not in KNOWN_CONFIDENCE:
            raise ValueError(
                f"Unknown confidence '{self.confidence}'. Expected one of: "
                + ", ".join(sorted(KNOWN_CONFIDENCE))
            )
        for name, value in (
            ("input_tokens", self.input_tokens),
            ("output_tokens", self.output_tokens),
            ("cache_creation_tokens", self.cache_creation_tokens),
            ("cache_read_tokens", self.cache_read_tokens),
            ("reasoning_tokens", self.reasoning_tokens),
        ):
            if int(value) < 0:
                raise ValueError(f"{name} must be non-negative")
        if float(self.cost) < 0:
            raise ValueError("cost must be non-negative")

        recorded = self.recorded_at
        if recorded.tzinfo is None:
            recorded = recorded.replace(tzinfo=timezone.utc)
        # Swift's default `JSONEncoder.dateEncodingStrategy` is
        # `.deferredToDate`, which encodes `Date` as a `Double` representing
        # seconds since 2001-01-01 00:00:00 UTC (Apple reference date). The
        # daemon ledger reader uses the default decoder, so we MUST emit the
        # same shape — ISO-8601 strings will type-mismatch and the row will be
        # silently dropped on import.
        recorded_seconds = recorded.astimezone(timezone.utc).timestamp() - APPLE_REFERENCE_DATE_OFFSET

        payload: dict[str, Any] = {
            "providerID": self.provider_id.lower(),
            "modelID": self.model_id,
            "inputTokens": int(self.input_tokens),
            "outputTokens": int(self.output_tokens),
            "cacheCreationTokens": int(self.cache_creation_tokens),
            "cacheReadTokens": int(self.cache_read_tokens),
            "reasoningTokens": int(self.reasoning_tokens),
            "cost": float(self.cost),
            "recordedAt": recorded_seconds,
            "confidence": self.confidence,
        }
        if self.run_id is not None:
            payload["runID"] = self.run_id
        if self.session_id is not None:
            payload["sessionID"] = self.session_id
        if self.project_name is not None:
            payload["projectName"] = self.project_name
        return payload


def derive_idempotency_key(
    *,
    provider_id: str,
    model_id: str,
    session_id: Optional[str],
    recorded_at: datetime,
    extra: Optional[str] = None,
) -> str:
    """Stable key for `(session, provider, model, time, extra)` tuples.

    Hermes will usually pass an upstream request id; when it doesn't, we fall
    back to a SHA-256 of the tuple so re-emitting the same usage row on retry
    does not double-count the spend.
    """
    when = recorded_at
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    payload = "|".join(
        [
            provider_id.lower(),
            model_id,
            session_id or "",
            f"{when.astimezone(timezone.utc).timestamp():.6f}",
            extra or "",
        ]
    )
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    return f"hermes-{digest[:32]}"


@contextmanager
def _exclusive_file_lock(path: Path) -> Iterator[None]:
    """Best-effort cooperative file lock for ledger appends.

    `OpenBurnBarUsageRecorder` uses an in-memory cache so this guard only
    protects multi-process appenders (proxy + MCP write-tool + daemon).
    """
    lock_path = path.with_suffix(path.suffix + ".lock")
    lock_path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def existing_idempotency_keys(ledger_path: Path) -> set[str]:
    """Return the set of idempotency keys already recorded on disk."""
    keys: set[str] = set()
    if not ledger_path.is_file():
        return keys
    try:
        with ledger_path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                key = record.get("idempotencyKey")
                if isinstance(key, str) and key:
                    keys.add(key)
    except OSError:
        # Treat unreadable ledger as empty — we'll still try to append below
        # and surface the OSError to the caller if that fails too.
        return keys
    return keys


def _default_socket_path() -> Path:
    override = (
        os.environ.get("OPENBURNBAR_DAEMON_SOCKET_PATH")
        or os.environ.get("BURNBAR_DAEMON_SOCKET_PATH")
        or ""
    ).strip()
    if override:
        return Path(override).expanduser().resolve()

    support_override = (
        os.environ.get("OPENBURNBAR_DAEMON_SUPPORT_DIR")
        or os.environ.get("BURNBAR_DAEMON_SUPPORT_DIR")
        or ""
    ).strip()
    if support_override:
        return Path(support_override).expanduser().resolve() / "openburnbar-daemon.sock"

    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "OpenBurnBar"
        / "openburnbar-daemon.sock"
    )


def _resolve_socket_auth_token() -> Optional[str]:
    """Best-effort lookup of the daemon socket auth token.

    The macOS app stamps the token into the launch-agent plist; the daemon
    process picks it up from the `OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN`
    env var. Hermes-launched MCP servers may inherit it directly.
    """
    env_token = (
        os.environ.get("OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN")
        or os.environ.get("BURNBAR_DAEMON_SOCKET_AUTH_TOKEN")
    )
    if env_token and env_token.strip():
        return env_token.strip()

    plist_path = (
        Path.home()
        / "Library"
        / "LaunchAgents"
        / "com.openburnbar.daemon.plist"
    )
    if not plist_path.is_file():
        return None
    try:
        result = subprocess.run(
            [
                "/usr/libexec/PlistBuddy",
                "-c",
                "Print :EnvironmentVariables:OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN",
                str(plist_path),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    if result.returncode != 0:
        return None
    token = result.stdout.strip()
    return token or None


def _try_record_via_daemon_socket(
    *,
    event_payload: dict[str, Any],
    idempotency_key: str,
    socket_path: Path,
    auth_token: Optional[str],
    timeout_seconds: float = 1.5,
) -> Optional[dict[str, Any]]:
    """Try to record the usage event by talking to the local daemon's RPC
    server. Returns `None` if the daemon is not reachable; raises only when
    the daemon explicitly rejects the request."""
    if not socket_path.exists():
        return None
    request = {
        "id": str(uuid.uuid4()),
        "method": "daemon.usage.record",
        "params": {"idempotencyKey": idempotency_key, "event": event_payload},
    }
    if auth_token:
        request["authToken"] = auth_token
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout_seconds)
        try:
            sock.connect(str(socket_path))
            sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = sock.recv(8192)
                if not chunk:
                    break
                buf += chunk
        finally:
            sock.close()
    except (OSError, socket.timeout):
        return None
    if not buf:
        return None
    try:
        envelope = json.loads(buf.decode("utf-8").rstrip("\n"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if envelope.get("error"):
        # Surface daemon-side rejection (e.g. unauthorized) so the caller can
        # decide whether to fall back to a direct write.
        err = envelope["error"]
        raise RuntimeError(
            f"daemon rejected usage record: code={err.get('code')} message={err.get('message')!r}"
        )
    result = envelope.get("result")
    if not isinstance(result, dict):
        return None
    return {
        "idempotencyKey": result.get("idempotencyKey", idempotency_key),
        "inserted": bool(result.get("inserted", False)),
        "event": result.get("event", event_payload),
        "via": "daemon",
        "socketPath": str(socket_path),
    }


def append_usage_record(
    *,
    event: UsageEvent,
    idempotency_key: str,
    ledger_path: Optional[Path] = None,
    prefer_daemon: bool = True,
) -> dict[str, Any]:
    """Append a usage record to the ledger if its key is not already present.

    When `prefer_daemon=True` (the default) the writer first tries to talk to
    a running OpenBurnBar daemon over its UNIX socket so the daemon's
    in-memory key cache stays consistent. If the daemon is unreachable, the
    writer falls back to a direct, idempotent ledger append.

    Returns a dict with `inserted` (bool), `idempotencyKey`, and the recorded
    event payload, mirroring `BurnBarRecordUsageResponse`. The result also
    includes a `via` key indicating which write path served the request.
    """
    if not isinstance(idempotency_key, str) or not idempotency_key.strip():
        raise ValueError("idempotency_key must be a non-empty string")

    ledger = _validate_ledger_path(ledger_path or default_ledger_path())
    ledger.parent.mkdir(parents=True, mode=0o700, exist_ok=True)

    payload = event.to_event_payload()
    key = idempotency_key.strip()

    if prefer_daemon:
        try:
            daemon_result = _try_record_via_daemon_socket(
                event_payload=payload,
                idempotency_key=key,
                socket_path=_default_socket_path(),
                auth_token=_resolve_socket_auth_token(),
            )
        except RuntimeError:
            # Daemon explicitly rejected — fall through to local append so we
            # still capture the spend; the daemon will dedupe on its next
            # ledger reload.
            daemon_result = None
        if daemon_result is not None:
            return daemon_result

    record = {"idempotencyKey": key, "event": payload}
    serialized = json.dumps(record, separators=(",", ":"), ensure_ascii=False)

    with _exclusive_file_lock(ledger):
        keys = existing_idempotency_keys(ledger)
        if record["idempotencyKey"] in keys:
            return {
                "idempotencyKey": record["idempotencyKey"],
                "inserted": False,
                "event": payload,
                "ledgerPath": str(ledger),
                "via": "ledger",
            }

        flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
        try:
            fd = os.open(ledger, flags, 0o600)
        except OSError as exc:
            raise OSError(
                f"Failed to open ledger at {ledger}: {os.strerror(exc.errno)}"
            ) from exc
        try:
            os.write(fd, (serialized + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        # Re-tighten perms in case the file was created with looser umask.
        try:
            os.chmod(ledger, 0o600)
        except OSError:
            pass

    return {
        "idempotencyKey": record["idempotencyKey"],
        "inserted": True,
        "event": payload,
        "ledgerPath": str(ledger),
        "via": "ledger",
    }


__all__ = [
    "APPLE_REFERENCE_DATE_OFFSET",
    "KNOWN_PROVIDER_IDS",
    "KNOWN_CONFIDENCE",
    "UsageEvent",
    "append_usage_record",
    "default_ledger_path",
    "derive_idempotency_key",
    "existing_idempotency_keys",
]
