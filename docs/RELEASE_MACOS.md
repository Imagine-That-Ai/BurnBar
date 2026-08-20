# macOS Release

OpenBurnBar's direct-download release pipeline is automated via `.github/workflows/release.yml`.
Pushing a `v*` tag builds, signs, notarizes, staples, and publishes a GitHub Release with DMG, ZIP, update feeds, checksums, SBOM, and provenance metadata.

## Distribution channels

OpenBurnBar should ship through both channels, but not as the exact same binary.

| Channel         | Use it for                                                                                                                  | Constraints                                                                                                                                                                                             |
| --------------- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mac App Store   | Discovery, Apple-hosted updates, App Store trust, Apple billing, simpler install for conservative users                     | App Sandbox is required; system-level Computer Use, broad filesystem access, direct LaunchAgent installation, and other unsandboxed helper behavior must be disabled or redesigned behind MAS-safe APIs |
| Direct download | Power-user build with full local daemon, faster hotfixes, system Computer Use, notarized DMG/ZIP, website-driven onboarding | We own hosting, updater, billing/support, and trust messaging; must keep Developer ID signing, hardened runtime, notarization, stapling, checksums, and smoke tests green                               |

The product policy is:

- **Mac App Store build:** sandboxed, `DISTRIBUTION_MAS=1`, no Mac System Computer Use, no unsandboxed daemon install path.
- **Direct-download build:** Developer ID signed and notarized, `DISTRIBUTION_MAS` unset, full local power-user surface.
- **Architecture:** current release artifacts are Apple Silicon (`arm64`) because the vendored Iroh XCFramework does not include a release-ready Intel slice.
- Both builds should share the same marketing version. Build numbers may differ if App Store Connect or notarization recovery requires it.

Run the current Mac App Store readiness compile gate with:

```bash
scripts/verify-macos-app-store-readiness.sh
```

That script verifies the MAS entitlements in `AgentLens/Resources/OpenBurnBarMAS.entitlements`, preserves the direct-download release entitlements, and compiles the Mac app with `DISTRIBUTION_MAS=1`.

Build the actual release artifacts with:

```bash
# Sandboxed Mac App Store archive/export. Add OPENBURNBAR_UPLOAD_MAC_APP_STORE=1
# to validate/upload the exported package with App Store Connect credentials.
scripts/build-macos-app-store-release.sh

# Developer ID direct-download artifacts. This signs, notarizes, staples, checksums,
# and emits DMG, ZIP, appcast, latest metadata, SBOM, and release metadata under
# build/macos-website-<version>-<build>/.
scripts/build-macos-website-release.sh
```

Before either channel ships publicly, run the AGPL compliance gate:

```bash
bash scripts/ci/verify-agpl-compliance.sh
```

Store-bound uploads also require legal review because App Store and Mac App
Store terms can interact with GPL/AGPL obligations. Do not upload
AGPL/libsignal-linked review binaries until counsel signs off. The upload path
fails unless `OPENBURNBAR_AGPL_STORE_LEGAL_REVIEW=approved` is set by the
operator after counsel approval.

The protected `promote=true` workflow publishes and verifies the exact audited
candidate in the Cloudflare R2 bucket behind `downloads.burnbar.ai` before it
makes the GitHub release latest. The commands below are the manual recovery
path for an interrupted R2 publication:

```bash
scripts/setup-macos-downloads-r2.sh

# Download the exact handoff retained after audit and before activation.
handoff_dir="$(mktemp -d)"
gh run download <release-workflow-run-id> \
  --repo Imagine-That-Ai/BurnBar \
  --name "macos-r2-publication-inputs-<release-commit>-<run-id>-<run-attempt>" \
  --dir "$handoff_dir"

OPENBURNBAR_RELEASE_ASSET_DIR="$handoff_dir/release-promotion-assets" \
OPENBURNBAR_RELEASE_RECEIPT="$handoff_dir/release-promotion-receipt.json" \
OPENBURNBAR_RELEASE_VERSION="<version>" \
OPENBURNBAR_RELEASE_TAG="v<version>" \
OPENBURNBAR_RELEASE_COMMIT="<full-release-commit>" \
OPENBURNBAR_EXPECTED_LIVE_VERSION="<currently-live-version>" \
OPENBURNBAR_EXPECTED_LIVE_COMMIT="<currently-live-full-commit>" \
scripts/upload-macos-downloads-r2.sh
```

The setup script creates the R2 bucket and can bind the branded custom domain.
The promotion job retains one authoritative handoff containing its exact
downloaded GitHub Release asset directory and immutable promotion-audit receipt
before any public pointer changes.
The R2 uploader requires both. Before resolving Wrangler or making any provider
call, it verifies every receipt asset's size and GitHub SHA-256 digest, then
reuses the release-promotion checksum and update-metadata validators to bind the
version, tag, commit, DMG/ZIP/source names, DMG byte length and SHA-256, Sparkle
signature, appcast, and release metadata. The Sparkle signature is verified over
the exact DMG using `SUPublicEDKey` extracted from the receipt-bound app ZIP;
the current checkout is not trusted for that key. The audited feeds must already
use the exact `OPENBURNBAR_MAC_UPDATE_BASE_URL`; publication never rewrites
signed or checksummed update metadata.

Only after that complete preflight succeeds does it publish:

1. immutable versioned artifacts: DMG, ZIP, checksums, SBOM, corresponding
   source, and source digest;
2. `release-metadata.json`;
3. `latest-macos.json`, then `appcast.xml` as the final activation pointer.

It then downloads every published R2 object with bounded retries, no-cache
headers, and cache-busting query parameters; the public bytes must match the
audited local size and SHA-256 and pass the same exact release bindings. A
missing final discovery file therefore produces zero R2 writes, while a stale
edge cache is retried rather than mistaken for the new candidate. Before any
write, the uploader seals the audited bytes into a private snapshot and
compare-and-swaps all three mutable public pointers against the operator-declared
live version/commit. It permits only a newer version or an exact same-candidate
retry. A failure after mutable publication starts attempts to restore and verify
the prior bytes; an unverified restore is a manual-recovery HOLD.

The uploader intentionally does not read `website/src/data/site.ts` or
`website/public/downloads/`: those describe the already-published public release
and may remain on the previous version until the replacement artifact has passed
public trust verification. Defaults:

- R2 bucket: `openburnbar-downloads`
- Public download URL: `https://downloads.burnbar.ai`

If the bucket or host changes, override with `OPENBURNBAR_R2_BUCKET` and
`OPENBURNBAR_R2_PUBLIC_BASE_URL`. Keep `SITE.macDownloadBaseUrl` in
`website/src/data/site.ts` on a first-party host; raw `r2.dev` bucket URLs are a
storage implementation detail, not the customer-facing trust boundary.
The repository variable `OPENBURNBAR_MAC_UPDATE_BASE_URL` is required before
tagging and must equal the stable R2 public base. Mutable GitHub
`releases/latest/download` URLs are rejected for release handoffs.

R2 publication is not website activation. Keep the website release pointer and
audited live URL on the previous version until the exact R2 candidate has passed
the public byte verifier and the macOS signing/notarization/trust gate. Update
and deploy the website separately, last.

### Website download preflight

Before publishing a website change that edits `SITE.macDownloadBaseUrl`,
`SITE.macReleaseLatest`, or `SITE.macReleaseFile`, verify the exact customer URL
that the Download button will use:

```bash
npm run test:download-provenance --prefix website
bash scripts/ci/verify-public-macos-download-trust.sh
```

That guard compares `SITE.macDownloadBaseUrl/SITE.macReleaseFile` to the
audited live DMG URL embedded in `website/scripts/test-download-provenance.mjs`,
then performs a live `HEAD` request against that audited URL. Changing the
public DMG requires updating both `SITE` and the audited URL constant in the
same PR, after the replacement artifact is published and manually verified. The
guard must fail if DNS is missing, the object was not uploaded, or a release
asset path is stale. Do not deploy the website with a dead direct-download host
and do not rely on `burnbar.ai/downloads/*` Firebase fallback pages as proof
that a DMG exists.

The macOS trust gate downloads the same public DMG and runs Apple platform
checks against the real artifact: Gatekeeper assessment for the DMG, stapler
validation for the notarization ticket, app bundle code-signature verification,
Developer ID certificate inspection, Firebase Auth Keychain entitlement/profile
verification, and Gatekeeper execution assessment for the mounted app. A public
download is not shippable unless this command passes; URL liveness alone is not
enough. The `Public macOS Download Trust` workflow runs this check automatically
when `website/src/data/site.ts` changes, so a future button update cannot
silently point users at an unsigned, unstapled, or Keychain-broken DMG.

### Temporary v1.0.29 profile-certificate exception

The immutable public `v1.0.29` DMG predates the current certificate/profile
pairing: its app is signed by one valid Developer ID certificate while its
embedded all-devices profile lists a different certificate from the same
release setup. The public-download verifier may bypass only that profile
certificate-membership comparison when every value below matches exactly:

- Version: `1.0.29`
- DMG SHA-256: `fc0926b4e7ae0c9e155d9be6711a06119f7a2fff2f7df8448fd34ca052db9d96`
- Bundle signer SHA-256: `2B5CCCC3256C4FE179A7C34614152AE3B940D21EB9193F36D312BAAD82C762BB`
- Sole profile certificate SHA-256: `F6D16CF680A35D2C27805517469FC6427CDFFFD3D2207C13FFF13CC0F10F6A6A`

The exception does not bypass the DMG digest check, Gatekeeper, notarization,
stapling, deep signature validation, Developer ID/team identity, entitlements,
Firebase configuration, App Check scan, Keychain profile authorization, daemon
launch/signing verification, or final Gatekeeper execution assessment. Normal
release packaging still invokes the certificate verifier without legacy
artifact context and therefore remains fail-closed. Remove the exception and
its tests as soon as the public download moves away from `v1.0.29`.

Release artifacts must also include the shipped Firebase client plist and the
app's `MAC_APP_DIRECT` provisioning profile. The plist is client configuration,
not a private signing secret. The profile authorizes Firebase Auth's macOS
Keychain access group for `com.openburnbar.app`. Both must be embedded before
Developer ID signing so the sealed app can initialize cloud auth and persist the
signed-in Firebase user. The release workflow runs
`scripts/ci/verify-apple-release-firebase-config.sh` on the unsigned app and
packaged DMG/ZIP; the website trust gate runs the same config check plus the
Keychain entitlement/profile check against the downloaded public copy. A DMG
that launches with "Cloud auth is unavailable" or Keychain access errors is not
shippable.

If the branded `downloads.burnbar.ai` host is down, the emergency recovery path
is to repoint the website at a known live GitHub Release asset, rerun the
provenance test, merge, and deploy Hosting. The permanent follow-up is to repair
the direct-download release lane, upload the signed/notarized artifacts, restore
`SITE.macDownloadBaseUrl` to `https://downloads.burnbar.ai`, and rerun the same
guard before deployment.

The app's default direct-update feeds are
`https://downloads.burnbar.ai/latest-macos.json` and
`https://downloads.burnbar.ai/appcast.xml`. Both the custom updater and Sparkle
therefore use the governed R2 rollback pointers. The release artifact scan
fails if either packaged Info.plist value drifts. The workflow still promotes
the same audited GitHub release last so already-shipped clients that poll the
legacy GitHub-latest URL can discover the transition release only after every
R2 byte is publicly verified. `SITE.macUpdateBaseUrl` controls the public feed
links on `/download`.

The direct-download app bundle declares `SUPublicEDKey`
`613YSraDEJ54LKsfpqbYhyzYnfYRg7z4QwiEJfoy0TI=`. Its matching private seed is
stored only as the GitHub Actions secret `OPENBURNBAR_SPARKLE_PRIVATE_KEY_BASE64`.

For the branded `downloads.burnbar.ai` host, the `burnbar.ai` DNS zone must be
available in Cloudflare. Then run:

```bash
OPENBURNBAR_R2_CUSTOM_DOMAIN=downloads.burnbar.ai \
OPENBURNBAR_R2_ZONE_ID=<cloudflare-zone-id> \
scripts/setup-macos-downloads-r2.sh
```

The direct-download path is the currently customer-downloadable Mac channel. The MAS build has passed
these release gates and is pending Apple review:

1. Sandboxed app and embedded helpers are signed with App Store distribution entitlements.
2. The app launches and core read-only dashboard/Hermes/quota flows work without writing LaunchAgents.
3. System Computer Use is hidden or disabled in the binary, not only in copy.
4. App Store Connect has macOS screenshots, metadata, privacy answers, review notes, and a reviewer-safe walkthrough.
5. A Mac App Store archive/export validates locally and uploads to App Store Connect.

## How to cut a release

```bash
# First: scan exactly the files that could be published from this checkout
scripts/security/scan-publishable-tree.sh

# Recommended: use the tag-release script for validated, annotated tags
scripts/tag-release.sh 0.2.0

# Or manually:
git tag -a v0.2.0 -m "OpenBurnBar 0.2.0"
git push origin v0.2.0
```

The `tag-release.sh` script:

- Validates semver format
- Checks that the version in `project.yml` matches the tag
- Verifies the version exists in `CHANGELOG.md`
- Creates an annotated tag with the changelog section as the body
- Pushes the tag to origin

The workflow will:

1. Require the protected `release` GitHub environment before any Apple signing material is available to the job
2. Scan the publishable tree with `gitleaks` and verified-secret `trufflehog`
3. Run Swift, app, and TypeScript tests. Release Swift/app tests intentionally run without coverage instrumentation; coverage belongs to PR/CI gates, while release publication needs bounded pass/fail proof.
4. Build `OpenBurnBar.app` unsigned
5. Embed daemon/helper artifacts and `OpenBurnBarCore.framework`
6. Sign app + DMG with Developer ID identity
7. Notarize + staple DMG using `notarytool` with App Store Connect API key
8. Generate the signed Sparkle-compatible appcast and latest-macOS JSON feed
9. Compute SHA256/SHA512 checksums for DMG, ZIP, source archive, appcast, and latest metadata
10. Optionally GPG-sign checksums if `RELEASE_SIGNING_KEY` is configured, and fail closed if that
    configured signing path does not produce a valid detached signature
11. Generate SPDX SBOM from SwiftPM, npm, Cargo, and Android/Gradle dependencies
12. Generate required keyless Sigstore blob attestations and verification bundles for the SBOM, VEX, checksums, binaries, source archive, and update feeds
13. Write release metadata JSON with version, commit, timestamp, update feed, and runner metadata
14. Upload the DMG, ZIP, update feeds, checksums, optional checksum signature, SBOM, Sigstore bundles/predicates, and metadata as Actions artifacts
15. Run release smoke from the uploaded DMG artifact, including app launch and authenticated daemon health
16. Publish a GitHub Release with the same downloaded artifacts as explicitly
    non-latest. A separate `workflow_dispatch` with `promote=true` audits the
    already-published tag, metadata, attestations, and every asset byte,
    publishes and verifies the exact R2 candidate, and only then makes that
    exact release GitHub's latest release.

If a stable tag exists but the Functions or Cloud Run dry-run status was never
published, do not move or recreate the tag. Use the fail-closed
[existing stable-tag dry-run recovery](runbooks/existing-stable-tag-dry-run-recovery.md);
it permits only an untouched tag whose commit remains reachable from current
main, with no GitHub Release, matching production deployment, or prior plane
status. After recovery, the Functions and Cloud Run real retries must also be
dispatched from `main` with `existing_tag_retry=true`; never select `v1.0.34`
as their dispatch ref or rerun its failed tag-triggered deploy jobs because that
would execute the older workflow/helper frozen in the tag.

`notarytool` and `stapler` are wrapped by
`scripts/ci/release-command-watchdog.py` in release CI. Apple's `--timeout` flag
is still passed to the inner notary request, and the wrapper enforces a separate
process-group watchdog so a hung notarization or stapling attempt can retry the
fallback auth mode or fail with a clear error instead of burning the entire
protected release job timeout.

Run the release workflow from the release tag ref (for example
`gh workflow run release.yml --ref v1.0.5 ...`) so the Sigstore certificate
identity is bound to `refs/tags/v1.0.5`, not the moving default branch.

Tag-triggered publication and ordinary manual retries always pass
`--latest=false`; publishing assets must never silently repoint the public
updater channel. After the non-latest release is published and independently
approved, promote it by dispatching the same workflow from the immutable tag:

```bash
gh workflow run release.yml \
  --ref v1.0.5 \
  -f tag=v1.0.5 \
  -f promote=true \
  -f expected_live_macos_version=1.0.4 \
  -f expected_live_macos_commit=<currently-live-full-commit>
```

The promotion retry downloads and verifies the complete existing asset set,
checks each GitHub asset ID, size, and SHA-256 digest against the audited bytes,
and rechecks the exact release metadata. It retains the exact handoff, performs
the R2 compare-and-swap against the declared live coordinates, uploads and
publicly verifies every candidate byte, and only then may it perform the single
`gh release edit ... --latest` mutation. GitHub latest is the final activation
for legacy installed clients. If that final mutation fails, the verified R2
candidate remains staged but the legacy client channel is unchanged; stop on a
manual-recovery HOLD and retry with the same candidate coordinates as the
expected live R2 release. The workflow finally verifies that
`releases/latest` resolves to the same release and unchanged asset identities
before the live Sparkle feed gate runs. A missing, substituted, extra, or
concurrently changed asset blocks promotion.

The `domain_core_profile` input must declare the governed profile the release
was published under. `public-production` (the default) requires the complete
native domain-core evidence set: the Apple, Android, and iOS Sigstore bundles,
the iOS archive, and the App Store Connect receipt. `public-production-rollback`
promotes a governed all-legacy rollback release, which publishes no native
domain-core evidence; any evidence asset that is present is still fully
verified. A declared profile that does not match the published asset set fails
closed before any mutation. When `checksums-vVERSION.txt.asc` is published, the
promotion lane verifies the detached GPG signature against the audited
checksums file and fails if `RELEASE_SIGNING_KEY` is not configured to verify
it.

Before approving a promoted release, verify that the tag still points at the
current `origin/main` tip. If `main` advances after the tag is cut, cancel the
run before publication and cut a new patch tag from the newest main. Do not ship
a public direct-download artifact from a stale tag when the release owner asked
for "everything."

Expected release timing: Swift package tests and macOS app XCTest each have
explicit workflow timeouts. If either step nears its timeout, treat it as an
actionable release-lane failure, inspect the completed job logs, fix the root
cause or split the gate, and rerun on a new tag. Do not let a publish run sit
opaque until the three-hour job timeout.

Release-lane structure: keep signing, notarization, artifact generation,
artifact-backed smoke, and publish serialized, but do not add unrelated quality
checks to that critical path. Every validation gate runs as an independent
release job and blocks `publish` through `needs`:

- `release-preflight` resolves and validates the tag once (SemVer grammar,
  dispatch-ref binding, origin/main reachability), scans the publishable tree
  for secrets, runs the BurnBar provenance/product preflights, and validates
  any bypass reasons. Every other lane consumes its
  `tag_name`/`tag_ref`/`release_commit`/`version`/`is_prerelease` outputs
  and re-proves `HEAD == release_commit` after its own checkout. The strict
  signing-secret presence check runs inside `build-and-release` instead,
  because environment-scoped secrets only resolve in environment-bound jobs.
- `release-swift-gate` (Swift package tests + retrieval replay evals),
  `release-app-gate` (release-critical app XCTest slice), `release-sqlcipher-gate`
  (Release-configuration codec proof), `release-mobile-gate` (iOS simulator
  smoke), and `release-android-gate` (Android JVM unit tests, ubuntu) run in
  parallel with each other and with packaging. The pre-existing functions,
  extension/TypeScript, and supply-chain gates are unchanged.
- `build-and-release` is packaging only: Signal FFI, extension, daemon, Release
  .app, Android signed bundle, macOS signing, notarization, provenance, and
  artifact uploads — serialized in one job so attestations bind to the same
  workspace that built the artifacts.
- `publish` requires the preflight, all seven validation gates, packaging, and
  the DMG smoke test. A failed or cancelled lane blocks publish; a lane is only
  skipped through the owner-approved bypass inputs that `release-preflight`
  validates fail-closed. `scripts/ci/verify-release-provenance-boundaries.mjs`
  pins this `needs` list — update it and its mutation tests in the same PR when
  the lane set changes.

This keeps a bad gate from shipping while cutting the wall-clock from a ~6 hour
serial chain to roughly the packaging lane's duration, and it makes retries
cheap: "Re-run failed jobs" re-runs only the lane that failed (a flaky DMG
smoke costs minutes, not a full pipeline).

The protected `build-and-release` job intentionally has a larger wall-clock cap
than the individual steps. It contains Android signing, macOS signing,
notarization, provenance, and artifact upload work; a cold runner can take a
few hours even when healthy. Keep step-level timeouts tight for diagnostics,
but do not let the aggregate job cap cancel a valid release mid-packaging. The
validation gates carry their own job caps (and the retrieval replay evals step
is capped at 75 minutes) so a hung gate can never silently eat the pipeline.

Emergency retry lane: if a tag run already passed Swift tests, release app
smoke, SQLCipher, mobile smoke, retrieval replay, and Android unit tests for the
same product source, but later died in packaging/notarization/publish, an owner
may rerun `workflow_dispatch` with `run_release_validation_gates=false`. The
reason must name owner approval and link the prior GitHub Actions run. This
skips only the slow validation gates; preflight, secret checks, config
injection, Android AAB build, macOS signing, notarization, artifact smoke,
provenance, publish, and live feed verification still run.

## Release artifacts

Each release includes:

| Asset                                             | Purpose                                                                                                   |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `OpenBurnBar-VERSION-macOS.dmg`                   | Signed, notarized DMG installer                                                                           |
| `OpenBurnBar-VERSION-macOS.zip`                   | Signed app archive                                                                                        |
| `appcast.xml`                                     | Sparkle-compatible direct-download update appcast; production releases must include `sparkle:edSignature` |
| `latest-macos.json`                               | Machine-readable latest release feed consumed by the direct-download app; unsigned metadata is ignored    |
| `checksums-vVERSION.txt`                          | SHA256/SHA512 checksums for DMG, ZIP, source archive, appcast, and latest metadata                        |
| `checksums-vVERSION.txt.asc`                      | GPG detached signature (if configured)                                                                    |
| `sbom-vVERSION.spdx.json`                         | Software Bill of Materials (SPDX format)                                                                  |
| `*.sigstore.json`                                 | Sigstore verification bundles for keyless blob attestations                                               |
| `*.predicate.json`                                | Release-artifact predicates bound into the Sigstore blob attestations                                     |
| `OpenBurnBar-VERSION-corresponding-source.tar.gz` | Corresponding source archive for AGPL-covered binaries and services                                       |
| `release-metadata.json`                           | Build provenance: version, commit, timestamp, update feed, runner                                         |

## Release provenance

Sigstore keyless blob attestations are the required release provenance control. They bind the release
artifacts to GitHub Actions OIDC identity, the release workflow, and the source commit without storing a
long-lived provenance signing key in the repository. The workflow uses `cosign attest-blob` for files on
disk and publishes the resulting `.sigstore.json` verification bundles plus the release-artifact predicate
JSON files. GPG checksum signatures are optional legacy compatibility artifacts; if `RELEASE_SIGNING_KEY`
is configured, the workflow verifies that the detached checksum signature was actually produced.

### Checksum verification

Download the checksums file from the GitHub release and verify:

```bash
# Download checksums
gh release download v0.2.0 --pattern "checksums-v0.2.0.txt"

# Verify against local downloads
shasum -a 256 --check checksums-v0.2.0.txt --ignore-missing
```

### GPG signature verification (if configured)

```bash
gpg --verify checksums-v0.2.0.txt.asc checksums-v0.2.0.txt
```

### SBOM inspection

```bash
# View the SPDX SBOM
python3 -m json.tool sbom-v0.2.0.spdx.json | head -30
```

## Manual rerun path

Use `workflow_dispatch` on `.github/workflows/release.yml` and provide an existing `v*` tag.
The workflow checks out that exact tag before building. This is intended for
release recovery without creating a new tag. Leave `promote=false` for
packaging or publication recovery. Set `promote=true` only after the stable,
already-published release is ready for the public updater channel; prerelease
tags are rejected and cannot become latest.

## Release environment and tag protection

The `build-and-release` packaging job is bound to the GitHub environment named
`release`. That environment should require a human reviewer and restrict
deployments to `v*` release tags. Apple Developer ID, notary, Firebase, and
optional checksum-signing secrets should live as environment secrets when
possible; repository secrets are still accepted by GitHub Actions, but the
environment approval gate is the release-time control that prevents an
accidental tag push from immediately using Apple signing material.

The validation gate jobs are intentionally NOT bound to the environment: they
consume only repository-level config secrets (Firebase plist, Sentry DSNs,
Android google-services), never Apple or Android signing material, so they
start immediately on dispatch while the packaging lane waits for the single
owner approval. Keystore injection and `bundleRelease` stay inside the
approved `build-and-release` job for exactly this reason — do not move signing
material into an unapproved lane.

Protect `v*` tags with a repository ruleset that blocks deletion and non-fast-forward
updates. A release tag should be created once, by `scripts/tag-release.sh`, and
never rewritten.

Before creating a tag, run:

```bash
scripts/security/scan-publishable-tree.sh
```

The scanner copies tracked files plus non-ignored untracked files into a temporary
publishable tree, then runs `gitleaks` and `trufflehog --only-verified`. Ignored
local files such as `GoogleService-Info.plist`, `.env`, `.p12`, `.p8`, and
provisioning profiles are intentionally excluded because they are not publishable.

## Release entitlements

The release workflow signs with `AgentLens/Resources/OpenBurnBarRelease.entitlements`
after expanding the team/bundle placeholders into a temporary signing plist. The
direct-download app must embed a `MAC_APP_DIRECT` profile for
`com.openburnbar.app` and must sign with `keychain-access-groups` containing
`TEAMID.com.openburnbar.app`; Firebase Auth on macOS cannot persist users
without it. Direct-download release entitlements still omit iCloud and Apple
Sign-In until those capabilities are intentionally added to the Developer ID
profile and QA flow. The development entitlements in
`AgentLens/Resources/OpenBurnBar.entitlements` remain broader for local/Xcode
builds.

## Rollback

See [RELEASE_ROLLBACK.md](RELEASE_ROLLBACK.md) for the full rollback decision tree and procedures, including hotfix tagging and Homebrew cask reversion.

## Required GitHub Actions secrets (strict mode)

Tagged releases are **fail-hard**: if any required secret below is missing, the workflow fails and no fallback unsigned release is produced.

| Secret                                                                                                | Description                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `APPLE_TEAM_ID`                                                                                       | 10-character Apple Developer Team ID                                                                                                                 |
| `APPLE_SIGNING_IDENTITY`                                                                              | Developer ID identity, e.g. `Developer ID Application: Your Name (TEAMID)`                                                                           |
| `APPLE_CERTIFICATE_P12`                                                                               | Base64-encoded `.p12` (Developer ID cert + private key)                                                                                              |
| `APPLE_CERTIFICATE_PASSWORD`                                                                          | Password used when exporting `.p12`                                                                                                                  |
| `APPLE_NOTARY_KEY_ID`                                                                                 | App Store Connect API key ID                                                                                                                         |
| `APPLE_NOTARY_ISSUER_ID`                                                                              | App Store Connect API issuer ID (required for team keys, optional for individual keys)                                                               |
| `APPLE_NOTARY_API_KEY_P8`                                                                             | Base64-encoded contents of `AuthKey_<KEYID>.p8`                                                                                                      |
| `OPENBURNBAR_APP_PROFILE_BASE64`                                                                      | Base64-encoded `MAC_APP_DIRECT` provisioning profile for `com.openburnbar.app`; required so Firebase Auth can use the app Keychain access group      |
| `OPENBURNBAR_SAFARI_EXTENSION_PROFILE_BASE64`                                                         | Base64-encoded `MAC_APP_DIRECT` provisioning profile for `com.openburnbar.app.safari-extension`; required because the appex claims the `group.com.openburnbar.app` App Group and the app's Keychain access group, both profile-restricted for Developer ID |
| `FIREBASE_PLIST_BASE64`                                                                               | Base64-encoded Firebase plist for CI                                                                                                                 |
| `FIREBASE_APP_CHECK_DEBUG_TOKEN`                                                                      | Firebase App Check debug token for CI                                                                                                                |
| `OPENBURNBAR_SPARKLE_PRIVATE_KEY_BASE64` / `OPENBURNBAR_SPARKLE_ED_SIGNATURE` / `SPARKLE_SIGN_UPDATE` | Sparkle EdDSA signing source for direct-download update appcast                                                                                      |
| `OPENBURNBAR_MAC_UPDATE_BASE_URL`                                                                     | Required stable first-party HTTPS base for generated update feeds (normally `https://downloads.burnbar.ai`); mutable GitHub latest URLs are rejected |
| `RELEASE_SIGNING_KEY`                                                                                 | _(Optional)_ Base64-encoded GPG private key for signing checksums                                                                                    |

Never commit raw Apple credentials. Local `.p12`, `.p8`, provisioning profile,
and developer-profile files are ignored by `.gitignore`; the workflow decodes
secret payloads only into `$RUNNER_TEMP`, imports them into a temporary keychain
or chmod-600 notary key file, and deletes those artifacts in an `always()` cleanup
step from the same job that created them.

### Generating secret payloads

```bash
# Developer ID certificate export (from Keychain Access -> My Certificates)
# Export as .p12, then encode:
base64 -i Certificates.p12 | pbcopy

# App Store Connect key file (AuthKey_<KEYID>.p8), then encode:
base64 -i AuthKey_ABC123XYZ.p8 | pbcopy
```

### Generating release signing key (optional)

The release workflow can GPG-sign the checksums file for provenance. If `RELEASE_SIGNING_KEY` is not configured, the checksums file is still published but without a detached signature.

```bash
# Generate a signing-only subkey (recommended)
gpg --batch --generate-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: OpenBurnBar Release
Name-Email: release@openburnbar.app
Expire-Date: 0
EOF

# Export the private key for GitHub Actions
gpg --export-secret-keys --armor RELEASE_KEY_ID | base64 | pbcopy

# Upload the public key for user verification
gpg --export --armor RELEASE_KEY_ID > openburnbar-release-pubkey.asc
```

## Workflow guardrail

`.github/workflows/workflow-lint.yml` runs `actionlint` on workflow-file changes so syntax/expression issues are caught before tag day.

## Build from source (local dev)

```bash
make install
open -a OpenBurnBar
```

## References

- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Packaging for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Bundle layout](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
