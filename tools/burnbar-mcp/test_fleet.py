#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import fleet


def _snap(**overrides):
    base = {
        "schemaVersion": 1,
        "generatedAt": "2026-08-15T18:00:00.000Z",
        "runningCount": 1,
        "agents": [
            {
                "id": "grok-cli",
                "status": "running",
                "displayName": "Grok CLI",
                "projectName": "/tmp/repo",
                "confidence": "exactProcess",
                "process": {"pid": 1},
            }
        ],
        "machine": {
            "cpuPercent": 20.0,
            "memoryUsedBytes": 8 * 1024**3,
            "memoryTotalBytes": 32 * 1024**3,
            "loadAverage": [1.0, 1.0, 1.0],
            "diskFreeBytes": 200 * 1024**3,
        },
        "repos": [{"projectName": "/tmp/repo", "agents": ["grok-cli"]}],
        "orchestrator": {"designation": {"kind": "none"}, "pendingDirectives": 0},
    }
    base.update(overrides)
    return base


class FleetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        os.environ["BURNBAR_DAEMON_SUPPORT_DIR"] = str(self.root)
        os.environ.pop("BURNBAR_FLEET_SNAPSHOT_PATH", None)
        os.environ.pop("BURNBAR_FLEET_PRESENCE_PATH", None)
        os.environ.pop("BURNBAR_FLEET_PEER_DIR", None)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_summarize_from_file(self) -> None:
        path = self.root / "fleet-snapshot.json"
        path.write_text(json.dumps(_snap()))
        summary = fleet.summarize_snapshot(fleet.load_snapshot())
        self.assertEqual(summary["source"], "file")
        self.assertEqual(summary["runningCount"], 1)
        self.assertEqual(summary["running"][0]["id"], "grok-cli")
        self.assertEqual(summary["machine"]["memoryPercent"], 25.0)

    def test_missing_snapshot_wait(self) -> None:
        decision = fleet.can_launch("xcodebuild")
        self.assertEqual(decision["verdict"], "wait")
        blob = " ".join(decision["reasons"] + [decision.get("advice", "")]).lower()
        self.assertTrue("fleet-snapshot" in blob or "missing" in blob)

    def test_heavy_job_waits_when_hot(self) -> None:
        snap = _snap(
            runningCount=3,
            machine={
                "cpuPercent": 90.0,
                "memoryUsedBytes": 30 * 1024**3,
                "memoryTotalBytes": 32 * 1024**3,
                "loadAverage": [14.0],
                "diskFreeBytes": 100 * 1024**3,
            },
            agents=[
                {"id": "factory-droid", "status": "running"},
                {"id": "cursor", "status": "running"},
                {"id": "grok-cli", "status": "running"},
            ],
        )
        decision = fleet.can_launch("xcodebuild", snap)
        self.assertEqual(decision["verdict"], "wait")
        self.assertTrue(any("cpu" in r or "memory" in r or "load" in r or "running" in r for r in decision["reasons"]))

    def test_low_disk_is_no(self) -> None:
        snap = _snap(machine={"diskFreeBytes": 1024, "memoryTotalBytes": 32 * 1024**3, "memoryUsedBytes": 1})
        decision = fleet.can_launch("vitest", snap)
        self.assertEqual(decision["verdict"], "no")

    def test_presence_ttl_and_can_launch(self) -> None:
        now = datetime(2026, 8, 15, 18, 0, tzinfo=timezone.utc)
        fleet.record_presence(
            agent_id="cursor",
            host_id="macbook",
            cwd="/Users/albertonunez/Developer/AgentLens",
            task="Live Agent Fleet MCP",
            intended_tests="xcodebuild",
            ttl_seconds=300,
            now=now,
        )
        live = fleet.load_presence(now=now.timestamp() + 10)
        self.assertEqual(len(live), 1)
        stale = fleet.load_presence(now=now.timestamp() + 400)
        self.assertEqual(stale, [])
        decision = fleet.can_launch("xcodebuild", _snap())
        # presence recordedAt is 2026, load_presence uses time.time() in can_launch —
        # rewrite presence with current time
        fleet.record_presence(
            agent_id="cursor",
            host_id="macbook",
            cwd="/tmp",
            task="heavy UI",
            intended_tests="app-ui",
            ttl_seconds=300,
        )
        decision = fleet.can_launch("xcodebuild", _snap())
        self.assertEqual(decision["verdict"], "wait")

    def test_peer_dir_overlay(self) -> None:
        peers = self.root / "peers"
        peers.mkdir()
        (peers / "mini.json").write_text(json.dumps(_snap(runningCount=2)))
        os.environ["BURNBAR_FLEET_PEER_DIR"] = str(peers)
        loaded = fleet.load_peer_snapshots()
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0]["_hostId"], "mini")
        (self.root / "fleet-snapshot.json").write_text(json.dumps(_snap()))
        decision = fleet.can_launch("vitest")
        self.assertTrue(any("peer" in r.lower() for r in decision["reasons"]))

    def test_app_ui_waits_for_droid(self) -> None:
        snap = _snap(
            runningCount=1,
            agents=[{"id": "factory-droid", "status": "running", "projectName": "/Users/albertonunez/Developer/AgentLens"}],
        )
        self.assertEqual(fleet.can_launch("app-ui", snap)["verdict"], "wait")
        self.assertEqual(fleet.can_launch("app-ui", _snap())["verdict"], "go")


if __name__ == "__main__":
    unittest.main()
