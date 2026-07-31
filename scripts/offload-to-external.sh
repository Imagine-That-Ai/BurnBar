#!/bin/zsh
# Verified move of a directory to an external volume, leaving a symlink behind.
#
#   offload-to-external.sh <source-dir> <dest-dir> [--apply]
#
# Copies with ditto (preserves ACLs / xattrs / resource forks), then proves the
# copy before deleting anything:
#   1. identical file AND directory path sets in both directions, exact byte
#      totals, and a per-file size manifest must match
#   2. sha256 spot-check over a random sample
# Only if all checks pass is the source removed and replaced with a symlink.
# Dry-run unless --apply is given.
#
# Refuses a destination that already exists: ditto would merge into it, and a
# merged tree is not provably equivalent to the source.
#
# Deliberately refuses to touch a source that is a git repo with worktrees —
# git stores absolute paths in .git/worktrees/*/gitdir, so those need
# `git worktree move`, not a copy+symlink.
set -euo pipefail

SRC="${1:?usage: offload-to-external.sh <src> <dest> [--apply]}"
DST="${2:?usage: offload-to-external.sh <src> <dest> [--apply]}"
APPLY="${3:-}"

SRC="${SRC%/}"; DST="${DST%/}"
# Canonicalize both to absolute paths. ditto resolves a relative DST against
# $PWD, while the trailing `ln -s` target would resolve relative to $SRC's
# parent — a mismatch that strands the verified copy and leaves a dangling
# symlink where the source used to be.
SRC="${SRC:a}"; DST="${DST:a}"

[[ -d "$SRC" ]] || { echo "error: source $SRC is not a directory"; exit 2; }
[[ -L "$SRC" ]] && { echo "error: $SRC is already a symlink"; exit 2; }
[[ -e "$DST" ]] && { echo "error: destination $DST already exists — ditto would merge into it; move it aside first"; exit 2; }

# Refuse git repos that have worktrees — those need `git worktree move`.
if [[ -e "$SRC/.git" ]]; then
  WT=$(cd "$SRC" && git worktree list 2>/dev/null | wc -l | tr -d ' ') \
    || { echo "error: could not inspect git worktree state of $SRC"; exit 2; }
  if [[ "${WT:-0}" -gt 1 ]]; then
    echo "error: $SRC is a git repo with $WT worktrees — use 'git worktree move' instead"
    exit 2
  fi
fi

# Open-handle probe fails closed: an answer lsof could not produce is not
# "no open files". Note that lsof's *exit status* is not a usable signal here:
# `lsof +D` exits 1 both when it finds nothing and when it successfully lists
# open files (verified on macOS lsof 4.91 — exit status 1 only means "something
# in the request could not be listed"). So the listing decides whether anything is
# open, and the status/stderr only decide whether the probe itself completed:
# an unexpected status or any diagnostic on stderr aborts the offload.
command -v lsof >/dev/null 2>&1 \
  || { echo "error: lsof not found — cannot prove nothing has $SRC open"; exit 2; }
LSOF_ERR_FILE="$(mktemp)"
LSOF_RC=0
# -Fn: one `n<absolute path>` line per open file, no header to skip.
LSOF_OUT="$(lsof -Fn +D "$SRC" 2>"$LSOF_ERR_FILE")" || LSOF_RC=$?
LSOF_DIAG="$(cat "$LSOF_ERR_FILE")"
rm -f "$LSOF_ERR_FILE"
typeset -a LSOF_OPEN
LSOF_OPEN=()
for LSOF_LINE in ${(f)LSOF_OUT}; do
  [[ "$LSOF_LINE" == n/* ]] && LSOF_OPEN+=("${LSOF_LINE#n}")
done
if (( ${#LSOF_OPEN} > 0 )); then
  echo "error: ${#LSOF_OPEN} open file handles under $SRC — close them first"
  print -rl -- ${LSOF_OPEN[1,5]}
  exit 2
fi
if (( LSOF_RC != 0 && LSOF_RC != 1 )) || [[ -n "$LSOF_DIAG" ]]; then
  echo "error: lsof could not inspect $SRC (rc=$LSOF_RC)${LSOF_DIAG:+: $LSOF_DIAG}"
  exit 2
fi

SIZE=$(du -sh "$SRC" 2>/dev/null | awk '{print $1}') || SIZE="?"
echo "source $SRC  ($SIZE)"
echo "dest   $DST"

if [[ "$APPLY" != "--apply" ]]; then
  echo "(dry run — pass --apply to execute)"
  exit 0
fi

echo "==> copying with ditto"
mkdir -p "$(dirname "$DST")"
ditto "$SRC" "$DST" || { echo "ditto FAILED"; exit 1; }

echo "==> verifying"
python3 - "$SRC" "$DST" <<'PY' || { echo "VERIFICATION FAILED — source left intact"; exit 1; }
import os, sys, random, hashlib
src_root, dst_root = sys.argv[1], sys.argv[2]

def scan(root):
    files, dirs, total = {}, set(), 0
    for dp, dns, fns in os.walk(root):
        for d in dns:
            dirs.add(os.path.relpath(os.path.join(dp, d), root))
        for f in fns:
            p = os.path.join(dp, f)
            try: sz = os.lstat(p).st_size
            except OSError: continue
            files[os.path.relpath(p, root)] = sz
            total += sz
    return files, dirs, total

src, sdirs, st = scan(src_root)
dst, ddirs, dt = scan(dst_root)
# Entry sets must be identical in BOTH directions: an extra file (even a
# zero-length one) or a missing/extra empty directory in the destination is
# as disqualifying as a missing copy.
missing  = set(src) - set(dst)
extra    = set(dst) - set(src)
dirdiff  = sdirs ^ ddirs
sizediff = [k for k in (set(src) & set(dst)) if src[k] != dst[k]]
print(f"    files {len(src):,} -> {len(dst):,}   dirs {len(sdirs):,} -> {len(ddirs):,}   bytes {st:,} -> {dt:,}")
if missing or extra or dirdiff or sizediff or st != dt:
    print(f"    MISMATCH  missing={len(missing)} extra={len(extra)} dirdiff={len(dirdiff)} sizediff={len(sizediff)}")
    for k in sorted(missing)[:5]: print("      MISSING:", k)
    for k in sorted(extra)[:5]:   print("      EXTRA:  ", k)
    for k in sorted(dirdiff)[:5]: print("      DIRDIFF:", k)
    sys.exit(1)

rels = list(src)
random.seed(20260724)
sample = random.sample(rels, min(300, len(rels)))
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as fh:
        while c := fh.read(1 << 20): h.update(c)
    return h.hexdigest()
bad = 0
for rel in sample:
    s, d = os.path.join(src_root, rel), os.path.join(dst_root, rel)
    try:
        if os.path.islink(s):
            if os.readlink(s) != os.readlink(d): bad += 1
        elif sha(s) != sha(d): bad += 1
    except OSError: bad += 1
print(f"    sha256 spot-check: {len(sample)} files, {bad} mismatches")
sys.exit(1 if bad else 0)
PY

echo "==> removing verified source and symlinking"
# set -e aborts before the success banner if any of these fail; verify the
# final link explicitly before declaring victory.
rm -rf "$SRC"
ln -s "$DST" "$SRC"
[[ -L "$SRC" && "$(readlink "$SRC")" == "$DST" && -d "$SRC" ]] \
  || { echo "error: symlink verification failed — the verified copy is intact at $DST"; exit 1; }
ls -ld "$SRC"
echo "done: $SIZE reclaimed from internal"
