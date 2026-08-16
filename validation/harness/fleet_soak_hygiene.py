#!/usr/bin/env python3
"""Hermetic M6 soak, logging, boundary, and liveness proof.

This harness owns its temporary roots, support directory, daemon, log
collector, canary, and scratch files. It never reads a real agent root or
``~/.factory/artifacts``. The factory artifacts fixture is seeded with a
fresh-looking signal, then explicitly excluded from every manifest/traversal.
"""

from __future__ import annotations

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

    # Corrupt Grok JSON carries a planted secret. The parser must report only a
    # typed generic degradation; it must never log or echo file contents.
    (roots / "grok/active_sessions.json").write_text(
        '{"active_sessions": ["' + SECRET + '",',
        encoding="utf-8",
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


def metric_output(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.stdout


def process_metrics(pid: int, support: pathlib.Path) -> dict[str, Any]:
    rss_text = metric_output(["ps", "-o", "rss=", "-p", str(pid)]).strip()
    rss_kb = int(rss_text) if rss_text else None

    thread_lines = [
        line for line in metric_output(["ps", "-M", "-p", str(pid)]).splitlines()
        if line.strip() and not line.lstrip().startswith("USER")
    ]
    fd_lines = [
        line for line in metric_output(["lsof", "-p", str(pid)]).splitlines()
        if line.strip()
    ]
    children = [
        line for line in metric_output(["pgrep", "-P", str(pid)]).splitlines()
        if line.strip()
    ]
    tmp_files = sorted(
        str(path.relative_to(support))
        for path in support.rglob("*.tmp")
        if path.is_file()
    ) if support.exists() else []
    return {
        "rss_kb": rss_kb,
        "fd_count": len(fd_lines),
        "thread_count": len(thread_lines),
        "child_count": len(children),
        "tmp_files": tmp_files,
    }


def declared_manifest(roots: pathlib.Path) -> list[dict[str, Any]]:
    """Hash only declared paths; factory/artifacts is pruned by construction."""
    entries: list[dict[str, Any]] = []
    for agent_id, relative_paths in DECLARED_PATHS.items():
        agent_root = roots / ROOT_NAMES[agent_id]
        for relative in relative_paths:
            target = agent_root / relative
            if not target.exists():
                entries.append({"agent": agent_id, "path": relative, "state": "missing"})
                continue
            candidates = [target]
            if target.is_dir():
                candidates = sorted(path for path in target.rglob("*") if path.is_file())
            for path in candidates:
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
    """Compare truth, not expected per-tick timestamps or machine telemetry."""
    return {
        "cadenceSeconds": value["cadenceSeconds"],
        "agents": [
            {
                "id": row["id"],
                "status": row["status"],
                "confidence": row["confidence"],
                "currentTask": row.get("currentTask"),
                "projectName": row.get("projectName"),
                "model": row.get("model"),
                "process": row.get("process"),
                "lastActivityAt": row.get("lastActivityAt"),
                "note": row.get("note"),
                "signals": [
                    {"kind": signal["kind"], "path": signal["path"]}
                    for signal in row.get("signals", [])
                ],
            }
            for row in value["agents"]
        ],
        "repos": value["repos"],
        "runningCount": value["runningCount"],
        "countsByAgent": value["countsByAgent"],
        "orchestrator": value["orchestrator"],
        "probeHealth": [
            {
                "agent": health["agent"],
                "state": health["state"],
                "rootPath": health["rootPath"],
            }
            for health in value["probeHealth"]
        ],
        "persistenceHealth": value["persistenceHealth"],
    }


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
            if index == 4:
                stable_reference = stable_snapshot(current)

        after_manifest = declared_manifest(roots)
        socket_stat = socket_path.stat()
        mode = stat.S_IMODE(socket_stat.st_mode)
        stable_first = stable_snapshot(first)
        stable_last = stable_snapshot(snapshot(socket_path) or first)
        metrics = {
            "rss_kb": [sample["rss_kb"] for sample in samples],
            "fd_count": [sample["fd_count"] for sample in samples],
            "thread_count": [sample["thread_count"] for sample in samples],
            "child_count": [sample["child_count"] for sample in samples],
            "tmp_files": [sample["tmp_files"] for sample in samples],
        }
        warmup_rss = [value for value in metrics["rss_kb"][4:9] if value is not None]
        warmup_fd = metrics["fd_count"][4:9]
        warmup_threads = metrics["thread_count"][4:9]
        rss_baseline = median(warmup_rss) if warmup_rss else 0
        fd_baseline = median(warmup_fd)
        thread_baseline = median(warmup_threads)
        rss_end = metrics["rss_kb"][-1] or 0
        rss_ratio = (rss_end / rss_baseline) if rss_baseline else 1.0

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

        canary_signals = (
            canary_log.read_text(encoding="utf-8").splitlines()
            if canary_log.exists()
            else []
        )
        static_scan = static_liveness_scan()
        event_counts: dict[str, int] = {}
        event_keys: list[tuple[str, int | None]] = []
        for event in events:
            event_counts[event["agent"]] = event_counts.get(event["agent"], 0) + 1
            event_keys.append((event["agent"], event["tick"]))
        affected_agents = ["grok-cli"]
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
        if not warmup_rss or rss_ratio > 1.20:
            raise RuntimeError(f"RSS exceeded the documented 20% bound: ratio={rss_ratio:.3f}")
        if any(
            value != 0
            for value in [
                max(abs(value - fd_baseline) for value in metrics["fd_count"]),
                max(abs(value - thread_baseline) for value in metrics["thread_count"]),
            ]
        ):
            raise RuntimeError("file descriptor or thread count escaped its warm-up band")
        if any(sample["child_count"] != 0 for sample in samples):
            raise RuntimeError("daemon left a child process at a tick boundary")
        if any(sample["tmp_files"] for sample in samples):
            raise RuntimeError("daemon left a temporary file at a tick boundary")
        if not soak_projection_stable:
            raise RuntimeError("stable snapshot projection changed after warm-up")
        if not at_most_one_per_agent_per_tick:
            raise RuntimeError("more than one degradation record appeared for an agent/tick")
        if len(events) > max_events:
            raise RuntimeError(f"degradation log exceeded the {max_events}-record cap")
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
                "rss_strictly_monotonic_growth": all(
                    later > earlier
                    for earlier, later in zip(metrics["rss_kb"], metrics["rss_kb"][1:])
                    if earlier is not None and later is not None
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
                    raw_log,
                    re.IGNORECASE,
                ),
                "secret_absent": SECRET not in raw_log,
                "sentinels_absent": UNDECLARED_SENTINEL not in raw_log
                and ARTIFACT_SENTINEL not in raw_log,
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
                    "Manifest enumerates only DECLARED_PATHS; factory/artifacts/** "
                    "is pruned before traversal and its content is never read."
                ),
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
                "dead_pid_fixture": dead_pid,
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
