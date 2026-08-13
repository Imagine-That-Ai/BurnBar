#!/usr/bin/env python3
"""Run xcodebuild with bounded, exact-PID failure containment.

Xcode can relaunch a macOS test host after one test exceeds its execution-time
allowance, then continue sequentially through every remaining selected test.
For visual suites this can turn one infrastructure hang into hours of repeated
ten-minute timeouts.

SwiftPM package resolution can also stop emitting output while a child Git
process performs repository discovery. Callers may therefore provide a finite
wall timeout for preflight operations that have no useful log marker.

The supervisor preserves streamed output and the exact shell exit status. It
interrupts only the supervised command PID, then escalates that same PID from
SIGINT to SIGTERM and SIGKILL when necessary. The canonical Bash wrapper remains
responsible for result classification, diagnostics, stale-host cleanup, and
retry policy. A concrete XCTest assertion remains authoritative; the supervisor
never changes result classification.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from collections.abc import Sequence
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

EXECUTION_TIMEOUT_MARKER = "exceeded execution time allowance"
RESTART_MARKER = "Restarting after unexpected exit, crash, or test timeout"
ASSERTION_FAILURE_PATTERN = re.compile(r"Test Case '-\[[^]]+\]' failed")


def _positive_float_from_env(name: str, default: float) -> float:
    raw_value = os.environ.get(name)
    if raw_value is None:
        return default
    return _positive_float(name, raw_value)


def _positive_float(name: str, raw_value: str) -> float:
    try:
        value = float(raw_value)
    except ValueError as error:
        raise ValueError(f"{name} must be a positive number, found {raw_value!r}") from error
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be a positive number, found {raw_value!r}")
    return value


def _shell_exit_status(return_code: int) -> int:
    if return_code >= 0:
        return min(return_code, 255)
    return min(128 + abs(return_code), 255)


def _write_json_atomically(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


class XcodebuildSupervisor:
    def __init__(
        self,
        command: Sequence[str],
        log_path: Path,
        receipt_path: Path,
        restart_grace_seconds: float,
        interrupt_grace_seconds: float,
        terminate_grace_seconds: float,
        wall_timeout_seconds: float | None,
    ) -> None:
        self.command = list(command)
        self.log_path = log_path
        self.receipt_path = receipt_path
        self.restart_grace_seconds = restart_grace_seconds
        self.interrupt_grace_seconds = interrupt_grace_seconds
        self.terminate_grace_seconds = terminate_grace_seconds
        self.wall_timeout_seconds = wall_timeout_seconds
        self.process: subprocess.Popen[bytes] | None = None
        self.lock = threading.RLock()
        self.timeout_seen = False
        self.restart_seen = False
        self.assertion_failure_seen = False
        self.containment_started = False
        self.receipt: dict[str, Any] = {}
        self.restart_grace_timer: threading.Timer | None = None
        self.interrupt_grace_timer: threading.Timer | None = None
        self.force_kill_timer: threading.Timer | None = None
        self.wall_timeout_timer: threading.Timer | None = None

    def _process_is_running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def _persist_receipt(self) -> None:
        if self.receipt:
            _write_json_atomically(self.receipt_path, self.receipt)

    def _force_kill_after_terminate_grace(self) -> None:
        with self.lock:
            if not self._process_is_running():
                return
            assert self.process is not None
            try:
                self.process.send_signal(signal.SIGKILL)
            except ProcessLookupError:
                return
            if self.receipt:
                self.receipt["forcedSignal"] = "SIGKILL"
                self.receipt["forcedAt"] = time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ",
                    time.gmtime(),
                )
                self._persist_receipt()
            print(
                f">>> Supervised xcodebuild did not exit after SIGTERM; sent SIGKILL to exact PID {self.process.pid}.",
                flush=True,
            )

    def _schedule_force_kill(self) -> None:
        if self.force_kill_timer is not None:
            return
        self.force_kill_timer = threading.Timer(
            self.terminate_grace_seconds,
            self._force_kill_after_terminate_grace,
        )
        self.force_kill_timer.daemon = True
        self.force_kill_timer.start()

    def _escalate_after_interrupt_grace(self) -> None:
        with self.lock:
            if not self._process_is_running():
                return
            assert self.process is not None
            try:
                self.process.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                return
            if self.receipt:
                self.receipt["escalatedSignal"] = "SIGTERM"
                self.receipt["escalatedAt"] = time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ",
                    time.gmtime(),
                )
                self._persist_receipt()
            print(
                ">>> Supervised xcodebuild did not exit after SIGINT; escalated "
                f"exact PID {self.process.pid} to SIGTERM.",
                flush=True,
            )
            self._schedule_force_kill()

    def _contain(self, reason: str) -> None:
        with self.lock:
            if self.containment_started or not self._process_is_running():
                return
            assert self.process is not None
            try:
                self.process.send_signal(signal.SIGINT)
            except ProcessLookupError:
                return

            self.containment_started = True
            self.receipt = {
                "assertionFailurePresent": self.assertion_failure_seen,
                "commandPid": self.process.pid,
                "detectedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "initialSignal": "SIGINT",
                "reason": reason,
                "restartMarkerObserved": self.restart_seen,
                "schemaVersion": 1,
                "timeoutMarkerObserved": self.timeout_seen,
            }
            if reason == "wall_timeout":
                self.receipt["wallTimeoutSeconds"] = self.wall_timeout_seconds
            self._persist_receipt()
            print(
                ">>> Containing supervised xcodebuild by sending SIGINT to "
                f"exact PID {self.process.pid} "
                f"(reason: {reason}).",
                flush=True,
            )

            self.interrupt_grace_timer = threading.Timer(
                self.interrupt_grace_seconds,
                self._escalate_after_interrupt_grace,
            )
            self.interrupt_grace_timer.daemon = True
            self.interrupt_grace_timer.start()

    def _contain_after_restart_grace(self) -> None:
        self._contain("execution_timeout_restart_grace_expired")

    def _contain_after_wall_timeout(self) -> None:
        self._contain("wall_timeout")

    def _observe_line(self, line: str) -> None:
        if ASSERTION_FAILURE_PATTERN.search(line):
            with self.lock:
                self.assertion_failure_seen = True

        if EXECUTION_TIMEOUT_MARKER in line:
            should_start_timer = False
            should_contain = False
            with self.lock:
                if not self.timeout_seen:
                    self.timeout_seen = True
                    should_contain = self.restart_seen
                    should_start_timer = not should_contain
            if should_contain:
                self._contain("execution_timeout_restart")
            elif should_start_timer:
                self.restart_grace_timer = threading.Timer(
                    self.restart_grace_seconds,
                    self._contain_after_restart_grace,
                )
                self.restart_grace_timer.daemon = True
                self.restart_grace_timer.start()

        if RESTART_MARKER in line:
            should_contain = False
            with self.lock:
                self.restart_seen = True
                should_contain = self.timeout_seen
            if should_contain:
                self._contain("execution_timeout_restart")

    def _relay_parent_signal(self, received_signal: int, _frame: Any) -> None:
        with self.lock:
            if not self._process_is_running():
                return
            assert self.process is not None
            try:
                self.process.send_signal(received_signal)
            except ProcessLookupError:
                return
            if received_signal == signal.SIGINT:
                if self.interrupt_grace_timer is None:
                    self.interrupt_grace_timer = threading.Timer(
                        self.interrupt_grace_seconds,
                        self._escalate_after_interrupt_grace,
                    )
                    self.interrupt_grace_timer.daemon = True
                    self.interrupt_grace_timer.start()
            else:
                self._schedule_force_kill()

    @staticmethod
    def _cancel_and_join_timer(timer: threading.Timer | None) -> None:
        if timer is None:
            return
        timer.cancel()
        if timer is not threading.current_thread():
            timer.join()

    def run(self) -> int:
        self.receipt_path.unlink(missing_ok=True)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)

        previous_handlers: dict[int, Any] = {}
        for handled_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[handled_signal] = signal.getsignal(handled_signal)
            signal.signal(handled_signal, self._relay_parent_signal)

        try:
            with self.log_path.open("wb") as log_handle:
                try:
                    self.process = subprocess.Popen(
                        self.command,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                    )
                except OSError as error:
                    print(
                        f"error: failed to launch supervised xcodebuild command: {error}",
                        file=sys.stderr,
                    )
                    return 127

                assert self.process.stdout is not None
                if self.wall_timeout_seconds is not None:
                    self.wall_timeout_timer = threading.Timer(
                        self.wall_timeout_seconds,
                        self._contain_after_wall_timeout,
                    )
                    self.wall_timeout_timer.daemon = True
                    self.wall_timeout_timer.start()
                for raw_line in iter(self.process.stdout.readline, b""):
                    sys.stdout.buffer.write(raw_line)
                    sys.stdout.buffer.flush()
                    log_handle.write(raw_line)
                    log_handle.flush()
                    self._observe_line(raw_line.decode("utf-8", errors="replace"))

                return_code = self.process.wait()
                return _shell_exit_status(return_code)
        finally:
            self._cancel_and_join_timer(self.restart_grace_timer)
            self._cancel_and_join_timer(self.interrupt_grace_timer)
            self._cancel_and_join_timer(self.force_kill_timer)
            self._cancel_and_join_timer(self.wall_timeout_timer)
            for handled_signal, previous_handler in previous_handlers.items():
                signal.signal(handled_signal, previous_handler)


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run xcodebuild with XCTest execution-timeout containment.")
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument(
        "--wall-timeout-seconds",
        help="Optional positive finite wall-clock limit for the supervised command.",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Command to supervise, after --.",
    )
    parsed = parser.parse_args(argv)
    if parsed.command and parsed.command[0] == "--":
        parsed.command = parsed.command[1:]
    if not parsed.command:
        parser.error("a command is required after --")
    return parsed


def main(argv: Sequence[str] | None = None) -> int:
    parsed = _parse_args(argv if argv is not None else sys.argv[1:])
    if parsed.log.resolve(strict=False) == parsed.receipt.resolve(strict=False):
        print("error: --log and --receipt must name different paths", file=sys.stderr)
        return 64
    try:
        restart_grace_seconds = _positive_float_from_env(
            "OPENBURNBAR_APP_TEST_TIMEOUT_RESTART_GRACE_SECONDS",
            5.0,
        )
        interrupt_grace_seconds = _positive_float_from_env(
            "OPENBURNBAR_APP_TEST_TIMEOUT_INTERRUPT_GRACE_SECONDS",
            15.0,
        )
        terminate_grace_seconds = _positive_float_from_env(
            "OPENBURNBAR_APP_TEST_TIMEOUT_TERMINATE_GRACE_SECONDS",
            5.0,
        )
        wall_timeout_seconds = (
            _positive_float(
                "--wall-timeout-seconds",
                parsed.wall_timeout_seconds,
            )
            if parsed.wall_timeout_seconds is not None
            else None
        )
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 64

    supervisor = XcodebuildSupervisor(
        parsed.command,
        parsed.log,
        parsed.receipt,
        restart_grace_seconds,
        interrupt_grace_seconds,
        terminate_grace_seconds,
        wall_timeout_seconds,
    )
    return supervisor.run()


if __name__ == "__main__":
    raise SystemExit(main())
