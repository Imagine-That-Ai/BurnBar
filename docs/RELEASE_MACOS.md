# macOS Release

OpenBurnBar's release pipeline is automated via `.github/workflows/release.yml`.
Pushing a `v*` tag builds, signs, notarizes, staples, and publishes a GitHub **prerelease** with DMG and ZIP artifacts.

## How to cut a release

```bash
git tag v0.1.0-beta
git push origin v0.1.0-beta
```

The workflow will:
1. Run Swift, app, and TypeScript tests
2. Build `OpenBurnBar.app` unsigned
3. Embed daemon/helper artifacts and `OpenBurnBarCore.framework`
4. Sign app + DMG with Developer ID identity
5. Notarize + staple DMG using `notarytool` with App Store Connect API key
6. Publish a GitHub prerelease with DMG and ZIP assets

## Manual rerun path

Use `workflow_dispatch` on `.github/workflows/release.yml` and provide an existing `v*` tag.
This is intended for release recovery without creating a new tag.

## Required GitHub Actions secrets (strict mode)

Tagged releases are **fail-hard**: if any required secret below is missing, the workflow fails and no fallback unsigned release is produced.

| Secret | Description |
|--------|-------------|
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `APPLE_SIGNING_IDENTITY` | Developer ID identity, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` (Developer ID cert + private key) |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting `.p12` |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID (required for team keys, optional for individual keys) |
| `APPLE_NOTARY_API_KEY_P8` | Base64-encoded contents of `AuthKey_<KEYID>.p8` |
| `FIREBASE_PLIST_BASE64` | Base64-encoded Firebase plist for CI |
| `FIREBASE_APP_CHECK_DEBUG_TOKEN` | Firebase App Check debug token for CI |

### Generating secret payloads

```bash
# Developer ID certificate export (from Keychain Access -> My Certificates)
# Export as .p12, then encode:
base64 -i Certificates.p12 | pbcopy

# App Store Connect key file (AuthKey_<KEYID>.p8), then encode:
base64 -i AuthKey_ABC123XYZ.p8 | pbcopy
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
