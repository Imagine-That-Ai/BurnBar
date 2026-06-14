> **CONFIDENTIAL — BurnBar security package.** Remediation record for the threat-model findings, on branch `remediation/tech-debt-fable-2026-06-12`. Share with Cure53 out-of-band; do not publish.

# Remediation Report

This records the disposition of all **106 findings** in [`threat-register.csv`](threat-register.csv) after remediation. The work was layered **additively** on two prior in-tree remediation waves (a committed pass + an uncommitted "wave-2"); nothing prior was reverted. **Not committed** — staged in the working tree for review (commit only on request).

## 1. Headline

- **2 Critical → both closed.** `T-TRN-01` (cloud-MITM of the iroh control channel) and `T-TOOL-02` (YOLO injection→RCE).
- **~75 findings code-fixed**; of those, **everything compilable in this environment was test-verified** (4,000+ tests across Swift core, daemon, TS, Rust, rules; see scorecard below). The original pass treated some iOS-app/AgentLens fixes as build-gated; the follow-up pass below adds focused local `xcodebuild test` proof for the security slices touched here.
- **13 findings were over-stated** (`AlreadyOK` — the code was already correct on re-inspection); they needed no change.
- **Residuals that are not pure code** (Apple-portal entitlement toggles, deployed IAM/console state, product/crypto decisions, and one architectural limit) are enumerated in §4 and dispositioned in [`operator-and-decisions.md`](operator-and-decisions.md). None is a silently-skipped item.

### Follow-up implementation verification

This worktree now has an additional focused remediation pass over the prior report:

- `T-TOOL-02`: `AgentDistributionGate.allowsDangerousAutonomyFlag` now requires a fresh local-auth proof in every build, including debug/developer builds. The per-N unrestricted-shell reauth cadence now distinguishes "no proof yet" from "proof recorded, zero actions consumed," so the first action is gated and a successful proof opens a bounded action window.
- Mobile target wiring: the Xcode mobile app target now includes the security-control sources used by existing code and tests: `IrohPairingAdmissionStore.swift`, `MercuryManifestMAC.swift`, `HermesGatewayVersionFloorStore.swift`, and `HermesTransportFallbackGuard.swift`.
- Pairing/version compile fixes: `FirestoreIrohPairingPublicKeyProvider` now expresses host-key pin decisions as explicit admitted/refused states; `HermesGatewayVersionFloorStore` parses persisted floor values into integers and treats non-integer persisted state as unreadable/fail-closed.
- Focused Xcode slices are no longer merely parse-gated: the AgentLens/macOS security slice and the OpenBurnBarMobile security/privacy slice both compile and pass locally. Full app-suite CI and deployed-state proof are still required before release claims.

## 2. Verification scorecard (run in this environment)

| Area | Command | Result |
|---|---|---|
| OpenBurnBarCore (Swift) | `swift test` | **1577 tests, 0 failures** |
| OpenBurnBarDaemon (Swift) | `swift test` | **648 tests, 0 failures** |
| Android (Kotlin) | `./gradlew :app:compileDebugKotlin --offline` | **BUILD SUCCESSFUL** |
| functions (TypeScript) | targeted `npm run test:*` + `vitest run` | **574 vitest passed, 0 failed** (+ node subsets) |
| crates/openburnbar-iroh (Rust) | `cargo build && cargo test && cargo clippy -D warnings` | **clean; 19 tests (10 new)** |
| firestore.rules | `firebase emulators:exec … rr12-relay-and-root` | **19/19 (7 new)** |
| .github CI | `actionlint` + `verify-supply-chain-hardening.sh` | **0 findings; 56/56 assertions** |
| OpenBurnBarMobile + AgentLens | focused `xcodebuild test` slices | **macOS security slice passed; mobile security/privacy slice passed** |

> Pre-existing, not introduced: `firestore-rules-tests/session-log-backup.test.js` fails 3/6 with "max 1000 expressions" on **HEAD baseline too** (rule-complexity limit, unrelated to these findings).

## 3. Disposition by domain

| Domain | Code-fixed (verified / build-gated) | AlreadyOK | Residual (portal/decision/arch) |
|---|---|---|---|
| Crypto-relay (T-CRY) | T-CRY-01 (version floor, BG), T-CRY-02 (Pi-agent sender-auth+replay, BG), T-CRY-03 (replay anchor, ✅core) | T-CRY-04 | T-CRY-05 (KCI — accepted non-goal) |
| CloudVault/Signal (T-CVS) | T-CVS-01/02 (✅kotlin), T-CVS-04 (KDF≥600k+import-floor, BG), T-CVS-06 (v1-AAD cutover, ✅core) | — | T-CVS-03 (libsignal non-extractable redesign — partial+decision), T-CVS-05 (epoching — decision) |
| Pairing/trust/revocation (T-PTR) | T-PTR-02 (Mac rotate-pickup, BG), **T-PTR-03 = T-TRN-01** (✅core+BG) | — | T-PTR-02 mobile-survivor (decision), T-PTR-04 (approve-time safety-code UI), T-PTR-06 (✅rules) |
| Transport/iroh (T-TRN) | **T-TRN-01 (✅ pin store 9/9 + wired)**, T-TRN-02/03/04/05 (BG), T-TRN-06 (rate-limit, ✅rust) | — | T-TRN-07 (rc pin — documented-accept) |
| Gateway/PoP (T-GW) | T-GW-02 (415 guard, ✅ts), T-GW-05 (in-clause targeting, ✅ts) | several | — |
| Cloud authz (T-AZ) | T-AZ-01/02/04 (✅rules), T-AZ-05 (authz-coverage test, ✅ts), T-AZ-08 (rate-limit, ✅ts) | T-AZ-* | T-AZ-03 (metadata — decision), T-AZ-06/07 (operator) |
| Daemon (T-DMN) | T-DMN-01/04/05 (✅daemon-tests), T-DMN-03 in-code re-verify (✅) | — | T-DMN-03 SMAppService install-location (target/portal) |
| Agent tools (T-TOOL) | **T-TOOL-02 (Critical, BG)**, T-TOOL-03/04/09/10 (BG), **T-TOOL-08 (✅ urlRegex 20/20)** | — | T-TOOL-01/05/07 (full in-CLI interposition architecturally impossible — strongest-feasible done) |
| Agentic prompt/memory (T-AI) | T-AI-01/02/03/06/07 (wrap+provenance+re-auth, BG), T-AI-04 (✅daemon) | — | — |
| iOS MASVS (T-IOS) | T-IOS-01/02/03/05/06/07/11 (BG + 28 tests), **T-IOS-06 app entitlement (lead)** | — | T-IOS-04 (NSE target), T-IOS-08/10 (decision/doc), portal capability toggles |
| Android MASVS (T-AND) | T-AND-01/02/04/05/06 (✅compiles), T-AND-03 (mostly) | — | — |
| Attachments/media (T-ATT) | **T-ATT-01 (✅rust hard-ceiling)**, T-ATT-02/03/05/06 (BG), T-ATT-04 (MercuryManifestMAC, BG), T-ATT-07/08 (✅ts) | — | — |
| Privacy/logging (T-PRV) | T-PRV-01/02/04/05/07 (✅ts), T-PRV-03 (BG iOS+macOS), T-PRV-06 (TTL, ✅ts) | — | — |
| Supply-chain (T-SC) | T-SC-02…10 (✅ actionlint/hardening) | T-SC-01/05 | — |

`✅` = test-verified here · `BG` = build-gated (Xcode/Gradle CI compiles) · `lead` = done directly by the lead.

## 4. Residuals — explicitly NOT pure code (dispositioned, not dropped)

1. **Apple Developer portal toggles** (code values are set; only the portal switch remains): Data Protection capability on the keyboard/widget targets (T-IOS-01); the `com.openburnbar.shared` keychain-access-group capability (T-IOS-06 — app + keyboard entitlements already reference it; **fails closed** until enabled). → operator.
2. **New Xcode targets** (in-code mitigation landed; the fuller target is a build-system change): Notification Service Extension for push-body decryption (T-IOS-04 — in-code redaction enforced now); SMAppService root-owned daemon install (T-DMN-03 — pre-exec self-codesign re-verify landed now).
3. **Architectural limit:** OpenBurnBar spawns external CLI agents (claude/codex/etc.) as full delegates; it cannot interpose on each in-CLI tool call (T-TOOL-01/05/07). Strongest feasible shipped: arg/env capability constraints + untrusted-content tagging + per-N-action re-auth on the unrestricted-shell path. Residual is inherent to delegation and is documented.
4. **Crypto-key redesign:** hardware-bound non-extractable identity keys (T-CVS-03) require moving libsignal identity keys off an extractable representation — partial (app-controlled keys now SE/biometry-gated); the libsignal piece is a decision.
5. **Product/crypto decisions & operator state:** T-CRY-05, T-CVS-05, T-AZ-03, T-IOS-08, T-IOS-10, T-PTR-02 (mobile-survivor rotation), T-AZ-06/07 + PITR/backups/alerting/branch-protection. → [`operator-and-decisions.md`](operator-and-decisions.md) and [`open-questions.md`](open-questions.md).

## 5. Documented variances (fix differs slightly from the literal recommendation)

- **T-ATT-01** — used a streaming **hard byte-ceiling** rather than a post-fetch `size == manifest.size` equality, because threading `manifest.size` through `fetch_blob` would change the UniFFI signature (regen churn). DoS is mitigated; `cargo` green.
- **T-PRV-06** — added the TTL (the substantive retention fix) but kept the generic "*X* replied" push title; dropping `providerLabel` would degrade a real UX feature and the finding marked it optional.
- **T-TRN-07** — kept the iroh `=1.0.0-rc.0` pin (a stable bump churns the lockfile) and documented the rc-acceptance; Low/Info.

## 6. How to re-verify

```
cd OpenBurnBarCore && swift test           # 1577
cd OpenBurnBarDaemon && swift test          # 648
cd functions && npm run test:security && npx vitest run
cd crates/openburnbar-iroh && cargo test --offline && cargo clippy --offline --all-targets -- -D warnings
cd firestore-rules-tests && npm run test:rr12-relay-and-root
cd android && ./gradlew :app:compileDebugKotlin --offline
actionlint
```

## 7. Provenance & safety

- The two Criticals were fixed with **new, tested primitives** reusing existing sibling patterns: `IrohHostKeyPinStore` (mirrors the proven `ControllerKeyPinStore`; pin-on-first-use + **mismatch→refuse** + fail-closed) and the gateway/CLI hardening.
- No cloud resource was created, modified, or deleted; deployed-state items are left to the operator runbook by design.
- The prior parallel draft + the uncommitted wave-2 patch are preserved under [`_evidence/_prior-cut/`](_evidence/_prior-cut/) and [`_evidence/_wave2-backup/`](_evidence/_wave2-backup/).
