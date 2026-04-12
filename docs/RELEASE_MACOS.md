# macOS Release

OpenBurnBar's release pipeline is automated via `.github/workflows/release.yml`. Pushing a `v*` tag triggers a build that produces an `OpenBurnBar` DMG and ZIP, attaches them to a draft GitHub Release, and signs + notarizes when Apple Developer secrets are configured.

## How to cut a release

```bash
git tag v0.1.0-beta
git push origin v0.1.0-beta
```

The workflow will:
1. Run all tests (Swift, app, TypeScript)
2. Build `OpenBurnBar.app` via `xcodebuild`
3. Package a DMG (with drag-to-Applications symlink) and ZIP
4. Sign and notarize if secrets are present (see below)
5. Create a draft GitHub Release with artifacts attached

Review the draft release on GitHub, edit notes if needed, then publish.

## CI secrets for signing & notarization

Without these secrets, the workflow still produces **unsigned** DMG/ZIP artifacts. Users will need to right-click → Open to bypass Gatekeeper. The workflow now fails fast if the signing or notarization secrets are only partially configured.

To enable full notarized distribution, add these GitHub Actions secrets:

| Secret | Description |
|--------|-------------|
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID |
| `APPLE_SIGNING_IDENTITY` | Code signing identity, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` export of your Developer ID certificate + private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_NOTARIZATION_APPLE_ID` | Apple ID email for `notarytool` |
| `APPLE_NOTARIZATION_PASSWORD` | App-specific password (generate at appleid.apple.com → Sign-In and Security → App-Specific Passwords) |

### Generating the certificate secret

```bash
# Export from Keychain Access → My Certificates → "Developer ID Application: ..."
# Choose .p12 format, set a password

# Base64 encode it for GitHub:
base64 -i Certificates.p12 | pbcopy
# Paste into APPLE_CERTIFICATE_P12 secret
```

## Homebrew Cask

A Cask formula is at `homebrew/burnbar.rb`. To publish:

1. Create a repo: `Ajnunezg/homebrew-tap`
2. Copy `homebrew/burnbar.rb` → `Casks/openburnbar.rb`
3. Update the `version` and `sha256` to match the latest release DMG
4. Users install with: `brew install --cask Ajnunezg/tap/openburnbar`

Consider automating the Cask update as a step in `release.yml` once the tap repo exists.

## Build from source (no signing)

For users who don't need Gatekeeper approval:

```bash
make install   # builds Release .app → /Applications
open -a OpenBurnBar
```

## Smoke tests after install

1. Launch from `/Applications` after drag-install or `make install`
2. Confirm OpenBurnBar appears in the menu bar
3. Open Settings → Chat Backends and verify gateway URLs/tokens if using Hermes/OpenClaw
4. Check the daemon resolves from `Contents/Helpers/OpenBurnBarDaemon`

## References

- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Packaging for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Bundle layout](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
