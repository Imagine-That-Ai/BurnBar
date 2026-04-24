# macOS Release

OpenBurnBar's release pipeline is automated via `.github/workflows/release.yml`.
Pushing a `v*` tag builds, signs, notarizes, staples, and publishes a GitHub **prerelease** with DMG, ZIP, checksums, SBOM, and provenance metadata.

## How to cut a release

```bash
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
1. Run Swift, app, and TypeScript tests
2. Build `OpenBurnBar.app` unsigned
3. Embed daemon/helper artifacts and `OpenBurnBarCore.framework`
4. Sign app + DMG with Developer ID identity
5. Notarize + staple DMG using `notarytool` with App Store Connect API key
6. Compute SHA256/SHA512 checksums for DMG and ZIP
7. Sign checksums with GPG key (if `RELEASE_SIGNING_KEY` secret is configured)
8. Generate SPDX SBOM from SPM + npm dependencies
9. Write release metadata JSON with version, commit, and timestamp
10. Publish a GitHub prerelease with all assets

## Release artifacts

Each release includes:

| Asset | Purpose |
|-------|---------|
| `OpenBurnBar-VERSION-macOS.dmg` | Signed, notarized DMG installer |
| `OpenBurnBar-VERSION-macOS.zip` | Signed app archive |
| `checksums-vVERSION.txt` | SHA256/SHA512 checksums for DMG + ZIP |
| `checksums-vVERSION.txt.asc` | GPG detached signature (if configured) |
| `sbom-vVERSION.spdx.json` | Software Bill of Materials (SPDX format) |
| `release-metadata.json` | Build provenance: version, commit, timestamp, runner |

## Release provenance

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
This is intended for release recovery without creating a new tag.

## Rollback

See [RELEASE_ROLLBACK.md](RELEASE_ROLLBACK.md) for the full rollback decision tree and procedures, including hotfix tagging and Homebrew cask reversion.

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
| `RELEASE_SIGNING_KEY` | *(Optional)* Base64-encoded GPG private key for signing checksums |

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
