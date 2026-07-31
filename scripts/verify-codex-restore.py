#!/usr/bin/env python3
"""Verify a Backblaze restore of ~/.codex/sessions against the pre-deletion manifest.

Backblaze Personal Backup restores arrive as one or more ZIPs that expand to the
original absolute path layout (Users/albertonunez/.codex/sessions/YYYY/MM/DD/...).
This checks what actually landed against the manifest captured from Backblaze's
own bz_done ledger before the restore, so gaps are named rather than assumed.

    ./verify-codex-restore.py --restored /Volumes/X31/codex-sessions-restore

Reports: present / missing / unexpected, plus total bytes and any zero-length
files (a truncated restore looks like a successful one until you check sizes).
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

DEFAULT_MANIFEST = Path.home() / "codex-sessions-backblaze-manifest.txt"


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:,.1f} {unit}"
        n /= 1024
    return f"{n:,.1f} TB"


def key_of(p: str) -> str:
    """Reduce any path to the stable 'YYYY/MM/DD/rollout-....jsonl' tail."""
    parts = Path(p).parts
    if "sessions" in parts:
        return "/".join(parts[parts.index("sessions") + 1:])
    return Path(p).name


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restored", type=Path, required=True,
                    help="root the restore was extracted into")
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--list-missing", action="store_true",
                    help="print every missing path, not just the count")
    args = ap.parse_args()

    if not args.manifest.is_file():
        print(f"error: manifest not found at {args.manifest}", file=sys.stderr)
        return 2
    if not args.restored.is_dir():
        print(f"error: {args.restored} is not a directory "
              "(is the volume mounted and accessible?)", file=sys.stderr)
        return 2

    expected = {key_of(l.strip()): l.strip()
                for l in args.manifest.read_text().splitlines() if l.strip()}

    found: dict[str, Path] = {}
    empty: list[Path] = []
    total = 0
    for p in args.restored.rglob("rollout-*.jsonl*"):
        if not p.is_file():
            continue
        k = key_of(str(p))
        found[k] = p
        try:
            sz = p.stat().st_size
        except OSError:
            continue
        total += sz
        if sz == 0:
            empty.append(p)

    missing = sorted(set(expected) - set(found))
    unexpected = sorted(set(found) - set(expected))

    print(f"manifest expects   {len(expected):,} files")
    print(f"restore contains   {len(found):,} files  ({human(total)})")
    print(f"  present          {len(expected) - len(missing):,}")
    print(f"  MISSING          {len(missing):,}")
    print(f"  unexpected       {len(unexpected):,}")
    if empty:
        print(f"  ZERO-LENGTH      {len(empty):,}  <- truncated restore")

    if missing and args.list_missing:
        print("\n--- missing ---")
        for k in missing:
            print(f"  {expected[k]}")
    elif missing:
        print("\nfirst 10 missing (use --list-missing for all):")
        for k in missing[:10]:
            print(f"  {expected[k]}")

    if empty:
        print("\nzero-length files:")
        for p in empty[:10]:
            print(f"  {p}")

    ok = not missing and not empty
    print("\n" + ("RESTORE COMPLETE — every manifest file present and non-empty"
                  if ok else "RESTORE INCOMPLETE — see above"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
