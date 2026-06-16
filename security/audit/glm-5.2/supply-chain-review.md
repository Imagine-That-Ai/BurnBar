# Supply Chain and Secure SDLC Review

## K.1 Dependency Management

### npm (Cloud Functions)
- **Lockfile:** `package-lock.json` v3 with 1087 `integrity` entries (subresource integrity on every resolved package)
- **Pins:** Exact versions for runtime deps; 2 caret ranges but lockfile pins exact resolved versions
- **Overrides:** Transitive deps pinned (`@tootallnate/once`, `fast-xml-builder`, `uuid`)
- **No install scripts:** Zero transitive packages declare `install`/`postinstall`/`preinstall`. Only project's own postinstall (`sync-local-packages.mjs`) which is benign
- **Scoped packages:** `@openburnbar/*` use `file:vendor/...` — no dependency confusion risk

### SPM / Cargo / Gradle
- SPM: `Package.resolved` for Swift dependencies
- Cargo: `Cargo.lock` for Rust (iroh crate)
- Gradle: Version catalogs for Android

### CI Dependency Auditing (4 layers)
1. `npm audit --audit-level=high` over 8 lockfiles (`security-pr.yml`)
2. GitHub Dependency Review Action (`fail-on-severity: high` + license allowlist)
3. OSV-Scanner over 8 lockfiles (`security-pr.yml`)
4. `check-known-vulnerability-floors.mjs` (custom floor check)
5. Rust: `cargo-audit --deny warnings` + `cargo-deny` (weekly + PR)

## K.2 CI/CD Security

### GitHub Actions Pinning
- **All external `uses:` pinned to 40-char commit SHAs** (verified by `verify-github-action-pins.mjs` CI gate)
- **No floating tags, branches, or `latest` refs** (grep confirmed zero matches)
- **No `pull_request_target`** (zero matches — eliminates classic privilege escalation)
- **Self-hosted runners denied** (`verify-release-attestations.sh:55` uses `--deny-self-hosted-runners`)

### Permissions
- **37/39 workflows** declare explicit `permissions:` blocks with least-privilege scopes
- **2 workflows lack explicit permissions** (FINDING-016): `computer-use-loopback-test.yml`, `droid-wiki-refresh.yml`
- **Secrets:** Passed via `env:` mapping, never inline in `run:` templates. Release validates 9 required secrets before proceeding. Cleanup guaranteed with `if: always()`.
- **Firebase config injection:** Validates non-placeholder keys, rejects `YOUR_*`/`REPLACE_*`, writes with `umask 077`

### Code Signing / Notarization
- **macOS:** Developer ID certificate -> codesign (`--options runtime --timestamp --deep --strict`) -> verify (`codesign --verify --deep --strict`) -> `spctl --assess` -> notarize (`notarytool submit --wait`) -> staple -> DMG sign + notarize
- **Sparkle:** Ed25519-signed update feed; `SUPublicEDKey` pinned in Info.plist
- **Android:** Release keystore injection + `bundleRelease`
- **Live feed verification gate** (`release.yml:1230-1294`): Post-publish, fetches update feed exactly as in-app updater does, verifies version match + sha256 + Ed25519 signature using `crypto.verify`

### SBOM / SLSA / Attestations
- **SBOM:** `generate-sbom.py` produces SPDX 2.3 JSON covering SPM, npm, Cargo, Gradle
- **SLSA:** `cosign attest` over SBOM, VEX, checksums, DMG, ZIP, source archive
- **OpenVEX:** `generate-vex.py` sidecar
- **Attestation verification:** `verify-release-attestations.sh` uses `gh attestation verify` pinned to signer workflow
- **Ecosystem deny:** `run-ecosystem-deny-checks.sh` runs cargo-deny, npm audit, OSV-Scanner

### Release Integrity
- **SemVer tag validation:** Strict regex `^v[0-9]{1,3}\.[0-9]+\.[0-9]+...`
- **Prerelease safety:** Prerelease tags NEVER promoted to `latest`
- **Pre-release scanning:** gitleaks + trufflehog `--only-verified` + confidentiality guard
- **Vendored agent provenance:** Pinned Hermes agent commit + `verify-vendored-agent-source.sh`
- **Corresponding source:** AGPL archive + sha256 sidecar + libsignal fork delta verification
- **Multi-algo checksums:** SHA-256 + SHA-512 for all release assets
- **Optional GPG:** Detached signature of checksums
- **Smoke test:** Mount DMG, launch app, verify daemon socket, authenticated `daemon.health` RPC

### CODEOWNERS
- `@Ajnunezg` owns all paths (solo operator model, documented in `docs/SOLO_OPERATOR_POLICY.md`)
- Branch protection on main is documented and verifier exists but is operator-only to enable (FINDING-017)

## K.3 Secret Scanning (Triple Layer)
1. **gitleaks** (`.gitleaks.toml`) — pre-commit + CI + release
2. **detect-secrets** (`.secrets.baseline`) — pre-commit
3. **trufflehog** (`--only-verified`) — release-time
4. **detect-private-key** — pre-commit hook
5. **scan-internal-content.mjs** — blocks internal-only content (pricing/COGS/GTM) from public tree
6. **check-no-committed-evidence.sh** — blocks security evidence artifacts

## K.4 Supply Chain Threat Model

| Threat | Likelihood | Impact | Existing Control | Gap |
|--------|-----------|--------|-----------------|-----|
| Malicious dependency | Low | High | npm audit + OSV + cargo-audit + lockfile integrity | None |
| Compromised maintainer | Low | High | Lockfile pins exact versions; manual review for updates | None |
| Dependency confusion | Very Low | High | `file:` protocol for scoped packages | None |
| Compromised CI runner | Low | Critical | SHA-pinned Actions, self-hosted denied, WIF (no long-lived keys) | None |
| Leaked CI secret | Low | High | Secret cleanup `if: always()`, temp keychain, masking | None |
| Malicious PR | Medium | Medium | `pull_request` (not `pull_request_target`), least-privilege perms | None |
| Artifact tampering | Low | Critical | Cosign attestations, GPG signatures, live feed verification | None |
| Release key compromise | Low | Critical | Key is GitHub Actions environment secret; WIF for deploy | None |
