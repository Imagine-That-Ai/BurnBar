# Google Play Publishing

The `Publish Android to Google Play` workflow is the only supported automated
publisher for `com.openburnbar`. It consumes the signed AAB already published by
the protected release workflow; it never rebuilds or re-signs the application.

## First-time provider setup

1. In Play Console, add the service account represented by the existing
   `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` repository or `release` environment secret.
2. Grant only the app-level permissions needed to create releases for
   `com.openburnbar`. Do not grant account-administration or financial-data
   permissions.
3. Keep the GitHub `release` environment approval and branch/tag restrictions
   enabled. A live upload cannot run before that environment is approved.
4. Confirm `config/android-upload-certificate.sha256` is the SHA-256 fingerprint
   of the Play upload certificate. This is separate from a Play App Signing
   certificate.

## Validate without uploading

Before dispatching the workflow, confirm the release source compiles and targets
Android 16 (API level 36). The canonical compile/target policy lives in
`android/gradle.properties`; every Android module and the publication gate
consume those values. The publisher independently reads
`uses-sdk/@android:targetSdkVersion` from the signed AAB with bundletool and
fails before authentication if the value differs from the reviewed policy
(`36` for this release). This keeps the August 31, 2026 Google Play target API
requirement attached to the exact artifact rather than trusting the Gradle
source alone.

1. Open **Actions → Publish Android to Google Play → Run workflow**.
2. Select the `main` branch. The workflow fails closed if its own definition is
   not executing from protected `main`.
3. Enter an existing canonical release tag such as `v1.2.3`.
4. Leave `track=internal`, `release_status=draft`, and `dry_run=true`.
5. Run the workflow. No Google credential is read in this mode.
6. Retain the `google-play-prepared-*` artifact as the exact validation record.

The validation job proves that the tag resolves to a commit reachable from
`origin/main`, downloads the exact release AAB, verifies its GitHub attestation
against `.github/workflows/release.yml` and that exact tag/SHA, checks the JAR
signature against the approved upload certificate, validates the bundle with a
pinned bundletool, and verifies package name, version name, and version code.

## Publish

Repeat the validation inputs with `dry_run=false`. The protected `release`
environment must be approved before the service-account credential is exposed.
The safe default is the `internal` track with a `draft` release.

Alpha, beta, and production require `confirm_non_internal=true`. Prerelease tags
are restricted to `internal`. The workflow never promotes an existing release
between tracks; it explicitly updates only the requested track in a fresh
Android Publisher edit.

The credentialed job downloads only the checksum-sealed AAB, manifest, and
publisher. It does not check out repository code. Before mutating the requested
track, the publisher reads the existing bundles and track state. It refuses a
version-code rollback, refuses to replace an unrelated mutable release
(`draft`, `inProgress`, or `halted`), and verifies the SHA-256 before reusing an
existing bundle. If the exact completed release is already present, the run is
a verified no-op. Otherwise it uploads only when needed, commits one edit, then
opens a fresh edit and reads the track back to verify the exact version and
status. Any uncommitted publication or readback edit is deleted on exit.

## Evidence and rollback

- Successful live runs, including verified no-ops, retain
  `google-play-receipt-*` for 400 days. The receipt binds the action, provider
  edit when committed, package, track, requested and observed release status,
  tag, commit, version, verified/required target SDK, pinned bundletool version,
  AAB SHA-256, upload certificate, workflow run, track readback, and provider
  responses.
- Dry-runs retain `google-play-prepared-*` for 90 days.
- Google Play version codes are immutable. Rollback means publishing a new,
  higher-versionCode AAB that restores the desired behavior; never reuse or
  replace an existing version code.
- If a run fails before commit, inspect the workflow logs and confirm no edit was
  committed. Re-run validation before retrying a live publication. If the
  provider accepted the commit but the fresh readback fails, stop and inspect
  the Play Console state before retrying; the receipt is intentionally not
  emitted unless readback succeeds.

## Reusable invocation

A protected workflow may call:

```yaml
uses: Imagine-That-Ai/BurnBar/.github/workflows/publish-google-play.yml@main
with:
  tag: v1.2.3
  track: internal
  dry_run: true
  release_status: draft
secrets: inherit
```

Keep the reusable workflow pinned to protected `main`; the called workflow
independently verifies its `GITHUB_WORKFLOW_REF`.
