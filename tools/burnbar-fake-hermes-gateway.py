#!/usr/bin/env python3
"""Deterministic Hermes gateway fixture for BurnBar M4 directive delivery.

This fixture implements the documented Hermes `api_server` delivery contract
(branch A of VAL-ORCH-014) so delivery flows can be validated end-to-end with
NO live gateway. It impersonates `POST /v1/chat/completions` on a scratch
port and acknowledges approved directives with the canonical
`burnbar_delivery` acknowledgement shape.

Usage (all modes are selected by env, never by live-gateway state):

  BURNBAR_FAKE_HERMES_PORT=<port>            listen port (default 8643)
  BURNBAR_FAKE_HERMES_MODE=ack               respond with the canonical
                                             acknowledgement immediately
  BURNBAR_FAKE_HERMES_MODE=hold              hold the acknowledgement until
                                             the release file appears
                                             (default $SCRATCH/release)
  BURNBAR_FAKE_HERMES_MODE=malformed-json    respond 200 with invalid JSON
  BURNBAR_FAKE_HERMES_MODE=malformed-id      respond 200 with a mismatched
                                             directive_id
  BURNBAR_FAKE_HERMES_MODE=malformed-status  respond 200 with status
                                             "pending" (contradictory)
  BURNBAR_FAKE_HERMES_MODE=fail              respond HTTP 500
  BURNBAR_FAKE_HERMES_SCRATCH=<dir>          receipts/request log dir
                                             (default $HOME/.burnbar-fake-hermes)
  BURNBAR_FAKE_HERMES_API_KEY=<key>          expected fixture key (default
                                             "test-key"). Requests must carry
                                             Authorization: Bearer <key>.

Receipt contract: every request is appended to $SCRATCH/receipts.jsonl with
the directive id, mode, and response status, so validators can assert receipt
and the absence of delivery side effects (VAL-ORCH-013/037).

The fixture never touches any agent root and never reads the real gateway.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def scratch_dir():
    return os.environ.get("BURNBAR_FAKE_HERMES_SCRATCH") or os.path.join(
        os.path.expanduser("~"), ".burnbar-fake-hermes"
    )


def release_file():
    return os.environ.get("BURNBAR_FAKE_HERMES_RELEASE_FILE") or os.path.join(
        scratch_dir(), "release"
    )


def mode():
    return os.environ.get("BURNBAR_FAKE_HERMES_MODE", "ack")


def log_receipt(directive_id, response_status, note=""):
    d = scratch_dir()
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "receipts.jsonl"), "a", encoding="utf-8") as f:
        f.write(
            json.dumps(
                {
                    "at": time.time(),
                    "directive_id": directive_id,
                    "mode": mode(),
                    "response_status": response_status,
                    "note": note,
                }
            )
            + "\n"
        )


def extract_directive_id(body):
    """Pull the directive id out of the chat-completions request body.

    The app embeds `burnbar_directive: {json}` in the user message; the
    fixture parses that JSON to correlate the acknowledgement.
    """
    try:
        payload = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return None
    messages = payload.get("messages") or []
    for message in messages:
        content = message.get("content") or ""
        if not isinstance(content, str):
            continue
        marker = "burnbar_directive: "
        idx = content.find(marker)
        if idx < 0:
            continue
        try:
            directive = json.loads(content[idx + len(marker):])
        except (json.JSONDecodeError, TypeError):
            continue
        return directive.get("id")
    return None


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        directive_id = extract_directive_id(body)

        if self.path != "/v1/chat/completions":
            log_receipt(directive_id, 404, note="unexpected path %s" % self.path)
            self._respond(404, {"error": {"message": "not found"}})
            return

        expected_key = os.environ.get("BURNBAR_FAKE_HERMES_API_KEY", "test-key")
        expected_auth = "Bearer " + expected_key
        if self.headers.get("Authorization") != expected_auth:
            log_receipt(directive_id, 401, note="invalid authorization")
            self._respond(401, {"error": {"message": "invalid bearer authorization"}})
            return

        current_mode = mode()

        if current_mode == "fail":
            log_receipt(directive_id, 500, note="mode=fail")
            self._respond(500, {"error": {"message": "gateway exploded"}})
            return

        if current_mode == "hold":
            # Hold the acknowledgement until the release file appears, so the
            # `approved` state is observable before any terminal delivery
            # outcome (VAL-ORCH-012). Bound the hold so a stuck validator
            # never hangs the fixture forever.
            deadline = time.time() + 60
            while time.time() < deadline:
                if os.path.exists(release_file()):
                    break
                time.sleep(0.1)
            log_receipt(directive_id, 200, note="mode=hold released")
            self._respond(200, ack_payload(directive_id))
            return

        if current_mode == "malformed-json":
            log_receipt(directive_id, 200, note="mode=malformed-json")
            self._respond_raw(200, b"{not json")
            return

        if current_mode == "malformed-id":
            log_receipt(directive_id, 200, note="mode=malformed-id")
            self._respond(200, ack_payload("some-other-id"))
            return

        if current_mode == "malformed-status":
            log_receipt(directive_id, 200, note="mode=malformed-status")
            self._respond(200, ack_payload(directive_id, status="pending"))
            return

        # ack (default)
        log_receipt(directive_id, 200, note="mode=ack")
        self._respond(200, ack_payload(directive_id))

    def _respond(self, status, payload):
        self._respond_raw(status, json.dumps(payload).encode("utf-8"))

    def _respond_raw(self, status, raw):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):
        # Silence per-request stderr noise; receipts.jsonl is the record.
        pass


def ack_payload(directive_id, status="delivered"):
    return {
        "id": "chatcmpl-fake",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": "hermes-gateway-fixture",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "directive acknowledged"},
                "finish_reason": "stop",
            }
        ],
        "burnbar_delivery": {
            "directive_id": directive_id,
            "status": status,
        },
    }


def main():
    port = int(os.environ.get("BURNBAR_FAKE_HERMES_PORT", "8643"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    d = scratch_dir()
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "fixture.log"), "a", encoding="utf-8") as f:
        f.write("fixture listening on 127.0.0.1:%d mode=%s\n" % (port, mode()))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
