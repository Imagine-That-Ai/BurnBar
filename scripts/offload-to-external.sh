#!/bin/zsh
# Verified move of a directory to an external volume, leaving a symlink behind.
#
#   offload-to-external.sh <source-dir> <dest-dir> [--apply]
#
# Copies with ditto (preserves ACLs / xattrs / resource forks), then proves the
# copy before deleting anything:
#   1. file count, exact byte totals, and per-file size manifest must match
#   2. sha256 spot-check over a random sample
# Only if all checks pass is the source removed and replaced with a symlink.
# Dry-run unless --apply is given.
#
# Deliberately refuses to touch a source that is a git repo with worktrees —
# git stores absolute paths in .git/worktrees/*/gitdir, so those need
# `git worktree move`, not a copy+symlink.
set -u

SRC="${1:?usage: offload-to-external.sh <src> <dest> [--apply]}"
DST="${2:?usage: offload-to-external.sh <src> <dest> [--apply]}"
APPLY="${3:-}"

SRC="${SRC%/}"; DST="${DST%/}"

[[ -d "$SRC" ]] || { echo "error: source $SRC is not a directory"; exit 2; }
[[ -L "$SRC" ]] && { echo "error: $SRC is already a symlink"; exit 2; }

# Refuse git repos that have worktrees — those need `git worktree move`.
if [[ -e "$SRC/.git" ]]; then
  WT=$(cd "$SRC" && git worktree list 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${WT:-0}" -gt 1 ]]; then
    echo "error: $SRC is a git repo with $WT worktrees — use 'git worktree move' instead"
    exit 2
  fi
fi

OPEN=$(lsof +D "$SRC" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${OPEN:-0}" -gt 0 ]]; then
  echo "error: $OPEN open file handles under $SRC — close them first"
  exit 2
fi

SIZE=$(du -sh "$SRC" 2>/dev/null | awk '{print $1}')
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
    out, total = {}, 0
    for dp, _, fns in os.walk(root):
        for f in fns:
            p = os.path.join(dp, f)
            try: sz = os.lstat(p).st_size
            except OSError: continue
            out[os.path.relpath(p, root)] = sz
            total += sz
    return out, total

src, st = scan(src_root)
dst, dt = scan(dst_root)
missing  = set(src) - set(dst)
sizediff = [k for k in (set(src) & set(dst)) if src[k] != dst[k]]
print(f"    files {len(src):,} -> {len(dst):,}   bytes {st:,} -> {dt:,}")
if missing or sizediff or st != dt:
    print(f"    MISMATCH  missing={len(missing)} sizediff={len(sizediff)}")
    for k in list(missing)[:5]:  print("      MISSING:", k)
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
rm -rf "$SRC"
ln -s "$DST" "$SRC"
ls -ld "$SRC"
echo "done: $SIZE reclaimed from internal"
