# Shared Rust Shadow Mode Startup

This runbook gives the exact operator commands and configuration inputs to
start quota shadow mode on the two policy-required consumers (Apple and
Windows). Shadow mode is the first phase of the promotion evidence pipeline
documented in [`shared-rust-promotion-evidence.md`](shared-rust-promotion-evidence.md).

Signed release artifacts do not take rollout authority from the app process
environment. They embed one validated profile from
[`config/domain-core-build-profiles.json`](../../config/domain-core-build-profiles.json),
and both consumers ignore runtime overrides when that profile has signed
authority. This prevents an installed public artifact from enabling shadow mode
or evidence upload by environment-variable injection.

The canonical `OPENBURNBAR_DOMAIN_CORE_*` names remain the development/test and
server configuration contract. Release tooling translates the reviewed catalog
profile into the platform-specific Apple build settings or Windows MSBuild
properties shown below. The 14-day clock starts only when a signed `internal` or
`beta` artifact is running, the account has matching server-issued enrollment
claims, and samples from both required consumers reach the evidence collection.

## What shadow mode does

When `OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=shadow`:

1. The existing platform parser remains authoritative — the user-visible result
   is unchanged.
2. The Rust domain core runs once against the same complete input.
3. The adapter records a privacy-safe `DomainCoreQuotaShadowComparison`
   (operation, core version, outcome, mismatch category, and whole-call
   microsecond timings — never payloads, parsed values, or credentials).
4. If the rollout channel is `internal` or `beta`, the comparison is spooled
   to durable JSONL and eventually uploaded to the
   `submitDomainCoreShadowSamples` Firebase callable.

Missing or invalid configuration resolves to `legacy` — the documented
rollback state. Shadow mode never changes the user-visible result.

## Apple (macOS / iOS)

### Start a signed internal or beta artifact

Resolve the reviewed profile instead of hand-setting individual values. The
Apple formatter emits the canonical `DOMAIN_CORE_*` Xcode build settings that
become `OpenBurnBarDomainCore*` keys in the signed app's Info.plist:

```bash
node scripts/ci/resolve-domain-core-build-profile.mjs \
  --profile internal \
  --format github-env-apple \
  > /tmp/openburnbar-domain-core-apple.env

set -a
. /tmp/openburnbar-domain-core-apple.env
set +a

xcodebuild \
  -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBar \
  -configuration Release \
  DOMAIN_CORE_BUILD_PROFILE="$DOMAIN_CORE_BUILD_PROFILE" \
  DOMAIN_CORE_BUILD_AUTHORITY="$DOMAIN_CORE_BUILD_AUTHORITY" \
  DOMAIN_CORE_DISTRIBUTION="$DOMAIN_CORE_DISTRIBUTION" \
  DOMAIN_CORE_ROLLOUT_CHANNEL="$DOMAIN_CORE_ROLLOUT_CHANNEL" \
  DOMAIN_CORE_EVIDENCE_ENABLED="$DOMAIN_CORE_EVIDENCE_ENABLED" \
  DOMAIN_CORE_QUOTA_MODE="$DOMAIN_CORE_QUOTA_MODE" \
  DOMAIN_CORE_CLOUDVAULT_MODE="$DOMAIN_CORE_CLOUDVAULT_MODE" \
  DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE="$DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE" \
  DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE="$DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE" \
  DOMAIN_CORE_HERMES_MODE="$DOMAIN_CORE_HERMES_MODE" \
  DOMAIN_CORE_PRICING_MODE="$DOMAIN_CORE_PRICING_MODE" \
  build
```

Use `--profile beta` for beta. Run the same signing, notarization, and packaging
steps as the existing release lane; profile resolution never replaces those
gates. Before distribution, verify the built artifact receipt:

```bash
node scripts/ci/verify-domain-core-build-profile-artifact.mjs \
  --profile internal \
  --apple-app /path/to/OpenBurnBar.app
```

At runtime, `DomainCoreBuildProfileResolver` validates the embedded authority,
profile, distribution, channel, evidence flag, and all domain modes as one
coherent record. `MacDomainCoreShadowEvidenceRecorder` enables its spool only
when that record is a valid signed `internal` or `beta` profile. Incomplete or
inconsistent signed metadata fails closed to `legacy` with evidence disabled.

### Development override (does not start the promotion clock)

For an unsigned development build, the canonical process variable still starts
the quota comparison path:

```bash
OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=shadow open -a OpenBurnBar
```

Development authority intentionally has no evidence channel and cannot upload
promotion evidence. Do not use `launchctl setenv`, `LSEnvironment`, or an
Info.plist edit to simulate an internal/beta signed profile; only the catalog
profile and artifact verification above start the production evidence path.

### Spool location

Apple spools bounded JSONL batches under
`Application Support/OpenBurnBar/DomainCoreShadow` (per-user, 0o700 directory,
0o600 active file). At most 8 ready files with at most 100 samples per file.

## Windows

### Start a signed internal or beta artifact

Generate the reviewed MSBuild property sheet, then pass it to every app publish
command in the signed Windows release lane:

```powershell
node scripts/ci/resolve-domain-core-build-profile.mjs `
  --profile internal `
  --format msbuild-props `
  --output .domain-core-internal.props

dotnet publish windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj `
  -c Release `
  -r win-x64 `
  --self-contained true `
  -p:Platform=x64 `
  -p:DomainCoreBuildProfileProps="$PWD/.domain-core-internal.props" `
  -o publish/win-x64

dotnet publish windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj `
  -c Release `
  -r win-arm64 `
  --self-contained true `
  -p:Platform=ARM64 `
  -p:DomainCoreBuildProfileProps="$PWD/.domain-core-internal.props" `
  -o publish/win-arm64
```

The production release lane also passes native-engine, parser, version, signing,
and packaging inputs; keep every existing argument and gate when substituting
the internal profile sheet. Use `--profile beta` for beta. Verify both receipts
before distribution:

```powershell
node scripts/ci/verify-domain-core-build-profile-artifact.mjs `
  --profile internal --windows-dir publish/win-x64
node scripts/ci/verify-domain-core-build-profile-artifact.mjs `
  --profile internal --windows-dir publish/win-arm64
```

`Directory.Build.props` embeds the sheet as assembly metadata and
`DomainCoreBuildProfileResolver` validates it at runtime. Signed assemblies
ignore process overrides. A valid signed `internal` or `beta` record requires
quota mode `shadow`, evidence enabled, and a rollout channel equal to the
distribution; any inconsistency fails closed.

### Development override (does not start the promotion clock)

For a developer build, the canonical process variable starts quota comparisons:

```powershell
$env:OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE = "shadow"
```

Developer authority has no evidence channel, so this cannot upload promotion
evidence. Persistent user or service environment variables do not override a
signed artifact.

### Spool location

Windows spools bounded schema-v2 JSONL batches under
`LocalApplicationData/OpenBurnBar/DomainCoreShadow`. The bounds match Apple:
8 ready files and 100 samples per file.

## Firebase Auth custom claims

The `submitDomainCoreShadowSamples` callable rejects absent or mismatched
Firebase Auth claims. Enroll the signed-in account with both:

```
domainCoreShadowChannel: "internal" | "beta"
domainCoreShadowConsumers: ["apple", "windows"]
```

Use `scripts/ops/manage-domain-core-shadow-enrollment.mjs` as documented in
[`shared-rust-build-profiles.md`](shared-rust-build-profiles.md); do not hand-edit
claims. The callable requires Firebase Auth and App Check. The request body
cannot self-assert enrollment, and Firestore rules deny direct client writes to
`domain_core_shadow_samples`.

## Verification (operator, post-startup)

After distributing verified `internal` or `beta` artifacts and enrolling the
account, verify telemetry is flowing within 24 hours:

1. **Check the local spool** on a device in the target channel:
   - Apple: `ls ~/Library/Application\ Support/OpenBurnBar/DomainCoreShadow/`
   - Windows: `dir %LOCALAPPDATA%\OpenBurnBar\DomainCoreShadow\`

   Ready files (`ready-*.jsonl`) or an `active.jsonl` with content confirm
   samples are being recorded.

2. **Check Firestore** (read-only, operator with Application Default
   Credentials). The repo's export script queries `domain_core_shadow_samples`
   via `firebase-admin` — use it with a narrow time window to confirm
   samples arrived without extracting full evidence:

   ```bash
   node scripts/ops/export-domain-core-promotion-evidence.mjs \
     --project burnbar \
     --start 2026-07-15T00:00:00Z \
     --end 2026-07-16T00:00:00Z \
     --channel internal \
     --core-version 0.3.0 \
     --source-uri https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples \
     --output /tmp/shadow-telemetry-quick-check.json
   ```

   The output JSON should show non-zero `sampleCount` for both `apple` and
   `windows` consumers. If either consumer has zero samples, telemetry is
   not flowing for that platform — check its artifact receipt, signed profile,
   Firebase Auth claims, and App Check status.

   Alternatively, use the Firebase console:
   https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples

3. **Verify the Firestore TTL policy** is active (required before beta
   evidence collection):

   ```bash
   gcloud firestore fields ttls update expireAt \
     --collection-group=domain_core_shadow_samples \
     --enable-ttl \
     --project=burnbar
   node scripts/ci/verify-firestore-ttl-state.mjs burnbar
   ```

   Note: `verify-firestore-ttl-state.mjs` takes the project ID as a
   positional argument (`process.argv[2]`), not via `--project`.

## Evidence export and promotion gate

Once the 14-day window has accrued samples, follow
[`shared-rust-promotion-evidence.md`](shared-rust-promotion-evidence.md) to
export and evaluate evidence. Do not hand-edit evidence or policy files.

## Policy floors (unchanged)

The promotion policy in `config/domain-core-promotion-policy.json` defines
the quantitative floors that must be met before any `rust` promotion:

| Floor | Value |
|---|---|
| Required consumers | `apple`, `windows` |
| Allowed channels | `internal`, `beta` |
| Minimum coverage | 1,209,600 seconds (14 days) |
| Minimum samples | 10,000 aggregate |
| Maximum p95 regression | 500 basis points (5%) |

These floors are not editable by a rollout job. The evaluator CLI has no
policy override. Never weaken a floor to fit evidence — if a floor is missed
at day 14, the fix is more soak time or more beta devices.

## Rollback

Signed consumers ignore process overrides. Roll back by stopping distribution
of the `internal`/`beta` artifact and deploying the reviewed
`public-production` profile through the normal signed release lane. Verify the
replacement artifact receipt before rollout. Public production is catalog-bound
to `legacy` with evidence disabled, so neither an operator environment variable
nor an installed-app launch script can re-enable shadow mode.

For unsigned development builds only, remove the canonical override or set:

```
OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=legacy
```

For development, this stops local shadow comparisons. Deploying the verified
public-production artifact stops signed comparison and spooling. The
user-visible quota result remains unchanged because legacy is authoritative in
shadow mode. Retain accumulated evidence; do not delete spool or Firestore data.