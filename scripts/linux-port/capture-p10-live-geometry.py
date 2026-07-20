#!/usr/bin/env python3
"""Capture live AT-SPI extents for P-10 clipping and overlap certification."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from collections import deque
from datetime import UTC, datetime
from pathlib import Path


ACTIONABLE = {"button", "check box", "combo box", "entry", "link", "page tab", "radio button", "slider"}


def children(node):
    for index in range(int(getattr(node, "childCount", 0))):
        try:
            child = node.getChildAtIndex(index)
        except Exception:
            child = None
        if child is not None:
            yield child


def text(value) -> str:
    try:
        return str(value or "").replace("\n", " ").strip()
    except Exception:
        return ""


def find_application(pyatspi, name: str, timeout: float):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        desktop = pyatspi.Registry.getDesktop(0)
        for app in children(desktop):
            if name.casefold() in text(getattr(app, "name", "")).casefold():
                return app
        time.sleep(0.25)
    raise RuntimeError(f"AT-SPI application not found: {name}")


def extent(node, pyatspi):
    try:
        value = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
        return {"x": int(value.x), "y": int(value.y), "width": int(value.width), "height": int(value.height)}
    except Exception:
        return None


def intersects(left, right) -> bool:
    return (
        left["x"] < right["x"] + right["width"]
        and right["x"] < left["x"] + left["width"]
        and left["y"] < right["y"] + right["height"]
        and right["y"] < left["y"] + left["height"]
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", default="OpenBurnBar")
    parser.add_argument("--source-atspi", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=20.0)
    args = parser.parse_args()

    import pyatspi

    app = find_application(pyatspi, args.application, args.timeout_seconds)
    app_extent = extent(app, pyatspi)
    if not app_extent or app_extent["width"] < 320 or app_extent["height"] < 200:
        raise RuntimeError("OpenBurnBar has no usable live AT-SPI application extent")
    rows = []
    queue = deque([(app, "0", None)])
    while queue and len(rows) < 5000:
        node, node_path, parent_path = queue.popleft()
        role = text(node.getRoleName()).lower()
        name = text(getattr(node, "name", ""))
        bounds = extent(node, pyatspi)
        if bounds:
            rows.append({"path": node_path, "parent": parent_path, "role": role, "name": name, "bounds": bounds})
        for index, child in enumerate(children(node)):
            queue.append((child, f"{node_path}.{index}", node_path))
    if not rows:
        raise RuntimeError("OpenBurnBar exposed no live AT-SPI component extents")

    right = app_extent["x"] + app_extent["width"]
    bottom = app_extent["y"] + app_extent["height"]
    clipped = [
        row
        for row in rows
        if row["name"]
        and (
            row["bounds"]["x"] < app_extent["x"]
            or row["bounds"]["y"] < app_extent["y"]
            or row["bounds"]["x"] + row["bounds"]["width"] > right
            or row["bounds"]["y"] + row["bounds"]["height"] > bottom
        )
    ]
    actionable = [
        row for row in rows if row["role"] in ACTIONABLE and row["bounds"]["width"] > 0 and row["bounds"]["height"] > 0
    ]
    overlaps = []
    for index, left in enumerate(actionable):
        for right_row in actionable[index + 1 :]:
            if left["parent"] == right_row["parent"] and intersects(left["bounds"], right_row["bounds"]):
                overlaps.append({"left": left["path"], "right": right_row["path"]})
    text_overflow = [row for row in rows if row["name"] and (row["bounds"]["width"] < 8 or row["bounds"]["height"] < 8)]
    unreadable = [row for row in rows if row["name"] and row["bounds"]["width"] <= 0]
    source = Path(args.source_atspi).read_bytes()
    output = {
        "producer": "openburnbar-p10-live-geometry-probe-v1",
        "capturedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "sourceAtspiSha256": hashlib.sha256(source).hexdigest(),
        "nodesInspected": len(rows),
        "clippedElements": [{"path": row["path"], "name": row["name"], "bounds": row["bounds"]} for row in clipped],
        "overlaps": overlaps,
        "textOverflow": [{"path": row["path"], "name": row["name"], "bounds": row["bounds"]} for row in text_overflow],
        "unreadableText": [{"path": row["path"], "name": row["name"], "bounds": row["bounds"]} for row in unreadable],
    }
    Path(args.output).write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    if clipped or overlaps or text_overflow or unreadable:
        raise RuntimeError("live dashboard geometry contains clipping, overlap, overflow, or unreadable text")


if __name__ == "__main__":
    main()
