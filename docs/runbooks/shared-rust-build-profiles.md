# Shared Rust build profiles

The reviewed catalog at [`config/domain-core-build-profiles.json`](../../config/domain-core-build-profiles.json)
is the authority for shared Rust rollout settings. Signed release artifacts embed
one exact catalog profile. Runtime environment variables are development/test
overrides only; signed consumers ignore them and fail closed to `legacy` with
evidence disabled when embedded metadata is incomplete or inconsistent.
Only a missing or explicit `development` authority enables development overrides;
unknown, misspelled, or unexpanded authority markers fail closed.

| Profile | Distribution | Evidence channel | Required behavior |
| --- | --- | --- | --- |
| `developer` | local development and tests | none | Legacy by default; validated overrides allowed; uploads disabled |
| `public-production` | public signed artifacts | none | Evidence disabled; shadow forbidden |
| `internal` | signed internal artifacts | `internal` | Evidence enabled; quota shadow required |
| `beta` | signed beta artifacts | `beta` | Evidence enabled; quota shadow required |

Resolve values instead of hand-copying them:

```bash
node scripts/ci/resolve-domain-core-build-profile.mjs --profile internal --format github-env
```

Apple embeds the profile in `Info.plist`, Android embeds
`domain-core-build-profile.json` in AAB assets, Windows writes the same receipt
beside the published app, and Console publishes it at
`/domain-core-build-profile.json`. Release lanes verify the built receipt.

## Account enrollment

Evidence uploads require server-issued `domainCoreShadowChannel` and
`domainCoreShadowConsumers` Firebase claims. The command is dry-run by default
and preserves unrelated claims:

```bash
node scripts/ops/manage-domain-core-shadow-enrollment.mjs \
  --project burnbar --uid USER_UID --channel internal --consumers apple,windows

node scripts/ops/manage-domain-core-shadow-enrollment.mjs \
  --project burnbar --uid USER_UID --channel internal --consumers apple,windows --apply

node scripts/ops/manage-domain-core-shadow-enrollment.mjs \
  --project burnbar --uid USER_UID --channel internal --consumers apple,windows --verify
```

The user must refresh their Firebase ID token after a claim change. Clear only
these enrollment claims with:

```bash
node scripts/ops/manage-domain-core-shadow-enrollment.mjs \
  --project burnbar --uid USER_UID --clear --apply
```

The callable verifies both claims against every sample. A matching client build
profile alone never grants upload permission.

Durable client evidence is bound to the artifact's validated channel. Public or
otherwise disabled profiles discard queued evidence, and an internal/beta channel
transition drops samples from the previous channel instead of uploading or
retrying them under the new profile.

## Artifact verification

```bash
node scripts/ci/verify-domain-core-build-profile-artifact.mjs \
  --profile public-production --apple-app /path/to/OpenBurnBar.app
node scripts/ci/verify-domain-core-build-profile-artifact.mjs \
  --profile public-production --android-aab /path/to/app-release.aab
node scripts/ci/verify-domain-core-build-profile-artifact.mjs \
  --profile public-production --windows-dir /path/to/publish/win-x64
```

Windows production App Check/attestation verification remains a separate
mandatory gate. Profile and enrollment success do not replace that proof.
