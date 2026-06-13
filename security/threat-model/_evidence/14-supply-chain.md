# 14 — Supply Chain / CI-CD / Build-Release Integrity (Phase 12; SLSA / NIST SSDF / OWASP SCVS)

Domain: supply-chain-cicd. Reviewer: senior product-sec. Date: 2026-06-13. Repo: BurnBar / OpenBurnBar.
Method: `rg` to locate symbols, `Read` of exact ranges, `git ls-files`/`git check-ignore` to confirm tracked binaries. Code is source of truth.

## Components & files reviewed
- `.github/workflows/deploy-production.yml` (Cloud Functions prod deploy)
- `.github/workflows/release.yml` (macOS app sign/notarize/Sparkle/SBOM/cosign/live-feed verify; 1280+ lines, read in ranges)
- `.github/workflows/supply-chain-provenance.yml` (SLSA/SBOM/VEX/cosign attest, ecosystem deny)
- `.github/workflows/build-iroh-android-aar.yml` (AAR rebuild + parity)
- `.github/workflows/iroh-xcframework.yml` (xcframework build)
- `.github/workflows/codeql.yml`, `codeql-pr.yml` (CodeQL languages)
- `.github/workflows/rust-sast.yml` (cargo-audit + clippy security)
- `.github/workflows/security-pr.yml` (gitleaks, dependency-review, npm audit, OSV-Scanner)
- `.github/workflows/confidentiality-guard.yml`, `droid-wiki-refresh.yml`, `fast-feedback.yml`
- `firebase.json` (predeploy hooks), `functions/package.json` (overrides, file: deps)
- `.gitleaks.toml`, `.pre-commit-config.yaml`, `.github/CODEOWNERS`
- `scripts/ci/check_burnbar_release_preflight.py`, `scripts/supply-chain/run-ecosystem-deny-checks.sh`
- `git ls-files '*Cargo.lock'`; `git check-ignore Vendor/OpenBurnBarIroh.xcframework`

## Controls present
- SHA-pinned actions (commit-pinned, near-universal) — `deploy-production.yml:37,72,207`, `release.yml:173,705`, `build-iroh-android-aar.yml:38,41,47,58` etc. — strong — virtually all `actions/*`, `sigstore/cosign-installer`, `dtolnay/rust-toolchain` pinned to 40-char SHA with version comment.
- Least-privilege top-level `permissions` (default `contents: read`) on 30/32 workflows — `deploy-production.yml:3-5`, `confidentiality-guard.yml:24-25`, `build-iroh-android-aar.yml:3-4` — strong.
- Prod deploy gated to `v*` tags only + `environment: production` — `deploy-production.yml:7-10,31`, `tag` step rejects non-`v*` `:56-59` — strong (no push-to-main / PR deploy path).
- Release gated to `push: tags: v*` + `workflow_dispatch` only — `release.yml:8-12` — strong.
- Fail-closed strict release-secret validation (signing/notary/Sparkle/Firebase all required) — `release.yml:139-170` — strong.
- macOS codesign + hardened runtime + notarize + staple — `release.yml:415-448` (codesign --options runtime), `:500-531` (notary + `xcrun stapler staple/validate`) — strong.
- Sparkle Ed25519 update signing via `sign_update --ed-key-file` — `release.yml:179-191,587-615` — strong.
- Post-publish fail-closed LIVE update-feed verify: fetches published feed, checks version, sha256==feed, length, and verifies DMG Ed25519 sig against `SUPublicEDKey` pinned in Info.plist — `release.yml:1167-1271` (`verify-live-update-feed`) — strong.
- cosign keyless SLSA attestations over SBOM/VEX/checksums/DMG/zip/source/appcast — `release.yml:704-737`, `supply-chain-provenance.yml:84-93` — moderate.
- SBOM (SPDX) + OpenVEX generation — `release.yml:677-702`, `generate-sbom.py`, `generate-vex.py` — moderate.
- GPG-signed release checksums — `release.yml:658-675` — moderate (gated on secret, see overclaim).
- Committed Android AAR rebuild-PARITY gate (`git diff --exit-code` of `Vendor/openburnbar-iroh.aar` + Kotlin bindings vs clean rebuild) — `build-iroh-android-aar.yml:110-119` — strong (catches tampered committed binary; AAR is tracked, confirmed `git ls-files`).
- Rust advisory scanning fail-closed (cargo-audit `--deny warnings`, RustSec DB fresh each run, weekly cron) over both shipping crates — `rust-sast.yml:42-98`; clippy FFI/memory lints `:100-131`.
- Secret scanning: gitleaks pinned `@v8.28.0` with PR-range + full-history fallback — `security-pr.yml:63-79`; pre-commit gitleaks `v8.27.2`, detect-secrets `v1.5.0`, detect-private-key, no-commit-to-branch — `.pre-commit-config.yaml:158-167,24,30`.
- GitHub Dependency Review (fail-on high) + license allowlist — `security-pr.yml:90-98`.
- OSV-Scanner over 8 npm package-locks — `security-pr.yml:199-209`.
- npm audit (high/critical) over PR-gated Node locks — `security-pr.yml:100-127`.
- CodeQL: swift, java-kotlin, javascript-typescript, python (matrix) — `codeql.yml:53-65`.
- Confidentiality Guard (internal-content scanner with self-test) — `confidentiality-guard.yml:45-49`.
- Fail-closed release preflight: source provenance + signed external-counsel legal approval — `check_burnbar_release_preflight.py:65-91`.
- Publishable-tree secret scan + privacy-manifest presence gates — `release.yml:121-122,739-755`.
- Post-deploy health gate + Sentry-required fail-closed — `deploy-production.yml:188-203`, `:152-155`.
- Droid wiki workflow refuses curl|pipe|sh installers, no write token — `droid-wiki-refresh.yml:24-25,34-37`.
- `git submodule update` resync to tag gitlink so provenance reads released libsignal commit — `deploy-production.yml:60-68`.

## Claims verified against code
- "All GitHub Actions are SHA-pinned" — **Partial** — most are (`deploy-production.yml:37,72,207`), but `fast-feedback.yml:478` `dtolnay/rust-toolchain@stable` (mutable tag); `codeql.yml:129,184` / `codeql-pr.yml:63,70` `github/codeql-action@v4`; `google-github-actions/auth@v2` (`deploy-production.yml:90,96`); `google/osv-scanner-action@v2.3.8` (`security-pr.yml:199`); `reactivecircus/android-emulator-runner@v2` (`openburnbar-pr-harness.yml:852`); `zaproxy/action-*@v0.x` (`nightly-e2e.yml:110,142`) — tag-pinned, mutable.
- "Committed iroh binaries are rebuild-verified" — **Partial** — TRUE for Android AAR (`build-iroh-android-aar.yml:110-119`, parity gate); the xcframework is gitignored/built-fresh (no committed binary to verify, `git check-ignore Vendor/OpenBurnBarIroh.xcframework`=IGNORED) so `iroh-xcframework.yml` has NO parity gate by design — acceptable, but no parity assurance if it ever became committed.
- "Release artifacts get SLSA provenance / cosign attestations" — **Defensible** — `release.yml:704-737`; cosign keyless. Note attestation is non-keyed Sigstore (transparency log), not a SLSA-L3 hermetic builder.
- "Bit-reproducible notarized builds" — **Defensible (honestly de-scoped)** — docs `SUPPLY_CHAIN_PROVENANCE.md:53-68` and `supply-chain-provenance.yml:113` explicitly state this is NOT targeted. No overclaim.
- "Prod cannot be deployed except from a signed v* tag" — **Defensible** — `deploy-production.yml:7-10,56-59`, `environment: production`.
- "Update feed is verified end-to-end before a release is trusted" — **Defensible** — `release.yml:1167-1271` fails the release if the live DMG's Ed25519 sig does not verify against the pinned key.
- "Ecosystem deny / dependency audit runs on the provenance lane" — **NotDefensible** — `supply-chain-provenance.yml:103-104` calls `run-ecosystem-deny-checks.sh` but never installs `cargo-deny` or `osv-scanner`; the script no-ops them (`command -v ... || skip`, `run-ecosystem-deny-checks.sh:10,16-18,25,32-33`). Only `npm audit` actually runs there.
- "All lockfiles are vuln-scanned" — **Partial** — OSV covers 8 npm locks (`security-pr.yml:199-209`); cargo-audit covers the 2 tracked Cargo.locks (`rust-sast.yml:50-55`; `git ls-files '*Cargo.lock'` = only `crates/burnbar-remote`, `crates/openburnbar-iroh`). No Cargo.lock is fed to OSV-Scanner; swiftpm/Android Gradle locks are not OSV-scanned.
- "CodeQL covers all shipping languages" — **Partial** — Rust NOT in CodeQL (CodeQL has no GA Rust analyzer; compensated by `rust-sast.yml`). Swift on push only, not PR (`codeql.yml:9-10`).
- "Single reviewer / CODEOWNERS provides separation of duties" — **NotDefensible** — `.github/CODEOWNERS` lists one owner `@Ajnunezg` for everything incl. `.github/workflows/` (line 18); no second-reviewer enforcement visible in-repo.

## Threats
- T-SC-01 — Mutable action tag enables CI compromise of release/build — Tampering/SSDF PW.4,PO.3 / SLSA build-L — High — `fast-feedback.yml:478` (`@stable`), `codeql.yml:129`, `security-pr.yml:199`, `nightly-e2e.yml:110,142` — Attack path: upstream action owner or tag-mover repoints `@stable`/`@v2`/`@v4`/`@v0.14.0` to malicious commit; runs in CI with repo token. Existing mitigation: most actions SHA-pinned; security workflows have read-only perms. Gap: these refs are tag/branch, not SHA. Residual: Medium (security/test lanes have read perms; Dependabot DOES cover github-actions but only surfaces tag drift, it does not SHA-pin).
- T-SC-02 — Provenance lane's ecosystem-deny silently no-ops — Tampering/Repudiation / SSDF PW.7,RV.1 / SCVS V2 — High — `supply-chain-provenance.yml:103-104`, `run-ecosystem-deny-checks.sh:10-18,25-34` — Attack path: a vulnerable/yanked Rust dep or unscanned npm lock ships; provenance "deny check" passes because `cargo-deny`/`osv-scanner` aren't installed on that runner so they skip. Existing mitigation: `rust-sast.yml` + `security-pr.yml` cover crates/locks on PR. Gap: provenance lane gives false assurance; cargo-deny `cargo deny check` (license/bans/sources) never actually runs in CI. Residual: Medium.
- T-SC-03 — Single CODEOWNER = SoD / insider single point of compromise — Elevation/Repudiation / SSDF PO.2,PW.7 — High — `.github/CODEOWNERS:4,18` — Attack path: compromise or coercion of `@Ajnunezg` (or a token) lets a malicious workflow/firestore.rules/release change merge with self-review; CODEOWNERS owns its own `.github/workflows/`. Existing mitigation: branch protection MAY require review (not in repo). Gap: no second reviewer; cannot verify required-reviews/required-checks from code. Residual: High until branch-protection/ruleset evidence supplied.
- T-SC-04 — Cargo.lock not OSV-scanned; swiftpm/Gradle locks unscanned — Tampering / SSDF RV.1 / SCVS V2 — Medium — `security-pr.yml:199-209` (npm only), `rust-sast.yml:50-55` (audit only) — Attack path: a malicious transitive crate version not yet in RustSec, or a vulnerable SwiftPM/Gradle dep, lands undetected by OSV. Existing mitigation: cargo-audit (RustSec) on 2 crates; dependency-review on PRs. Gap: no OSV/grype over Cargo.lock or Package.resolved; SwiftPM resolved-lock refresh exists but not vuln-scanned. Residual: Medium.
- T-SC-05 — xcframework has no rebuild-parity gate — Tampering / SSDF PW.4 / SLSA — Low — `iroh-xcframework.yml:63-79` — Attack path: if `Vendor/OpenBurnBarIroh.xcframework` ever became committed, a tampered binary would not be diff-checked (unlike the AAR). Existing mitigation: currently gitignored/built-fresh in release (`git check-ignore`=IGNORED). Gap: asymmetric control vs AAR; no guard if policy changes. Residual: Low.
- T-SC-06 — GPG checksum signing is best-effort, not enforced — Repudiation / SSDF PS.2 — Medium — `release.yml:658-664` (`if: env.RELEASE_SIGNING_KEY != ''`) — Attack path: if `RELEASE_SIGNING_KEY` secret is unset/cleared, the release still publishes with UNSIGNED checksums (no `.asc`); only Sparkle Ed25519 + notarization remain. Existing mitigation: strict-secret gate `:139-170` does NOT include `RELEASE_SIGNING_KEY`; live-feed Ed25519 verify still runs. Gap: GPG provenance is silently optional. Residual: Low-Medium (cosign + notarization + Sparkle remain).
- T-SC-07 — `firebase.json` predeploy runs arbitrary npm build at deploy — Tampering / SSDF PW.6 — Low — `firebase.json:5-7,30-32,309` (`npm --prefix ... run build`/`verify`) — Attack path: a malicious build/verify script or compromised devDependency executes inside the GCP-authenticated deploy job (after `google-github-actions/auth`). Existing mitigation: deploy from signed tag only; `npm ci` from committed lockfile; least-priv token. Gap: build runs with deploy credentials present in env. Residual: Low.
- T-SC-08 — Provenance SBOM regenerated from source, not from the published artifacts — Spoofing/Repudiation / SSDF PS.3,RV — Medium — `supply-chain-provenance.yml:59-69` ("PR-style fallback when artifacts missing"), attests `$SBOM` from `$GITHUB_WORKSPACE` — Attack path: the attested SBOM describes the re-checked-out source tree, not the bytes that were actually built/published in the triggering run; mismatch between attestation subject and shipped artifact. Existing mitigation: `release.yml` attests the actual DMG/zip (`:707-737`); download-artifact present `:48-54`. Gap: provenance lane attests a freshly-generated SBOM regardless of whether artifacts downloaded. Residual: Medium.
- T-SC-09 — `workflow_run` trigger executes in trusted context off an external workflow's success — Elevation / SSDF PO.3 — Low — `supply-chain-provenance.yml:11-14,23-25,48-54` — Attack path: `workflow_run` jobs get repo secrets + `id-token`/`attestations: write`; gated only on `conclusion==success && head_branch starts v`. Existing mitigation: it regenerates SBOM from source and does not execute downloaded artifacts; tag-prefix guard. Gap: branch/tag-prefix is forgeable on a fork-less push but acceptable given no artifact execution. Residual: Low.
- T-SC-10 — `droid exec --skip-permissions-unsafe` in CI — Elevation/Agentic-tool-abuse / SSDF PW.6 — Low — `droid-wiki-refresh.yml:34-37` — Attack path: an autonomous agent runs unattended with skipped tool-permission prompts on push-to-main. Existing mitigation: no write token on the job (no top-level `permissions`, default read), `continue-on-error`, refuses installers `:24-25`. Gap: workflow lacks explicit top-level `permissions:` block (relies on repo default). Residual: Low.

## Gaps / missing controls
- No explicit top-level `permissions:` on `computer-use-loopback-test.yml` and `droid-wiki-refresh.yml` (rely on repo default, not least-privilege-by-file).
- `cargo deny check` (license/bans/sources/advisories) never actually executes in CI — only cargo-audit (advisories) does; provenance lane's deny step is a silent no-op (T-SC-02).
- No OSV/grype coverage for Cargo.lock, SwiftPM `Package.resolved`, or Android Gradle dependency locks (T-SC-04).
- No in-repo evidence of branch protection / required reviews / required status checks / signed-commit enforcement; CODEOWNERS is single-owner (T-SC-03). UNKNOWN — needs GitHub ruleset/branch-protection export.
- CORRECTION (verified): `.github/dependabot.yml` IS present at `5416ef780` and covers `github-actions` (dir `/`) plus npm×7/gradle/cargo/swift×2. It surfaces weekly tag-bump PRs but does NOT convert mutable refs to SHA pins, so mutable action tags (T-SC-01) remain mutable between bumps.
- GPG checksum signing optional, not in strict-secret gate (T-SC-06).
- Provenance SBOM attests source, not the as-shipped artifact bytes (T-SC-08).

## Overclaims
- Workflow comments / banners imply comprehensive "Supply chain provenance" and "Ecosystem deny checks" (`supply-chain-provenance.yml:1-2,103`), but the deny step no-ops cargo-deny + osv-scanner on that runner (real coverage = npm audit only). The NAME overclaims relative to the CODE (T-SC-02).
- Comment "All GitHub Actions are SHA-pinned" posture is implied by pervasive pinning + version comments, but `@stable`/`@v2`/`@v4`/`@v0.x` exceptions remain (T-SC-01). Not a doc statement found, but the consistency suggests an intended invariant that is violated.
- `rust-sast.yml:6-9` says "cargo-deny already gates" advisories — but `cargo deny check` is not wired into any CI step that demonstrably installs cargo-deny and runs; only cargo-AUDIT runs. Mild overclaim about the gating mechanism.

## Crypto / protocol notes
- Sparkle update channel: Ed25519 (`SUPublicEDKey` pinned in `AgentLens/Resources/OpenBurnBar-Info.plist`, verified at `release.yml:1254-1268` via SPKI-wrapped raw 32-byte key + `crypto.verify(null, dmg, key, sig)`). Strong, fail-closed.
- cosign attestations are keyless (Fulcio/Rekor OIDC) — verifiable via transparency log but not a long-lived org key; consumers must trust Sigstore root + workflow identity. No SLSA-L3 hermetic/isolated builder (GitHub-hosted runners, network access).
- GPG (`release.yml:667-672`) detached-armor over checksums with imported key; passphrase empty; signing key from `RELEASE_SIGNING_KEY` secret. Optional path.

## Open questions / UNKNOWN
- Branch protection / repo rulesets: required reviewers, required status checks (CodeQL swift, Confidentiality Guard, security-pr lanes), signed-commit & linear-history, restrict-who-can-push-to-main? — NotInRepo. Resolve via `gh api repos/{o}/{r}/rulesets` + `branches/main/protection`.
- CORRECTION (verified): `.github/dependabot.yml` IS present (12 update streams: actions/npm×7/gradle/cargo/swift×2). Remaining question reduced to whether Dependabot PRs are merged promptly (process), not whether automation exists.
- Are GitHub Actions secrets (GCP_SA_KEY, APPLE_*, OPENBURNBAR_SPARKLE_PRIVATE_KEY_BASE64, RELEASE_SIGNING_KEY) scoped to the `production` environment with required reviewers/approval? `deploy-production.yml:31` uses `environment: production`; release jobs' environment binding not confirmed. Resolve via environment protection-rules export.
- Does the deployed GCP service account behind `GCP_SA_KEY` hold least-privilege Firebase-deploy roles only? Needs IAM export (cloud read-only).
- Are cargo-deny/osv-scanner intended to be installed on the provenance runner (T-SC-02 a regression vs intent)?
