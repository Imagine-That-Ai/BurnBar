#!/usr/bin/env python3
"""Tiny HTTP wrapper around the official OpenTimestamps `ots verify` CLI.

The Firebase Node.js callable cannot assume a Python OpenTimestamps binary is
installed in its runtime image. This service is intentionally small and
container-native: deploy it to Cloud Run, set `OPENBURNBAR_OTS_VERIFY_URL` on
the Firebase function, and the callable delegates proof verification here.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


MAX_BODY_BYTES = 14 * 1024 * 1024
MAX_PROOF_BYTES = 256 * 1024
MAX_CHAIN_BYTES = 10 * 1024 * 1024


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("content-type", "application/json")
    handler.send_header("content-length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _decode_base64(value: object, field: str, max_bytes: int) -> bytes:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} is required")
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ValueError(f"{field} must be base64") from exc
    if not raw:
        raise ValueError(f"{field} decoded to empty bytes")
    if len(raw) > max_bytes:
        raise ValueError(f"{field} is too large")
    return raw


class Handler(BaseHTTPRequestHandler):
    server_version = "OpenBurnBarOTSVerifier/1.0"

    def do_GET(self) -> None:
        if self.path in ("/health", "/healthz"):
            _json_response(self, 200, {"ok": True, "service": "opentimestamps-verifier"})
            return
        _json_response(self, 404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path not in ("/", "/verify"):
            _json_response(self, 404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError:
            _json_response(self, 400, {"error": "bad_content_length"})
            return
        if length <= 0 or length > MAX_BODY_BYTES:
            _json_response(self, 413, {"error": "body_too_large"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            proof = _decode_base64(payload.get("proofBase64"), "proofBase64", MAX_PROOF_BYTES)
            chain_value = payload.get("chainFileBase64")
            chain = None if chain_value is None else _decode_base64(
                chain_value,
                "chainFileBase64",
                MAX_CHAIN_BYTES,
            )
        except ValueError as exc:
            _json_response(self, 400, {"error": str(exc)})
            return
        except Exception:
            _json_response(self, 400, {"error": "invalid_json"})
            return

        with tempfile.TemporaryDirectory(prefix="openburnbar-ots-") as tmp:
            root = Path(tmp)
            proof_path = root / "chain.jsonl.ots"
            proof_path.write_bytes(proof)
            if chain is not None:
                (root / "chain.jsonl").write_bytes(chain)
            try:
                completed = subprocess.run(
                    ["ots", "verify", str(proof_path)],
                    cwd=root,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=30,
                    check=False,
                )
            except FileNotFoundError:
                _json_response(self, 503, {
                    "verified": False,
                    "output": "ots binary unavailable",
                })
                return
            except subprocess.TimeoutExpired:
                _json_response(self, 504, {
                    "verified": False,
                    "output": "ots verify timed out",
                })
                return

        output = "\n".join(part for part in [completed.stdout, completed.stderr] if part).strip()
        if completed.returncode == 0:
            _json_response(self, 200, {"verified": True, "output": output})
        else:
            _json_response(self, 422, {"verified": False, "output": output})

    def log_message(self, fmt: str, *args: object) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"OpenBurnBar OTS verifier listening on :{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
