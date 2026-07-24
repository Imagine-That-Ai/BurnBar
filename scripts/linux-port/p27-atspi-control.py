#!/usr/bin/env python3
import argparse
import json
import logging
import re
from datetime import UTC, datetime

import pyatspi

LOGGER = logging.getLogger(__name__)


def walk(node, output):
    try:
        name = (node.name or "").strip()
        role = node.getRoleName()
        actions = []
        try:
            interface = node.queryAction()
            actions = [interface.getName(index) for index in range(interface.nActions)]
        except Exception:
            LOGGER.debug("AT-SPI action interface unavailable", exc_info=True)
        focused = False
        try:
            focused = node.getState().contains(pyatspi.STATE_FOCUSED)
        except Exception:
            LOGGER.debug("AT-SPI focus state unavailable", exc_info=True)
        if name:
            output.append({"name": name, "role": role, "actions": actions, "focused": focused})
        for index in range(min(node.childCount, 500)):
            walk(node.getChildAtIndex(index), output)
    except Exception:
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True, choices=["open", "reply", "cold", "warm"])
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    desktop = pyatspi.Registry.getDesktop(0)
    application = next((app for app in desktop if "openburnbar" in (app.name or "").lower()), None)
    if application is None:
        raise RuntimeError("OpenBurnBar AT-SPI application is absent")
    nodes = []
    walk(application, nodes)
    focused = next((node for node in nodes if node["focused"]), None)
    expected = {
        "open": ("overview", False, r"overview|dashboard"),
        "reply": ("chat", True, r"message|composer|chat"),
        "cold": ("account", False, r"membership|account"),
        "warm": ("providers", False, r"provider|model"),
    }[args.mode]
    observed = next((node["name"] for node in nodes if re.search(expected[2], node["name"], re.IGNORECASE)), None)
    if focused is None or observed is None:
        raise RuntimeError(f"{args.mode} focus or destination is absent from live AT-SPI")
    composer_focused = bool(re.search(r"message|composer|chat", focused["name"], re.IGNORECASE))
    if composer_focused != expected[1]:
        raise RuntimeError(f"{args.mode} composer focus outcome is incorrect")
    document = {
        "producer": "openburnbar-p27-atspi-live-v1",
        "application": "OpenBurnBar",
        "capturedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "focusedName": focused["name"],
        "route": expected[0],
        "composerFocused": composer_focused,
        "statusText": observed,
        "namedNodes": [{key: value for key, value in node.items() if key != "focused"} for node in nodes],
    }
    with open(args.output, "x", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")
    print(json.dumps(document))


if __name__ == "__main__":
    main()
