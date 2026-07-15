#!/usr/bin/env python3
"""Validate an altool build-status response and emit its canonical success state."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


SUCCESS_STATES = {
    "complete",
    "completed",
    "processed",
    "processing complete",
    "success",
    "succeeded",
}
FAILURE_STATES = {
    "error",
    "failed",
    "failure",
    "invalid",
    "rejected",
}
STATUS_KEYS = {
    "buildstatus",
    "deliverystatus",
    "state",
    "status",
}


def status_values(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            normalized_key = "".join(character for character in key.lower() if character.isalnum())
            if normalized_key in STATUS_KEYS and isinstance(child, str) and child.strip():
                found.append(child.strip())
            found.extend(status_values(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(status_values(child))
    return found


def validate(path: Path) -> dict[str, str]:
    raw = path.read_bytes()
    if not raw:
        raise ValueError("App Store Connect status response is empty")
    value = json.loads(raw)
    statuses = status_values(value)
    normalized = [status.casefold() for status in statuses]
    failures = [status for status in normalized if status in FAILURE_STATES]
    successes = [status for status in normalized if status in SUCCESS_STATES]
    if failures or len(successes) != 1:
        raise ValueError(
            "App Store Connect response must contain exactly one successful terminal status "
            "and no failure status"
        )
    return {
        "processedStatus": successes[0],
        "statusResponseSha256": hashlib.sha256(raw).hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = validate(args.status)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
