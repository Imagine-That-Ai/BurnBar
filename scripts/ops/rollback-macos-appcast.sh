#!/usr/bin/env bash
# macOS Sparkle appcast rollback (pin the published feed to a previous good build).
#
# The backend has tiered rollback (fast revision-pin at scripts/ops/rollback-revision.sh,
# slow source rollback at scripts/rollback.sh). The direct-download macOS channel had
# no equivalent: once a bad signed build is advertised in the published Sparkle appcast,
# every macOS client that polls the feed offers it. This script is that missing lever.
# It rolls the published feed(s) back to a previous good version by REMOVING every
# <item> newer than the target so the target becomes the advertised latest. The signed
# enclosure for the target build is preserved verbatim (we never re-sign or re-host the
# build — we only stop advertising the bad one).
#
# This is the macOS analogue of rollback-revision.sh: a fast feed-pin, NOT a rebuild.
# It does NOT publish (no network/cloud mutation here): it writes the rolled-back feed
# locally and prints the exact operator publish + verify steps.
#
# Usage:
#   ./scripts/ops/rollback-macos-appcast.sh --list
#       Show the versions currently advertised in each feed (newest first), so the
#       operator can identify the bad build and the last-known-good target.
#
#   ./scripts/ops/rollback-macos-appcast.sh --to-version 1.0.1
#       DRY RUN (default): show the plan to pin every feed back to 1.0.1. Changes nothing.
#
#   ./scripts/ops/rollback-macos-appcast.sh --to-version 1.0.1 --yes
#       Apply: rewrite each feed in place so 1.0.1 is the advertised latest, dropping
#       the newer (bad) item(s). Prints the publish + verify steps for the operator.
#
# Flags:
#   --to-version <X>    Target good shortVersionString to pin the feed back to (REQUIRED
#                       to act; this script refuses to guess a target). SemVer grammar.
#   --list              List versions advertised in each feed and exit.
#   --feed <path>       Appcast file to operate on. Repeatable. Defaults to the standard
#                       pair (appcast.xml + appcast-x86_64.xml) under the downloads dir,
#                       restricted to those that exist.
#   --dry-run           Print the plan; change nothing. This is the DEFAULT.
#   --yes, -y           Apply the rollback (write the feed files). Without this the
#                       script never modifies a feed.
#   --allow-stale       Permit pinning to a target older than the freshness window
#                       (STALE_VERSION_MAX_AGE_DAYS, default 30) when the feed records a
#                       pubDate. An over-old target usually means the wrong version.
#   -h, --help          Show this help.
#
# Environment:
#   OPENBURNBAR_DOWNLOADS_DIR     Local feed directory. Default: website/public/downloads
#   OPENBURNBAR_R2_PUBLIC_BASE_URL Public feed base URL used in the printed verify step.
#   STALE_VERSION_MAX_AGE_DAYS    Freshness window for --allow-stale guard (default 30).
#
# Prerequisites:
#   - python3 (XML parsing; matches scripts/ops/rollback-revision.sh).
#   - The feed files to roll back exist locally (they are published from
#     OPENBURNBAR_DOWNLOADS_DIR by scripts/upload-macos-downloads-r2.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."

# SemVer grammar this app ships its macOS shortVersionString under: MAJOR.MINOR.PATCH
# with an optional -prerelease / +build suffix, and an OPTIONAL leading "v". MAJOR is
# capped at three digits (0-999) so a year-shaped calver (2026.6.5) can never be
# selected as a target — the same H14/H19 guard scripts/rollback.sh uses for tags.
SEMVER_VERSION_RE='^v?[0-9]{1,3}\.[0-9]+\.[0-9]+([-+].*)?$'

# Refuse to pin to a target whose feed pubDate is older than this many days without
# --allow-stale. A "previous good" version that predates the window is almost certainly
# the wrong target and would convert a partial outage into a worse one.
STALE_VERSION_MAX_AGE_DAYS="${STALE_VERSION_MAX_AGE_DAYS:-30}"

DOWNLOADS_DIR="${OPENBURNBAR_DOWNLOADS_DIR:-website/public/downloads}"
PUBLIC_BASE_URL="${OPENBURNBAR_R2_PUBLIC_BASE_URL:-}"

TO_VERSION=""
LIST_ONLY=false
DRY_RUN=true        # remediation(B4): dry-run is the default; --yes opts into writes.
ASSUME_YES=false
ALLOW_STALE=false
FEEDS=()

usage() {
  sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-version) TO_VERSION="${2:?--to-version needs a value}"; shift 2 ;;
    --to-version=*) TO_VERSION="${1#*=}"; shift ;;
    --list) LIST_ONLY=true; shift ;;
    --feed) FEEDS+=("${2:?--feed needs a value}"); shift 2 ;;
    --feed=*) FEEDS+=("${1#*=}"); shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) ASSUME_YES=true; DRY_RUN=false; shift ;;
    --allow-stale) ALLOW_STALE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown flag: $1" >&2; usage; exit 1 ;;
    *) echo "ERROR: unexpected positional argument: $1" >&2; usage; exit 1 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found — required to parse the appcast XML." >&2
  exit 1
fi

# ── Resolve feeds (flag → standard pair that exists) ───────────────────────
# The published direct-download channel is a pair: the arm64 feed (appcast.xml) and the
# Intel feed (appcast-x86_64.xml). Default to whichever of the pair actually exists so a
# single-arch deployment still works; an explicit --feed overrides the default entirely.
if [[ ${#FEEDS[@]} -eq 0 ]]; then
  for candidate in "$DOWNLOADS_DIR/appcast.xml" "$DOWNLOADS_DIR/appcast-x86_64.xml"; do
    if [[ -f "$candidate" ]]; then
      FEEDS+=("$candidate")
    fi
  done
  if [[ ${#FEEDS[@]} -eq 0 ]]; then
    echo "ERROR: no appcast feed found under ${DOWNLOADS_DIR}." >&2
    echo "       Pass --feed <path>, or set OPENBURNBAR_DOWNLOADS_DIR to the directory" >&2
    echo "       that scripts/upload-macos-downloads-r2.sh publishes from." >&2
    exit 1
  fi
fi

for feed in "${FEEDS[@]}"; do
  if [[ ! -f "$feed" ]]; then
    echo "ERROR: feed not found: ${feed}" >&2
    exit 1
  fi
done

# parse_feed <feed-path>
# Emits one TSV line per <item>, newest-first as ordered in the feed:
#   <shortVersionString>\t<sparkle:version>\t<pubDate-epoch-or-0>\t<pubDate-text>
# A malformed feed exits non-zero (fail closed — never act on an unparseable feed).
parse_feed() {
  python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except Exception as exc:  # noqa: BLE001 - surface any parse failure as fail-closed
    sys.stderr.write(f"ERROR: could not parse appcast {path}: {exc}\n")
    sys.exit(2)

channel = root.find("channel")
if channel is None:
    sys.stderr.write(f"ERROR: appcast {path} has no <channel>\n")
    sys.exit(2)

for item in channel.findall("item"):
    short = item.findtext(f"{{{SPARKLE}}}shortVersionString") or ""
    build = item.findtext(f"{{{SPARKLE}}}version") or ""
    pub = item.findtext("pubDate") or ""
    epoch = 0
    if pub:
        try:
            epoch = int(parsedate_to_datetime(pub).timestamp())
        except Exception:  # noqa: BLE001 - tolerate non-RFC822 dates
            epoch = 0
    short = short.strip()
    build = build.strip()
    if not short:
        continue
    print(f"{short}\t{build}\t{epoch}\t{pub.strip()}")
PY
}

# ── --list: show advertised versions per feed and exit ─────────────────────
if [[ "$LIST_ONLY" == "true" ]]; then
  for feed in "${FEEDS[@]}"; do
    echo "==> ${feed}"
    items="$(parse_feed "$feed")"
    if [[ -z "$items" ]]; then
      echo "    (no <item> entries)"
      continue
    fi
    printf '    %-16s %-10s %s\n' "VERSION" "BUILD" "PUBDATE"
    first=true
    while IFS=$'\t' read -r short build _epoch pub; do
      [[ -z "$short" ]] && continue
      marker=""
      if [[ "$first" == "true" ]]; then
        marker="  <- latest"
        first=false
      fi
      printf '    %-16s %-10s %s%s\n' "$short" "${build:--}" "${pub:--}" "$marker"
    done <<< "$items"
  done
  exit 0
fi

# ── Require an explicit target ──────────────────────────────────────────────
# Idempotent + refuses to act without an explicit target: this script never guesses
# "the previous version" the way an unguarded auto-rollback would. The operator must
# read --list and name the last-known-good version.
if [[ -z "$TO_VERSION" ]]; then
  echo "ERROR: --to-version <X> is required (this script refuses to guess a target)." >&2
  echo "       Run with --list to see the advertised versions, then pin explicitly:" >&2
  echo "       ./scripts/ops/rollback-macos-appcast.sh --to-version <last-good> --yes" >&2
  exit 1
fi

if ! [[ "$TO_VERSION" =~ $SEMVER_VERSION_RE ]]; then
  echo "ERROR: target '${TO_VERSION}' is not a valid SemVer version (grammar ${SEMVER_VERSION_RE})." >&2
  echo "       Use the shortVersionString exactly as it appears in --list (e.g. 1.0.1)." >&2
  exit 1
fi

# rewrite_feed <feed-path> <target-version> <mode>
# mode=plan  : print, per feed, the current latest, the target, and which items would
#              be dropped (newer than the target). Exits 3 if the target is not present;
#              exits 0 with a NO-OP note if the target is already the latest.
# mode=apply : additionally rewrite the feed in place (target becomes latest; newer
#              items removed), preserving the target item's signed enclosure verbatim.
# Stale-target guard is enforced inside (planning surfaces it; apply refuses without
# --allow-stale) so plan and apply can never disagree.
rewrite_feed() {
  python3 - "$1" "$2" "$3" "$ALLOW_STALE" "$STALE_VERSION_MAX_AGE_DAYS" <<'PY'
import sys, time
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
path, target, mode, allow_stale, max_age_days = sys.argv[1:6]
allow_stale = allow_stale == "true"
max_age_days = int(max_age_days)

# Preserve the sparkle namespace prefix on serialization (ElementTree would otherwise
# rename it to ns0:, which Sparkle clients still parse but which needlessly churns the
# published feed). Registering the prefix keeps the diff minimal.
ET.register_namespace("sparkle", SPARKLE)

try:
    tree = ET.parse(path)
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"ERROR: could not parse appcast {path}: {exc}\n")
    sys.exit(2)

root = tree.getroot()
channel = root.find("channel")
if channel is None:
    sys.stderr.write(f"ERROR: appcast {path} has no <channel>\n")
    sys.exit(2)

items = channel.findall("item")
def short_of(it):
    return (it.findtext(f"{{{SPARKLE}}}shortVersionString") or "").strip()

versions = [short_of(it) for it in items if short_of(it)]
if not versions:
    sys.stderr.write(f"ERROR: appcast {path} advertises no versioned items.\n")
    sys.exit(2)

# Locate the target item (first match, newest-first feed order).
target_idx = next((i for i, it in enumerate(items) if short_of(it) == target), None)
if target_idx is None:
    sys.stderr.write(
        f"ERROR: target version '{target}' is not present in {path}.\n"
        f"       Advertised versions: {', '.join(versions)}\n"
        f"       Pin only to a version that already has a signed item in the feed.\n"
    )
    sys.exit(3)

latest = versions[0]

# Freshness guard: refuse an over-old target unless --allow-stale (only when the target
# item records a parseable pubDate; absent a date we cannot judge and do not block).
target_item = items[target_idx]
pub = (target_item.findtext("pubDate") or "").strip()
age_days = None
if pub:
    try:
        age_days = int((time.time() - parsedate_to_datetime(pub).timestamp()) // 86400)
    except Exception:  # noqa: BLE001
        age_days = None

print(f"  feed:    {path}")
print(f"  latest:  {latest}")
print(f"  target:  {target}")
if age_days is not None:
    print(f"  age:     {age_days} day(s) since target pubDate")

if target_idx == 0:
    print("  result:  NO-OP (target is already the advertised latest)")
    sys.exit(0)

dropped = versions[:target_idx]
print(f"  drop:    {', '.join(dropped)}  (newer than target)")

if age_days is not None and age_days > max_age_days and not allow_stale:
    sys.stderr.write(
        f"ERROR: target '{target}' in {path} is {age_days} days old "
        f"(> {max_age_days}-day freshness window).\n"
        f"       Pinning this far back is almost certainly wrong. If you are sure, "
        f"re-run with --allow-stale.\n"
    )
    sys.exit(4)

if mode != "apply":
    print("  action:  would remove the newer item(s); target becomes latest")
    sys.exit(0)

# Apply: remove every item newer than the target (indices 0..target_idx-1). The target
# item and all older items keep their signed enclosures verbatim — we never re-sign.
for stale in items[:target_idx]:
    channel.remove(stale)

tree.write(path, encoding="utf-8", xml_declaration=True)
# Keep a trailing newline to match the generator's output (POSIX text file).
with open(path, "a", encoding="utf-8") as handle:
    handle.write("\n")
print("  action:  rewrote feed in place; target is now the advertised latest")
sys.exit(0)
PY
}

# ── Plan ────────────────────────────────────────────────────────────────────
echo "==> macOS appcast rollback plan"
echo "    target:    ${TO_VERSION}"
echo "    feeds:     ${FEEDS[*]}"
echo "    mode:      $([[ "$DRY_RUN" == "true" ]] && echo 'DRY RUN (no writes)' || echo 'APPLY')"
echo ""

ANY_CHANGE=false
for feed in "${FEEDS[@]}"; do
  echo "=== ${feed} ==="
  if rewrite_feed "$feed" "$TO_VERSION" "plan"; then
    # Plan succeeded; detect whether it was a real change (vs NO-OP) for the summary.
    if rewrite_feed "$feed" "$TO_VERSION" "plan" | grep -q "would remove the newer item"; then
      ANY_CHANGE=true
    fi
  else
    # Target missing / unparseable / stale: rewrite_feed already explained why. Fail
    # closed so the operator fixes the target before any feed is touched.
    echo "ERROR: aborting — no feed was modified." >&2
    exit 1
  fi
  echo ""
done

if [[ "$ANY_CHANGE" != "true" ]]; then
  echo "Nothing to do: ${TO_VERSION} is already the advertised latest in every feed."
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: no feed modified. Re-run with --yes to apply."
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────
if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Pin every feed back to ${TO_VERSION} (drops newer items)? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Rollback cancelled."
    exit 0
  fi
fi

# ── Apply ───────────────────────────────────────────────────────────────────
for feed in "${FEEDS[@]}"; do
  echo "=== ${feed} ==="
  rewrite_feed "$feed" "$TO_VERSION" "apply"
  echo ""
done

echo "=== macOS appcast rollback applied locally ==="
echo "    Pinned latest: ${TO_VERSION}"
echo "    Feeds rewritten: ${FEEDS[*]}"
echo ""
echo "PUBLISH STEP (operator runs this — NOT performed here; no upload from this script):"
echo "  # Re-upload the rolled-back feed(s) to the public download host. The uploader"
echo "  # also re-verifies the live appcast advertises a Sparkle version."
echo "  scripts/upload-macos-downloads-r2.sh"
# remediation(B4): the upload is intentionally NOT executed here — this script makes no
# network/cloud mutation. The line above is the exact operator command, no automatic run.
echo ""
echo "VERIFY STEP (after publish):"
if [[ -n "$PUBLIC_BASE_URL" ]]; then
  base="${PUBLIC_BASE_URL%/}"
  for feed in "${FEEDS[@]}"; do
    echo "  curl -fsSL ${base}/$(basename "$feed") | grep -F '<sparkle:shortVersionString>${TO_VERSION}</sparkle:shortVersionString>'"
  done
else
  echo "  # Set OPENBURNBAR_R2_PUBLIC_BASE_URL to print exact verify URLs. General form:"
  for feed in "${FEEDS[@]}"; do
    echo "  curl -fsSL <public-base-url>/$(basename "$feed") | grep -F '<sparkle:shortVersionString>${TO_VERSION}</sparkle:shortVersionString>'"
  done
fi
echo ""
echo "Next steps:"
echo "  1. Publish (command above) and run the VERIFY step until the live feed advertises ${TO_VERSION}."
echo "  2. Confirm a macOS client offered ${TO_VERSION} (Check for Updates), not the dropped build."
echo "  3. Fix forward: ship a hotfix release (docs/RELEASE_ROLLBACK.md) so the feed advances past the bad build."
