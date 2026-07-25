#!/usr/bin/env python3
"""Verify a Backblaze restore of ~/.codex/sessions against the pre-deletion manifest.

Backblaze Personal Backup restores arrive as one or more ZIPs that expand to the
original absolute path layout (Users/albertonunez/.codex/sessions/YYYY/MM/DD/...).
This checks what actually landed against the manifest captured from Backblaze's
own bz_done ledger before the restore, so gaps are named rather than assumed.

    ./verify-codex-restore.py --restored /Volumes/X31/codex-sessions-restore

Manifest format, one entry per line:

    <path>\t<bytes>     size-verified (detects truncated/partial restores)
    <path>              existence-only; requires --presence-only to accept

A verifier that gates discarding the other copies must compare sizes, not just
existence: a rollout truncated to one byte still "exists". Generate a sized
manifest with e.g.

    while IFS= read -r p; do printf '%s\t%s\n' "$p" "$(stat -f%z "$p")"; done \
        < paths.txt > manifest.txt

Reports: present / missing / unexpected / size-mismatched, plus total bytes and
any zero-length files.
"""

from __future__ import annotations

import argparse
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
    """Reduce any path to the stable 'YYYY/MM/DD/rollout-....jsonl' tail.

    A restore can be extracted under an ancestor that is itself named
    'sessions' (e.g. /Volumes/X31/sessions/Users/me/.codex/sessions/...), so
    prefer the explicit '.codex/sessions' pair and otherwise take the LAST
    'sessions' component, never the first.
    """
    parts = Path(p).parts
    for i in range(len(parts) - 1, 0, -1):
        if parts[i] == "sessions" and parts[i - 1] == ".codex":
            return "/".join(parts[i + 1:])
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "sessions":
            return "/".join(parts[i + 1:])
    return Path(p).name


def parse_manifest_line(line: str) -> tuple[str, int | None]:
    """A manifest line is '<path>' or '<path>\t<bytes>'."""
    path, sep, size = line.rpartition("\t")
    if sep and path and size.isdigit():
        return path, int(size)
    return line, None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restored", type=Path, required=True,
                    help="root the restore was extracted into")
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--list-missing", action="store_true",
                    help="print every missing path, not just the count")
    ap.add_argument("--presence-only", action="store_true",
                    help="accept a manifest without sizes and verify only "
                         "existence/non-emptiness (cannot detect truncation)")
    args = ap.parse_args()

    if not args.manifest.is_file():
        print(f"error: manifest not found at {args.manifest}", file=sys.stderr)
        return 2
    if not args.restored.is_dir():
        print(f"error: {args.restored} is not a directory "
              "(is the volume mounted and accessible?)", file=sys.stderr)
        return 2

    expected: dict[str, tuple[str, int | None]] = {}
    for raw in args.manifest.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        path, size = parse_manifest_line(line)
        expected[key_of(path)] = (path, size)
    if not expected:
        print(f"error: manifest {args.manifest} is empty", file=sys.stderr)
        return 2

    sized = sum(1 for _, size in expected.values() if size is not None)
    if sized < len(expected) and not args.presence_only:
        print(f"error: manifest carries sizes for only {sized:,}/"
              f"{len(expected):,} entries; existence checks alone cannot "
              "detect a truncated restore. Regenerate it with "
              "'<path>\\t<bytes>' lines, or pass --presence-only to "
              "explicitly accept the weaker check.", file=sys.stderr)
        return 2

    found: dict[str, Path] = {}
    fsize: dict[str, int] = {}
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
        fsize[k] = sz
        total += sz
        if sz == 0:
            empty.append(p)

    missing = sorted(set(expected) - set(found))
    unexpected = sorted(set(found) - set(expected))
    truncated = sorted(
        k for k in set(found) & set(expected)
        if expected[k][1] is not None and fsize.get(k) != expected[k][1]
    )

    print(f"manifest expects   {len(expected):,} files"
          + ("" if sized == len(expected) else f"  ({sized:,} with sizes)"))
    print(f"restore contains   {len(found):,} files  ({human(total)})")
    print(f"  present          {len(expected) - len(missing):,}")
    print(f"  MISSING          {len(missing):,}")
    print(f"  unexpected       {len(unexpected):,}")
    if truncated:
        print(f"  SIZE MISMATCH    {len(truncated):,}  <- truncated/corrupted restore")
    if empty:
        print(f"  ZERO-LENGTH      {len(empty):,}  <- truncated restore")

    if missing and args.list_missing:
        print("\n--- missing ---")
        for k in missing:
            print(f"  {expected[k][0]}")
    elif missing:
        print("\nfirst 10 missing (use --list-missing for all):")
        for k in missing[:10]:
            print(f"  {expected[k][0]}")

    if truncated:
        print("\nfirst 10 size mismatches (manifest bytes -> restored bytes):")
        for k in truncated[:10]:
            print(f"  {found[k]}  ({expected[k][1]:,} -> {fsize.get(k, 'unreadable')})")

    if empty:
        print("\nzero-length files:")
        for p in empty[:10]:
            print(f"  {p}")

    ok = not missing and not empty and not truncated
    if ok:
        detail = ("every manifest file present with the expected size"
                  if sized == len(expected)
                  else "every manifest file present and non-empty "
                       "(sizes NOT verified — presence-only mode)")
        print(f"\nRESTORE COMPLETE — {detail}")
    else:
        print("\nRESTORE INCOMPLETE — see above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
