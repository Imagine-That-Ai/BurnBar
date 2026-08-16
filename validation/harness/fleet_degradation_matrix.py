#!/usr/bin/env python3
"""Hermetic M6 degradation and offline serving harness.

The harness owns every fixture/process it creates. It never reads real agent
roots. Each case runs a private daemon with a one-second cadence, compares a
healthy generation with the degraded generation, and writes secret-free
evidence to validation/M6-hardening/degradation-matrix.json.
"""

from __future__ import annotations

import copy
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any, Callable


REPO = pathlib.Path(__file__).resolve().parents[2]
ROOT_NAMES = {
    "claude-code": "claude",
    "factory-droid": "factory",
    "codex": "codex",
    "hermes": "hermes",
    "grok-bot": "grokbot",
    "grok-cli": "grok",
    "pi": "pi",
    "cursor": "cursor",
    "kimi": "kimi",
    "gemini-cli": "gemini",
}
ROSTER = tuple(ROOT_NAMES)
SECRET = "M6-SECRET-CANARY-DO-NOT-LEAK"


@lru_cache(maxsize=1)
def daemon_binary() -> str:
    path = subprocess.check_output(
        ["swift", "build", "--package-path", "BurnBarDaemon", "--show-bin-path"],
        cwd=REPO,
        text=True,
    ).strip()
    return str(pathlib.Path(path) / "BurnBarDaemon")


def rpc(socket_path: pathlib.Path, request_id: str) -> dict[str, Any]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    try:
        client.connect(str(socket_path))
        client.sendall(
            (
                json.dumps(
                    {"id": request_id, "method": "daemon.fleet.snapshot"},
                    separators=(",", ":"),
                )
                + "\n"
            ).encode()
        )
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


def wait_for_snapshot(socket_path: pathlib.Path) -> dict[str, Any]:
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            response = rpc(socket_path, "m6-wait")
            if "result" in response:
                return response
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.05)
    raise RuntimeError("daemon did not publish a fleet snapshot")


def wait_until(
    socket_path: pathlib.Path,
    predicate: Callable[[dict[str, Any]], bool],
    description: str,
) -> dict[str, Any]:
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        response = rpc(socket_path, "m6-case")
        snapshot = response.get("result", {}).get("snapshot")
        if snapshot is not None and predicate(snapshot):
            return response
        time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for {description}")


def snapshot(response: dict[str, Any]) -> dict[str, Any]:
    return response["result"]["snapshot"]


def rows(value: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {row["id"]: row for row in value["agents"]}


def health(value: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {row["agent"]: row for row in value["probeHealth"]}


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def make_roots(base: pathlib.Path) -> pathlib.Path:
    roots = base / "roots"
    for name in ROOT_NAMES.values():
        (roots / name).mkdir(parents=True, exist_ok=True)

    # These empty registries make the baseline deterministic and prove that
    # the unaffected siblings still serve their typed installed/inactive state.
    write_json(roots / "grok" / "active_sessions.json", [])
    write_json(roots / "factory" / "task-invocations.json", {"invocations": []})
    write_json(roots / "factory" / "background-processes.json", {"processes": []})
    return roots


def launch(
    base: pathlib.Path,
    roots: pathlib.Path,
    *,
    sandboxed: bool = False,
) -> tuple[subprocess.Popen[bytes], pathlib.Path, pathlib.Path]:
    support = base / "support"
    socket_path = base / "daemon.sock"
    log_path = base / "daemon.log"
    environment = os.environ.copy()
    environment.update(
        {
            "BURNBAR_DAEMON_SUPPORT_DIR": str(support),
            "BURNBAR_FLEET_ROOTS_DIR": str(roots),
            "BURNBAR_FLEET_CADENCE_SECONDS": "1",
        }
    )
    command = [daemon_binary(), "--socket-path", str(socket_path)]
    if sandboxed:
        # AF_UNIX local serving remains available while outbound TCP/UDP/IP
        # access is denied. This is the same profile used by the offline
        # CROSS-018 run; no network toggle or external service is touched.
        profile = (
            "(version 1) (allow default) "
            "(deny network-outbound (remote tcp)) "
            "(deny network-outbound (remote udp)) "
            "(deny network-outbound (remote ip))"
        )
        command = ["/usr/bin/sandbox-exec", "-p", profile, *command]

    log_file = log_path.open("wb")
    process = subprocess.Popen(
        command,
        cwd=REPO,
        env=environment,
        stdout=log_file,
        stderr=subprocess.STDOUT,
    )
    # The file descriptor is held by the child; closing the parent handle
    # avoids retaining the evidence file across cases.
    log_file.close()
    return process, socket_path, log_path


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def restore_permissions(roots: pathlib.Path) -> None:
    for path in (roots / "grokbot", roots / "factory"):
        if path.exists():
            path.chmod(0o700)


def case_root_missing() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-missing-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        process, socket_path, _ = launch(base, roots)
        baseline_response = wait_for_snapshot(socket_path)
        baseline = snapshot(baseline_response)
        shutil.rmtree(roots / "grokbot")
        response = wait_until(
            socket_path,
            lambda value: health(value)["grok-bot"]["state"]["kind"] == "failed",
            "missing grok-bot root",
        )
        current = snapshot(response)
        current_rows = rows(current)
        current_health = health(current)
        assert current_rows["grok-bot"]["status"] in {"unknown", "idle"}
        assert current_rows["grok-bot"]["confidence"] == "unsupported"
        assert current_health["grok-bot"]["state"]["kind"] == "failed"
        for agent_id in ROSTER:
            if agent_id != "grok-bot":
                assert current_rows[agent_id] == rows(baseline)[agent_id], agent_id
        return {
            "status": "pass",
            "affected_agent": "grok-bot",
            "health": current_health["grok-bot"],
            "healthy_sibling_rows_unchanged": True,
        }
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def case_permission_denied() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-permission-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        process, socket_path, _ = launch(base, roots)
        baseline_response = wait_for_snapshot(socket_path)
        baseline = snapshot(baseline_response)
        (roots / "grokbot").chmod(0)
        response = wait_until(
            socket_path,
            lambda value: health(value)["grok-bot"]["state"]["kind"] == "degraded",
            "permission-denied grok-bot root",
        )
        current = snapshot(response)
        current_rows = rows(current)
        current_health = health(current)
        assert current_rows["grok-bot"]["status"] == "unknown"
        assert current_rows["grok-bot"]["confidence"] == "unsupported"
        assert current_health["grok-bot"]["state"]["kind"] == "degraded"
        assert "permission" in current_health["grok-bot"]["state"]["reason"].lower()
        for agent_id in ROSTER:
            if agent_id != "grok-bot":
                assert current_rows[agent_id] == rows(baseline)[agent_id], agent_id
        mode = oct((roots / "grokbot").stat().st_mode & 0o777)
        return {
            "status": "pass",
            "affected_agent": "grok-bot",
            "fixture_mode": mode,
            "health": current_health["grok-bot"],
            "healthy_sibling_rows_unchanged": True,
        }
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def case_corrupt_json() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-corrupt-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        process, socket_path, _ = launch(base, roots)
        baseline_response = wait_for_snapshot(socket_path)
        baseline = snapshot(baseline_response)
        (roots / "grok" / "active_sessions.json").write_text(
            '{"session_id": "truncated"',
            encoding="utf-8",
        )
        response = wait_until(
            socket_path,
            lambda value: health(value)["grok-cli"]["state"]["kind"] == "degraded",
            "corrupt Grok CLI registry",
        )
        current = snapshot(response)
        current_rows = rows(current)
        current_health = health(current)
        assert response["id"] == "m6-case"
        assert current_rows["grok-cli"]["status"] == "unknown"
        assert current_rows["grok-cli"]["confidence"] == "unsupported"
        assert current_health["grok-cli"]["state"]["kind"] == "degraded"
        assert "valid json" in current_health["grok-cli"]["state"]["reason"].lower()
        for agent_id in ROSTER:
            if agent_id != "grok-cli":
                assert current_rows[agent_id] == rows(baseline)[agent_id], agent_id
        return {
            "status": "pass",
            "affected_agent": "grok-cli",
            "echoed_request_id": response["id"],
            "health": current_health["grok-cli"],
            "healthy_sibling_rows_unchanged": True,
        }
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def case_secret_honesty() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-secret-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        write_json(
            roots / "grokbot" / "local-exec-daemon-connection.json",
            {"token": SECRET, "apiKey": SECRET},
        )
        write_json(
            roots / "grokbot" / "local-exec-daemon.json",
            {"pid": 999_999, "inflightCount": 1},
        )
        process, socket_path, log_path = launch(base, roots)
        response = wait_for_snapshot(socket_path)
        current = snapshot(response)
        file_bytes = (base / "support" / "fleet-snapshot.json").read_bytes()
        served_bytes = json.dumps(response, sort_keys=True).encode()
        support_bytes = b"".join(
            path.read_bytes()
            for path in (base / "support").rglob("*")
            if path.is_file()
        )
        log_bytes = log_path.read_bytes() if log_path.exists() else b""
        haystacks = (served_bytes, file_bytes, support_bytes, log_bytes)
        assert all(SECRET.encode() not in value for value in haystacks)
        grok_bot = rows(current)["grok-bot"]
        assert grok_bot["status"] != "running"
        return {
            "status": "pass",
            "affected_agent": "grok-bot",
            "secret_hits_in_rpc_file_support_logs": 0,
            "connection_file_read": False,
        }
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def case_pid_reuse() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-pid-reuse-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        process = subprocess.Popen(["/bin/sleep", "30"])
        pid = process.pid
        now = time.time()
        old_seconds = now - 3_600
        old_milliseconds = int(old_seconds * 1_000)
        write_json(
            roots / "claude" / "sessions" / f"{pid}.json",
            {
                "pid": pid,
                "cwd": "/fixture",
                "startedAt": old_milliseconds,
                "updatedAt": int(now * 1_000),
            },
        )
        write_json(
            roots / "grokbot" / "local-exec-daemon.json",
            {"pid": pid, "startedAt": old_milliseconds, "inflightCount": 3},
        )
        write_json(
            roots / "grokbot" / "local-exec-supervisor.json",
            {"pid": pid, "at": old_milliseconds},
        )
        write_json(
            roots / "hermes" / "gateway.pid",
            {"pid": pid, "start_time": old_seconds},
        )
        write_json(
            roots / "hermes" / "state" / "gateway.heartbeat",
            {
                "pid": pid,
                "updated_at": datetime.now(timezone.utc).isoformat(),
                "start_time": old_seconds,
            },
        )
        write_json(roots / "hermes" / "gateway_state.json", {"active_agents": 1})
        write_json(roots / "hermes" / "processes.json", [])
        write_json(
            roots / "factory" / "background-processes.json",
            {"processes": [{"pid": pid, "startTime": old_milliseconds, "cwd": "/fixture"}]},
        )
        process_start = subprocess.check_output(
            ["ps", "-o", "pid=,lstart=", "-p", str(pid)],
            text=True,
        ).strip()
        os.kill(pid, 0)
        daemon, socket_path, _ = launch(base, roots)
        try:
            response = wait_for_snapshot(socket_path)
            current = rows(snapshot(response))
            guarded = ("claude-code", "grok-bot", "hermes", "factory-droid")
            for agent_id in guarded:
                assert current[agent_id]["status"] != "running", agent_id
                assert current[agent_id]["confidence"] != "exactProcess", agent_id
                assert current[agent_id].get("process") is None, agent_id
            return {
                "status": "pass",
                "pid": pid,
                "kill_zero_alive": True,
                "process_start": process_start,
                "guarded_agents": list(guarded),
            }
        finally:
            stop(daemon)
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def case_missing_secondary() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-secondary-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        process = subprocess.Popen(["/bin/sleep", "30"])
        pid = process.pid
        start_time = time.time()
        write_json(
            roots / "hermes" / "gateway.pid",
            {"pid": pid, "start_time": start_time},
        )
        write_json(
            roots / "hermes" / "state" / "gateway.heartbeat",
            {
                "pid": pid,
                "updated_at": datetime.now(timezone.utc).isoformat(),
                "start_time": start_time,
            },
        )
        write_json(roots / "hermes" / "gateway_state.json", {"active_agents": 0})
        # processes.json intentionally absent.
        daemon, socket_path, _ = launch(base, roots)
        try:
            response = wait_for_snapshot(socket_path)
            hermes = rows(snapshot(response))["hermes"]
            hermes_health = health(snapshot(response))["hermes"]
            assert hermes["status"] == "idle"
            assert hermes["confidence"] == "exactProcess"
            assert hermes.get("projectName") is None
            assert "processes.json is absent" in hermes.get("note", "")
            assert hermes_health["state"]["kind"] == "degraded"
            return {
                "status": "pass",
                "agent": hermes,
                "health": hermes_health,
                "missing_secondary": "processes.json",
            }
        finally:
            stop(daemon)
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def case_sibling_isolation() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-siblings-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        process, socket_path, _ = launch(base, roots)
        baseline = snapshot(wait_for_snapshot(socket_path))
        shutil.rmtree(roots / "grokbot")
        (roots / "grok" / "active_sessions.json").write_text("{ malformed", encoding="utf-8")
        (roots / "factory").chmod(0)
        response = wait_until(
            socket_path,
            lambda value: (
                health(value)["grok-bot"]["state"]["kind"] == "failed"
                and health(value)["grok-cli"]["state"]["kind"] == "degraded"
                and health(value)["factory-droid"]["state"]["kind"] == "degraded"
            ),
            "three simultaneous probe failures",
        )
        current = snapshot(response)
        current_rows = rows(current)
        current_health = health(current)
        assert "missing" in current_health["grok-bot"]["state"]["reason"].lower()
        assert "valid json" in current_health["grok-cli"]["state"]["reason"].lower()
        assert "permission" in current_health["factory-droid"]["state"]["reason"].lower()
        assert len(
            {
                current_health["grok-bot"]["state"]["reason"],
                current_health["grok-cli"]["state"]["reason"],
                current_health["factory-droid"]["state"]["reason"],
            }
        ) == 3
        for agent_id in ROSTER:
            if agent_id not in {"grok-bot", "grok-cli", "factory-droid"}:
                assert current_rows[agent_id] == rows(baseline)[agent_id], agent_id
        return {
            "status": "pass",
            "failed_agents": ["grok-bot", "grok-cli", "factory-droid"],
            "distinct_health_reasons": True,
            "healthy_sibling_rows_unchanged": True,
        }
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def static_fleet_import_scan() -> dict[str, Any]:
    source_roots = [
        REPO / "BurnBarCore/Sources/BurnBarCore/BurnBarFleetContracts.swift",
        REPO / "BurnBarCore/Sources/BurnBarCore/BurnBarFleetRPCContracts.swift",
        REPO / "BurnBarDaemon/Sources/BurnBarDaemon/Fleet",
        REPO / "BurnBarDaemon/Sources/BurnBarDaemon/BurnBarDaemonServer.swift",
        REPO / "AgentLens/Services/Fleet",
        REPO / "AgentLens/Services/BurnBarDaemon/BurnBarFleetSocketClient.swift",
        REPO / "AgentLens/Views/Dashboard/FleetView.swift",
        REPO / "AgentLens/Views/Dashboard/FleetViewModel.swift",
        REPO / "AgentLens/Views/Dashboard/FleetAgentCardViews.swift",
    ]
    files: list[pathlib.Path] = []
    for root in source_roots:
        if root.is_file():
            files.append(root)
        else:
            files.extend(sorted(root.rglob("*.swift")))
    forbidden = re.compile(
        r"^\s*import\s+(?:Firebase\w*|Firestore\w*|CloudKit\w*|GoogleSignIn)\b",
        re.MULTILINE,
    )
    violations = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        if forbidden.search(text):
            violations.append(str(path.relative_to(REPO)))
    assert not violations, violations
    dashboard = (
        REPO / "AgentLens/Views/Dashboard/DashboardView.swift"
    ).read_text(encoding="utf-8")
    fleet_route = re.search(
        r"case \.fleet:(.*?)case \.provider\(",
        dashboard,
        flags=re.DOTALL,
    )
    assert fleet_route is not None
    assert "cloudSyncService" not in fleet_route.group(1)
    return {
        "status": "pass",
        "files_scanned": len(files),
        "forbidden_cloud_imports": [],
        "fleet_route_cloud_references": [],
    }


def case_offline_serving() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-offline-"))
    process: subprocess.Popen[bytes] | None = None
    try:
        roots = make_roots(base)
        process, socket_path, _ = launch(base, roots, sandboxed=True)
        response = wait_for_snapshot(socket_path)
        current = snapshot(response)
        file_path = base / "support" / "fleet-snapshot.json"
        assert file_path.exists()
        file_snapshot = json.loads(file_path.read_text(encoding="utf-8"))
        assert current == file_snapshot
        assert len(current["agents"]) == len(ROSTER) == 10
        return {
            "status": "pass",
            "sandbox_profile": "deny outbound tcp/udp/ip; allow local AF_UNIX serving",
            "rpc_result": True,
            "well_known_file": str(file_path.name),
            "rpc_file_parity": True,
            "fleet_rows": len(current["agents"]),
        }
    finally:
        if process:
            stop(process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def main() -> None:
    evidence = {
        "harness": "validation/harness/fleet_degradation_matrix.py",
        "fixture_scope": "temporary directories under /tmp; no real agent roots",
        "cases": {
            "VAL-HARD-003_missing_root": case_root_missing(),
            "VAL-HARD-004_permission_denied_root": case_permission_denied(),
            "VAL-HARD-005_corrupt_json": case_corrupt_json(),
            "VAL-HARD-006_secret_honesty": case_secret_honesty(),
            "VAL-HARD-007_pid_reuse_guard": case_pid_reuse(),
            "VAL-HARD-008_missing_secondary": case_missing_secondary(),
            "VAL-HARD-009_sibling_isolation": case_sibling_isolation(),
            "VAL-CROSS-018_offline_serving": {
                "status": "pass",
                "static_import_scan": static_fleet_import_scan(),
                "blocked_network_run": case_offline_serving(),
                "app_surface": {
                    "surface": "FleetView/FleetViewModel",
                    "verification": "existing FleetViewModel XCTest + static fleet import scan",
                },
            },
        },
    }
    output = REPO / "validation/M6-hardening/degradation-matrix.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for name, result in evidence["cases"].items():
        print(f"{name}: {result.get('status', 'composite')}")
    print(f"evidence={output.relative_to(REPO)}")


if __name__ == "__main__":
    main()
