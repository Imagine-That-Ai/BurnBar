#!/usr/bin/env python3

"""Extract the single macOS provisioning identifier from system_profiler JSON."""

from __future__ import annotations

import json
import re
import sys
from typing import NoReturn

PROVISIONING_UDID_PATTERN = re.compile(r"^[A-Za-z0-9-]{8,128}$")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"ERROR: {message}")


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        fail("system_profiler returned malformed JSON.")

    items = payload.get("SPHardwareDataType") if isinstance(payload, dict) else None
    values = (
        [
            item["provisioning_UDID"].strip()
            for item in items
            if isinstance(item, dict)
            and isinstance(item.get("provisioning_UDID"), str)
            and item["provisioning_UDID"].strip()
        ]
        if isinstance(items, list)
        else []
    )
    if len(values) != 1:
        fail(
            "system_profiler must return exactly one non-empty provisioning_UDID; "
            f"found {len(values)}."
        )

    provisioning_udid = values[0]
    if PROVISIONING_UDID_PATTERN.fullmatch(provisioning_udid) is None:
        fail("system_profiler returned a malformed provisioning_UDID.")

    print(provisioning_udid)


if __name__ == "__main__":
    main()
