#!/usr/bin/env python3
"""Validate and write Sentry DSNs as data, never shell/parser fragments."""

from __future__ import annotations

import os
import plistlib
import sys
import urllib.parse
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def validate_sentry_dsn(raw: str, name: str) -> str:
    if not raw:
        return ""
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in raw):
        fail(f"{name} must not contain control characters.")
    if any(ch.isspace() for ch in raw):
        fail(f"{name} must not contain raw whitespace.")

    try:
        parsed = urllib.parse.urlsplit(raw)
    except ValueError as exc:
        fail(f"{name} is not a valid URL: {exc}")

    if parsed.scheme != "https":
        fail(f"{name} must use https.")
    if not parsed.username or not parsed.hostname:
        fail(f"{name} does not match the expected Sentry DSN shape.")
    if parsed.password:
        fail(f"{name} must not include a password component.")

    path_segments = [segment for segment in parsed.path.split("/") if segment]
    project_id = path_segments[-1] if path_segments else ""
    if not project_id.isdigit():
        fail(f"{name} does not match the expected Sentry DSN shape.")

    return parsed.geturl()


def inject_plists(env_name: str, plist_paths: list[str]) -> None:
    dsn = validate_sentry_dsn(os.environ.get(env_name, ""), env_name)
    if not dsn:
        return

    for raw_path in plist_paths:
        if not raw_path:
            continue
        path = Path(raw_path)
        if not path.exists():
            print(f"::warning::Sentry target plist not found: {path}")
            continue
        try:
            payload = plistlib.loads(path.read_bytes())
        except Exception as exc:
            fail(f"Plist syntax validation failed for {path}: {exc}")
        payload["sentry.dsn"] = dsn
        path.write_bytes(plistlib.dumps(payload, sort_keys=True))
        try:
            plistlib.loads(path.read_bytes())
        except Exception as exc:
            fail(f"Plist syntax validation failed after mutation for {path}: {exc}")
        print(f"::notice::Sentry DSN injected into {path}")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: sentry_dsn.py validate ENV_NAME | plist-env ENV_NAME PATH[:PATH...]",
            file=sys.stderr,
        )
        return 2

    command = argv[1]
    env_name = argv[2]
    if command == "validate":
        print(validate_sentry_dsn(os.environ.get(env_name, ""), env_name))
        return 0
    if command == "plist-env":
        if len(argv) != 4:
            print("usage: sentry_dsn.py plist-env ENV_NAME PATH[:PATH...]", file=sys.stderr)
            return 2
        inject_plists(env_name, argv[3].split(":"))
        return 0

    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
