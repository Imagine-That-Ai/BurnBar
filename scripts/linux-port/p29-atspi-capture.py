#!/usr/bin/env python3
"""Capture a bounded, real AT-SPI tree for the installed P-29 surface."""

import argparse
import json
import logging
import time
from collections import deque
from pathlib import Path

LOGGER = logging.getLogger(__name__)


def safe(value):
    try:
        return str(value or "").replace("\n", " ").strip()
    except Exception:
        return ""


def children(node):
    for index in range(int(getattr(node, "childCount", 0))):
        try:
            yield node.getChildAtIndex(index)
        except Exception:
            LOGGER.debug("AT-SPI child lookup failed at index %d", index, exc_info=True)
            continue


def application(pyatspi, expected, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for app in children(pyatspi.Registry.getDesktop(0)):
            if expected.casefold() in safe(getattr(app, "name", "")).casefold():
                return app
        time.sleep(0.2)
    raise RuntimeError("OpenBurnBar AT-SPI application was not found")


def walk(root, limit=6000):
    queue = deque([root])
    visited = 0
    while queue and visited < limit:
        node = queue.popleft()
        visited += 1
        yield node
        queue.extend(children(node))
    if queue:
        raise RuntimeError("P-29 AT-SPI tree exceeded its node budget")


def inspect(root, pyatspi):
    rows = []
    for node in walk(root):
        name = safe(getattr(node, "name", ""))
        try:
            role = safe(node.getRoleName()).lower()
        except Exception:
            role = "unknown"
        try:
            action = node.queryAction()
            actions = [safe(action.getName(index)).lower() for index in range(action.nActions)]
        except Exception:
            actions = []
        try:
            states = sorted(safe(pyatspi.stateToString(value)).lower() for value in node.getState().getStates())
        except Exception:
            states = []
        if name or actions or states:
            rows.append({"name": name, "role": role, "actions": actions, "states": states})
    if len(rows) < 8:
        raise RuntimeError("P-29 surface exposed fewer than eight AT-SPI nodes")
    names = " ".join(row["name"] for row in rows).casefold()
    if "text expansion" not in names and "input-method engine" not in names:
        raise RuntimeError("P-29 text-expansion surface was not visible through AT-SPI")
    return rows


def find_named(root, expected):
    matches = [node for node in walk(root) if safe(getattr(node, "name", "")) == expected]
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one AT-SPI node named {expected!r}, found {len(matches)}")
    return matches[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    parser.add_argument("--application", default="OpenBurnBar")
    parser.add_argument("--mode", choices=("snapshot", "focus"), default="snapshot")
    parser.add_argument("--name")
    parser.add_argument("--route", default="text-expansion")
    parser.add_argument("--timeout-seconds", type=float, default=20.0)
    args = parser.parse_args()
    import pyatspi

    root = application(pyatspi, args.application, args.timeout_seconds)
    if args.mode == "focus":
        if not args.name:
            raise RuntimeError("--name is required for focus mode")
        node = find_named(root, args.name)
        if not node.queryComponent().grabFocus():
            raise RuntimeError(f"AT-SPI could not focus {args.name!r}")
        document = {
            "application": args.application,
            "mode": "focus",
            "name": safe(getattr(node, "name", "")),
            "role": safe(node.getRoleName()).lower(),
        }
        print(json.dumps(document, separators=(",", ":")))
        return
    if not args.output:
        raise RuntimeError("--output is required for snapshot mode")
    rows = inspect(root, pyatspi)
    document = {
        "application": args.application,
        "route": args.route,
        "pass": True,
        "producer": "openburnbar-p29-atspi-capture-v1",
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "nodes": rows,
    }
    Path(args.output).write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(document, separators=(",", ":")))


if __name__ == "__main__":
    main()
