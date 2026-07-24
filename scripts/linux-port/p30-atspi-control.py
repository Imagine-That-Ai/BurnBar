#!/usr/bin/env python3
"""Bounded AT-SPI controller for the installed P-30 Pet Companion flow."""

from __future__ import annotations

import argparse
import json
import logging
import time
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Any

LOGGER = logging.getLogger(__name__)


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
            LOGGER.debug("AT-SPI child lookup failed at index %d", index, exc_info=True)
            continue


def walk(root: Any, limit: int = 6000):
    queue = deque([root])
    seen = 0
    while queue and seen < limit:
        node = queue.popleft()
        seen += 1
        yield node
        queue.extend(children(node))
    if queue:
        raise RuntimeError("AT-SPI tree exceeded the P-30 node budget")


def application(pyatspi: Any, timeout: float):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        matches = [
            app
            for app in children(pyatspi.Registry.getDesktop(0))
            if "openburnbar" in safe(getattr(app, "name", "")).casefold()
        ]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RuntimeError("multiple OpenBurnBar AT-SPI applications are running")
        time.sleep(0.2)
    raise RuntimeError("OpenBurnBar AT-SPI application not found")


def details(node: Any) -> tuple[str, str, list[str], list[str]]:
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
        attributes = [safe(value) for value in node.getAttributes()]
    except Exception:
        attributes = []
    return name, role, actions, attributes


def find(root: Any, expected: str, actionable: bool = False):
    needle = expected.casefold()
    matches = []
    for node in walk(root):
        name, _, actions, _ = details(node)
        if needle not in name.casefold() or (actionable and not actions):
            continue
        matches.append((0 if name.casefold() == needle else 1, len(name), node))
    if not matches:
        raise RuntimeError(f"AT-SPI node not found: {expected}")
    return sorted(matches, key=lambda row: (row[0], row[1]))[0][2]


def activate(node: Any) -> None:
    action = node.queryAction()
    names = [safe(action.getName(index)).lower() for index in range(action.nActions)]
    index = next(
        (
            index
            for wanted in ("press", "click", "activate", "toggle", "select")
            for index, name in enumerate(names)
            if name == wanted
        ),
        0,
    )
    if not names or not action.doAction(index):
        raise RuntimeError(f"AT-SPI action failed: {safe(getattr(node, 'name', ''))}")


def focus(node: Any) -> None:
    if not node.queryComponent().grabFocus():
        raise RuntimeError("AT-SPI focus request was rejected")


def status(root: Any) -> str:
    candidates = []
    for node in walk(root):
        name, role, _, attributes = details(node)
        if role in ("status bar", "notification", "alert") or any("live=" in item for item in attributes):
            if name:
                candidates.append(name)
    if not candidates:
        raise RuntimeError("Pet live status was not exposed through AT-SPI")
    return candidates[-1]


def snapshot(root: Any) -> dict[str, Any]:
    rows = []
    focused = ""
    shortcut = ""
    for node in walk(root):
        name, role, actions, attributes = details(node)
        if name or actions:
            rows.append({"name": name, "role": role, "actions": actions})
        try:
            states = [safe(value).lower() for value in node.getState().getStates()]
            if any("focused" in value for value in states) and name:
                focused = name
        except Exception:
            LOGGER.debug("AT-SPI focus state unavailable", exc_info=True)
        if any("ctrl+alt+super+p" in value.casefold() for value in attributes):
            shortcut = "Ctrl+Alt+Super+P"
    preview = find(root, "Pet companion contained preview")
    focus(preview)
    focused = safe(getattr(preview, "name", ""))
    if not shortcut:
        try:
            button = find(root, "Open native companion", True)
            _, _, _, attributes = details(button)
            if any("ctrl+alt+super+p" in value.casefold() for value in attributes):
                shortcut = "Ctrl+Alt+Super+P"
        except RuntimeError:
            shortcut = "unavailable-on-contained-fallback"
    if len(rows) < 6:
        raise RuntimeError("Pet surface exposed too few named AT-SPI nodes")
    return {
        "producer": "openburnbar-p30-atspi-live-v1",
        "application": "OpenBurnBar",
        "capturedAt": datetime.now(datetime.UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "focusedName": focused,
        "statusText": status(root),
        "ariaKeyshortcuts": shortcut,
        "namedNodes": rows,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        required=True,
        choices=(
            "route",
            "summon",
            "select",
            "clear",
            "keyboard",
            "reset",
            "pointer",
            "native-open",
            "click-through",
            "click-restore",
            "snapshot",
        ),
    )
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=20.0)
    args = parser.parse_args()
    import pyatspi  # type: ignore

    app = application(pyatspi, args.timeout_seconds)
    if args.mode == "route":
        activate(find(app, "Pet companion", True))
        result = {
            "producer": "openburnbar-p30-atspi-live-v1",
            "application": "OpenBurnBar",
            "routeActivated": "Pet companion",
        }
        Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, separators=(",", ":")))
        return
    elif args.mode == "summon":
        activate(find(app, "Summon contained preview", True))
    elif args.mode == "select":
        activate(find(app, "Select contained pet", True))
    elif args.mode == "clear":
        activate(find(app, "Pet selected", True))
    elif args.mode == "keyboard":
        preview = find(app, "Pet companion contained preview")
        focus(preview)
        for key in ("Right", "Down"):
            pyatspi.Registry.generateKeyboardEvent(0, key, pyatspi.KEY_SYM)
    elif args.mode == "reset":
        preview = find(app, "Pet companion contained preview")
        focus(preview)
        pyatspi.Registry.generateKeyboardEvent(0, "Home", pyatspi.KEY_SYM)
    elif args.mode == "pointer":
        preview = find(app, "Pet companion contained preview")
        extents = preview.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
        pyatspi.Registry.generateMouseEvent(extents.x + 20, extents.y + 20, "b1p")
        pyatspi.Registry.generateMouseEvent(extents.x + 70, extents.y + 50, "abs")
        pyatspi.Registry.generateMouseEvent(extents.x + 70, extents.y + 50, "b1r")
    elif args.mode == "native-open":
        activate(find(app, "Open native companion", True))
    elif args.mode == "click-through":
        activate(find(app, "Enable click-through", True))
    elif args.mode == "click-restore":
        activate(find(app, "Restore companion interaction", True))
    time.sleep(0.35)
    document = snapshot(app)
    Path(args.output).write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(document, separators=(",", ":")))


if __name__ == "__main__":
    main()
