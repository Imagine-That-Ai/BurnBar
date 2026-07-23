#!/usr/bin/python3
"""OpenBurnBar's bounded IBus text-expansion engine.

The daemon launches this file in JSONL mode. IBus launches it in component mode.
Neither mode reads clipboard contents, surrounding text, or global input events.
"""

import json
import os
import re
import signal
import subprocess
import sys
import uuid

MAX_LINE = 64 * 1024
MAX_REPLACEMENT = 64 * 1024
TRIGGER = re.compile(r"^[a-z0-9_-]{2,64}$")
PROTOCOL = "openburnbar.text-expansion"
VERSION = 1
ENGINE_ID = "org.openburnbar.TextExpansion"
STOP = False
CLI_ENVIRONMENT_KEYS = (
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "XDG_RUNTIME_DIR",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "OPENBURNBAR_DAEMON_SUPPORT_DIR",
    "OPENBURNBAR_DAEMON_SOCKET_PATH",
    "BURNBAR_DAEMON_SOCKET_PATH",
    "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE",
    "BURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE",
)


def _stop(_signum, _frame):
    global STOP
    STOP = True


def _emit(value):
    data = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    if len(data.encode("utf-8")) > MAX_LINE:
        raise ValueError("response exceeds protocol bound")
    sys.stdout.write(data + "\n")
    sys.stdout.flush()


def _canonical_trigger(value):
    if not isinstance(value, str):
        return None
    value = value.strip().lower()
    while value.startswith("&&"):
        value = value[2:]
    return value if TRIGGER.fullmatch(value) else None


def _field_allows_expansion(inspectable, purpose):
    if not bool(inspectable):
        return False
    try:
        code = int(purpose)
    except (TypeError, ValueError):
        # An app can send key events before IBus calls do_set_content_type, so
        # purpose is still the sentinel "unknown". Deny expansion, matching the
        # deny-by-default posture -- never raise, or the IME dies for every
        # field that omits content-type metadata.
        return False
    return code not in (8, 9)


def _commit_plan(candidate, replacement, delimiter):
    if not candidate.startswith("&&") or _canonical_trigger(candidate) is None:
        return None
    return {"backspaces": len(candidate), "text": replacement + delimiter}


def run_jsonl(engine_id):
    for raw in sys.stdin.buffer:
        if STOP:
            return 0
        if len(raw) > MAX_LINE or not raw.endswith(b"\n"):
            return 64
        try:
            request = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return 64
        operation = request.get("operation")
        if operation == "handshake":
            valid = (
                request.get("protocol") == PROTOCOL
                and request.get("protocolVersion") == VERSION
                and request.get("engineID") == engine_id
                and request.get("noGlobalCapture") is True
                and request.get("readsClipboard") is False
                and request.get("readsSurroundingText") is False
                and request.get("secureFieldPolicy")
                == "deny-unless-inspectable-and-explicitly-nonsecure"
            )
            if not valid:
                return 65
            _emit({
                "operation": "handshake_ack",
                "protocol": PROTOCOL,
                "protocolVersion": VERSION,
                "engineID": engine_id,
                "ready": True,
                "noGlobalCapture": True,
                "readsClipboard": False,
                "readsSurroundingText": False,
                "secureFieldPolicy": "deny-unless-inspectable-and-explicitly-nonsecure",
            })
            continue
        if operation != "expand" or request.get("protocol") != PROTOCOL:
            return 65
        request_id = request.get("requestID")
        trigger = _canonical_trigger(request.get("trigger"))
        replacement = request.get("replacement")
        if not isinstance(request_id, str) or len(request_id.encode()) > 128 or trigger is None:
            return 65
        if replacement is None:
            status = "not_found"
        elif not isinstance(replacement, str) or len(replacement.encode()) > MAX_REPLACEMENT:
            return 65
        else:
            status = "expanded"
        response = {
            "operation": "expand_result",
            "protocol": PROTOCOL,
            "protocolVersion": VERSION,
            "requestID": request_id,
            "status": status,
        }
        if replacement is not None:
            response["replacement"] = replacement
        _emit(response)
    return 0


def _daemon_expand(trigger, context):
    request = {
        "trigger": trigger,
        "context": context,
        "timeoutMillis": 1000,
        "requestID": "ime-" + uuid.uuid4().hex,
    }
    try:
        result = subprocess.run(
            ["/usr/bin/openburnbar-cli", "text-expansion-engine-expand"],
            input=json.dumps(request).encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
            env={key: os.environ[key] for key in CLI_ENVIRONMENT_KEYS if key in os.environ},
        )
    except (OSError, subprocess.TimeoutExpired):
        # An unavailable or wedged daemon must not take down the IBus worker.
        # Returning no replacement leaves the user's trigger untouched and
        # keeps the input-method session available for the next field/event.
        return None
    if result.returncode != 0 or len(result.stdout) > MAX_LINE:
        return None
    try:
        response = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    replacement = response.get("replacement")
    return replacement if isinstance(replacement, str) and len(replacement.encode()) <= MAX_REPLACEMENT else None


def run_ibus():
    try:
        import gi
        gi.require_version("IBus", "1.0")
        from gi.repository import GLib, IBus
    except (ImportError, ValueError):
        return 69

    IBus.init()

    class Engine(IBus.Engine):
        def __init__(self, connection, object_path):
            super().__init__(connection=connection, object_path=object_path)
            self.pending = ""
            self.inspectable = False
            self.secure = True
            self.purpose = "unknown"

        def do_set_content_type(self, purpose, hints):
            self.inspectable = True
            self.purpose = str(int(purpose))
            # IBus.InputPurpose PASSWORD=8 and PIN=9. Unknown remains denied.
            self.secure = int(purpose) in (8, 9)

        def do_focus_out(self):
            self.pending = ""
            self.inspectable = False
            self.secure = True

        def do_process_key_event(self, keyval, _keycode, state):
            if state & (IBus.ModifierType.CONTROL_MASK | IBus.ModifierType.MOD1_MASK):
                self.pending = ""
                return False
            char = chr(IBus.keyval_to_unicode(keyval)) if IBus.keyval_to_unicode(keyval) else ""
            if char and (char.isalnum() or char in "&_-" ):
                self.pending = (self.pending + char)[-68:]
                return False
            if char not in (" ", "\n", "\t"):
                self.pending = ""
                return False
            candidate = self.pending
            self.pending = ""
            trigger = _canonical_trigger(candidate) if candidate.startswith("&&") else None
            if trigger is None or not _field_allows_expansion(self.inspectable, self.purpose):
                return False
            replacement = _daemon_expand(trigger, {
                "inspectable": True,
                "isSecureField": False,
                "applicationID": "ibus-input-context",
                "role": "text",
                "inputPurpose": self.purpose,
            })
            if replacement is None:
                return False
            plan = _commit_plan(candidate, replacement, char)
            if plan is None:
                return False
            for _ in range(plan["backspaces"]):
                self.forward_key_event(IBus.KEY_BackSpace, 0, 0)
            self.commit_text(IBus.Text.new_from_string(plan["text"]))
            return True

    class Factory(IBus.Factory):
        def do_create_engine(self, name):
            if name != "openburnbar":
                return None
            return Engine(self.get_connection(), "/org/openburnbar/IBus/Engine/" + uuid.uuid4().hex)

    bus = IBus.Bus()
    if not bus.is_connected():
        return 69
    Factory(connection=bus.get_connection())
    bus.request_name("org.freedesktop.IBus.OpenBurnBar", 0)
    loop = GLib.MainLoop()

    def stop_when_signalled():
        if STOP:
            loop.quit()
            return False
        return True

    GLib.timeout_add(100, stop_when_signalled)
    loop.run()
    return 0


def main():
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    args = sys.argv[1:]
    if "--self-test" in args:
        _emit({
            "unknownDenied": not _field_allows_expansion(False, 0),
            "passwordDenied": not _field_allows_expansion(True, 8),
            "pinDenied": not _field_allows_expansion(True, 9),
            "freeFormAllowed": _field_allows_expansion(True, 0),
            "plan": _commit_plan("&&hello", "Hello", " "),
        })
        return 0
    if "--ibus" in args:
        return run_ibus()
    try:
        index = args.index("--engine-id")
        engine_id = args[index + 1]
    except (ValueError, IndexError):
        engine_id = ENGINE_ID
    if engine_id != ENGINE_ID:
        return 64
    return run_jsonl(engine_id)


if __name__ == "__main__":
    raise SystemExit(main())
