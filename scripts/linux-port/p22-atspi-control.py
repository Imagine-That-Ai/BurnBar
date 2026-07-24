#!/usr/bin/env python3
"""Bounded AT-SPI controller for the installed P-22 Database flow."""

from __future__ import annotations

import argparse
import json
import time
from collections import deque
from pathlib import Path
from typing import Any


def safe(value: Any) -> str:
    try:
        return str(value or "").replace("\n", " ").strip()
    except Exception:
        return ""


def children(node: Any):
    for index in range(int(getattr(node, "childCount", 0))):
        try:
            yield node.getChildAtIndex(index)
        except Exception as error:
            _ = error


def role(node: Any) -> str:
    try:
        return safe(node.getRoleName()).lower()
    except Exception:
        return "unknown"


def actions(node: Any) -> list[str]:
    try:
        action = node.queryAction()
        return [safe(action.getName(index)).lower() for index in range(action.nActions)]
    except Exception:
        return []


def states(node: Any, pyatspi: Any) -> list[str]:
    try:
        return sorted(safe(pyatspi.stateToString(value)).lower() for value in node.getState().getStates())
    except Exception:
        return []


def application(pyatspi: Any, expected: str, timeout: float):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for app in children(pyatspi.Registry.getDesktop(0)):
            if expected.casefold() in safe(getattr(app, "name", "")).casefold():
                return app
        time.sleep(0.2)
    raise RuntimeError(f"AT-SPI application not found: {expected}")


def walk(root: Any, limit: int = 5000):
    queue = deque([root])
    visited = 0
    while queue and visited < limit:
        node = queue.popleft()
        visited += 1
        yield node
        queue.extend(children(node))
    if queue:
        raise RuntimeError("AT-SPI tree exceeded the P-22 node budget")


def find(root: Any, expected: str, actionable: bool = False):
    needle = expected.casefold()
    matches = []
    for node in walk(root):
        name = safe(getattr(node, "name", ""))
        node_actions = actions(node)
        if needle not in name.casefold() or (actionable and not node_actions):
            continue
        score = 0 if name.casefold() == needle else 1 if name.casefold().startswith(needle) else 2
        matches.append((score, len(name), node))
    if not matches:
        raise RuntimeError(f"AT-SPI node not found: {expected}")
    matches.sort(key=lambda row: (row[0], row[1]))
    return matches[0][2]


def activate(node: Any) -> dict[str, str]:
    action = node.queryAction()
    names = [safe(action.getName(index)).lower() for index in range(action.nActions)]
    preferred = ("press", "click", "activate", "select", "jump")
    index = next((i for name in preferred for i, available in enumerate(names) if available == name), 0)
    if not names or not action.doAction(index):
        raise RuntimeError(f"AT-SPI action failed: {safe(getattr(node, 'name', ''))}")
    return {"name": safe(getattr(node, "name", "")), "role": role(node), "action": names[index]}


def set_text(node: Any, value: str) -> dict[str, str]:
    try:
        editable = node.queryEditableText()
        editable.setTextContents(value)
    except Exception as error:
        raise RuntimeError(f"AT-SPI text update failed: {safe(getattr(node, 'name', ''))}") from error
    return {"name": safe(getattr(node, "name", "")), "role": role(node), "value": value}


def snapshot(root: Any, pyatspi: Any) -> dict[str, Any]:
    rows = []
    for node in walk(root):
        name = safe(getattr(node, "name", ""))
        node_actions = actions(node)
        node_states = states(node, pyatspi)
        if name or node_actions or "selected" in node_states or "focused" in node_states:
            rows.append({"name": name, "role": role(node), "actions": node_actions, "states": node_states})
    if len(rows) < 20:
        raise RuntimeError("installed Database exposed too few AT-SPI nodes")
    return {
        "producer": "openburnbar-p22-atspi-control-v1",
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "nodes": rows,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", default="OpenBurnBar")
    parser.add_argument("--mode", required=True, choices=("snapshot", "activate", "set-text"))
    parser.add_argument("--name")
    parser.add_argument("--value")
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=20.0)
    args = parser.parse_args()

    import pyatspi

    app = application(pyatspi, args.application, args.timeout_seconds)
    if args.mode == "snapshot":
        result = snapshot(app, pyatspi)
    elif args.mode == "activate":
        if not args.name:
            raise RuntimeError("--name is required")
        result = {"producer": "openburnbar-p22-atspi-control-v1", "activation": activate(find(app, args.name, True))}
    else:
        if not args.name or args.value is None:
            raise RuntimeError("--name and --value are required")
        result = {"producer": "openburnbar-p22-atspi-control-v1", "text": set_text(find(app, args.name), args.value)}
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
