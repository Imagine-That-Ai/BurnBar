# Release Rollback Procedures

This document covers how to roll back a bad OpenBurnBar release at any stage of the release pipeline.

## Release Pipeline Overview

```text
Developer                GitHub Actions                Users
────────                 ──────────────                ─────
git tag v0.2.0    ──►   release.yml runs       ──►   Download DMG
  │                       │                            │
  │                       ├─ Build + Test               │
  │                       ├─ Sign + Notarize            │
  │                       ├─ DMG + ZIP + Checksums      │
  │                       ├─ SBOM + Release metadata     │
  │                       └─ Publish prerelease           │
  │                                                      │
  └── Manual promotion ──────────────────────────────────┘
       (prerelease → latest)
```

## Rollback by Stage

### Stage 1: Before Tag Push (easiest)

The tag was created locally but not yet pushed.

```bash
# Delete the local tag
git tag -d v0.2.0

# Fix the issue, re-tag, then push
git tag -a v0.2.0 -m "OpenBurnBar 0.2.0"
git push origin v0.2.0
```

### Stage 2: Release Workflow Failed (no published assets)

The tag was pushed but the workflow failed before publishing.

```bash
# Fix the issue (commit + push to main)
git push origin main

# Re-run the workflow with the same tag
gh workflow run release.yml --field tag=v0.2.0
```

### Stage 3: Prerelease Published (DMG/ZIP available but not promoted)

The workflow completed and published to GitHub as a prerelease.

```bash
# Option A: Mark as draft (hides from users)
gh release edit v0.2.0 --draft

# Option B: Delete the release (destructive)
gh release delete v0.2.0 --yes
git push origin :refs/tags/v0.2.0  # Delete remote tag

# Fix, re-tag, re-push:
git tag -d v0.2.0          # Delete local tag
git tag -a v0.2.0 -m "OpenBurnBar 0.2.0"  # Create new tag
git push origin v0.2.0

# The release workflow will re-run automatically
```

### Stage 4: Homebrew Cask Published

The `update-homebrew.sh` script was run and the cask points to this release.

```bash
# 1. In the homebrew tap repo (Ajnunezg/homebrew-tap):
#    Revert the commit that updated the cask
cd path/to/homebrew-tap
git revert HEAD
git push

# 2. Users who already installed via brew will have the bad version.
#    Publish a hotfix:
git tag -a v0.2.1 -m "OpenBurnBar 0.2.1 (hotfix)"
git push origin v0.2.1
# After the release workflow completes:
scripts/update-homebrew.sh 0.2.1
```

### Stage 5: Promoted to Latest (worst case)

The release was promoted from prerelease to latest. Users can download it.

```bash
# 1. Immediately mark the release as draft
gh release edit v0.2.0 --draft

# 2. If users are actively downloading, publish a hotfix
#    Cherry-pick the fix onto a new branch from the tag
git checkout v0.2.0
git checkout -b hotfix/0.2.1
git cherry-pick <fix-commit>
git push origin hotfix/0.2.1

# 3. Tag the hotfix
scripts/tag-release.sh 0.2.1

# 4. After the hotfix release is published, mark it as latest
gh release edit v0.2.1 --latest

# 5. Update Homebrew
scripts/update-homebrew.sh 0.2.1
```

## Hotfix Tag Procedure

When a critical bug is found in a released version:

```bash
# 1. Create a hotfix branch from the release tag
git checkout v0.2.0
git checkout -b hotfix/0.2.1

# 2. Apply the fix
# ... make changes, commit ...

# 3. Update version in project.yml
# Change MARKETING_VERSION from 0.2.0 to 0.2.1

# 4. Add a changelog entry
# Add "## [0.2.1] - YYYY-MM-DD" section to CHANGELOG.md

# 5. Commit version bump
git add project.yml CHANGELOG.md
git commit -m "fix: bump version to 0.2.1 for hotfix"

# 6. Tag using the release script
scripts/tag-release.sh 0.2.1

# 7. Push the hotfix branch (for reference)
git push origin hotfix/0.2.1

# 8. After release workflow completes, verify and promote
gh release view v0.2.1
gh release edit v0.2.1 --latest
```

## Checksum Verification

After any release, verify the published artifacts match what was built:

```bash
# Download checksums from the release
gh release download v0.2.0 --pattern "checksums-v0.2.0.txt" --output /tmp/checksums.txt

# Verify DMG checksum
shasum -a 256 --check /tmp/checksums.txt --ignore-missing

# Verify GPG signature (if RELEASE_SIGNING_KEY was configured)
gpg --verify checksums-v0.2.0.txt.sig checksums-v0.2.0.txt
```

For local builds:

```bash
make release-checksums
# Outputs SHA256 and SHA512 checksums for verification
```

## Release Metadata

Every release includes a `release-metadata.json` containing:

```json
{
  "version": "0.2.0",
  "tag": "v0.2.0",
  "commit": "abc1234def567890...",
  "build_timestamp": "2026-04-22T15:30:00Z",
  "runner_os": "macos-15"
}
```

This artifact provides immutable provenance linking the release to its source commit.

## Decision Tree

```text
Bad release detected
│
├─ No users have downloaded yet?
│  ├─ Tag not pushed? → Delete local tag, fix, re-tag
│  └─ Tag pushed, workflow failed? → Fix, re-run workflow
│
├─ Prerelease published but not promoted?
│  ├─ Minor issue? → Publish a patch prerelease
│  └─ Major issue? → Mark as draft, re-tag
│
└─ Users may have downloaded?
   ├─ Prerelease only? → Mark draft, publish hotfix
   └─ Published latest? → Publish hotfix, promote to latest
```

## Rollback Drill

Run this drill quarterly to maintain confidence in the rollback procedure:

1. **Tag and push a test release** (use a `-test` suffix tag)
   ```bash
   git tag v0.0.0-rollback-drill
   git push origin v0.0.0-rollback-drill
   ```

2. **Verify the workflow triggered** on GitHub Actions

3. **Mark the release as draft**
   ```bash
   gh release edit v0.0.0-rollback-drill --draft
   ```

4. **Delete the release and tag**
   ```bash
   gh release delete v0.0.0-rollback-drill --yes
   git push origin :refs/tags/v0.0.0-rollback-drill
   git tag -d v0.0.0-rollback-drill
   ```

5. **Verify it's gone**: Check that `gh release view v0.0.0-rollback-drill` returns 404

## Local Build Verification

For manual verification before promoting a release:

```bash
# Build locally
make build

# Run the release smoke test
scripts/test-openburnbar-release-smoke.sh

# Check code signing
codesign -dvvv .derived-data/Build/Products/Release/OpenBurnBar.app

# Verify notarization (requires Apple Developer account)
spctl --assess --type execute -vv .derived-data/Build/Products/Release/OpenBurnBar.app
```
