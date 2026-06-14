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
- Local copies of the feed file(s) that the channel publishes — by default the arm64
  feed `appcast.xml` and the Intel feed `appcast-x86_64.xml` under
  `website/public/downloads` (override with `OPENBURNBAR_DOWNLOADS_DIR` or `--feed`).
  These are the same files [`scripts/upload-macos-downloads-r2.sh`](../scripts/upload-macos-downloads-r2.sh)
  publishes.
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
  the rolled-back feed locally and prints the exact operator publish + verify commands.

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

`--yes` opts into the write; without it the script never modifies a feed. Both feeds
(arm64 + Intel) are rewritten so the target is the advertised latest. The command then
prints the publish and verify steps.

### 4. Publish the rolled-back feed

The script does **not** upload. Run the publish command it prints:

```bash
scripts/upload-macos-downloads-r2.sh
```

This re-uploads the rewritten `appcast.xml` (and `appcast-x86_64.xml`) and re-verifies
the live feed advertises a Sparkle version. The feed objects carry a short
`max-age=300` cache, so the public CDN converges within a few minutes.

### 5. Verify clients see the rolled-back feed

Fetch the live feed and confirm the target is the advertised latest (the script prints
the exact URLs when `OPENBURNBAR_R2_PUBLIC_BASE_URL` is set):

```bash
curl -fsSL https://<public-base-url>/appcast.xml \
  | grep -F '<sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>'
curl -fsSL https://<public-base-url>/appcast-x86_64.xml \
  | grep -F '<sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>'
```

Then confirm the bad version is gone:

```bash
curl -fsSL https://<public-base-url>/appcast.xml | grep -F '1.0.2' && echo "STILL PRESENT" || echo "dropped: OK"
```

On a macOS client, use **Check for Updates** (or wait for the scheduled poll) and confirm
Sparkle offers the target version, not the dropped build. New downloads of the bad DMG
stop because no `<item>` advertises it anymore.

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
  item in **every** feed (arm64 and Intel).
- A `curl` of each live feed contains the target `shortVersionString` and **does not**
  contain the bad version string.
- A real macOS client's **Check for Updates** offers the target version (not the dropped
  build), or reports up-to-date if already on the target.
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
