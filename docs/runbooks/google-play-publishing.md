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

The credentialed job downloads only the checksum-sealed AAB and manifest. It
does not check out repository code. It creates one edit, uploads the exact AAB,
updates the requested track, and commits the edit. Any failure before commit
attempts to delete the edit.

## Evidence and rollback

- Successful live runs retain `google-play-receipt-*` for 400 days. The receipt
  binds the provider edit, package, track, release status, tag, commit, version,
  AAB SHA-256, upload certificate, workflow run, and provider responses.
- Dry-runs retain `google-play-prepared-*` for 90 days.
- Google Play version codes are immutable. Rollback means publishing a new,
  higher-versionCode AAB that restores the desired behavior; never reuse or
  replace an existing version code.
- If a run fails before commit, inspect the workflow logs and confirm no edit was
  committed. Re-run validation before retrying a live publication.

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
