#!/usr/bin/env python3
"""Regression scan for committed hosted-relay runbook topology leaks."""
from __future__ import annotations

import ipaddress
import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
RUNBOOK_DIR = ROOT / "docs/runbooks/iroh-dev-validation"
RUNBOOKS = sorted(RUNBOOK_DIR.glob("*hosted-relay-payload-run.json"))

IP_PORT_RE = re.compile(r"\b(?P<ip>(?:\d{1,3}\.){3}\d{1,3}):(?P<port>\d{2,5})\b")
COREDEVICE_ID_RE = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
ESCROW_DEVICE_PATH_RE = re.compile(
    r"escrow_devices/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)
IROH_NODE_ID_RE = re.compile(r"^[0-9a-f]{64}$")


def walk(value: Any, path: tuple[str, ...] = ()) -> list[tuple[tuple[str, ...], Any]]:
    rows = [(path, value)]
    if isinstance(value, dict):
        for key, child in value.items():
            rows.extend(walk(child, path + (str(key),)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            rows.extend(walk(child, path + (str(index),)))
    return rows


def assert_runbook_redacted(path: Path) -> None:
    payload = json.loads(path.read_text(encoding="utf-8"))
    failures: list[str] = []

    for location, value in walk(payload):
        leaf = location[-1] if location else ""
        rendered = ".".join(location)
        if leaf == "directAddresses":
            failures.append(f"{rendered}: raw directAddresses key is not allowed")
        if isinstance(value, str):
            if "burnbar.iroh.link" in value:
                failures.append(f"{rendered}: hosted relay URL must be redacted")
            for match in IP_PORT_RE.finditer(value):
                try:
                    ip = ipaddress.ip_address(match.group("ip"))
                except ValueError:
                    continue
                if not ip.is_loopback:
                    failures.append(f"{rendered}: direct IP:port must be redacted")
            if leaf in {"device", "deviceId"} and COREDEVICE_ID_RE.fullmatch(value):
                failures.append(f"{rendered}: physical device identifier must be redacted")
            if leaf == "nodeId" and IROH_NODE_ID_RE.fullmatch(value):
                failures.append(f"{rendered}: iroh node ID must be redacted")

    if failures:
        raise AssertionError(f"{path} contains unredacted topology:\n" + "\n".join(failures))


def main() -> None:
    if not RUNBOOKS:
        raise AssertionError(f"No hosted relay payload runbooks found under {RUNBOOK_DIR}")
    for runbook in RUNBOOKS:
        assert_runbook_redacted(runbook)
    escrow_failures: list[str] = []
    for runbook in sorted((ROOT / "docs/runbooks").rglob("*")):
        if not runbook.is_file():
            continue
        try:
            text = runbook.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if ESCROW_DEVICE_PATH_RE.search(text):
            escrow_failures.append(str(runbook.relative_to(ROOT)))
    if escrow_failures:
        raise AssertionError(
            "Runbooks contain raw escrow_devices UUID paths:\n" + "\n".join(escrow_failures)
        )
    print(f"iroh hosted-relay runbook redaction ok ({len(RUNBOOKS)} files)")


if __name__ == "__main__":
    main()
