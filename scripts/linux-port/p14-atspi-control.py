#!/usr/bin/env python3
"""Bounded AT-SPI controller for the installed P-14 chat certification flow."""

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
        except Exception:
            continue


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


def find_application(pyatspi: Any, expected: str, timeout: float):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        desktop = pyatspi.Registry.getDesktop(0)
        for app in children(desktop):
            if expected.casefold() in safe(getattr(app, "name", "")).casefold():
                return app
        time.sleep(0.2)
    raise RuntimeError(f"AT-SPI application not found: {expected}")


def walk(root: Any, limit: int = 5000):
    queue = deque([root])
    seen = 0
    while queue and seen < limit:
        node = queue.popleft()
        seen += 1
        yield node
        queue.extend(children(node))
    if queue:
        raise RuntimeError("AT-SPI tree exceeded the P-14 node budget")


def find_node(root: Any, expected: str, expected_role: str | None = None, actionable: bool = False):
    needle = expected.casefold()
    candidates = []
    for node in walk(root):
        name = safe(getattr(node, "name", ""))
        node_role = role(node)
        node_actions = actions(node)
        if needle not in name.casefold() or (expected_role and node_role != expected_role.casefold()):
            continue
        if actionable and not node_actions:
            continue
        score = 0 if name.casefold() == needle else 1 if name.casefold().startswith(needle) else 2
        candidates.append((score, len(name), node))
    if not candidates:
        raise RuntimeError(f"AT-SPI node not found: {expected}")
    candidates.sort(key=lambda item: (item[0], item[1]))
    return candidates[0][2]


def activate(node: Any) -> dict[str, Any]:
    action = node.queryAction()
    names = [safe(action.getName(index)).lower() for index in range(action.nActions)]
    preferred = ("press", "click", "activate", "select", "jump")
    index = next((i for name in preferred for i, available in enumerate(names) if available == name), 0)
    if not names or not action.doAction(index):
        raise RuntimeError(f"AT-SPI action failed: {safe(getattr(node, 'name', ''))}")
    return {"name": safe(getattr(node, "name", "")), "role": role(node), "action": names[index]}


def set_text(node: Any, value: str) -> None:
    try:
        editable = node.queryEditableText()
        if not editable.setTextContents(value):
            raise RuntimeError("setTextContents returned false")
    except Exception as error:
        raise RuntimeError(f"AT-SPI text replacement failed: {error}") from error


def snapshot(root: Any, pyatspi: Any) -> dict[str, Any]:
    rows = []
    for node in walk(root):
        name = safe(getattr(node, "name", ""))
        node_role = role(node)
        node_actions = actions(node)
        node_states = states(node, pyatspi)
        if name or node_actions or "selected" in node_states or "focused" in node_states:
            rows.append({"name": name, "role": node_role, "actions": node_actions, "states": node_states})
    if len(rows) < 10:
        raise RuntimeError("installed chat exposed too few AT-SPI nodes")
    return {"producer": "openburnbar-p14-atspi-control-v1", "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "nodes": rows}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", default="OpenBurnBar")
    parser.add_argument("--mode", required=True, choices=("snapshot", "activate", "set-text", "select"))
    parser.add_argument("--name")
    parser.add_argument("--role")
    parser.add_argument("--text")
    parser.add_argument("--option")
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=20.0)
    args = parser.parse_args()

    import pyatspi  # type: ignore

    app = find_application(pyatspi, args.application, args.timeout_seconds)
    result: dict[str, Any]
    if args.mode == "snapshot":
        result = snapshot(app, pyatspi)
    elif args.mode == "activate":
        if not args.name:
            raise RuntimeError("--name is required")
        result = {"producer": "openburnbar-p14-atspi-control-v1", "activation": activate(find_node(app, args.name, args.role, True))}
    elif args.mode == "set-text":
        if not args.name or args.text is None:
            raise RuntimeError("--name and --text are required")
        node = find_node(app, args.name, args.role)
        set_text(node, args.text)
        result = {"producer": "openburnbar-p14-atspi-control-v1", "edited": {"name": safe(getattr(node, "name", "")), "role": role(node), "utf8Bytes": len(args.text.encode("utf-8"))}}
    else:
        if not args.name or not args.option:
            raise RuntimeError("--name and --option are required")
        activate(find_node(app, args.name, args.role, True))
        deadline = time.monotonic() + args.timeout_seconds
        selected = None
        while time.monotonic() < deadline:
            app = find_application(pyatspi, args.application, 1.0)
            try:
                selected = activate(find_node(app, args.option, None, True))
                break
            except Exception:
                time.sleep(0.2)
        if selected is None:
            raise RuntimeError(f"AT-SPI option not found: {args.option}")
        result = {"producer": "openburnbar-p14-atspi-control-v1", "selection": selected}
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
