"""Live Agent Fleet helpers for BurnBar MCP.

Reads the daemon's well-known fleet-snapshot.json (M1). Does not edit Swift.
Presence is a sidecar JSON next to the snapshot until daemon.fleet.presence.record
exists (after Droid M5). Team merge is a local peer-directory overlay until
CloudSync (after Droid M6).
"""

from __future__ import annotations

import json
import os
import socket
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "BurnBar"
SNAPSHOT_NAME = "fleet-snapshot.json"
PRESENCE_NAME = "fleet-presence.json"
SOCKET_NAME = "burnbar-daemon.sock"
PRESENCE_TTL_DEFAULT = 300

HEAVY_JOBS = frozenset(
    {
        "xcodebuild",
        "app-ui",
        "swift-app-test",
        "npm-test-full",
        "full-ci",
    }
)
MEDIUM_JOBS = frozenset({"daemon-socket", "vitest", "swift-package-test", "npm-test"})


def support_dir() -> Path:
    override = os.environ.get("BURNBAR_DAEMON_SUPPORT_DIR", "").strip()
    return Path(override).expanduser() if override else SUPPORT_DIR


def snapshot_path() -> Path:
    env = os.environ.get("BURNBAR_FLEET_SNAPSHOT_PATH", "").strip()
    return Path(env).expanduser() if env else support_dir() / SNAPSHOT_NAME


def presence_path() -> Path:
    env = os.environ.get("BURNBAR_FLEET_PRESENCE_PATH", "").strip()
    return Path(env).expanduser() if env else support_dir() / PRESENCE_NAME


def socket_path() -> Path:
    env = os.environ.get("BURNBAR_DAEMON_SOCKET", "").strip()
    return Path(env).expanduser() if env else support_dir() / SOCKET_NAME


def peer_dir() -> Path | None:
    env = os.environ.get("BURNBAR_FLEET_PEER_DIR", "").strip()
    return Path(env).expanduser() if env else None


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        raw = path.read_text()
    except OSError:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def load_snapshot_file(path: Path | None = None) -> dict[str, Any] | None:
    return _read_json(path or snapshot_path())


def rpc_snapshot(timeout: float = 2.0) -> dict[str, Any] | None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(str(socket_path()))
        req = json.dumps({"id": "burnbar-mcp-fleet", "method": "daemon.fleet.snapshot"}) + "\n"
        sock.sendall(req.encode("utf-8"))
        chunks: list[bytes] = []
        while True:
            piece = sock.recv(65536)
            if not piece:
                break
            chunks.append(piece)
            if b"\n" in piece:
                break
        line = b"".join(chunks).split(b"\n", 1)[0]
        payload = json.loads(line.decode("utf-8"))
    except OSError:
        return None
    except json.JSONDecodeError:
        return None
    finally:
        sock.close()
    if not isinstance(payload, dict):
        return None
    if payload.get("error"):
        return None
    result = payload.get("result")
    if isinstance(result, dict) and isinstance(result.get("snapshot"), dict):
        return result["snapshot"]
    if isinstance(result, dict) and "agents" in result:
        return result
    return None


def load_snapshot() -> dict[str, Any]:
    file_snap = load_snapshot_file()
    if file_snap is not None:
        file_snap.setdefault("_source", "file")
        file_snap.setdefault("_path", str(snapshot_path()))
        return file_snap
    rpc_snap = rpc_snapshot()
    if rpc_snap is not None:
        rpc_snap.setdefault("_source", "rpc")
        return rpc_snap
    return {
        "_source": "missing",
        "_error": "No fleet-snapshot.json and daemon.fleet.snapshot RPC failed. Is BurnBar daemon running?",
        "agents": [],
        "runningCount": 0,
        "machine": {},
    }


def machine_block(snapshot: dict[str, Any]) -> dict[str, Any]:
    block = snapshot.get("machine") or snapshot.get("machineStatus") or {}
    return block if isinstance(block, dict) else {}


def running_agents(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    agents = snapshot.get("agents") or []
    if not isinstance(agents, list):
        return []
    return [a for a in agents if isinstance(a, dict) and a.get("status") == "running"]


def _parse_iso(value: str | None) -> float | None:
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def load_presence(now: float | None = None) -> list[dict[str, Any]]:
    data = _read_json(presence_path())
    if not data:
        return []
    entries = data.get("entries") or []
    if not isinstance(entries, list):
        return []
    stamp = now if now is not None else time.time()
    live: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        recorded = _parse_iso(entry.get("recordedAt"))
        ttl = int(entry.get("ttlSeconds") or PRESENCE_TTL_DEFAULT)
        if recorded is None or stamp - recorded > ttl:
            continue
        live.append(entry)
    return live


def record_presence(
    *,
    agent_id: str,
    host_id: str,
    cwd: str,
    task: str,
    intended_tests: str = "",
    ttl_seconds: int = PRESENCE_TTL_DEFAULT,
    session_ref: str = "",
    now: datetime | None = None,
) -> dict[str, Any]:
    """Sidecar write. Not daemon.fleet.presence.record. TTL-pruned."""
    agent_id = agent_id.strip()
    task = task.strip()
    if not agent_id or not task:
        raise ValueError("agent_id and task are required")
    moment = now or datetime.now(timezone.utc)
    recorded = moment.isoformat().replace("+00:00", "Z")
    entry = {
        "id": session_ref.strip() or f"{agent_id}:{host_id}:{int(moment.timestamp())}",
        "agentId": agent_id,
        "hostId": host_id.strip() or socket.gethostname(),
        "cwd": cwd.strip(),
        "task": task,
        "intendedTests": intended_tests.strip(),
        "ttlSeconds": max(30, int(ttl_seconds)),
        "recordedAt": recorded,
    }
    path = presence_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = _read_json(path) or {"schemaVersion": 1, "entries": []}
    entries = [e for e in existing.get("entries") or [] if isinstance(e, dict)]
    stamp = moment.timestamp()
    kept: list[dict[str, Any]] = []
    for old in entries:
        if old.get("id") == entry["id"]:
            continue
        if old.get("agentId") == entry["agentId"] and old.get("cwd") == entry["cwd"]:
            continue
        recorded = _parse_iso(old.get("recordedAt"))
        ttl = int(old.get("ttlSeconds") or PRESENCE_TTL_DEFAULT)
        if recorded is None or stamp - recorded > ttl:
            continue
        kept.append(old)
    kept.append(entry)
    payload = {
        "schemaVersion": 1,
        "updatedAt": recorded,
        "note": "MCP sidecar until daemon.fleet.presence.record ships after Droid M5. Daemon probes stay source of liveness.",
        "entries": kept,
    }
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n")
    tmp.replace(path)
    return entry


def load_peer_snapshots() -> list[dict[str, Any]]:
    directory = peer_dir()
    if directory is None or not directory.is_dir():
        return []
    peers: list[dict[str, Any]] = []
    for child in sorted(directory.glob("*.json")):
        data = _read_json(child)
        if data is None:
            continue
        data.setdefault("_hostId", child.stem)
        data.setdefault("_source", "peer")
        peers.append(data)
    return peers


def summarize_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    machine = machine_block(snapshot)
    mem_used = machine.get("memoryUsedBytes")
    mem_total = machine.get("memoryTotalBytes")
    mem_pct = None
    if isinstance(mem_used, (int, float)) and isinstance(mem_total, (int, float)) and mem_total:
        mem_pct = round(100.0 * float(mem_used) / float(mem_total), 1)
    running = running_agents(snapshot)
    return {
        "source": snapshot.get("_source"),
        "path": snapshot.get("_path"),
        "error": snapshot.get("_error"),
        "generatedAt": snapshot.get("generatedAt"),
        "runningCount": snapshot.get("runningCount", len(running)),
        "running": [
            {
                "id": a.get("id"),
                "displayName": a.get("displayName"),
                "projectName": a.get("projectName"),
                "confidence": a.get("confidence"),
                "pid": (a.get("process") or {}).get("pid") if isinstance(a.get("process"), dict) else None,
            }
            for a in running
        ],
        "repos": snapshot.get("repos") or [],
        "machine": {
            "cpuPercent": machine.get("cpuPercent"),
            "memoryPercent": mem_pct,
            "loadAverage": machine.get("loadAverage"),
            "diskFreeBytes": machine.get("diskFreeBytes"),
        },
        "orchestrator": snapshot.get("orchestrator"),
        "presence": load_presence(),
        "peers": [
            {
                "hostId": p.get("_hostId"),
                "generatedAt": p.get("generatedAt"),
                "runningCount": p.get("runningCount"),
            }
            for p in load_peer_snapshots()
        ],
    }


def normalize_job(job: str) -> str:
    raw = (job or "").strip().lower().replace(" ", "-")
    aliases = {
        "xcode": "xcodebuild",
        "app-ui-validator": "app-ui",
        "full-npm-test": "npm-test-full",
        "npm": "npm-test",
        "vitest-run": "vitest",
        "swift-test": "swift-package-test",
    }
    return aliases.get(raw, raw or "unknown")


def can_launch(job: str, snapshot: dict[str, Any] | None = None) -> dict[str, Any]:
    """Advice only. Never kills or renices processes."""
    snap = snapshot if snapshot is not None else load_snapshot()
    if snap.get("_source") == "missing":
        return {
            "verdict": "wait",
            "job": normalize_job(job),
            "reasons": [snap.get("_error") or "fleet snapshot missing"],
            "advice": "Start BurnBar daemon or wait for fleet-snapshot.json. Do not guess load.",
        }
    job_id = normalize_job(job)
    machine = machine_block(snap)
    reasons: list[str] = []
    verdict = "go"

    def bump(level: str, reason: str) -> None:
        nonlocal verdict
        reasons.append(reason)
        order = {"go": 0, "wait": 1, "no": 2}
        if order[level] > order[verdict]:
            verdict = level

    cpu = machine.get("cpuPercent")
    mem_used = machine.get("memoryUsedBytes")
    mem_total = machine.get("memoryTotalBytes")
    mem_pct = None
    if isinstance(mem_used, (int, float)) and isinstance(mem_total, (int, float)) and mem_total:
        mem_pct = 100.0 * float(mem_used) / float(mem_total)
    load = None
    load_avg = machine.get("loadAverage")
    if isinstance(load_avg, list) and load_avg and isinstance(load_avg[0], (int, float)):
        load = float(load_avg[0])
    disk = machine.get("diskFreeBytes")
    running = running_agents(snap)
    running_count = int(snap.get("runningCount") or len(running))

    if isinstance(disk, int) and disk < 5 * 1024**3:
        bump("no", f"disk free {disk} bytes (< 5 GiB)")
    if mem_pct is not None and mem_pct >= 96:
        bump("no" if job_id in HEAVY_JOBS else "wait", f"memory {mem_pct:.0f}%")
    elif mem_pct is not None and mem_pct >= 90 and job_id in HEAVY_JOBS:
        bump("wait", f"memory {mem_pct:.0f}% (heavy job)")
    if isinstance(cpu, (int, float)) and cpu >= 85 and job_id in HEAVY_JOBS:
        bump("wait", f"cpu {cpu:.0f}%")
    if load is not None and load >= 12 and job_id in HEAVY_JOBS:
        bump("wait", f"load {load:.1f}")
    if job_id in HEAVY_JOBS and running_count >= 3:
        bump("wait", f"{running_count} agents already running")
    if job_id == "app-ui" and any(a.get("id") == "factory-droid" for a in running):
        bump("wait", "factory-droid is running — Droid app-UI validator cap is 1")

    presence = load_presence()
    for row in presence:
        intended = str(row.get("intendedTests") or "").lower()
        if job_id in HEAVY_JOBS and any(token in intended for token in ("xcode", "app-ui", "full-ci")):
            bump("wait", f"presence {row.get('agentId')} already claimed heavy tests ({row.get('task')})")

    peers = load_peer_snapshots()
    if peers:
        reasons.append(f"{len(peers)} peer snapshot(s) in BURNBAR_FLEET_PEER_DIR (local overlay, not CloudSync)")

    if not reasons:
        reasons.append("headroom looks ok")

    return {
        "verdict": verdict,
        "job": job_id,
        "reasons": reasons,
        "runningCount": running_count,
        "machine": {
            "cpuPercent": cpu,
            "memoryPercent": round(mem_pct, 1) if mem_pct is not None else None,
            "load1": load,
            "diskFreeBytes": disk,
        },
        "advice": "Advice only. Do not kill other agents. If wait/no, pick a lighter test or another machine.",
    }
