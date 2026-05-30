# Deployment

---

## Release channels

### macOS

Two separate binaries ship from the same source:

| Channel | Build flag | Sandbox | Features |
|---------|-----------|---------|---------|
| Mac App Store | `DISTRIBUTION_MAS=1` | Yes | No Phase 11 Computer Use, no bare LaunchAgent install |
| Developer ID DMG (GitHub Releases / R2) | unset | No | Full daemon, Computer Use Phase 11 |

Architecture: Apple Silicon (`arm64`) only — the vendored iroh XCFramework does not include a release-ready Intel slice.

Build scripts:
```bash
scripts/build-macos-app-store-release.sh   # sandboxed archive/export for App Store Connect
scripts/build-macos-website-release.sh      # Developer ID: sign, notarize, staple, checksum, DMG+ZIP+SBOM
scripts/verify-macos-app-store-readiness.sh # MAS compile gate (DISTRIBUTION_MAS=1)
```

Upload to Cloudflare R2 (direct download hosting):
```bash
scripts/setup-macos-downloads-r2.sh    # create bucket + public URL
scripts/upload-macos-downloads-r2.sh   # upload DMG, ZIP, checksums, SBOM, release metadata
```

Release runbook: [`docs/RELEASE_MACOS.md`](../docs/RELEASE_MACOS.md)

### iOS

- Distribution: App Store via App Store Connect
- Bundle ID: `com.openburnbar.app`, Apple app ID: `6766366964`
- Build upload: `scripts/build-ios-app-store-release.sh` (archive + export)
- CI injection: `scripts/ci/inject-firebase-config.sh` reads `FIREBASE_PLIST_BASE64` GitHub secret
- Release runbook: [`docs/IOS_APP_STORE_RELEASE_RUNBOOK.md`](../docs/IOS_APP_STORE_RELEASE_RUNBOOK.md)

### Android

- Distribution: Google Play closed testing → production
- Build: `cd android && ./gradlew assembleRelease`
- CI injection: `scripts/ci/inject-firebase-config-android.sh` reads `GOOGLE_SERVICES_JSON_BASE64` GitHub secret
- Template (safe to commit): `android/app/google-services.json.template`

### Firebase Functions

```bash
firebase deploy --only functions
```

Functions source: `functions/src/` (89 TypeScript files, 49 callable endpoints).

---

## CI/CD

GitHub Actions workflows in `.github/workflows/`:

| Workflow | Purpose |
|----------|---------|
| `release.yml` | Full release pipeline (sign, notarize, staple, publish GitHub prerelease) |
| `openburnbar-pr-harness.yml` | PR-level build and test gate |
| `qa.yml` | QA test suite |
| `nightly-e2e.yml` | Nightly end-to-end tests |
| `codeql.yml` | Daily CodeQL security scan |
| `computer-use-loopback-test.yml` | Computer Use loopback smoke test |
| `build-iroh-android-aar.yml` | Build `Vendor/openburnbar-iroh.aar` from Rust crate |
| `iroh-xcframework.yml` | Build `Vendor/OpenBurnBarIroh.xcframework` |
| `droid-wiki-refresh.yml` | Regenerate this wiki on push to main |
| `openburnbar-app-swiftpm-lock-refresh.yml` | Refresh Swift Package lock |
| `workflow-lint.yml` | Lint GitHub Actions YAML |
| `website-ci.yml` | Website build check |

---

## Environment secrets

| Secret | Used by |
|--------|---------|
| `FIREBASE_PLIST_BASE64` | iOS CI: inject `GoogleService-Info.plist` |
| `GOOGLE_SERVICES_JSON_BASE64` | Android CI: inject `google-services.json` |
| `APP_STORE_ASC_KEY_ID` | iOS App Store Connect upload |
| `APP_STORE_ASC_ISSUER_ID` | iOS App Store Connect upload |
| `APP_STORE_ASC_KEY_P8` | iOS App Store Connect upload |

All Firebase secrets are also available via `firebase functions:secrets:access` for local operator runs.

---

## Artifact checksums

```bash
make release-checksums   # computes SHA256 + SHA512 for built artifacts
```

The `build-macos-website-release.sh` script emits a checksums file alongside the DMG and ZIP. SPDX SBOM is generated per release via `make sbom`.

---

## Local CI parity

```bash
make ci    # Functions, evals, Firestore rules, supply chain, all test surfaces
```
