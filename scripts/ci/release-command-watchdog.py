#!/usr/bin/env python3
"""Run a release command with a hard outer watchdog.

`xcrun notarytool submit --wait --timeout 30m` is the inner Apple wait bound,
but release evidence has shown the process can remain attached to the GitHub
Actions step beyond that requested timeout. This wrapper owns the process group
and returns 124 after the outer deadline, allowing the workflow to retry/fail
with a useful error instead of burning the whole release job timeout. It is also
used around `stapler`, which has no comparable CLI timeout flag.
"""

from __future__ import annotations

import argparse
import os
import shlex
import signal
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, help="Human-readable notary auth mode.")
    parser.add_argument(
        "--outer-timeout-seconds",
        required=True,
        type=int,
        help="Hard wall-clock deadline for the child process group.",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Command to run after --.")
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("command is required after --")
    if args.outer_timeout_seconds <= 0:
        parser.error("--outer-timeout-seconds must be positive")
    return args


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=15)
    except Exception:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except Exception as kill_error:
            print(
                f"::warning::failed to SIGKILL release command process group: {kill_error}",
                file=sys.stderr,
                flush=True,
            )


def main() -> int:
    args = parse_args()
    print(f"Release command attempt: {args.mode}", flush=True)
    print("+ " + " ".join(shlex.quote(part) for part in args.command), flush=True)

    process = subprocess.Popen(args.command, start_new_session=True)
    try:
        return process.wait(timeout=args.outer_timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"::error::{args.mode} attempt exceeded outer watchdog "
            f"({args.outer_timeout_seconds}s). Terminating process group before "
            "fallback/failed release.",
            file=sys.stderr,
            flush=True,
        )
        terminate_process_group(process)
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
