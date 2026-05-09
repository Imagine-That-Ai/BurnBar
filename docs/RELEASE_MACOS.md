# macOS Release

OpenBurnBar's release pipeline is automated via `.github/workflows/release.yml`.
Pushing a `v*` tag builds, signs, notarizes, staples, and publishes a GitHub **prerelease** with DMG, ZIP, checksums, SBOM, and provenance metadata.

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
3. Run Swift, app, and TypeScript tests
4. Build `OpenBurnBar.app` unsigned
5. Embed daemon/helper artifacts and `OpenBurnBarCore.framework`
6. Sign app + DMG with Developer ID identity
7. Notarize + staple DMG using `notarytool` with App Store Connect API key
8. Compute SHA256/SHA512 checksums for DMG and ZIP
9. Sign checksums with GPG key (if `RELEASE_SIGNING_KEY` secret is configured)
10. Generate SPDX SBOM from SPM + npm dependencies
11. Write release metadata JSON with version, commit, timestamp, and runner metadata
12. Upload the DMG, ZIP, checksums, optional checksum signature, SBOM, and metadata as Actions artifacts
13. Run release smoke from the uploaded DMG artifact, including app launch and authenticated daemon health
14. Publish a GitHub prerelease with the same downloaded artifacts

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
The workflow checks out that exact tag before building. This is intended for release recovery without creating a new tag.

## Release environment and tag protection

The `build-and-release` job is bound to the GitHub environment named `release`.
That environment should require a human reviewer and restrict deployments to `v*`
release tags. Apple Developer ID, notary, Firebase, and optional checksum-signing
secrets should live as environment secrets when possible; repository secrets are
still accepted by GitHub Actions, but the environment approval gate is the
release-time control that prevents an accidental tag push from immediately using
Apple signing material.

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

The release workflow signs with `AgentLens/Resources/OpenBurnBarRelease.entitlements`. That file intentionally omits provisioning-profile-only capabilities such as iCloud, Apple Sign-In, and keychain access groups unless a matching Developer ID provisioning profile is embedded before signing. The development entitlements in `AgentLens/Resources/OpenBurnBar.entitlements` remain broader for local/Xcode builds.

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
