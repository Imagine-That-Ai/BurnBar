#!/usr/bin/env python3
"""Bound the on-disk size of the Codex CLI session corpus (~/.codex/sessions).

Codex CLI (0.145.0) writes one append-only JSONL rollout per session and never
prunes them: it ships `codex archive` / `codex delete` for single sessions by id
and no retention policy at all. On a heavy agent-fleet machine the corpus grows
several GB/day, which costs SSD capacity, backup churn (Backblaze/Time Machine
re-read every changed file), and read amplification for anything that scans the
tree.

Tiered policy, by file modification time (compression preserves the original
mtime, so archives age out of the compressed tier on the session's real age):

    age <= --keep-raw-days      leave alone   (resumable via `codex resume`)
    age <= --compress-days      gzip in place (readable, ~2.9x on this corpus)
    age >  --compress-days      delete        (raw and previously-gzipped alike)

Safety properties:
  * dry-run unless --apply is passed;
  * never touches a file younger than --min-age-hours (default 12), so a live
    or just-finished session is never raced;
  * never touches a file any process currently holds open (lsof probe); an
    lsof that cannot complete counts as "held", never as "free";
  * every candidate's size, mtime, and open-handle state are re-checked
    immediately before its unlink, so a session resumed mid-sweep is skipped
    rather than raced;
  * compression is atomic — the .gz is written, fsync'd, size-verified and
    gzip-tested before the original is unlinked, so an interrupted run loses
    nothing;
  * refuses to operate outside the configured sessions root.

OpenBurnBar usage history: rows already ingested into openburnbar.sqlite are
untouched. Reconstructed history survives pruning as long as OpenBurnBar's
parser cache has seen the session once — CodexSessionLogScanner serves token
usage for a missing rollout from that cache, but on a fresh or cleared cache
it skips threads whose state-database `rollout_path` no longer exists instead
of falling back to the state-database totals (see
OpenBurnBarLogParsers/LogParser/CodexSessionLogScanner.swift). If from-scratch
reconstruction matters, run a full OpenBurnBar scan to warm that cache before
the first --apply sweep.
"""

from __future__ import annotations

import argparse
import gzip
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ROOT = Path.home() / ".codex" / "sessions"
DEFAULT_KEEP_RAW_DAYS = 3
DEFAULT_COMPRESS_DAYS = 14
DEFAULT_MIN_AGE_HOURS = 12

# Measured on this corpus: 200 MB of rollout JSONL -> 68.5 MB gzip -6 (2.9x).
# Projections use a conservative 2.5x so they never over-promise.
ASSUMED_GZIP_RATIO = 2.5


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:,.1f} {unit}"
        n /= 1024
    return f"{n:,.1f} TB"


class RolloutActive(OSError):
    """A candidate changed or was reopened between the scan and the unlink."""


@dataclass
class Candidate:
    path: Path
    size: int
    age_days: float
    mtime: float
    action: str  # "compress" | "delete"

    @property
    def reclaim(self) -> int:
        if self.action == "delete":
            return self.size
        return int(self.size * (1 - 1 / ASSUMED_GZIP_RATIO))


def growth_rate_gb_per_day(root: Path, window_days: int = 7) -> float:
    """Bytes/day of new rollout written over the trailing window.

    This is the number that decides whether a policy actually bounds the
    corpus: retention only helps if the steady state it implies is smaller
    than what the fleet generates.
    """
    now = time.time()
    cutoff = now - window_days * 86400
    total = 0
    for path in root.rglob("*.jsonl"):
        try:
            st = path.stat()
        except OSError:
            continue
        if st.st_mtime >= cutoff:
            total += st.st_size
    return total / window_days / 2**30


def steady_state_gb(rate_gb_day: float, keep_raw_days: int, compress_days: int) -> float:
    """Corpus size this policy converges to at the observed generation rate."""
    raw = rate_gb_day * keep_raw_days
    compressed = rate_gb_day * max(compress_days - keep_raw_days, 0) / ASSUMED_GZIP_RATIO
    return raw + compressed


def open_files(paths: list[Path]) -> set[Path]:
    """Paths currently held open by some process, via a single lsof batch.

    Fails closed: any probe that does not provably complete marks the whole
    chunk as held. lsof exits 0 when it lists open files and 1 when none of
    the named files are open; any other exit status, or diagnostics on
    stderr, means the check itself failed rather than "nothing is open".
    """
    if not paths:
        return set()
    held: set[Path] = set()
    # lsof argv has limits; chunk it.
    for i in range(0, len(paths), 400):
        chunk = [str(p) for p in paths[i : i + 400]]
        try:
            proc = subprocess.run(
                ["lsof", "-Fn", "--", *chunk],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            # Fail closed: if we cannot prove a file is unused, skip the chunk.
            held.update(paths[i : i + 400])
            continue
        if proc.returncode not in (0, 1) or (proc.returncode == 1 and proc.stderr.strip()):
            held.update(paths[i : i + 400])
            continue
        for line in proc.stdout.splitlines():
            if line.startswith("n"):
                held.add(Path(line[1:]))
    return held


def collect(root: Path, keep_raw_days: int, compress_days: int, min_age_hours: int) -> list[Candidate]:
    now = time.time()
    min_age = min_age_hours * 3600
    out: list[Candidate] = []
    # Scan *.jsonl.gz too: archives produced by earlier sweeps must age out of
    # the compressed tier, not accumulate forever.
    for pattern in ("*.jsonl", "*.jsonl.gz"):
        for path in root.rglob(pattern):
            try:
                st = path.stat()
            except OSError:
                continue
            if not path.is_file():
                continue
            age = now - st.st_mtime
            if age < min_age:
                continue
            age_days = age / 86400
            if age_days <= keep_raw_days:
                continue
            if age_days <= compress_days:
                if path.name.endswith(".gz"):
                    continue  # already in its final tier for this age band
                action = "compress"
            else:
                action = "delete"
            out.append(Candidate(path, st.st_size, age_days, st.st_mtime, action))
    return sorted(out, key=lambda c: -c.size)


def ensure_still_quiet(path: Path, expected_size: int, expected_mtime: float) -> None:
    """Raise RolloutActive unless `path` is unchanged since the scan and unheld.

    The sweep-wide lsof snapshot goes stale during a long compression pass; an
    old session can be resumed after it. Call this immediately before any
    unlink so an active rollout is skipped instead of raced.
    """
    try:
        st = path.stat()
    except OSError as exc:
        raise RolloutActive(f"disappeared since the scan ({exc})") from exc
    if st.st_size != expected_size or st.st_mtime != expected_mtime:
        raise RolloutActive("changed since the scan")
    if open_files([path]):
        raise RolloutActive("reopened since the scan")


def compress(path: Path, expected_size: int, expected_mtime: float) -> int:
    """gzip `path` atomically. Returns bytes reclaimed. Raises on any failure."""
    dest = path.with_suffix(path.suffix + ".gz")
    tmp = path.with_suffix(path.suffix + ".gz.partial")
    st = path.stat()
    original = st.st_size
    try:
        with open(path, "rb") as src, gzip.open(tmp, "wb", compresslevel=6) as dst:
            shutil.copyfileobj(src, dst, length=4 * 1024 * 1024)
        with open(tmp, "rb") as fh:
            os.fsync(fh.fileno())
        # Verify the archive round-trips before destroying the source.
        with gzip.open(tmp, "rb") as fh:
            checked = 0
            while chunk := fh.read(8 * 1024 * 1024):
                checked += len(chunk)
        if checked != original:
            raise OSError(f"verify mismatch: {checked} != {original}")
        # Compression takes long enough for a session to be resumed; re-check
        # identity and open handles immediately before the unlink.
        ensure_still_quiet(path, expected_size, expected_mtime)
        os.replace(tmp, dest)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    # Preserve the original mtime so the delete tier keys off the session's
    # real age rather than the compression time.
    os.utime(dest, (st.st_atime, st.st_mtime))
    path.unlink()
    return original - dest.stat().st_size


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Bound ~/.codex/sessions growth with a tiered retention policy.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    ap.add_argument(
        "--keep-raw-days", type=int, default=DEFAULT_KEEP_RAW_DAYS, help="newer than this: untouched and resumable"
    )
    ap.add_argument(
        "--compress-days",
        type=int,
        default=DEFAULT_COMPRESS_DAYS,
        help="between keep-raw and this: gzip; older: delete",
    )
    ap.add_argument(
        "--min-age-hours", type=int, default=DEFAULT_MIN_AGE_HOURS, help="never touch anything younger than this"
    )
    ap.add_argument("--apply", action="store_true", help="actually modify files (default is a dry run)")
    ap.add_argument("--quiet", action="store_true", help="summary only")
    args = ap.parse_args()

    root = args.root.expanduser().resolve()
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 2
    if min(args.keep_raw_days, args.compress_days, args.min_age_hours) < 0:
        print("error: --keep-raw-days, --compress-days and --min-age-hours must all be >= 0", file=sys.stderr)
        return 2
    if args.keep_raw_days > args.compress_days:
        print("error: --keep-raw-days must be <= --compress-days", file=sys.stderr)
        return 2

    total_before = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())

    cands = collect(root, args.keep_raw_days, args.compress_days, args.min_age_hours)
    if not cands:
        print(f"nothing to do — corpus {human(total_before)}, all within retention")
        return 0

    held = open_files([c.path for c in cands])
    skipped = [c for c in cands if c.path in held]
    cands = [c for c in cands if c.path not in held]

    to_compress = [c for c in cands if c.action == "compress"]
    to_delete = [c for c in cands if c.action == "delete"]
    projected = sum(c.reclaim for c in cands)

    mode = "APPLY" if args.apply else "DRY RUN"
    print(f"[{mode}] {root}")
    print(f"  corpus now          {human(total_before)}")
    print(f"  keep raw  <= {args.keep_raw_days:>3}d   {len(cands) and ''}untouched")
    print(
        f"  compress  <= {args.compress_days:>3}d   {len(to_compress):>5} files  "
        f"{human(sum(c.size for c in to_compress))}"
    )
    print(
        f"  delete     > {args.compress_days:>3}d   {len(to_delete):>5} files  {human(sum(c.size for c in to_delete))}"
    )
    if skipped:
        print(f"  skipped (open)      {len(skipped):>5} files  {human(sum(c.size for c in skipped))}")
    print(f"  projected reclaim   {human(projected)}")
    print(f"  corpus after        ~{human(total_before - projected)}")

    rate = growth_rate_gb_per_day(root)
    steady = steady_state_gb(rate, args.keep_raw_days, args.compress_days)
    print(f"\n  observed growth     {rate:,.1f} GB/day (trailing 7d)")
    print(f"  STEADY STATE        ~{steady:,.1f} GB under this policy")
    if steady > total_before / 2**30:
        print("  !! this policy converges ABOVE the current size — tighten --keep-raw-days / --compress-days")

    if not args.apply:
        print("\n(dry run — re-run with --apply to execute)")
        return 0

    reclaimed = 0
    failures = 0
    became_active = 0
    for c in cands:
        try:
            if c.action == "compress":
                got = compress(c.path, c.size, c.mtime)
            else:
                ensure_still_quiet(c.path, c.size, c.mtime)
                got = c.size
                c.path.unlink()
            reclaimed += got
            if not args.quiet:
                print(f"  {c.action:<8} {human(c.size):>10}  {c.path.name}")
        except RolloutActive as exc:
            became_active += 1
            if not args.quiet:
                print(f"  skipped  {c.path.name}: {exc}")
        except Exception as exc:  # keep going; one bad file must not abort the sweep
            failures += 1
            print(f"  FAILED   {c.path}: {exc}", file=sys.stderr)

    print(
        f"\nreclaimed {human(reclaimed)}"
        + (f"  ({became_active} skipped as active)" if became_active else "")
        + (f"  ({failures} failures)" if failures else "")
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
