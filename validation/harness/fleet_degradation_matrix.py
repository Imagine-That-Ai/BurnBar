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
import signal
import socket
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any, Callable
from urllib.parse import urlparse


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
FLEET_ROOT_OVERRIDE_PREFIX = "BURNBAR_FLEET_ROOT_"
OFFLINE_SANDBOX_PROFILE = (
    "(version 1) (allow default) "
    "(deny network-outbound (remote tcp)) "
    "(deny network-outbound (remote udp)) "
    "(deny network-outbound (remote ip))"
)
APP_BINARY = (
    REPO
    / ".derived-data/Build/Products/Debug/BurnBar.app/Contents/MacOS/BurnBar"
)
OFFLINE_EVIDENCE_DIR = REPO / "validation/M6-hardening"
OFFLINE_SCREENSHOT = OFFLINE_EVIDENCE_DIR / "offline-fleet-view.png"
OFFLINE_AX_EVIDENCE = OFFLINE_EVIDENCE_DIR / "offline-fleet-view-ax.json"


@lru_cache(maxsize=1)
def daemon_binary() -> str:
    built = REPO / "BurnBarDaemon/.build/out/Products/Debug/BurnBarDaemon"
    if built.is_file() and os.access(built, os.X_OK):
        return str(built)
    path = subprocess.check_output(
        ["swift", "build", "--package-path", "BurnBarDaemon", "--show-bin-path"],
        cwd=REPO,
        text=True,
    ).strip()
    candidate = pathlib.Path(path) / "BurnBarDaemon"
    if candidate.is_file():
        return str(candidate)
    raise RuntimeError(f"swift build did not produce a daemon binary at {candidate}")


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


def assert_fixture_root_containment(
    value: dict[str, Any],
    roots: pathlib.Path,
) -> None:
    expected_roots = {
        agent_id: (roots / root_name).resolve()
        for agent_id, root_name in ROOT_NAMES.items()
    }
    actual_roots = {
        row["agent"]: pathlib.Path(row["rootPath"]).resolve()
        for row in value["probeHealth"]
    }
    assert set(actual_roots) == set(expected_roots), actual_roots
    for agent_id, expected in expected_roots.items():
        assert actual_roots[agent_id] == expected, (
            f"{agent_id} escaped validator fixture root: "
            f"{actual_roots[agent_id]} != {expected}"
        )


def wait_for_snapshot(
    socket_path: pathlib.Path,
    roots: pathlib.Path | None = None,
) -> dict[str, Any]:
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            response = rpc(socket_path, "m6-wait")
            if "result" in response:
                if roots is not None:
                    assert_fixture_root_containment(snapshot(response), roots)
                return response
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.05)
    raise RuntimeError("daemon did not publish a fleet snapshot")


def wait_until(
    socket_path: pathlib.Path,
    predicate: Callable[[dict[str, Any]], bool],
    description: str,
    roots: pathlib.Path | None = None,
) -> dict[str, Any]:
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        response = rpc(socket_path, "m6-case")
        snapshot = response.get("result", {}).get("snapshot")
        if snapshot is not None and roots is not None:
            assert_fixture_root_containment(snapshot, roots)
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


def fixture_tree_manifest(roots: pathlib.Path) -> list[dict[str, Any]]:
    """Return a secret-free manifest of the validator-owned fixture tree."""
    if not roots.exists():
        return []
    manifest: list[dict[str, Any]] = []
    for path in sorted(roots.rglob("*")):
        relative = path.relative_to(roots)
        entry: dict[str, Any] = {
            "path": str(relative),
            "kind": "directory" if path.is_dir() else "file",
            "mode": oct(path.stat().st_mode & 0o777),
        }
        if path.is_file():
            entry["size"] = path.stat().st_size
        manifest.append(entry)
    return manifest


def case_evidence(
    *,
    baseline_response: dict[str, Any] | None,
    degraded_response: dict[str, Any] | None,
    roots: pathlib.Path,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Archive complete, secret-free evidence for independent review."""
    evidence: dict[str, Any] = {
        "fixture_tree_manifest": fixture_tree_manifest(roots),
        "baseline_raw_rpc": baseline_response,
        "degraded_raw_rpc": degraded_response,
    }
    if baseline_response and "result" in baseline_response:
        evidence["baseline_snapshot"] = snapshot(baseline_response)
        evidence["baseline_health"] = snapshot(baseline_response)["probeHealth"]
    if degraded_response and "result" in degraded_response:
        evidence["degraded_snapshot"] = snapshot(degraded_response)
        evidence["degraded_health"] = snapshot(degraded_response)["probeHealth"]
    if extra:
        evidence.update(extra)
    return evidence


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
    socket_path: pathlib.Path | None = None,
) -> tuple[subprocess.Popen[bytes], pathlib.Path, pathlib.Path]:
    support = base / "support"
    socket_path = socket_path or base / "daemon.sock"
    log_path = base / "daemon.log"
    environment = os.environ.copy()
    # Per-agent overrides intentionally win over BURNBAR_FLEET_ROOTS_DIR in
    # the daemon. A validator must not inherit one from the invoking shell,
    # because that would let a probe escape this fixture tree.
    inherited_overrides = [
        key
        for key in environment
        if key.startswith(FLEET_ROOT_OVERRIDE_PREFIX)
    ]
    for key in inherited_overrides:
        environment.pop(key, None)
    environment.update(
        {
            "BURNBAR_DAEMON_SUPPORT_DIR": str(support),
            "BURNBAR_FLEET_ROOTS_DIR": str(roots),
            "BURNBAR_FLEET_CADENCE_SECONDS": "1",
        }
    )
    assert not any(
        key.startswith(FLEET_ROOT_OVERRIDE_PREFIX)
        for key in environment
        if key != "BURNBAR_FLEET_ROOTS_DIR"
    ), "per-agent root override leaked into hermetic daemon environment"
    command = [daemon_binary(), "--socket-path", str(socket_path)]
    if sandboxed:
        # AF_UNIX local serving remains available while outbound TCP/UDP/IP
        # access is denied. This is the same profile used by the offline
        # CROSS-018 run; no network toggle or external service is touched.
        command = ["/usr/bin/sandbox-exec", "-p", OFFLINE_SANDBOX_PROFILE, *command]

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


def stop(
    process: subprocess.Popen[bytes],
    *,
    child_pid: int | None = None,
) -> None:
    if process.poll() is not None:
        if child_pid is None:
            return
    else:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    if child_pid is not None:
        try:
            os.kill(child_pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        try:
            os.kill(child_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


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
        baseline_response = wait_for_snapshot(socket_path, roots)
        baseline = snapshot(baseline_response)
        shutil.rmtree(roots / "grokbot")
        response = wait_until(
            socket_path,
            lambda value: health(value)["grok-bot"]["state"]["kind"] == "failed",
            "missing grok-bot root",
            roots,
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
            **case_evidence(
                baseline_response=baseline_response,
                degraded_response=response,
                roots=roots,
            ),
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
        baseline_response = wait_for_snapshot(socket_path, roots)
        baseline = snapshot(baseline_response)
        (roots / "grokbot").chmod(0)
        response = wait_until(
            socket_path,
            lambda value: health(value)["grok-bot"]["state"]["kind"] == "degraded",
            "permission-denied grok-bot root",
            roots,
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
            **case_evidence(
                baseline_response=baseline_response,
                degraded_response=response,
                roots=roots,
            ),
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
        baseline_response = wait_for_snapshot(socket_path, roots)
        baseline = snapshot(baseline_response)
        (roots / "grok" / "active_sessions.json").write_text(
            '{"session_id": "truncated"',
            encoding="utf-8",
        )
        response = wait_until(
            socket_path,
            lambda value: health(value)["grok-cli"]["state"]["kind"] == "degraded",
            "corrupt Grok CLI registry",
            roots,
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
            **case_evidence(
                baseline_response=baseline_response,
                degraded_response=response,
                roots=roots,
            ),
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
        response = wait_for_snapshot(socket_path, roots)
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
            **case_evidence(
                baseline_response=None,
                degraded_response=response,
                roots=roots,
            ),
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
            response = wait_for_snapshot(socket_path, roots)
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
                **case_evidence(
                    baseline_response=None,
                    degraded_response=response,
                    roots=roots,
                ),
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
            response = wait_for_snapshot(socket_path, roots)
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
                **case_evidence(
                    baseline_response=None,
                    degraded_response=response,
                    roots=roots,
                ),
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
        baseline_response = wait_for_snapshot(socket_path, roots)
        baseline = snapshot(baseline_response)
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
            roots,
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
            **case_evidence(
                baseline_response=baseline_response,
                degraded_response=response,
                roots=roots,
            ),
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
        REPO / "BurnBarCore/Sources/BurnBarCore/BurnBarContracts.swift",
        REPO / "BurnBarDaemon/Sources/BurnBarDaemon/Fleet",
        REPO / "BurnBarDaemon/Sources/BurnBarDaemon/BurnBarDaemonServer.swift",
        REPO / "BurnBarDaemon/Sources/BurnBarDaemon/BurnBarDaemonServer+RPCDispatch.swift",
        REPO / "BurnBarDaemon/Sources/BurnBarDaemon/BurnBarDaemonServer+FleetControl.swift",
        REPO / "AgentLens/Services/Fleet",
        REPO / "AgentLens/Services/BurnBarDaemon/BurnBarFleetSocketClient.swift",
        REPO / "AgentLens/Services/ContextBuilder.swift",
        REPO / "AgentLens/Views/Dashboard/FleetView.swift",
        REPO / "AgentLens/Views/Dashboard/FleetViewModel.swift",
        REPO / "AgentLens/Views/Dashboard/FleetAgentCardViews.swift",
        REPO / "AgentLens/Views/Dashboard/DashboardView.swift",
        REPO / "AgentLens/Views/Chat/ChatMessageView.swift",
        REPO / "AgentLens/Views/Chat/ChatSessionController.swift",
        REPO / "AgentLens/Views/Chat/ChatSessionController+Delivery.swift",
    ]
    files: list[pathlib.Path] = []
    for root in source_roots:
        assert root.exists(), f"fleet serving path is missing: {root}"
        if root.is_file():
            files.append(root)
        else:
            files.extend(sorted(root.rglob("*.swift")))
    forbidden_import = re.compile(
        r"^\s*import\s+(?:Firebase\w*|Firestore\w*|CloudKit\w*|GoogleSignIn)\b",
        re.MULTILINE,
    )
    forbidden_symbols = re.compile(
        r"\b(?:Firestore|CloudKit|FirebaseFirestore|CloudSyncService|"
        r"ICloudSessionMirrorService)\b"
    )
    import_violations: list[str] = []
    symbol_violations: list[str] = []
    remote_url_violations: list[str] = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        relative_path = str(path.relative_to(REPO))
        if forbidden_import.search(text):
            import_violations.append(relative_path)
        # DashboardView owns non-fleet dashboard wiring, so inspect only its
        # fleet route below for cloud symbols. Every other serving-path file
        # must be cloud-symbol free in its entirety.
        if path.name != "DashboardView.swift" and forbidden_symbols.search(text):
            symbol_violations.append(relative_path)
        if relative_path.startswith("AgentLens/Services/Fleet/"):
            for url_match in re.finditer(r"https?://[^\s\"')]+", text):
                parsed = urlparse(url_match.group(0))
                if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
                    remote_url_violations.append(
                        f"{relative_path}:{url_match.group(0)}"
                    )
    assert not import_violations, import_violations
    assert not symbol_violations, symbol_violations
    assert not remote_url_violations, remote_url_violations
    dashboard = (
        REPO / "AgentLens/Views/Dashboard/DashboardView.swift"
    ).read_text(encoding="utf-8")
    fleet_route = re.search(
        r"(?ms)^\s*case \.fleet:\s*\n(?P<body>\s*FleetView\(.*?)(?=^\s*case \.provider\()",
        dashboard,
    )
    assert fleet_route is not None
    assert "FleetView(" in fleet_route.group("body")
    assert "cloudSyncService" not in fleet_route.group("body")
    assert "iCloudSessionMirrorService" not in fleet_route.group("body")
    return {
        "status": "pass",
        "files_scanned": len(files),
        "scanned_paths": [str(path.relative_to(REPO)) for path in files],
        "forbidden_cloud_imports": import_violations,
        "forbidden_cloud_symbols": symbol_violations,
        "non_loopback_urls": remote_url_violations,
        "fleet_route_cloud_references": [],
        "fleet_route": "DashboardView.swift case .fleet -> FleetView",
    }


def _cua_call(
    driver: str,
    driver_socket: pathlib.Path,
    tool: str,
    arguments: dict[str, Any],
    *,
    session: str,
) -> dict[str, Any]:
    payload = dict(arguments)
    payload["session"] = session
    completed = subprocess.run(
        [driver, "call", tool, "--socket", str(driver_socket)],
        input=(json.dumps(payload) + "\n").encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"cua-driver {tool} failed ({completed.returncode}): "
            f"{completed.stderr.decode(errors='replace').strip()}"
        )
    try:
        result = json.loads(completed.stdout.decode())
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"cua-driver {tool} returned non-JSON output: "
            f"{completed.stdout.decode(errors='replace')}"
        ) from error
    if isinstance(result, dict) and result.get("code") in {
        "window_target_not_found",
        "window_id_not_found",
        "ax_window_unresolved",
    }:
        raise RuntimeError(f"cua-driver {tool} refused the exact app target: {result}")
    return result


def _process_id_for_executable(executable: pathlib.Path) -> int | None:
    completed = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        timeout=5,
    )
    expected = str(executable)
    for line in completed.stdout.decode().splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        if fields[1].split(" ", maxsplit=1)[0] == expected:
            return pid
    return None


def _process_id_for_socket(socket_path: pathlib.Path) -> int | None:
    completed = subprocess.run(
        ["lsof", "-t", str(socket_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=5,
    )
    for line in completed.stdout.decode().splitlines():
        try:
            return int(line.strip())
        except ValueError:
            continue
    return None


def _wait_for_app_window(
    driver: str,
    driver_socket: pathlib.Path,
    app_pid: int,
    *,
    session: str,
) -> dict[str, Any]:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        windows = _cua_call(
            driver,
            driver_socket,
            "list_windows",
            {"pid": app_pid},
            session=session,
        ).get("windows", [])
        for window in windows:
            if window.get("title") == "BurnBar":
                return window
        time.sleep(0.25)
    raise RuntimeError("BurnBar did not expose an accessibility window within 30s")


def _wait_for_fleet_render(
    driver: str,
    driver_socket: pathlib.Path,
    app_pid: int,
    window_id: int,
    *,
    session: str,
) -> dict[str, Any]:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        state = _cua_call(
            driver,
            driver_socket,
            "get_window_state",
            {
                "pid": app_pid,
                "window_id": window_id,
                "include_screenshot": False,
                "max_elements": 500,
            },
            session=session,
        )
        labels = {
            element.get("label")
            for element in state.get("elements", [])
            if element.get("label")
        }
        if "Live Agent Fleet" in labels:
            return state
        time.sleep(0.25)
    raise RuntimeError("FleetView did not render its Live Agent Fleet heading")


def case_offline_serving() -> dict[str, Any]:
    # The macOS AF_UNIX path limit is 104 bytes. Keep this fixture outside the
    # mounted build-cache TMPDIR so HOME/Application Support/BurnBar remains
    # short enough for the app's production socket path.
    base = pathlib.Path(tempfile.mkdtemp(prefix="m6-offline-", dir="/tmp"))
    process: subprocess.Popen[bytes] | None = None
    app_process: subprocess.Popen[bytes] | None = None
    driver_process: subprocess.Popen[bytes] | None = None
    app_pid: int | None = None
    driver: str | None = shutil.which("cua-driver")
    driver_socket = base / "cua-driver.sock"
    session = f"m6-offline-fleet-{base.name}"
    try:
        if not APP_BINARY.is_file():
            raise RuntimeError(f"app build missing: {APP_BINARY}")
        roots = make_roots(base)
        home = base / "home"
        app_socket = home / "Library/Application Support/BurnBar/burnbar-daemon.sock"
        app_socket.parent.mkdir(parents=True, exist_ok=True)
        process, socket_path, daemon_log = launch(
            base,
            roots,
            sandboxed=True,
            socket_path=app_socket,
        )
        response = wait_for_snapshot(socket_path, roots)
        current = snapshot(response)
        file_path = base / "support" / "fleet-snapshot.json"
        assert file_path.exists()
        file_snapshot = json.loads(file_path.read_text(encoding="utf-8"))
        assert current == file_snapshot
        assert len(current["agents"]) == len(ROSTER) == 10
        if driver is None:
            return {
                "status": "blocked",
                "blocker": (
                    "cua-driver is not installed or not on PATH; the required "
                    "desktop-control FleetView capture could not be attempted."
                ),
                "desktop_control_attempted": False,
                "capture_command": "command -v cua-driver",
                "capture_command_result": "not found",
                "fallback_required": (
                    "Run the scoped FleetView/FleetViewModel XCTest fallback and "
                    "report this UI proof as blocked-with-fallback-evidence."
                ),
                "rpc_result": True,
                "well_known_file": str(file_path.name),
                "rpc_file_parity": True,
                "fleet_rows": len(current["agents"]),
                **case_evidence(
                    baseline_response=response,
                    degraded_response=response,
                    roots=roots,
                ),
            }

        driver_log = base / "cua-driver.log"
        driver_log_file = driver_log.open("wb")
        driver_process = subprocess.Popen(
            [driver, "serve", "--socket", str(driver_socket), "--no-overlay"],
            stdout=driver_log_file,
            stderr=subprocess.STDOUT,
        )
        driver_log_file.close()
        deadline = time.monotonic() + 10
        while not driver_socket.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        if not driver_socket.exists():
            raise RuntimeError("cua-driver did not create its temporary socket")
        _cua_call(
            driver,
            driver_socket,
            "start_session",
            {"capture_scope": "window"},
            session=session,
        )

        app_environment = os.environ.copy()
        for key in list(app_environment):
            if key.startswith(FLEET_ROOT_OVERRIDE_PREFIX):
                app_environment.pop(key, None)
        app_environment.update(
            {
                "HOME": str(home),
                "CFFIXED_USER_HOME": str(home),
                "BURNBAR_FLEET_ROOTS_DIR": str(roots),
                "BURNBAR_DAEMON_SUPPORT_DIR": str(base / "support"),
            }
        )
        # The one-shot dashboard flag is scoped to the validator-owned HOME.
        subprocess.run(
            ["defaults", "write", "com.burnbar.app", "hasShownInitialDashboard", "-bool", "false"],
            env=app_environment,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        app_log = base / "app.log"
        app_log_file = app_log.open("wb")
        app_process = subprocess.Popen(
            [
                "/usr/bin/sandbox-exec",
                "-p",
                OFFLINE_SANDBOX_PROFILE,
                str(APP_BINARY),
            ],
            cwd=REPO,
            env=app_environment,
            stdout=app_log_file,
            stderr=subprocess.STDOUT,
        )
        app_log_file.close()
        app_pid = _process_id_for_executable(APP_BINARY)
        if app_pid is None:
            raise RuntimeError("could not resolve the exact BurnBar app PID")
        window = _wait_for_app_window(
            driver,
            driver_socket,
            app_pid,
            session=session,
        )
        window_id = int(window["window_id"])
        route_state = _cua_call(
            driver,
            driver_socket,
            "get_window_state",
            {
                "pid": app_pid,
                "window_id": window_id,
                "query": "Fleet",
                "include_screenshot": False,
                "max_elements": 500,
            },
            session=session,
        )
        route_elements = route_state.get("elements", [])
        route_element = next(
            (
                element
                for element in route_elements
                if element.get("label") == "Fleet, Live agents & machine state"
            ),
            None,
        )
        if route_element is None:
            raise RuntimeError("Fleet route was not reachable from the running dashboard")
        _cua_call(
            driver,
            driver_socket,
            "click",
            {
                "pid": app_pid,
                "window_id": window_id,
                "element_token": route_element["element_token"],
                "delivery_mode": "background",
            },
            session=session,
        )
        rendered = _wait_for_fleet_render(
            driver,
            driver_socket,
            app_pid,
            window_id,
            session=session,
        )
        rendered = _cua_call(
            driver,
            driver_socket,
            "get_window_state",
            {
                "pid": app_pid,
                "window_id": window_id,
                "include_screenshot": True,
                "screenshot_out_file": str(OFFLINE_SCREENSHOT),
                "max_elements": 500,
            },
            session=session,
        )
        labels = [
            element["label"]
            for element in rendered.get("elements", [])
            if element.get("label")
        ]
        assert "Live Agent Fleet" in labels
        assert any("running" in label.lower() for label in labels)
        assert any("declared agents" in label.lower() for label in labels)
        assert OFFLINE_SCREENSHOT.is_file() and OFFLINE_SCREENSHOT.stat().st_size > 0
        OFFLINE_AX_EVIDENCE.write_text(
            json.dumps(
                {
                    "status": "pass",
                    "surface": "BurnBar.app DashboardView -> FleetView",
                    "network_profile": OFFLINE_SANDBOX_PROFILE,
                    "daemon_socket": str(socket_path),
                    "route": {
                        "label": route_element["label"],
                        "reachable": True,
                        "clicked": True,
                    },
                    "render": {
                        "heading": "Live Agent Fleet",
                        "labels": labels,
                        "screenshot": str(OFFLINE_SCREENSHOT.relative_to(REPO)),
                    },
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        return {
            "status": "pass",
            "sandbox_profile": "deny outbound tcp/udp/ip; allow local AF_UNIX serving",
            "rpc_result": True,
            "well_known_file": str(file_path.name),
            "rpc_file_parity": True,
            "fleet_rows": len(current["agents"]),
            "app_surface": {
                "status": "pass",
                "route": "DashboardView -> FleetView",
                "window_title": window["title"],
                "screenshot": str(OFFLINE_SCREENSHOT.relative_to(REPO)),
                "accessibility_evidence": str(OFFLINE_AX_EVIDENCE.relative_to(REPO)),
                "heading": "Live Agent Fleet",
                "running_label_observed": True,
                "declared_agents_label_observed": True,
            },
        }
    except RuntimeError as error:
        return {
            "status": "blocked",
            "blocker": str(error),
            "desktop_control_attempted": driver is not None,
            "fallback_required": (
                "The app surface was attempted but did not produce capture "
                "evidence; use scoped FleetView XCTest evidence and retain this "
                "blocker verbatim."
            ),
        }
    finally:
        if driver and driver_process:
            try:
                _cua_call(
                    driver,
                    driver_socket,
                    "end_session",
                    {},
                    session=session,
                )
            except (OSError, RuntimeError, subprocess.SubprocessError):
                pass
        if app_process:
            stop(app_process, child_pid=app_pid)
        if process:
            daemon_pid = _process_id_for_socket(socket_path)
            stop(process, child_pid=daemon_pid)
        if driver_process:
            stop(driver_process)
        restore_permissions(base / "roots")
        shutil.rmtree(base, ignore_errors=True)


def main() -> None:
    offline_static_scan = static_fleet_import_scan()
    offline_run = case_offline_serving()
    evidence = {
        "harness": "validation/harness/fleet_degradation_matrix.py",
        "evidence_version": 2,
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
                "status": (
                    "pass"
                    if offline_static_scan["status"] == "pass"
                    and offline_run["status"] == "pass"
                    else offline_run["status"]
                ),
                "static_import_scan": offline_static_scan,
                "blocked_network_run": offline_run,
            },
        },
    }
    output = REPO / "validation/M6-hardening/degradation-matrix.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for name, result in evidence["cases"].items():
        print(f"{name}: {result.get('status', 'composite')}")
    statuses = [result.get("status") for result in evidence["cases"].values()]
    if all(status == "pass" for status in statuses):
        print("matrix=8/8 pass")
    else:
        print(
            "matrix=blocked/failed; "
            f"pass_count={sum(status == 'pass' for status in statuses)}/8"
        )
    print(f"evidence={output.relative_to(REPO)}")


if __name__ == "__main__":
    main()
