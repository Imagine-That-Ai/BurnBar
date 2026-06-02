#!/usr/bin/env python3
"""
Retired legacy App Store Connect helper.

The maintained Computer Use / commercial IAP pipeline is:

  node tools/app-store-connect/submit-computer-use-iaps.js [--apply]

That Node pipeline is idempotent: it looks up existing subscription groups and
subscriptions, patches existing metadata/localizations, and applies USA base
pricing through /v1/subscriptionPrices.
"""
from __future__ import annotations

import argparse
import sys


CANONICAL_COMMAND = "node tools/app-store-connect/submit-computer-use-iaps.js [--apply]"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Retired flag retained only so old automation gets a clear error.",
    )
    parser.add_argument("--dry-run", action="store_true", help=argparse.SUPPRESS)
    parser.parse_known_args(argv)

    print("scripts/submit-asc-computer-use-iaps.py is retired.", file=sys.stderr)
    print("Use the maintained idempotent App Store Connect pipeline instead:", file=sys.stderr)
    print(f"  {CANONICAL_COMMAND}", file=sys.stderr)
    print(
        "The Node pipeline handles existing records, metadata updates, localizations, "
        "and subscription pricing.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
