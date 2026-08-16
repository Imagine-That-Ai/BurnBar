#!/usr/bin/env python3
"""Hermetic M6 soak, logging, boundary, and liveness proof.

This harness owns its temporary roots, support directory, daemon, log
collector, canary, and scratch files. It never reads a real agent root or
``~/.factory/artifacts``. The factory artifacts fixture is seeded with a
fresh-looking signal, then explicitly excluded from every manifest/traversal.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from statistics import median
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[2]
EVIDENCE = REPO / "validation/M6-hardening/soak-hygiene.json"
CADENCE_SECONDS = 1
SOAK_TICKS = 40
TREND_WARMUP_TICKS = 20
TREND_WINDOW_TICKS = 5
MIN_TREND_INCREASES = 2
MIN_TREND_NET_INCREASE_BYTES = 128 * 1024
RSS_TREND_ORACLE = "physical_footprint"
LATE_TOLERANCE = max(0.5, 2.0 * CADENCE_SECONDS / 15.0)
SECRET = "M6_HYGIENE_PLANTED_SECRET_7f5c"
UNDECLARED_SENTINEL = "M6_UNDECLARED_SENTINEL_4b21"
ARTIFACT_SENTINEL = "M6_ARTIFACT_SENTINEL_91aa"
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

# Only these paths are in the probe contract. The manifest intentionally does
# not recurse from the factory root, so factory/artifacts and undeclared
# siblings can never be read, hashed, or listed as evidence.
DECLARED_PATHS = {
    "claude-code": ("sessions",),
    "factory-droid": (
        "task-invocations.json",
        "background-processes.json",
        "sessions",
        "missions",
    ),
    "codex": ("thread-writer-locks", "state_5.sqlite-wal", ".codex-global-state.json"),
    "hermes": (
        "gateway.pid",
        "state/gateway.heartbeat",
        "gateway_state.json",
        "processes.json",
    ),
    "grok-bot": (
        "local-exec-daemon.json",
        "local-exec-supervisor.json",
        "local-exec-daemon.log",
    ),
    "grok-cli": ("active_sessions.json", "active_sessions.lock"),
    "pi": ("agent/sessions",),
    "cursor": ("agent-cli-state.json", "ai-tracking"),
    "kimi": (),
    "gemini-cli": (),
}


def daemon_binary() -> pathlib.Path:
    path = subprocess.check_output(
        ["swift", "build", "--package-path", "BurnBarDaemon", "--show-bin-path"],
        cwd=REPO,
        text=True,
    ).strip()
    return pathlib.Path(path) / "BurnBarDaemon"


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def make_roots(base: pathlib.Path, canary_pid: int, dead_pid: int) -> pathlib.Path:
    roots = base / "roots"
    for root_name in ROOT_NAMES.values():
        (roots / root_name).mkdir(parents=True, exist_ok=True)

    now_ms = int(time.time() * 1_000)
    old_ms = now_ms - 3_600_000

    # Claude is the live canary-backed process signal.
    write_json(
        roots / "claude/sessions" / f"{canary_pid}.json",
        {
            "pid": canary_pid,
            "sessionId": "m6-soak-claude",
            "cwd": "/fixture/AgentLens",
            "updatedAt": now_ms,
        },
    )

    # Grok CLI exercises the dead-pid-but-fresh-file confidence downgrade.
    write_json(
        roots / "grok/active_sessions.json",
        [
            {
                "session_id": "m6-dead-grok",
                "pid": dead_pid,
                "cwd": "/fixture/Dead",
                "opened_at": iso_now(),
            }
        ],
    )

    # Grok Bot is active and backed by the canary, without reading any
    # connection/credential file.
    write_json(
        roots / "grokbot/local-exec-daemon.json",
        {"pid": canary_pid, "inflightCount": 1},
    )
    write_json(
        roots / "grokbot/local-exec-supervisor.json",
        {"pid": canary_pid, "at": now_ms},
    )
    # Keep the valid Grok CLI dead-pid registry intact so its
    # activeSessionFile confidence downgrade is exercised. The corrupt,
    # secret-bearing fixture is a separate Grok Bot signal file.
    (roots / "grokbot/local-exec-supervisor.json").write_text(
        '{"pid": "' + SECRET + '",',
        encoding="utf-8",
    )

    # Hermes is active with fresh heartbeat and no process-list attribution.
    write_json(roots / "hermes/gateway.pid", {"pid": canary_pid})
    write_json(
        roots / "hermes/state/gateway.heartbeat",
        {"pid": canary_pid, "updated_at": iso_now()},
    )
    write_json(
        roots / "hermes/gateway_state.json",
        {"pid": canary_pid, "gateway_state": "running", "active_agents": 1},
    )
    write_json(roots / "hermes/processes.json", [])

    # Factory has a valid but reused pid entry. The old startTime must prevent
    # a false live process claim, while the artifacts copy must be ignored.
    write_json(
        roots / "factory/task-invocations.json",
        {"invocations": []},
    )
    write_json(
        roots / "factory/background-processes.json",
        {
            "processes": [
                {
                    "pid": canary_pid,
                    "startTime": old_ms,
                    "cwd": "/fixture/Reused",
                }
            ]
        },
    )
    write_json(
        roots / "factory/artifacts/task-invocations.json",
        {
            "invocations": [
                {
                    "status": "running",
                    "updatedAt": now_ms,
                    "cwd": "/fixture/Artifacts",
                    "description": ARTIFACT_SENTINEL,
                }
            ]
        },
    )
    write_json(
        roots / "factory/undeclared-sibling/task-invocations.json",
        {
            "invocations": [
                {
                    "status": "running",
                    "updatedAt": now_ms,
                    "cwd": "/fixture/Undeclared",
                    "description": UNDECLARED_SENTINEL,
                }
            ]
        },
    )
    artifacts_session = roots / "factory/artifacts/escaped-session"
    artifacts_session.mkdir(parents=True, exist_ok=True)
    set_file = artifacts_session / "sentinel.txt"
    set_file.write_text(ARTIFACT_SENTINEL, encoding="utf-8")
    (roots / "factory/sessions").mkdir(parents=True, exist_ok=True)
    os.symlink(
        "../artifacts/escaped-session",
        roots / "factory/sessions/escaped-artifact-session",
    )

    lock = roots / "codex/thread-writer-locks/m6.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.write_bytes(b"")

    pi_transcript = roots / "pi/agent/sessions/--fixture--AgentLens/m6.jsonl"
    pi_transcript.parent.mkdir(parents=True, exist_ok=True)
    pi_transcript.write_text(
        '{"type":"session","id":"m6-pi","cwd":"/fixture/AgentLens",'
        '"timestamp":"2026-08-15T00:00:00Z"}\n',
        encoding="utf-8",
    )

    write_json(
        roots / "cursor/agent-cli-state.json",
        {"workerIdsByDisplayName": {"AgentLens": "m6-worker"}},
    )
    tracking = roots / "cursor/ai-tracking/tracking.db"
    tracking.parent.mkdir(parents=True, exist_ok=True)
    tracking.write_text("synthetic tracking", encoding="utf-8")
    return roots


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


def snapshot(socket_path: pathlib.Path) -> dict[str, Any] | None:
    response = rpc(socket_path, "m6-soak")
    return response.get("result", {}).get("snapshot")


def wait_for_snapshot(socket_path: pathlib.Path, timeout: float = 10) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = snapshot(socket_path)
            if value is not None:
                return value
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.05)
    raise RuntimeError("daemon did not publish a fleet snapshot")


def metric_output(
    command: list[str],
    *,
    allow_no_matches: bool = False,
) -> tuple[str, dict[str, Any]]:
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
    )
    allowed_codes = {0, 1} if allow_no_matches else {0}
    if completed.returncode not in allowed_codes:
        raise RuntimeError(
            f"metric command failed ({completed.returncode}): "
            f"{' '.join(command)}; stderr={completed.stderr.strip()!r}"
        )
    if not completed.stdout.strip() and not allow_no_matches:
        raise RuntimeError(
            f"metric command returned no sample: {' '.join(command)}; "
            f"stderr={completed.stderr.strip()!r}"
        )
    return completed.stdout, {
        "command": command,
        "returncode": completed.returncode,
        "stderr": completed.stderr,
    }


def process_metrics(pid: int, support: pathlib.Path) -> dict[str, Any]:
    rss_output, rss_command = metric_output(["ps", "-o", "rss=", "-p", str(pid)])
    rss_values = [line.strip() for line in rss_output.splitlines() if line.strip()]
    if len(rss_values) != 1 or not rss_values[0].isdigit() or int(rss_values[0]) <= 0:
        raise RuntimeError(f"RSS sample was invalid: {rss_values!r}")
    rss_kb = int(rss_values[0])

    footprint_output, footprint_command = metric_output(
        [
            "footprint",
            "--pid",
            str(pid),
            "--noCategories",
            "--format",
            "bytes",
        ]
    )
    footprint_match = re.search(
        r"^\s*phys_footprint:\s+([0-9]+)\s+B\s*$",
        footprint_output,
        re.MULTILINE,
    )
    if footprint_match is None or int(footprint_match.group(1)) <= 0:
        raise RuntimeError(
            "physical footprint sample was invalid: "
            f"{footprint_output.strip()!r}"
        )
    physical_footprint_bytes = int(footprint_match.group(1))

    thread_output, thread_command = metric_output(["ps", "-M", "-p", str(pid)])
    thread_lines = [
        line for line in thread_output.splitlines()
        if line.strip() and not line.lstrip().startswith("USER")
    ]
    if not thread_lines:
        raise RuntimeError("thread metric returned no thread rows")
    fd_output, fd_command = metric_output(["lsof", "-p", str(pid)])
    fd_lines = [
        line for line in fd_output.splitlines()
        if line.strip()
    ]
    if not fd_lines:
        raise RuntimeError("fd metric returned no file rows")
    child_output, child_command = metric_output(
        ["pgrep", "-P", str(pid)],
        allow_no_matches=True,
    )
    children = [
        line for line in child_output.splitlines()
        if line.strip()
    ]
    tmp_files = sorted(
        str(path.relative_to(support))
        for path in support.rglob("*.tmp")
        if path.is_file()
    ) if support.exists() else []
    return {
        "rss_kb": rss_kb,
        "physical_footprint_bytes": physical_footprint_bytes,
        "fd_count": len(fd_lines),
        "thread_count": len(thread_lines),
        "child_count": len(children),
        "tmp_files": tmp_files,
        "metric_commands": [
            rss_command,
            footprint_command,
            thread_command,
            fd_command,
            child_command,
        ],
    }


def declared_manifest(roots: pathlib.Path) -> list[dict[str, Any]]:
    """Hash only declared paths, rejecting symlinks without resolving them."""
    entries: list[dict[str, Any]] = []
    for agent_id, relative_paths in DECLARED_PATHS.items():
        agent_root = roots / ROOT_NAMES[agent_id]
        for relative in relative_paths:
            target = agent_root / relative
            if target.is_symlink():
                entries.append(
                    {
                        "agent": agent_id,
                        "path": relative,
                        "state": "symlink-rejected",
                    }
                )
                continue
            if not target.exists():
                entries.append({"agent": agent_id, "path": relative, "state": "missing"})
                continue
            pending = [target]
            while pending:
                path = pending.pop()
                if path.is_symlink():
                    entries.append(
                        {
                            "agent": agent_id,
                            "path": str(path.relative_to(agent_root)),
                            "state": "symlink-rejected",
                        }
                    )
                    continue
                if path.is_dir():
                    pending.extend(sorted(path.iterdir(), reverse=True))
                    continue
                data = path.read_bytes()
                metadata = path.stat()
                entries.append(
                    {
                        "agent": agent_id,
                        "path": str(path.relative_to(agent_root)),
                        "state": "file",
                        "size": metadata.st_size,
                        "mtime_ns": metadata.st_mtime_ns,
                        "sha256": hashlib.sha256(data).hexdigest(),
                    }
                )
    return sorted(entries, key=lambda item: (item["agent"], item["path"]))


def stable_snapshot(value: dict[str, Any]) -> dict[str, Any]:
    """Preserve the complete payload while marking only volatile values."""
    result = copy.deepcopy(value)
    result["generatedAt"] = "<time-varying generation>"
    machine = result["machine"]
    for key in (
        "cpuPercent",
        "memoryUsedBytes",
        "memoryTotalBytes",
        "loadAverage",
        "diskFreeBytes",
    ):
        if key in machine:
            machine[key] = "<time-varying machine metric>"
    for row in result["agents"]:
        if row.get("lastActivityAt") is not None:
            row["lastActivityAt"] = "<time-varying activity>"
        for signal_source in row.get("signals", []):
            if signal_source.get("detail"):
                signal_source["detail"] = re.sub(
                    r"\b\d+[smhd] ago\b",
                    "<time-varying age>",
                    signal_source["detail"],
                )
        if row.get("process"):
            for key in ("cpuPercent", "memoryBytes", "startedAt"):
                if key in row["process"] and row["process"][key] is not None:
                    row["process"][key] = "<time-varying process metric>"
    for health in result["probeHealth"]:
        health["checkedAt"] = "<time-varying health check>"
    return result


def is_nondecreasing(values: list[int]) -> bool:
    return all(later >= earlier for earlier, later in zip(values, values[1:]))


def is_strictly_increasing(values: list[int]) -> bool:
    return all(later > earlier for earlier, later in zip(values, values[1:]))


def window_medians(values: list[int], window_size: int) -> list[float]:
    if window_size <= 0 or len(values) % window_size:
        raise ValueError("trend samples must divide into complete windows")
    return [
        median(values[index:index + window_size])
        for index in range(0, len(values), window_size)
    ]


def static_liveness_scan() -> dict[str, Any]:
    probe_root = REPO / "BurnBarDaemon/Sources/BurnBarDaemon/Fleet/Probes"
    offending: list[dict[str, Any]] = []
    kill_checks: list[str] = []
    for path in sorted(probe_root.rglob("*.swift")):
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//", 1)[0]
            if re.search(r"\bkill\s*\(", code):
                if re.search(r",\s*0\s*\)", code):
                    kill_checks.append(f"{path.relative_to(REPO)}:{line_number}")
                else:
                    offending.append(
                        {
                            "path": str(path.relative_to(REPO)),
                            "line": line_number,
                            "reason": "kill call is not an existence check",
                        }
                    )
            if re.search(r"\b(?:raise|terminate|signal)\s*\(", code):
                offending.append(
                    {
                        "path": str(path.relative_to(REPO)),
                        "line": line_number,
                        "reason": "process-control call in liveness layer",
                    }
                )
    return {
        "scanned_root": "BurnBarDaemon/Sources/BurnBarDaemon/Fleet/Probes",
        "allowed_kill_zero_checks": kill_checks,
        "offending_calls": offending,
        "proc_pidinfo_allowed": True,
    }


def start_log_capture() -> subprocess.Popen[str]:
    return subprocess.Popen(
        [
            "log",
            "stream",
            "--style",
            "compact",
            "--level",
            "debug",
            "--predicate",
            'subsystem == "com.burnbar.daemon" AND category == "fleet"',
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def stop_log_capture(process: subprocess.Popen[str]) -> str:
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            return process.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            process.kill()
    stdout, _ = process.communicate(timeout=5)
    return stdout


def parse_degradation_events(raw: str, pid: int) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in raw.splitlines():
        if "event=fleet_probe_degraded" not in line or f"daemon_pid={pid}" not in line:
            continue
        fields = dict(re.findall(r"(\w+)=([^\s]+)", line))
        if fields.get("event") != "fleet_probe_degraded":
            continue
        events.append(
            {
                "agent": fields.get("agent", ""),
                "state": fields.get("state", ""),
                "tick": int(fields["tick"]) if fields.get("tick", "").isdigit() else None,
            }
        )
    return events


def run() -> dict[str, Any]:
    base = pathlib.Path(tempfile.mkdtemp(prefix="burnbar-m6-soak-"))
    daemon: subprocess.Popen[bytes] | None = None
    log_process: subprocess.Popen[str] | None = None
    canary: subprocess.Popen[bytes] | None = None
    try:
        canary_log = base / "canary-signals.log"
        canary_code = (
            "import signal,sys,time\n"
            "path=sys.argv[1]\n"
            "def observed(signum, _frame):\n"
            "    open(path, 'a', encoding='utf-8').write(str(signum)+'\\n')\n"
            "for value in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGUSR1, signal.SIGUSR2):\n"
            "    signal.signal(value, observed)\n"
            "while True: time.sleep(1)\n"
        )
        canary = subprocess.Popen(
            [sys.executable, "-c", canary_code, str(canary_log)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        dead = subprocess.Popen(["sleep", "0.05"])
        dead_pid = dead.pid
        dead.wait(timeout=2)

        roots = make_roots(base, canary.pid, dead_pid)
        before_manifest = declared_manifest(roots)
        log_process = start_log_capture()
        support = base / "support"
        socket_path = base / "daemon.sock"
        daemon_log = base / "daemon.stdout.log"
        environment = os.environ.copy()
        inherited_root_overrides = sorted(
            key for key in environment if key.startswith("BURNBAR_FLEET_ROOT_")
        )
        for key in inherited_root_overrides:
            del environment[key]
        environment.update(
            {
                "BURNBAR_DAEMON_SUPPORT_DIR": str(support),
                "BURNBAR_FLEET_ROOTS_DIR": str(roots),
                "BURNBAR_FLEET_CADENCE_SECONDS": str(CADENCE_SECONDS),
            }
        )
        with daemon_log.open("wb") as output:
            daemon = subprocess.Popen(
                [str(daemon_binary()), "--socket-path", str(socket_path)],
                cwd=REPO,
                env=environment,
                stdout=output,
                stderr=subprocess.STDOUT,
            )

        first = wait_for_snapshot(socket_path)
        first_observed = time.monotonic()
        samples: list[dict[str, Any]] = []
        intervals: list[float] = []
        previous_generation = first["generatedAt"]
        previous_observed = first_observed
        stable_reference: dict[str, Any] | None = None
        for index in range(SOAK_TICKS):
            deadline = time.monotonic() + CADENCE_SECONDS + LATE_TOLERANCE + 2
            current: dict[str, Any] | None = None
            while time.monotonic() < deadline:
                candidate = snapshot(socket_path)
                if candidate is not None and candidate["generatedAt"] != previous_generation:
                    current = candidate
                    break
                time.sleep(0.05)
            if current is None:
                raise RuntimeError(f"tick {index + 1} did not advance")
            observed = time.monotonic()
            intervals.append(observed - previous_observed)
            previous_observed = observed
            previous_generation = current["generatedAt"]
            samples.append(
                {
                    "tick": index + 1,
                    "generatedAt": current["generatedAt"],
                    "observedAt": datetime.now(timezone.utc).isoformat(),
                    **process_metrics(daemon.pid, support),
                }
            )
            if canary.poll() is not None:
                raise RuntimeError(f"canary exited before final tick: {canary.returncode}")
            samples[-1]["canary_alive"] = True
            if index == 4:
                stable_reference = stable_snapshot(current)

        after_manifest = declared_manifest(roots)
        socket_stat = socket_path.stat()
        mode = stat.S_IMODE(socket_stat.st_mode)
        stable_first = stable_snapshot(first)
        stable_last = stable_snapshot(snapshot(socket_path) or first)
        metrics = {
            "rss_kb": [sample["rss_kb"] for sample in samples],
            "physical_footprint_bytes": [
                sample["physical_footprint_bytes"] for sample in samples
            ],
            "fd_count": [sample["fd_count"] for sample in samples],
            "thread_count": [sample["thread_count"] for sample in samples],
            "child_count": [sample["child_count"] for sample in samples],
            "tmp_files": [sample["tmp_files"] for sample in samples],
        }
        warmup_rss = [value for value in metrics["rss_kb"][4:9] if value is not None]
        warmup_fd = metrics["fd_count"][4:9]
        # Swift's cooperative executor can lazily create its final worker
        # thread well after the first few ticks. Use the full allocator/trend
        # warm-up for the thread baseline, then require no further drift.
        warmup_threads = metrics["thread_count"][:TREND_WARMUP_TICKS]
        if len(warmup_rss) != 5:
            raise RuntimeError("RSS warm-up window is missing samples")
        rss_baseline = median(warmup_rss)
        warmup_footprint = metrics["physical_footprint_bytes"][4:9]
        footprint_baseline = median(warmup_footprint)
        fd_baseline = median(warmup_fd)
        thread_baseline = median(warmup_threads)
        thread_band = (min(warmup_threads), max(warmup_threads))
        rss_end = metrics["rss_kb"][-1]
        rss_ratio = rss_end / rss_baseline
        rss_decrease_count = sum(
            later < earlier
            for earlier, later in zip(metrics["rss_kb"], metrics["rss_kb"][1:])
        )
        rss_increase_count = sum(
            later > earlier
            for earlier, later in zip(metrics["rss_kb"], metrics["rss_kb"][1:])
        )
        rss_non_monotonic = rss_decrease_count > 0
        rss_nondecreasing = is_nondecreasing(metrics["rss_kb"])
        rss_strictly_increasing = is_strictly_increasing(metrics["rss_kb"])
        footprint_trend_samples = metrics["physical_footprint_bytes"][TREND_WARMUP_TICKS:]
        footprint_windows = window_medians(
            footprint_trend_samples,
            TREND_WINDOW_TICKS,
        )
        footprint_window_decrease_count = sum(
            later < earlier
            for earlier, later in zip(footprint_windows, footprint_windows[1:])
        )
        footprint_window_increase_count = sum(
            later > earlier
            for earlier, later in zip(footprint_windows, footprint_windows[1:])
        )
        footprint_window_net_increase = footprint_windows[-1] - footprint_windows[0]
        footprint_window_nondecreasing = is_nondecreasing(footprint_windows)
        footprint_end = metrics["physical_footprint_bytes"][-1]
        footprint_ratio = footprint_end / footprint_baseline

        dead_grok_row = next(
            row for row in first["agents"] if row["id"] == "grok-cli"
        )
        if (
            dead_grok_row["status"] != "stale"
            or dead_grok_row["confidence"] != "activeSessionFile"
        ):
            raise RuntimeError(
                "dead-pid Grok fixture did not downgrade to stale/activeSessionFile: "
                f"{dead_grok_row}"
            )

        raw_log = stop_log_capture(log_process)
        log_process = None
        events = parse_degradation_events(raw_log, daemon.pid)
        if not events:
            fallback = subprocess.run(
                [
                    "log",
                    "show",
                    "--last",
                    "2m",
                    "--style",
                    "compact",
                    "--predicate",
                    'subsystem == "com.burnbar.daemon" AND category == "fleet"',
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            raw_log = fallback.stdout
            events = parse_degradation_events(raw_log, daemon.pid)
        daemon_stdout = daemon_log.read_text(encoding="utf-8", errors="replace")
        scanned_logs = raw_log + "\n" + daemon_stdout

        canary_signals = (
            canary_log.read_text(encoding="utf-8").splitlines()
            if canary_log.exists()
            else []
        )
        canary_alive_at_final_tick = canary.poll() is None
        if not canary_alive_at_final_tick:
            raise RuntimeError(
                f"canary exited before final assertion: {canary.returncode}"
            )
        static_scan = static_liveness_scan()
        event_counts: dict[str, int] = {}
        event_keys: list[tuple[str, int | None]] = []
        for event in events:
            event_counts[event["agent"]] = event_counts.get(event["agent"], 0) + 1
            event_keys.append((event["agent"], event["tick"]))
        affected_agents = ["factory-droid", "grok-bot"]
        max_events = len(affected_agents) * (SOAK_TICKS + 1)
        at_most_one_per_agent_per_tick = len(event_keys) == len(set(event_keys))
        log_bytes_cap = max_events * 512
        log_bytes = len("\n".join(
            line for line in raw_log.splitlines()
            if "event=fleet_probe_degraded" in line and f"daemon_pid={daemon.pid}" in line
        ).encode())
        soak_projection_stable = stable_reference == stable_last
        if mode & 0o077:
            raise RuntimeError(f"fleet socket is not owner-only: mode {oct(mode)}")
        if not (socket_stat.st_uid == os.getuid() and (mode & 0o077) == 0):
            raise RuntimeError("fleet socket owner policy failed")
        if len(intervals) != SOAK_TICKS:
            raise RuntimeError(f"expected {SOAK_TICKS} tick intervals, got {len(intervals)}")
        if sum(
            CADENCE_SECONDS - LATE_TOLERANCE <= value <= CADENCE_SECONDS + LATE_TOLERANCE
            for value in intervals
        ) < SOAK_TICKS - 1:
            raise RuntimeError("more than one cadence interval was late")
        if footprint_ratio > 1.20:
            raise RuntimeError(
                "physical footprint exceeded the documented 20% bound: "
                f"ratio={footprint_ratio:.3f}"
            )
        if (
            footprint_window_nondecreasing
            and footprint_window_increase_count >= MIN_TREND_INCREASES
            and footprint_window_net_increase >= MIN_TREND_NET_INCREASE_BYTES
        ):
            raise RuntimeError(
                "physical footprint window medians showed a nondecreasing growth "
                "trend; "
                f"increases={footprint_window_increase_count}, "
                f"decreases={footprint_window_decrease_count}, "
                f"window_medians_bytes={footprint_windows}"
            )
        # macOS RSS includes shared/file-backed and page-quantized residency.
        # Keep its bound and raw series for auditability, but use the
        # fail-closed physical-footprint window gate above for trend detection.
        if rss_ratio > 1.20:
            raise RuntimeError(f"RSS exceeded the documented 20% bound: ratio={rss_ratio:.3f}")
        if max(abs(value - fd_baseline) for value in metrics["fd_count"]) != 0:
            raise RuntimeError(
                "file descriptor or thread count escaped its warm-up band; "
                f"fd_baseline={fd_baseline}, fd_series={metrics['fd_count']}, "
                f"thread_baseline={thread_baseline}, "
                f"thread_series={metrics['thread_count']}"
            )
        if any(
            value < thread_band[0] or value > thread_band[1]
            for value in metrics["thread_count"]
        ):
            raise RuntimeError(
                "thread count escaped its warm-up band; "
                f"thread_band={thread_band}, thread_series={metrics['thread_count']}"
            )
        if any(sample["child_count"] != 0 for sample in samples):
            raise RuntimeError("daemon left a child process at a tick boundary")
        if any(sample["tmp_files"] for sample in samples):
            raise RuntimeError("daemon left a temporary file at a tick boundary")
        if not soak_projection_stable:
            raise RuntimeError("stable snapshot projection changed after warm-up")
        if not at_most_one_per_agent_per_tick:
            raise RuntimeError("more than one degradation record appeared for an agent/tick")
        if not events:
            raise RuntimeError("malformed Grok Bot fixture produced no degradation event")
        if len(events) > max_events:
            raise RuntimeError(
                f"degradation log exceeded the {max_events}-record cap; "
                f"counts_by_agent={event_counts}"
            )
        if log_bytes > log_bytes_cap:
            raise RuntimeError(f"degradation log exceeded its {log_bytes_cap}-byte cap")
        if static_scan["offending_calls"]:
            raise RuntimeError(f"liveness static scan found calls: {static_scan['offending_calls']}")
        if canary_signals:
            raise RuntimeError(f"canary observed nonzero signals: {canary_signals}")

        return {
            "status": "pass",
            "configuration": {
                "cadence_seconds": CADENCE_SECONDS,
                "ticks_requested": SOAK_TICKS,
                "late_tolerance_seconds": LATE_TOLERANCE,
                "warmup_samples": 5,
                "rss_bound_warmup_ticks": 5,
                "rss_trend_oracle": RSS_TREND_ORACLE,
                "physical_footprint_trend_warmup_ticks": TREND_WARMUP_TICKS,
                "physical_footprint_trend_window_ticks": TREND_WINDOW_TICKS,
                "physical_footprint_minimum_trend_increases": MIN_TREND_INCREASES,
                "physical_footprint_minimum_trend_net_increase_bytes": (
                    MIN_TREND_NET_INCREASE_BYTES
                ),
            },
            "socket": {
                "mode_octal": oct(mode),
                "owner_uid": socket_stat.st_uid,
                "invoking_uid": os.getuid(),
                "owner_only": socket_stat.st_uid == os.getuid() and (mode & 0o077) == 0,
                "same_user_rpc": True,
            },
            "soak": {
                "samples": samples,
                "intervals_seconds": intervals,
                "on_time_ticks": sum(
                    CADENCE_SECONDS - LATE_TOLERANCE <= value <= CADENCE_SECONDS + LATE_TOLERANCE
                    for value in intervals
                ),
                "late_ticks": sum(
                    value < CADENCE_SECONDS - LATE_TOLERANCE
                    or value > CADENCE_SECONDS + LATE_TOLERANCE
                    for value in intervals
                ),
                "rss_baseline_kb": rss_baseline,
                "rss_end_kb": rss_end,
                "rss_end_to_warmup_ratio": rss_ratio,
                "rss_bound_ratio": 1.20,
                "rss_series_kb": metrics["rss_kb"],
                "rss_increase_count": rss_increase_count,
                "rss_decrease_count": rss_decrease_count,
                "rss_nondecreasing_growth": rss_nondecreasing,
                "rss_strictly_increasing_growth": rss_strictly_increasing,
                "rss_raw_non_monotonic_observation": rss_non_monotonic,
                "rss_trend_oracle": RSS_TREND_ORACLE,
                "physical_footprint_baseline_bytes": footprint_baseline,
                "physical_footprint_end_bytes": footprint_end,
                "physical_footprint_end_to_warmup_ratio": footprint_ratio,
                "physical_footprint_bound_ratio": 1.20,
                "physical_footprint_series_bytes": metrics["physical_footprint_bytes"],
                "physical_footprint_trend_window_ticks": TREND_WINDOW_TICKS,
                "physical_footprint_window_medians_bytes": footprint_windows,
                "physical_footprint_window_increase_count": footprint_window_increase_count,
                "physical_footprint_window_decrease_count": footprint_window_decrease_count,
                "physical_footprint_window_net_increase_bytes": footprint_window_net_increase,
                "physical_footprint_window_nondecreasing_growth": footprint_window_nondecreasing,
                "physical_footprint_growth_trend_gate": not (
                    footprint_window_nondecreasing
                    and footprint_window_increase_count >= MIN_TREND_INCREASES
                    and footprint_window_net_increase >= MIN_TREND_NET_INCREASE_BYTES
                ),
                "fd_baseline": fd_baseline,
                "fd_max_delta_from_warmup": max(
                    abs(value - fd_baseline) for value in metrics["fd_count"]
                ),
                "fd_strictly_monotonic_growth": all(
                    later > earlier
                    for earlier, later in zip(metrics["fd_count"], metrics["fd_count"][1:])
                ),
                "thread_baseline": thread_baseline,
                "thread_max_delta_from_warmup": max(
                    abs(value - thread_baseline) for value in metrics["thread_count"]
                ),
                "thread_warmup_band": list(thread_band),
                "thread_strictly_monotonic_growth": all(
                    later > earlier
                    for earlier, later in zip(metrics["thread_count"], metrics["thread_count"][1:])
                ),
                "child_counts": metrics["child_count"],
                "tmp_files": metrics["tmp_files"],
                "stable_snapshot_projection": soak_projection_stable,
            },
            "degradation_logging": {
                "affected_agents": affected_agents,
                "events": events,
                "counts_by_agent": event_counts,
                "max_records": max_events,
                "record_key_uniqueness": at_most_one_per_agent_per_tick,
                "at_most_one_per_agent_per_tick": at_most_one_per_agent_per_tick,
                "captured_event_bytes": log_bytes,
                "log_bytes_cap": log_bytes_cap,
                "log_bytes_bounded": log_bytes <= log_bytes_cap,
                "no_stack_trace_markers": not re.search(
                    r"Traceback|stack trace|backtrace|fatal error",
                    scanned_logs,
                    re.IGNORECASE,
                ),
                "secret_absent": SECRET not in scanned_logs,
                "sentinels_absent": UNDECLARED_SENTINEL not in scanned_logs
                and ARTIFACT_SENTINEL not in scanned_logs,
                "scanned_streams": ["oslog", "daemon.stdout.log"],
            },
            "fixture_isolation": {
                "declared_manifest_before": before_manifest,
                "declared_manifest_after": after_manifest,
                "declared_manifest_unchanged": before_manifest == after_manifest,
                "excluded_paths": [
                    "factory/artifacts/**",
                    "factory/undeclared-sibling/**",
                ],
                "traversal_rule": (
                    "Manifest enumerates only DECLARED_PATHS and rejects symlink "
                    "descendants before stat/read; factory/artifacts/** is never read."
                ),
                "symlink_rejections": [
                    entry for entry in before_manifest
                    if entry.get("state") == "symlink-rejected"
                ],
                "per_agent_root_overrides_cleared": inherited_root_overrides == [],
                "snapshot_sentinels_absent": UNDECLARED_SENTINEL
                not in json.dumps([stable_first, stable_last])
                and ARTIFACT_SENTINEL not in json.dumps([stable_first, stable_last])
                and SECRET not in json.dumps([stable_first, stable_last]),
                "factory_row_not_driven_by_undeclared_content": next(
                    row for row in stable_last["agents"] if row["id"] == "factory-droid"
                )["status"] != "running",
            },
            "liveness": {
                "canary_pid": canary.pid,
                "canary_nonzero_signal_log": canary_signals,
                "canary_received_no_nonzero_signal": not canary_signals,
                "canary_alive_at_final_tick": canary_alive_at_final_tick,
                "dead_pid_fixture": dead_pid,
                "dead_pid_downgrade": {
                    "agent": "grok-cli",
                    "status": dead_grok_row["status"],
                    "confidence": dead_grok_row["confidence"],
                },
                "pid_reuse_fixture": {
                    "agent": "factory-droid",
                    "recorded_start_time": "one hour before canary start",
                    "canary_pid": canary.pid,
                },
                "static_scan": static_scan,
            },
        }
    finally:
        if log_process is not None:
            stop_log_capture(log_process)
        if daemon is not None and daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)
        if canary is not None and canary.poll() is None:
            canary.terminate()
            try:
                canary.wait(timeout=3)
            except subprocess.TimeoutExpired:
                canary.kill()
                canary.wait(timeout=3)
        shutil.rmtree(base, ignore_errors=True)


def main() -> None:
    try:
        evidence = run()
    except Exception as error:
        evidence = {"status": "fail", "error": str(error)}
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        raise
    EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    EVIDENCE.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
