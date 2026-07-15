# Shared Rust Shadow Mode Startup

This runbook gives the exact operator commands and configuration inputs to
start quota shadow mode on the two policy-required consumers (Apple and
Windows). Shadow mode is the first phase of the promotion evidence pipeline
documented in [`shared-rust-promotion-evidence.md`](shared-rust-promotion-evidence.md).

**No committed config file activates shadow mode.** Both consumers read
environment variables at runtime. Setting them in the signed build environment
starts the 14-day evidence clock required by
[`config/domain-core-promotion-policy.json`](../../config/domain-core-promotion-policy.json).

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

### Mode

The Swift quota adapter resolves the mode from the process environment:

```swift
// ClaudeQuotaDomainCoreAdapter.swift
static func resolve(environment: [String: String]) -> Self {
    guard let raw = environment["OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE"]?.lowercased() else {
        return .legacy
    }
    return Self(rawValue: raw) ?? .legacy
}
```

`ProviderQuotaService` defaults `environment` to
`ProcessInfo.processInfo.environment`.

**To start shadow mode, set in the signed build environment:**

```
OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=shadow
```

For an Xcode signed build, set this as a preprocessor define or user-defined
build setting that propagates to `ProcessInfo.processInfo.environment`. For
CI/export, pass it via `xcodebuild -configuration … OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=shadow`
or set it in the scheme's run-time arguments environment.

### Channel (telemetry enablement)

The Apple telemetry recorder resolves the channel from the environment, with an
Info.plist fallback:

```swift
// DomainCoreShadowEvidenceSpool.swift — MacDomainCoreShadowEvidenceRecorder.init
let configured = environment["OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL"]
    ?? Bundle.main.object(forInfoDictionaryKey: "OpenBurnBarDomainCoreRolloutChannel") as? String
self.channel = configured == "internal" || configured == "beta" ? configured : nil
```

**To enable telemetry spooling, set one of:**

- Environment variable: `OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL=internal`
  (or `beta`)
- Info.plist key: `OpenBurnBarDomainCoreRolloutChannel` = `internal` (or `beta`)

An absent, unknown, or `production` value disables collection — no samples are
spooled or uploaded.

### Spool location

Apple spools bounded JSONL batches under
`Application Support/OpenBurnBar/DomainCoreShadow` (per-user, 0o700 directory,
0o600 active file). At most 8 ready files with at most 100 samples per file.

## Windows

### Mode

The C# quota bridge resolves the mode from the process environment:

```csharp
// DomainCoreQuotaBridge.cs
var mode = requestedMode ?? ClaudeStatuslineQuotaDomainCore.ResolveMode(
    Environment.GetEnvironmentVariable("OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE"));
```

```csharp
// ClaudeStatuslineQuotaDomainCore.cs
internal static DomainCoreQuotaMigrationMode ResolveMode(string? raw)
{
    return raw?.Trim().ToLowerInvariant() switch
    {
        "shadow" => DomainCoreQuotaMigrationMode.Shadow,
        "rust" => DomainCoreQuotaMigrationMode.Rust,
        _ => DomainCoreQuotaMigrationMode.Legacy,
    };
}
```

**To start shadow mode, set in the signed build environment:**

```
OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=shadow
```

For an MSBuild signed build, set this as a system/user environment variable
before launching the app, or inject it via the build's environment block.

### Channel (telemetry enablement)

The Windows telemetry recorder reads the channel from the environment:

```csharp
// DomainCoreQuotaShadowEvidence.cs — PersistComparison
string? channel = Environment.GetEnvironmentVariable(
    "OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL")?.Trim().ToLowerInvariant();
if (channel is not ("internal" or "beta") || …)
{
    return; // no sample persisted
}
```

**To enable telemetry spooling, set:**

```
OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL=internal
```

(or `beta`). An absent, unknown, or `production` value disables collection.

### Spool location

Windows spools bounded JSONL batches under
`LocalApplicationData/OpenBurnBar/DomainCoreShadow`. Same bounds as Apple
(8 ready files, 100 samples per file).

## Firebase Auth custom claim

The `submitDomainCoreShadowSamples` callable rejects absent or mismatched
Firebase Auth custom claims. Enroll the signed-in account with:

```
domainCoreShadowChannel: "internal" | "beta"
```

The callable requires Firebase Auth and App Check. The request body cannot
self-assert enrollment. Firestore rules deny direct client access to
`domain_core_shadow_samples`; the callable is the only write path.

## Verification (operator, post-startup)

After setting both env vars and enrolling the account, verify telemetry is
flowing within 24 hours:

1. **Check the local spool** on a device in the target channel:
   - Apple: `ls ~/Library/Application\ Support/OpenBurnBar/DomainCoreShadow/`
   - Windows: `dir %LOCALAPPDATA%\OpenBurnBar\DomainCoreShadow\`

   Ready files (`ready-*.jsonl`) or an `active.jsonl` with content confirm
   samples are being recorded.

2. **Check Firestore** (read-only, operator with `gcloud` access):
   ```bash
   gcloud firestore documents list \
     --collection-group=domain_core_shadow_samples \
     --limit=10 \
     --project=burnbar
   ```
   Documents should appear with `consumer=apple` and `consumer=windows`,
   `channel=internal|beta`, and recent `observedAt` timestamps.

3. **Verify the Firestore TTL policy** is active (required before beta
   evidence collection):
   ```bash
   gcloud firestore fields ttls update expireAt \
     --collection-group=domain_core_shadow_samples \
     --enable-ttl \
     --project=burnbar
   node scripts/ci/verify-firestore-ttl-state.mjs --project burnbar
   ```

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

To roll back from shadow to legacy, unset or change the mode env var:

```
OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=legacy
```

This stops shadow comparisons and telemetry spooling immediately. The
user-visible quota result is unchanged (legacy was always authoritative in
shadow mode). Retain accumulated evidence; do not delete the spool or
Firestore documents.