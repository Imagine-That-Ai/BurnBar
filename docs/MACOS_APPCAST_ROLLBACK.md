# macOS Appcast Rollback Runbook

This runbook covers rolling back a bad **direct-download** macOS release after its
signed build is already advertised in the published Sparkle **appcast** feed. It is the
macOS analogue of the backend's fast revision-pin
([`scripts/ops/rollback-revision.sh`](../scripts/ops/rollback-revision.sh)): instead of
flipping Cloud Run traffic, you re-pin the published appcast so clients stop being
offered the bad build.

It complements, and does not replace, the general
[`RELEASE_ROLLBACK.md`](RELEASE_ROLLBACK.md): that doc covers the GitHub release / tag /
Homebrew side; this doc covers the **Sparkle update feed** that every direct-download
macOS client polls.

The tool is [`scripts/ops/rollback-macos-appcast.sh`](../scripts/ops/rollback-macos-appcast.sh).

## When To Use It

Use this when the macOS direct-download channel has already published a bad signed build
to the appcast and you need clients to stop updating to it **now**, before a hotfix is
ready:

- A signed/notarized build shipped with a crash, data-loss, or security regression and
  Sparkle is already advertising it (`<sparkle:shortVersionString>` of the bad version is
  the newest `<item>` in the live feed).
- You have a **previous good** version that already has a signed `<item>` in the feed and
  whose DMG is still hosted. Re-pinning to it is instant and requires no rebuild or
  re-signing.

Do **not** use this when:

- The bad build was never published to the appcast — use the earlier stages in
  [`RELEASE_ROLLBACK.md`](RELEASE_ROLLBACK.md) (delete tag, mark draft).
- No previous good signed item exists in the feed — there is nothing to pin back to.
  Ship a hotfix instead (see the Fix-Forward section).
- The regression is on the **App Store / iOS** side — see "Relationship To iOS Phased
  Release" below; the appcast does not govern App Store distribution.

## Prerequisites

- `python3` (used to parse the appcast XML; same dependency as
  `scripts/ops/rollback-revision.sh`).
- A local copy of the canonical universal feed, `appcast.xml` (override its directory
  with `OPENBURNBAR_DOWNLOADS_DIR` or its path with `--feed`). Download the live feed
  immediately before the rollback; do not use the stale website source tree as
  production evidence.
- The previous-good release's exact retained R2 handoff: its audited GitHub Release
  asset directory plus promotion receipt. The rollback publisher uses those immutable
  inputs to restore `release-metadata.json` and `latest-macos.json`, bind the rolled-back
  appcast to the previous-good signed DMG, and verify the exact public bytes.
- Publish access to the download host (Cloudflare R2) to upload the rolled-back feed.
- The previous good version string, taken from `--list` (the `shortVersionString`).

## What The Script Does (And Does Not Do)

- It **removes every `<item>` newer than the target** so the target becomes the
  advertised latest. The target item's signed enclosure (`sparkle:edSignature`, DMG URL,
  length) is preserved **verbatim** — the script never re-signs or re-hosts a build.
- It is **dry-run by default** and **refuses to act without an explicit `--to-version`**
  (it never guesses a target).
- It is **idempotent**: if the target is already the latest item, it is a clean no-op.
- It **fails closed**: an unparseable feed, a missing target version, or a stale target
  (older than the freshness window without `--allow-stale`) aborts with **no feed
  modified**.
- It does **not** publish. There is no upload, no network, no cloud mutation. It writes
  the rolled-back feed locally and prints the exact dedicated publish + verify command.

## Step-By-Step

### 1. Detect the bad release and identify the target

List the versions currently advertised in each feed (newest first):

```bash
scripts/ops/rollback-macos-appcast.sh --list
```

The first row per feed is what Sparkle currently offers. Confirm the bad version is the
latest, and note the previous good `shortVersionString` you will pin back to.

### 2. Dry-run the rollback (default)

```bash
scripts/ops/rollback-macos-appcast.sh --to-version 1.0.1
```

This prints, per feed, the current latest, the target, and which item(s) would be
dropped. **Nothing is modified.** Review that only the bad item(s) are dropped and the
target is correct.

### 3. Apply the rollback locally

```bash
scripts/ops/rollback-macos-appcast.sh --to-version 1.0.1 --yes
```

`--yes` opts into the write; without it the script never modifies a feed. The canonical
universal feed is rewritten so the target is the advertised latest. The command then
prints the publish and verify steps.

### 4. Publish the rolled-back feed

The script does **not** upload. Prepare an exact rollback-target handoff first.
The target is eligible only when its audited `appcast.xml`,
`latest-macos.json`, and `release-metadata.json` were originally generated for
the same stable R2 public base. Legacy releases such as `v1.0.29`, whose audited
feeds point at GitHub `releases/latest/download`, are not eligible for direct R2
rollback without a separately signed and checksummed migration artifact.

```bash
handoff_dir="$(mktemp -d)"

# Current release lane:
gh run download <previous-good-release-run-id> \
  --repo Imagine-That-Ai/BurnBar \
  --name "macos-r2-publication-inputs-<commit>-<run-id>-<run-attempt>" \
  --dir "$handoff_dir"

# Read-only target audit for an already-R2-bound release:
node scripts/ci/promote-github-release.mjs audit-rollback-target \
  --tag "v<previous-good-version>" \
  --commit "<previous-good-full-commit>" \
  --asset-dir "$handoff_dir/release-promotion-assets" \
  --receipt "$handoff_dir/release-promotion-receipt.json"

OPENBURNBAR_RELEASE_ASSET_DIR="$handoff_dir/release-promotion-assets" \
OPENBURNBAR_RELEASE_RECEIPT="$handoff_dir/release-promotion-receipt.json" \
OPENBURNBAR_RELEASE_VERSION="<previous-good-version>" \
OPENBURNBAR_RELEASE_TAG="v<previous-good-version>" \
OPENBURNBAR_RELEASE_COMMIT="<previous-good-full-commit>" \
OPENBURNBAR_ROLLBACK_APPCAST="$handoff_dir/release-promotion-assets/appcast.xml" \
OPENBURNBAR_EXPECTED_LIVE_VERSION="<bad-live-version>" \
OPENBURNBAR_EXPECTED_LIVE_COMMIT="<bad-live-full-commit>" \
OPENBURNBAR_ROLLBACK_CONFIRM=publish-appcast-rollback \
scripts/publish-macos-appcast-rollback-r2.sh

# Only after R2 verifies byte-exact, restore GitHub latest for installed
# clients that still poll releases/latest/download.
node scripts/ci/promote-github-release.mjs promote-rollback-target \
  --receipt "$handoff_dir/release-promotion-receipt.json"
```

The rollback publisher fully preflights before resolving Wrangler or making the first
R2 write. It validates every previous-good receipt asset and requires the supplied
appcast plus the other mutable pointers to match the audited target bytes exactly.
It verifies the target version, commit, DMG length/SHA-256, and Sparkle signature
against `SUPublicEDKey` inside the audited app ZIP. Before mutation it snapshots all
three live objects and checks the operator-declared live version/commit. It restores
`release-metadata.json`, moves `latest-macos.json`, and activates `appcast.xml` last.
Any upload or verification failure attempts to restore and verify the exact snapshot
(or delete an object that was previously absent); a failed or unverified compensation
is a manual-recovery HOLD. It then downloads those three public pointers plus the
immutable previous-good DMG, app ZIP, and corresponding source with bounded
no-cache requests and requires exact byte, signature, and cross-binding matches.
The mutable objects carry `max-age=300`, so the public CDN may need a few minutes
to converge. Only after that proof succeeds may the same immutable
rollback-target receipt restore GitHub latest for legacy installed clients. If
that final GitHub mutation or verification fails, stop on a manual-recovery
HOLD: R2-bound clients are contained, but legacy GitHub-feed clients are not.

### 5. Verify clients see the rolled-back feed

Fetch the live feed and confirm the target is the advertised latest (the script prints
the exact URLs when `OPENBURNBAR_R2_PUBLIC_BASE_URL` is set):

```bash
curl -fsSL https://<public-base-url>/appcast.xml \
  | grep -F '<sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>'
```

Then confirm the bad version is gone:

```bash
curl -fsSL https://<public-base-url>/appcast.xml | grep -F '1.0.2' && echo "STILL PRESENT" || echo "dropped: OK"
```

On a macOS client running a version below the target, use **Check for Updates** (or wait
for the scheduled poll) and confirm Sparkle offers the target, not the dropped build.
A client already running the higher bad version will not downgrade through Sparkle; it
requires a higher-version hotfix or explicit manual recovery. New upgrades to the bad
DMG stop only after both the R2 pointers and GitHub latest identify the audited
previous-good release.

`v1.0.29` is a migration boundary: its signed/checksummed metadata is
GitHub-latest-bound, so it cannot be published as an R2 rollback target. If the
first R2-bound transition release is bad, restore GitHub latest to `v1.0.29`
for legacy clients and ship a higher-version R2-bound hotfix for
transition-release clients. Do not claim full rollback containment until that
hotfix is live.

## Fix-Forward

Re-pinning is a stop-gap: the feed is now pinned **behind** the bad build, so the next
release must advance past it. After the incident is contained:

1. Build and ship a hotfix release with a version **higher** than the bad build, via the
   normal release path in [`RELEASE_ROLLBACK.md`](RELEASE_ROLLBACK.md) (hotfix tag).
2. The release workflow regenerates and republishes the appcast with the hotfix as the
   new latest item; clients update forward.
3. Optionally delete/draft the bad GitHub release and revert any Homebrew cask bump
   (see `RELEASE_ROLLBACK.md` Stages 3-5).

## Relationship To iOS Phased Release

The macOS direct-download channel and the iOS App Store use **different** rollback
levers — this script governs only the former:

- **macOS direct-download (this script):** you own the Sparkle appcast, so you can pull a
  bad build from the feed instantly by re-pinning. There is no Apple-side phased release;
  the feed is the single source of truth for what clients are offered.
- **iOS App Store:** Apple controls distribution. There is no "delete the build" lever
  once a version is live. The equivalent moves are to **halt the phased release** in App
  Store Connect (pausing the 7-day staged rollout) and to **submit an expedited hotfix**.
  Removing a paid surface from sale for new purchasers is covered in
  [`COMMERCIAL_ROLLBACK.md`](COMMERCIAL_ROLLBACK.md) ("Apple And Google Play Controls").
- **macOS App Store** builds follow the iOS App Store model (phased release / halt /
  expedited review), **not** the appcast. Use this script only for the
  direct-download/Sparkle channel.

In short: macOS direct-download is the only channel where you can unilaterally roll the
feed back; for store channels you pause the phased rollout and fix forward.

## Rollback Verification Checklist

After publishing, the rollback is confirmed when all of these hold:

- `--list` against the live feed (or a fresh local copy) shows the target as the latest
  item in the canonical `appcast.xml`.
- GitHub `releases/latest` resolves to the same audited rollback target,
  covering installed clients that have not migrated from the legacy GitHub
  feed.
- A `curl` of the live feed contains the target `shortVersionString` and **does not**
  contain the bad version string; `latest-macos.json` and `release-metadata.json`
  identify the same previous-good version and commit.
- A real macOS client below the target is offered the target, while a client at the
  target reports up-to-date. Already-bad higher-version clients are tracked for
  hotfix/manual recovery rather than counted as rollback success.
- The bad DMG URL is no longer referenced by any `<enclosure>` in the live feeds.

## Rollback Drill

Run this drill quarterly alongside the `RELEASE_ROLLBACK.md` drill so the appcast lever
is rehearsed, not first-used during an incident. Use a throwaway copy of the feed — never
the live one — by pointing `OPENBURNBAR_DOWNLOADS_DIR` at a scratch directory:

1. Copy the current published feeds into a scratch dir and export
   `OPENBURNBAR_DOWNLOADS_DIR=<scratch>`.
2. `scripts/ops/rollback-macos-appcast.sh --list` — confirm it parses both feeds.
3. `scripts/ops/rollback-macos-appcast.sh --to-version <previous-good>` — confirm the
   dry-run plan drops only the latest item.
4. `scripts/ops/rollback-macos-appcast.sh --to-version <previous-good> --yes` — confirm
   the scratch feeds are rewritten and well-formed (`xmllint --noout` or re-run `--list`).
5. Confirm a second run is a clean **NO-OP** (idempotency).
6. Confirm a bad target (`--to-version 9.9.9`) and a stale target are both **refused**
   with no feed modified.

The drill passes when an on-call operator can, against a scratch copy, identify the safe
target from `--list`, produce a correct rolled-back feed, and recite the publish + verify
steps — without touching the live feed.
