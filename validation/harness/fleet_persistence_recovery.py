"""Hermetic M6 fleet persistence recovery harness.

This harness owns its temporary support directory, fixture roots, sockets, and
daemon processes. It exercises:

* corruption and partial-schema recovery;
* fleet.sqlite deletion across a daemon restart;
* fleet.sqlite deletion while the daemon is running;
* read-only support-directory serving;
* SIGKILL/torn-write recovery and orphaned temporary files.

It never reads real agent roots, the user's BurnBar support directory, or
``~/.factory/artifacts``. Evidence is written to
``validation/M6-hardening/persistence-recovery.json``.
"""

from __future__ import annotations

import json
import os
import pathlib
import signal
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
from typing import Any, Callable


REPO = pathlib.Path(__file__).resolve().parents[2]
ROSTER_ROOTS = (
    "claude",
    "factory",
    "codex",
    "hermes",
    "grokbot",
    "grok",
    "pi",
    "cursor",
    "kimi",
    "gemini",
)


def daemon_binary() -> pathlib.Path:
    path = subprocess.check_output(
        ["swift", "build", "--package-path", "BurnBarDaemon", "--show-bin-path"],
        cwd=REPO,
        text=True,
    ).strip()
    return pathlib.Path(path) / "BurnBarDaemon"


def rpc(socket_path: pathlib.Path, request: dict[str, Any]) -> dict[str, Any]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3)
    try:
        client.connect(str(socket_path))
        client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        response = bytearray()
        while True:
            chunk = client.recv(65_536)
            if not chunk:
                break
            response.extend(chunk)
            if response.endswith(b"\n"):
                break
        return json.loads(response.decode().strip())
    finally:
        client.close()


def snapshot(socket_path: pathlib.Path, request_id: str = "m6-recovery") -> dict[str, Any] | None:
    response = rpc(
        socket_path,
        {"id": request_id, "method": "daemon.fleet.snapshot"},
    )
    return response.get("result", {}).get("snapshot")


def wait_for_snapshot(
    socket_path: pathlib.Path,
    predicate: Callable[[dict[str, Any]], bool] | None = None,
    timeout: float = 8,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = snapshot(socket_path)
            if value is not None and (predicate is None or predicate(value)):
                return value
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.05)
    raise RuntimeError("timed out waiting for fleet snapshot")


def launch(
    base: pathlib.Path,
    binary: pathlib.Path,
    *,
    support: pathlib.Path | None = None,
    cadence: int = 1,
) -> tuple[subprocess.Popen[bytes], pathlib.Path, pathlib.Path]:
    support = support or base / "support"
    socket_path = base / "daemon.sock"
    log_path = base / "daemon.log"
    environment = os.environ.copy()
    environment.update(
        {
            "BURNBAR_DAEMON_SUPPORT_DIR": str(support),
            "BURNBAR_FLEET_ROOTS_DIR": str(base / "roots"),
            "BURNBAR_FLEET_CADENCE_SECONDS": str(cadence),
        }
    )
    log_file = log_path.open("ab")
    process = subprocess.Popen(
        [str(binary), "--socket-path", str(socket_path)],
        cwd=REPO,
        env=environment,
        stdout=log_file,
        stderr=subprocess.STDOUT,
    )
    log_file.close()
    return process, socket_path, log_path


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=4)


def kill_owned(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        os.kill(process.pid, signal.SIGKILL)
    process.wait(timeout=4)


def make_roots(base: pathlib.Path) -> pathlib.Path:
    roots = base / "roots"
    for name in ROSTER_ROOTS:
        (roots / name).mkdir(parents=True, exist_ok=True)
    (roots / "grok" / "active_sessions.json").write_text("[]", encoding="utf-8")
    (roots / "factory" / "task-invocations.json").write_text(
        '{"invocations":[]}', encoding="utf-8"
    )
    (roots / "factory" / "background-processes.json").write_text(
        '{"processes":[]}', encoding="utf-8"
    )
    return roots


def health_kind(value: dict[str, Any]) -> str:
    return value["persistenceHealth"]["kind"]


def health_reason(value: dict[str, Any]) -> str:
    return value["persistenceHealth"].get("reason", "")


def set_designation(socket_path: pathlib.Path) -> dict[str, Any]:
    return rpc(
        socket_path,
        {
            "id": "m6-designate",
            "method": "daemon.fleet.orchestrator.set",
            "params": {
                "state": {"designation": {"kind": "burnBarManaged"}},
            },
        },
    )


def get_designation(socket_path: pathlib.Path) -> dict[str, Any]:
    return rpc(
        socket_path,
        {"id": "m6-get-designation", "method": "daemon.fleet.orchestrator.get"},
    )


def case_corruption_and_schema(binary: pathlib.Path) -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-recovery-schema-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        make_roots(base)
        support = base / "support"
        support.mkdir()
        store = support / "fleet.sqlite"
        store.write_bytes(b"not a sqlite database")
        process, socket_path, _ = launch(base, binary)
        first = wait_for_snapshot(socket_path, lambda value: health_kind(value) == "degraded")
        assert "rebuilt" in health_reason(first)
        second = wait_for_snapshot(
            socket_path,
            lambda value: health_kind(value) == "ok",
        )
        stop(process)
        process = None

        # An older store with user_version 0 and only an early snapshot table
        # models a pre-v1 schema. The daemon must migrate or rebuild it typed,
        # not crash or read the wrong schema. This fixture intentionally
        # chooses the documented rebuild path.
        store.unlink()
        with sqlite3.connect(store) as connection:
            connection.execute(
                "CREATE TABLE fleet_snapshots ("
                "id INTEGER PRIMARY KEY, generated_at REAL, payload TEXT"
                ")"
            )
            connection.execute("PRAGMA user_version = 0")
            connection.commit()
        process, socket_path, _ = launch(base, binary)
        schema_recovery = wait_for_snapshot(
            socket_path,
            lambda value: health_kind(value) == "degraded",
        )
        assert "rebuilt" in health_reason(schema_recovery)
        assert "schema mismatch" in health_reason(schema_recovery)
        schema_ok = wait_for_snapshot(socket_path, lambda value: health_kind(value) == "ok")
        with sqlite3.connect(f"file:{store}?mode=ro", uri=True) as connection:
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
        expected = {
            "fleet_snapshots",
            "fleet_events",
            "orchestrator_state",
            "fleet_directives",
        }
        assert expected.issubset(tables)
        return {
            "status": "pass",
            "corruption": {
                "first_health": first["persistenceHealth"],
                "recovered_health": second["persistenceHealth"],
            },
            "schema_version_mismatch": {
                "first_health": schema_recovery["persistenceHealth"],
                "recovered_health": schema_ok["persistenceHealth"],
                "required_tables_present": sorted(expected),
            },
        }
    finally:
        if process is not None:
            stop(process)
        shutil.rmtree(base, ignore_errors=True)


def case_delete_while_running(binary: pathlib.Path) -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-recovery-delete-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        make_roots(base)
        process, socket_path, _ = launch(base, binary)
        before = wait_for_snapshot(socket_path)
        designated = set_designation(socket_path)
        assert designated.get("result", {}).get("state", {}).get(
            "designation", {}
        ).get("kind") == "burnBarManaged"
        designated_state = get_designation(socket_path)["result"]["state"]
        assert designated_state["designation"]["kind"] == (
            "burnBarManaged"
        )
        store = base / "support" / "fleet.sqlite"
        store.unlink()
        during = wait_for_snapshot(
            socket_path,
            lambda value: health_kind(value) == "degraded"
            and "rebuilt" in health_reason(value),
        )
        assert during["orchestrator"]["designation"]["kind"] == "none"
        assert store.exists()
        after = wait_for_snapshot(
            socket_path,
            lambda value: health_kind(value) == "ok"
            and value["generatedAt"] != during["generatedAt"],
        )
        assert after["orchestrator"]["designation"]["kind"] == "none"
        return {
            "status": "pass",
            "before": {
                "generatedAt": before["generatedAt"],
                "designation": designated_state["designation"],
            },
            "during_rebuild": {
                "persistenceHealth": during["persistenceHealth"],
                "designation": during["orchestrator"]["designation"],
            },
            "after": {
                "generatedAt": after["generatedAt"],
                "persistenceHealth": after["persistenceHealth"],
                "designation": after["orchestrator"]["designation"],
            },
        }
    finally:
        if process is not None:
            stop(process)
        shutil.rmtree(base, ignore_errors=True)


def case_delete_after_restart(binary: pathlib.Path) -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-recovery-restart-delete-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        make_roots(base)
        process, socket_path, _ = launch(base, binary)
        before = wait_for_snapshot(socket_path)
        designated = set_designation(socket_path)
        assert designated.get("result", {}).get("state", {}).get(
            "designation", {}
        ).get("kind") == "burnBarManaged"
        designated_state = get_designation(socket_path)["result"]["state"]
        assert designated_state["designation"]["kind"] == "burnBarManaged"
        stop(process)
        process = None

        store = base / "support" / "fleet.sqlite"
        store.unlink()
        process, socket_path, _ = launch(base, binary)
        during = wait_for_snapshot(
            socket_path,
            lambda value: health_kind(value) == "degraded"
            and "rebuilt" in health_reason(value),
        )
        assert during["orchestrator"]["designation"]["kind"] == "none"
        assert store.exists()
        after = wait_for_snapshot(
            socket_path,
            lambda value: health_kind(value) == "ok"
            and value["generatedAt"] != during["generatedAt"],
        )
        assert after["orchestrator"]["designation"]["kind"] == "none"
        return {
            "status": "pass",
            "before": {
                "generatedAt": before["generatedAt"],
                "designation": designated_state["designation"],
            },
            "during_rebuild": {
                "persistenceHealth": during["persistenceHealth"],
                "designation": during["orchestrator"]["designation"],
            },
            "after": {
                "generatedAt": after["generatedAt"],
                "persistenceHealth": after["persistenceHealth"],
                "designation": after["orchestrator"]["designation"],
            },
        }
    finally:
        if process is not None:
            stop(process)
        shutil.rmtree(base, ignore_errors=True)


def case_read_only(binary: pathlib.Path) -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-recovery-readonly-"))
    process: subprocess.Popen[bytes] | None = None
    support = base / "support"
    try:
        make_roots(base)
        support.mkdir()
        support.chmod(0o555)
        read_only_mode = oct(support.stat().st_mode & 0o777)
        process, socket_path, _ = launch(base, binary, support=support)
        value = wait_for_snapshot(socket_path, lambda current: health_kind(current) == "degraded")
        assert value["agents"] and len(value["agents"]) == 10
        assert "persistenceHealth" in value
        support.chmod(0o700)
        recovered = wait_for_snapshot(socket_path, lambda current: health_kind(current) == "ok")
        return {
            "status": "pass",
            "mode": read_only_mode,
            "persistenceHealth": value["persistenceHealth"],
            "agentCount": len(value["agents"]),
            "recoveredHealth": recovered["persistenceHealth"],
        }
    finally:
        support.chmod(0o700)
        if process is not None:
            stop(process)
        shutil.rmtree(base, ignore_errors=True)


def case_sigkill_torn_writes(binary: pathlib.Path) -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-recovery-torn-"))
    process: subprocess.Popen[bytes] | None = None
    attempts: list[dict[str, Any]] = []
    try:
        make_roots(base)
        process, socket_path, _ = launch(base, binary)
        wait_for_snapshot(socket_path)
        stop(process)
        process = None
        file_path = base / "support" / "fleet-snapshot.json"
        last_good = file_path.read_bytes()

        # Kill during several distinct startup/tick offsets. The write window
        # is intentionally tiny; each outcome must leave either the preceding
        # or the next complete generation, never a truncated destination.
        for index, delay in enumerate((0.0001, 0.0005, 0.001, 0.003, 0.01, 0.03)):
            process, socket_path, _ = launch(base, binary)
            time.sleep(delay)
            kill_owned(process)
            process = None
            destination = file_path.read_bytes()
            decoded = json.loads(destination.decode("utf-8"))
            assert decoded["schemaVersion"] == 1
            attempts.append(
                {
                    "attempt": index + 1,
                    "killDelaySeconds": delay,
                    "destinationBytes": len(destination),
                    "destinationGeneratedAt": decoded["generatedAt"],
                    "destinationWasPriorComplete": destination == last_good,
                }
            )

        # Plant a deliberately truncated orphan and prove the next completed
        # tick ignores/overwrites it rather than promoting it.
        temporary = base / "support" / "fleet-snapshot.json.tmp"
        temporary.write_text('{"schemaVersion":1,"agents":"truncated"', encoding="utf-8")
        process, socket_path, _ = launch(base, binary)
        completed = wait_for_snapshot(socket_path)
        stop(process)
        process = None
        destination = file_path.read_bytes()
        json.loads(destination.decode("utf-8"))
        assert completed["generatedAt"]
        assert not temporary.exists()
        return {
            "status": "pass",
            "attempts": attempts,
            "orphanTemporaryPromoted": False,
            "lastGoodBytes": len(last_good),
        }
    finally:
        if process is not None:
            if process.poll() is None:
                kill_owned(process)
        shutil.rmtree(base, ignore_errors=True)


def main() -> None:
    binary = daemon_binary()
    evidence = {
        "harness": "validation/harness/fleet_persistence_recovery.py",
        "cadenceSeconds": 1,
        "status": "pass",
        "cases": {
            "corruption_and_schema_mismatch": case_corruption_and_schema(binary),
            "delete_after_restart": case_delete_after_restart(binary),
            "delete_while_running": case_delete_while_running(binary),
            "read_only_support": case_read_only(binary),
            "sigkill_torn_writes": case_sigkill_torn_writes(binary),
        },
    }
    output = REPO / "validation" / "M6-hardening" / "persistence-recovery.json"
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
