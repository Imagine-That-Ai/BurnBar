#!/usr/bin/env python3
import argparse
import json
import logging
import re
import time
from datetime import UTC, datetime

import pyatspi

LOGGER = logging.getLogger(__name__)


def children(node):
    for index in range(min(node.childCount, 500)):
        try:
            yield node.getChildAtIndex(index)
        except Exception:
            LOGGER.debug("AT-SPI child lookup failed at index %d", index, exc_info=True)
            continue


def walk(node, depth=0):
    if depth > 12:
        return
    yield node
    for child in children(node):
        yield from walk(child, depth + 1)


def text(node):
    try:
        return (node.name or "").strip()
    except Exception:
        return ""


def actions(node):
    try:
        interface = node.queryAction()
        return interface, [interface.getName(index) for index in range(interface.nActions)]
    except Exception:
        return None, []


def ancestors(node):
    current = node
    for _ in range(8):
        if current is None:
            return
        yield current
        try:
            current = current.parent
        except Exception:
            return


def activate(marker, action):
    expected = re.compile(rf"^{re.escape(action)}$", re.IGNORECASE)
    desktop = pyatspi.Registry.getDesktop(0)
    for application in desktop:
        for marker_node in walk(application):
            if marker not in text(marker_node):
                continue
            for container in ancestors(marker_node):
                for node in walk(container, 0):
                    if not expected.match(text(node)):
                        continue
                    interface, names = actions(node)
                    if interface is None:
                        continue
                    for index, name in enumerate(names):
                        if name.lower() in {"click", "press", "activate", "invoke"} or len(names) == 1:
                            if interface.doAction(index):
                                return {
                                    "producer": "openburnbar-p27-notification-atspi-action-v1",
                                    "capturedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                                    "marker": marker,
                                    "action": action.lower(),
                                    "application": text(application),
                                    "controlName": text(node),
                                    "activated": True,
                                }
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--marker", required=True)
    parser.add_argument("--action", required=True, choices=["open", "reply"])
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    deadline = time.monotonic() + max(1.0, min(args.timeout, 30.0))
    while time.monotonic() < deadline:
        result = activate(args.marker, args.action)
        if result is not None:
            print(json.dumps(result))
            return
        time.sleep(0.2)
    raise RuntimeError("native notification action is absent from the live AT-SPI tree")


if __name__ == "__main__":
    main()
