# SOTASIGNAL — Skeptical Adversarial Review Handoff

**For:** the next agent, tasked with running a *skeptical, hostile* adversarial review of the Signal (libsignal) migration work.
**From:** the SOTASIGNAL server/proof/docs implementation pass (`.agent/runs/sotasignal-full-ship-20260605/`).
**Date:** 2026-06-05 · **Branch:** `signal/phase2` @ `642258b9` · **Plan:** `~/Desktop/SOTASIGNAL.md` + `docs/signalification/`.

Your job is NOT to trust this document. It is to **try to break** everything below, confirm or refute each claim against the live code, and find what both prior agents missed. This file tells you exactly where to look and what was *not* done.

---

## Output requirement — WHERE TO PUT YOUR FINDINGS

When you finish your skeptical adversarial review, write **all** of your findings to a single Markdown file in the dedicated audit folder on the Desktop. Do not just reply in chat; produce the durable artifact.

- **Folder:** `~/Desktop/Signal Audit/` — create it if missing: `mkdir -p "$HOME/Desktop/Signal Audit"`
- **Filename:** `audit-<model-that-produced-it>-<YYYY-MM-DD>-<HHMMSS>.md`
  - `<model-that-produced-it>` = YOUR model id (e.g. `claude-opus-4-8`, `gpt-5`, `gemini-3-pro`).
  - timestamp from `date +"%Y-%m-%d-%H%M%S"`. Example: `audit-claude-opus-4-8-2026-06-05-023411.md`.
  - **Never overwrite a prior audit** — each run is its own timestamped file, so the folder accumulates one audit per reviewer/run.
- **Contents:** every finding with **severity, `file:line`, the attack/repro, a confirmed/refuted verdict, and your recommended fix**, plus the human/hardware-gated items you could not close, plus the exact commands you ran to verify. Be hostile: try to break the claims in this handoff, don't restate them.

The first such audit (this finish's consolidated findings) is already there — read it, then try to break its conclusions:
`~/Desktop/Signal Audit/audit-claude-opus-4-8-2026-06-05-023411.md`.

---

## 0. Read this first — there are TWO agents in this tree

This work was originally done **alongside a second, live "native-crypto" agent** that owned the libsignal packaging + Swift/Kotlin sealer lanes. A later continuation fixed the native L37/AAD activation-gate bugs in this same dirty working tree. **Before you edit anything, confirm which agent owns the file and re-run the focused tests below.**

| Surface | Owner | SOTASIGNAL items |
| --- | --- | --- |
| `Vendor/libsignal/`, `Vendor/OpenBurnBarSignalFfi.xcframework/`, `OpenBurnBarCore/Package.swift`, Gradle build graph, `scripts/build-signal-ffi-xcframework.sh` | shared native packaging lane | Phase A, L38, L39; final reproducible Apple/Android packaging proof |
| `OpenBurnBarCore/Sources/OpenBurnBarSignalCore/**`, `OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/**`, `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SignalEnvelopeAAD.swift`, Android `app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt`, Android `CloudVaultCryptoTest.kt`, mobile Signal at-rest helper files | fixed in continuation | Swift/Android **L37 expected-binding** + Swift AAD scalar guard; see `.agent/runs/sotasignal-full-ship-20260605/evidence/native-l37-continuation-20260605.md` |
| `firestore.rules`, `functions/scripts/test-firestore-rules.mjs` | this pass | **L31, L37 (rules half)** |
| `functions/src/signalAtRestWrite.ts` (+ test) | this pass | **L23, L37 (admin half)** |
| `scripts/ci/**`, `scripts/ops/**` (5 new scripts) | this pass | **Phase F** |
| honesty audit + allowlist | this pass | **L21** |
| this handoff + `.agent/runs/sotasignal-full-ship-20260605/` | this pass | the review + handoff |

**Do not assume the native-crypto lane is finished.** The L37/AAD correctness bugs are patched, but the current `Vendor/OpenBurnBarSignalFfi.xcframework` was previously described as a *temporary macOS-only proof artifact*, not the final reproducible multi-slice framework. Reprove packaging before any device/activation claim.

---

## FINAL STATUS — current pre-activation truth (2026-06-05, supersedes stale details below)

The second agent was stopped; one owner then finished the safety/proof layers and re-ran focused physical-device proofs. **The flag-OFF safety infrastructure is green, but production activation is still blocked.** The current activation validator fails with 32 real Phase-E issues; do not claim "10/10" or flags-on readiness until those are closed.

For the operational checklist of every remaining item, owner, order, and acceptance gate, use:
[`docs/signalification/REMAINING_SIGNAL_WORK_HANDOFF.md`](./REMAINING_SIGNAL_WORK_HANDOFF.md).

**Done + verified green (re-run §5 to reprove):**
- **L37 native openers are now AIRTIGHT** (final-review verdict: "AIRTIGHT — no findings"). `expectedBinding` is **non-optional** (no nil/`null` overload survives anywhere — grep proves it), the binding equality `guard`/`require` is unconditional, and the AEAD AAD is derived from **`expectedBinding`** (not `envelope.binding`). Swift `swift test` OpenBurnBarSignalCoreTests 5/5 + SignalEnvelopeAADTests 5/5; Android `:app:testDebugUnitTest` BUILD SUCCESSFUL, CloudVaultCryptoTest 10/10.
- **L40 canonical `sourceManifestId`** is closed across backend and Firestore rules: new rows/manifests use `sourceManifestId`, transitional `sourceSlugToken` is rejected on client writes, legacy rows remain lazy-dual-readable, and export treats the canonical field as opaque.
- **L41 Signal identity/prekey/session directory rules** are green for the server/rules contract (identity versions 1-10, public-only prekeys, metadata-only sessions, append-only rotation events); runtime producers/revocation/rewrap remain activation work.
- **All user-facing honesty over-claims FIXED** (not just flagged): every "the server searches without reading it" / "ANN search without reading" string rewritten to the caveated form across website (`PricingPlans.astro`, `faq.ts`, `pricing.astro`, regenerated `trust.generated.ts`), macOS (`CloudStoreSettingsView.swift`, `GatedFeature.swift`), iOS (`HostedQuotaSubscriptionStore.swift`, `CloudTierComponents.swift`, `DataVaultControl*View.swift`), Android (`GatedFeature.kt`, `CloudStoreViewPlanSections.kt`, regenerated `DataDomains.kt`) — fixed at the **registry source** for the generated copies. The honesty gate now also scans the **iOS app + shared Swift catalog** and the **singular** "search without reading".
- **Full gate sweep GREEN:** functions `tsc` clean; full vitest **320 pass**; emulator rules **50/50**; contract **12/12**; libsignal-protocol **7/7**; data-domains **19/19** + no drift; crypto-harness **18/18**; activation-parity OK; honesty OK; schema-drift OK.
- **Final local physical-device Signal proof GREEN:** iPad `PensieveMemorySearchSignalTests` **3/3**, iPad chat relocation **1/1**, Android physical Signal instrumented **2 tests on SM-S921U**, and Android JVM regression all exit 0 in `.agent/runs/sotasignal-full-ship-20260605/evidence/device-physical-final/`. Earlier iPhone focused/full Signal proofs remain in `evidence/device-packaging/`; the final rerun found the iPhone CoreDevice tunnel unavailable after build validation, so no new iPhone code failure was observed.
- **rule0 gate** intentionally flags **3** Rule-0 touches — `.gitmodules` + `Vendor/libsignal/` (AGPL vendoring → **legal/L12 sign-off**) and `website/src/data/trust.generated.ts` (the honesty regen → **registry/copy-owner ratification**). These are legitimate-but-owner-gated; the gate surfacing them is correct.

**Remaining activation blockers (the real "not 10/10 yet" list):**
1. **External cryptographer review** + **legal/AGPL & MAS sign-off** (hard Phase-E prerequisites; require named independent/owner signers).
2. **Release packaging proof** — local Apple multi-slice XCFramework + iOS/macOS builds and Android device proof are green; notarization/MAS/store/legal approval remains.
3. **Live physical-device E2E matrix** — local flag-OFF Signal proofs are green on iPhone evidence already collected, iPad final rerun, and Android final rerun; production-domain live flows remain blocked until producers are enabled and activation flags are staged.
4. **Production producer wiring** of the at-rest sealer through every domain + **wiring the admin validator** at every real admin/callable write site. The pensieve server/admin seam is partially wired and tested; app/daemon producers, Android direct producers, client readers, telemetry, and live domain flows still block activation.
5. **Broader L41 runtime work** — client prekey/session producers, revocation exclusion, and rewrap jobs. L40 (`sourceSlugToken` → canonical `sourceManifestId`) is closed in the current working tree; see `.agent/runs/sotasignal-full-ship-20260605/evidence/l40-source-manifest-id.md`.
6. **Phase-E activation** (ring rollout) + **live timed rollback drill** + owner ratification of the two rule0-flagged items.

Sections 1–7 below are the original review record; where they say "optional expectedBinding", "unfixed over-claim", or "flagged for owner", read the FINAL STATUS above as authoritative.

---

## 1. What this pass actually built (verify each, with commands)

All additive, **flag-OFF**, no production behavior change. Every claim has a reproduction command.

### 1a. Firestore rules `validSignalAtRestEnvelope` (L31 + L37 rules half)
- **Files:** `firestore.rules` — new functions `validSignalBase64`, `validSignalCiphertextLayer`, `validSignalAtRestKeyDelivery`, `validSignalAtRestBinding`, `validSignalAtRestEnvelope`; optional-additive `signalEnvelope` field wired into `mobile_assistant_chats` and `cli_agent_mission_requests`.
- **Why these two collections:** they are the **client-writable** at-rest body collections (W2). The pensieve W1 collections (`cloud_search_knowledge`, `knowledge_sync_manifests`, `knowledge_repos`) are `allow write: if false` (admin/callable-written) → enforced by the Admin validator instead (1b).
- **The L37 guarantee:** the binding is compared **field-by-field to the doc PATH** (`uid`/`collection`/`docId`/`field`), never trusted from the envelope; `scope`/`mode`/`formatVersion` pinned; `hasOnly()` rejects `relayKeyVersion` and gateway-only `clientId`/`slotId` on an at-rest binding.
- **Repro:** `cd functions && npm run test:firestore-rules` → **50/50 pass**, incl. L37 `ok 31/32/33`, L40 canonical `sourceManifestId`, and L41 Signal identity/prekey/session directory validation.
- **Skeptic's angle:** Firestore rules **cannot iterate a list**, so per-wrap deep validation is *intentionally* delegated to the Admin validator + TS sanitizer. Confirm that split is real (1b) and that nothing client-writable persists a `signalEnvelope` whose **wraps** are unvalidated. Also confirm adding `"signalEnvelope"` to the two `hasOnly` lists did not loosen any pre-existing required-field invariant.

### 1b. Admin SDK validator (L23 + L37 admin half)
- **Files:** `functions/src/signalAtRestWrite.ts` (`validateSignalAtRestEnvelopeForWrite`, `assertSignalAtRestEnvelopeForWrite`), test `functions/src/__tests__/signalAtRestWrite.test.ts`.
- Deep-validates every wrap via the shared `sanitizeCloudVaultSignalEnvelope`, then enforces path-binding against caller-EXPECTED coordinates, then derives the canonical AAD.
- **Design note (verify it's safe):** it **STRIPS** additive pollution (returns the sanitized `result.envelope` to persist) and **REJECTS** forbidden-field pollution + all relocation. Writing the sanitized object is structurally stronger than rejecting — but **only if callers persist `result.envelope`, never the raw input.**
- **Repro:** `cd functions && npx tsc --noEmit && npx vitest run src/__tests__/signalAtRestWrite.test.ts` → tsc clean, **8/8 pass**.
- **⚠ OPEN GAP for you to confirm:** this validator is currently **UNWIRED** — no callable calls it yet (there is no real producer; the libsignal bridge is still a readiness stub per `docs/signalification/DOMAIN_SIGNALIFICATION_MAP.md`). That is correct for flag-OFF, but it means the L23 guarantee is **latent**. When the producer lands, every `signalEnvelope` admin write MUST route through `assertSignalAtRestEnvelopeForWrite` and persist `result.envelope`. **Grep for the first write site and confirm it does.**

### 1c. Phase F — proof/ops scripts, CI wiring, and external-review package
- `scripts/ci/crypto-proof-harness.mjs` → **18/18**: real libsignal 0.94.4 at-rest HPKE seal/open round-trip + relocation/tamper/wrong-key negatives + `bindingToAAD` NFC byte-parity vs the cross-language fixture + contract-recognizer negatives + fixture sha pinning. Emits a manifest (node/libsignal/Maven/fixture-sha256). Repro: `node scripts/ci/crypto-proof-harness.mjs`.
- `scripts/ci/verify-signal-activation-parity.sh` → **GREEN**: asserts `HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS` is empty, no domain has a `signal` `sealingScheme`, no committed RC template flips a signal flag ON.
- `scripts/ci/verify-signal-rule0.sh` → **INTENTIONAL FAIL in this dirty tree**: flags `.gitmodules`, `Vendor/libsignal/`, and `website/src/data/trust.generated.ts`. That is correct: AGPL vendoring and generated public trust copy require legal/ownership/copy-owner ratification before landing.
- `scripts/ci/verify-signal-honesty-copy.sh` (+ `signal-honesty-allowlist.txt`) → **GREEN** baseline (see L21 below).
- `scripts/ops/signal-rollback-drill.sh` → dry-run kill-path rehearsal; asserts the kill levers exist in code; times the locally-verifiable steps.
- `.github/workflows/fast-feedback.yml` now runs the Signal crypto proof harness in the Signal crypto proof job, after the legacy libsignal bridge package proof.
- `docs/signalification/EXTERNAL_CRYPTO_REVIEW_PACKAGE.md` is the external-review package index. It is **not** a sign-off; it records the exact artifacts and the remaining human/legal/hardware gates.
- **Skeptic's angle:** these are **gates** — try to make each **false-pass**. The crypto harness proves the Node at-rest HPKE proof and pins the native fixtures; the Swift/Kotlin *open of a Node-sealed KAT* is delegated to the platform suites. Re-run the focused Swift and Android suites before trusting this.

### 1d. L21 honesty audit
- **Files:** `.agent/runs/sotasignal-full-ship-20260605/evidence/honesty-copy-audit.md`, `scripts/ci/signal-honesty-allowlist.txt`.
- Current gate result: **GREEN**, 29 count-bearing reviewed file/phrase pairs, no un-reviewed over-claim phrases. The user-facing "server searches without reading it" copy was rewritten to a caveated form across website/app surfaces in the continuation.
- **Skeptic's angle:** the allowlist is count-bearing, not line-specific. A changed count trips review, but a semantically worse rewrite using different wording still requires human review. Try to introduce singular/plural variants and confirm the gate catches them.

---

## 2. What was NOT done — honest blocker register (do not let anyone claim 10/10)

The plan itself forbids "flags ON" / 10/10 until these pass. Some are technical work, some are shared-lane packaging/device work, and some require human/legal/external review.

| Item | State | Owner / gate |
| --- | --- | --- |
| L38 Apple libsignal packaging green (xcframework, rpath, notarize/MAS) | **in flight, not final** | native-crypto agent + Apple toolchain |
| L39 Android libsignal green (desugaring, Maven-only, assemble) | `:app:testDebugUnitTest` + `:app:assembleDebug` green; physical Signal instrumented proof green on SM-S921U | Android toolchain + device E2E |
| **L37 Swift** `SignalAtRestSealer.openPayload` used `envelope.binding` (relocation bug) | **FIXED in working tree** — `expectedBinding` is non-optional, equality is unconditional, AAD derives from `expectedBinding` | re-run Swift tests |
| **AAD grapheme guard** (`SignalEnvelopeAAD.swift`) is grapheme-level (fail-open vs TS scalar-level) | **FIXED in working tree** — `unicodeScalars` guard + negative test | re-run Swift AAD tests |
| **L37 Android** `openSignalPayload` used `envelope.binding` | **FIXED in working tree** — `expectedBinding` is non-null and required, equality is unconditional, AAD derives from `expectedBinding` | re-run Android tests |
| Production client ciphertext wiring (Phase C producers) | at-rest mobile paths partially wired; real transport v4 and Android/Mac production domain wiring still incomplete | future |
| L23 admin validator **wired** into a real producer | validator built, **unwired** | future producer PR |
| Phase D physical-device E2E (iPhone/iPad/Android/Mac/Python matrix) | local flag-OFF iPhone/iPad/Android Signal proofs green; live production-domain flows still blocked by flag-OFF producers | hardware + producer activation |
| External crypto review + legal/AGPL sign-off | not done | humans (hard Phase-E gate) |
| Phase E activation + ring rollout + live rollback drill | not done | ops + all the above |
| L40 `sourceSlugToken` → canonical `sourceManifestId` | **done in working tree** | focused backend migration; re-run `npx vitest run src/__tests__/knowledgeRepoMatchToken.test.ts src/__tests__/knowledgeMemoryDedupHash.test.ts src/__tests__/dataExport.test.ts` |
| L41 separate Signal identity/prekey directory (not P-256 escrow keys) | identity public-key rules are v1-green; broader prekey/session directory and rotation remain incomplete | native-crypto + key-storage |
| User-facing search/privacy over-claims | **fixed** across website, macOS, iOS, Android, and generated trust/domain copies; honesty gate green | copy owner should still review before GA |

---

## 3. Previously confirmed native findings — now fixed in the working tree (re-verify skeptically)

These were read directly during the adversarial pass, then fixed in a later continuation. **Re-confirm each at the cited file — the tree is dirty and another agent may still edit nearby packaging/build-graph files.**

### F1 — `[P0]` Swift high-level open trusted `envelope.binding` (L37 relocation) — FIXED
`OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift` — `openPayload(_:recipientIdentityKeyId:recipientIdentityPrivateKey:)`:
```swift
let aad = try canonicalAAD(for: envelope.binding.aadBinding)   // ← derives AAD from the ENVELOPE
```
Status now: `OpenBurnBarSignalAtRest.openPayload` requires a non-optional `expectedBinding`, throws unconditionally on mismatch, and derives AEAD AAD from `expectedBinding.aadBinding`. The mobile Signal at-rest helper passes the expected path binding into the opener. Repro: `swift test --package-path OpenBurnBarCore --filter SignalAtRestSealerTests` and the focused mobile relocation test listed in §5.

### F2 — `[P1]` AAD reserved-char guard was grapheme-level (cross-language fail-open) — FIXED
`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SignalEnvelopeAAD.swift` — `signalEnvelopeBindingToAAD`:
```swift
for segment in segments where segment.contains(where: { $0 == "|" || $0 == "\r" || $0 == "\n" }) { ... }
```
Status now: the guard iterates `segment.unicodeScalars`; the Swift AAD tests include a `|` plus combining mark negative. Repro: `swift test --package-path OpenBurnBarCore --filter SignalEnvelopeAADTests`.

### F3 — `[P0]` Android high-level open trusted `envelope.binding` (L37 relocation) — FIXED
`android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt` — `openSignalPayload(envelope, recipientIdentityKeyId, recipientIdentityPrivateKey)`:
```kotlin
val canonicalAAD = CloudVaultCryptoSupport.bindingToAAD(envelope.binding.aadBinding)   // ← ENVELOPE
val contentKey = CloudVaultCryptoSupport.atRestOpen(sealedContentKey, recipientIdentityPrivateKey, envelope.binding.aadBinding)
```
Status now: `CloudVaultCrypto.openSignalPayload` requires `expectedBinding: CloudVaultSignalBinding`, fails closed on mismatch, and derives AEAD AAD from `expectedBinding.aadBinding`. `CloudVaultCryptoTest` includes the relocation-negative case. Repro: `cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:testDebugUnitTest --tests com.openburnbar.data.cloud.CloudVaultCryptoTest --no-daemon`.

> Note: the **TS** low-level `atRestSeal`/`atRestOpen` in `packages/libsignal-protocol` already take the caller's `binding` as a parameter (no L37 bug there). The bug is specifically the **high-level Swift/Kotlin envelope openers** that read `envelope.binding`.

---

## 4. Attack surface for your skeptical pass — what to try to break

1. **Relocation everywhere.** Seal a doc, then try to open/accept it at a different `uid`/`collection`/`docId`/`field`/`mode`/`scope` in: Firestore rules, the admin validator, the Swift opener (F1), the Android opener (F3), and the TS sanitizer. The server halves and native openers should now fail closed; reprove this against current code.
2. **Mode/scope confusion.** Try a transport (`gateway`) envelope at an at-rest path and vice-versa. Confirm `relayKeyVersion` is rejected on at-rest and required (==4) on transport.
3. **AAD injection / non-byte-parity.** Feed a binding segment with an embedded `|`/CR/LF as a multi-scalar grapheme (F2). Confirm TS and Swift both reject.
4. **Pollution.** Add unlisted keys at every level. Rules `hasOnly` rejects; the sanitizer *strips* — confirm no consumer re-emits the RAW polluted value.
5. **Unwired validator (confused deputy).** Confirm there is genuinely **no** code path that writes a `signalEnvelope` (rules-accepted optional field) without the admin validator. When a producer lands, this is the #1 thing to re-check.
6. **Gate false-pass.** Try to slip a domain activation, a Rule-0 edit, or a new user-facing over-claim past the 4 CI gates.
7. **Downgrade/replay on transport** (`hermesGateway.ts`): can v4 be negotiated unilaterally or accepted when the production set is empty?
8. **The 60s reversibility claim** (invariant #10): is it actually achievable, and does the drill measure the right thing (RC propagation, not local test re-runs)?

---

## 5. One-shot reproduction (fresh clone)

```bash
# server / rules / admin
cd functions && npm ci && npm run test:firestore-rules        # 49/49 incl. L37 ok 30/31/32 and L41 v1 identity keys
npx tsc --noEmit && npx vitest run src/__tests__/signalAtRestWrite.test.ts   # tsc clean, 8/8

# proof + gates (from repo root)
node scripts/ci/crypto-proof-harness.mjs                      # 18/18, real libsignal seal/open
bash  scripts/ci/verify-signal-activation-parity.sh           # GREEN (fail-closed defaults)
bash  scripts/ci/verify-signal-rule0.sh                       # INTENTIONAL FAIL in this tree: AGPL/legal + generated trust copy owner gates
bash  scripts/ci/verify-signal-honesty-copy.sh                # GREEN baseline
RUN_TESTS=false bash scripts/ops/signal-rollback-drill.sh     # dry-run kill-path rehearsal

# native (needs the libsignal toolchains)
cd OpenBurnBarCore && swift test --filter SignalEnvelopeAADTests --filter OpenBurnBarSignalCoreTests
cd packages/libsignal-protocol && npm test                    # 7/7 Node libsignal

# native continuation proofs
swift test --package-path OpenBurnBarCore --filter SignalEnvelopeAADTests
swift test --package-path OpenBurnBarCore --filter SignalAtRestSealerTests
xcodebuild -quiet -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobileUnitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -clonedSourcePackagesDirPath .spm-cache-new \
  -derivedDataPath build/DerivedData-mobile-signal-tests-after-binding \
  -only-testing:OpenBurnBarMobileTests/MobileChatHistoryStoreTests/testDecodeThreadOpensPathBoundSignalEnvelopeAndRejectsRelocation test
cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:testDebugUnitTest --no-daemon
cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:assembleDebug --no-daemon
```

---

## 6. 3-wave adversarial review — machine-verified results

A read-only workflow (8 finders → adversarial verification → synthesis) ran over the whole Signal surface: **32 candidates → 18 survived** adversarial verification. Full JSON: `.agent/runs/sotasignal-full-ship-20260605/evidence/adversarial-3waves.json`. The verifier did real work — it **killed/softened several reviewer over-classifications** (e.g. a claimed "P2 plaintext leak" in the rules-comment finding was demoted to P3 once it confirmed `sealedPayload` is the independent mandatory seal; `cli_sessions` was proven already-fail-closed). The big-three native items were **independently CONFIRMED** during review and then fixed in the later native continuation.

### 6a. Confirmed findings I FIXED (all entirely in my lane) — re-verify them

| Sev | Finding | Fix (commit/working-tree) | Re-verify |
| --- | --- | --- | --- |
| **P1** | `sanitizeSignalEnvelopeForExport` FAIL-OPENED — re-emitted the RAW value (incl. plaintext) with `dropped:[]` when strict validation failed (reached via `dataExport.ts:512`). | `packages/signal-envelope-contracts/src/index.ts:377` now **fails closed**: drops every key, reports them. + new contract test. | `cd packages/signal-envelope-contracts && npm test` (12/12); `cd functions && npx vitest run src/__tests__/signalEnvelopeExport.test.ts src/__tests__/dataExportFailClosed.test.ts` |
| **P1** | Honesty gate never scanned the macOS (`AgentLens/`) or Android (`android/app/src/main`) apps — live over-claims shipped green. | Added both to `ROOTS`; the scan now surfaces **8 user-facing search over-claims** (website + `CloudStoreSettingsView.swift` + `GatedFeature.kt` + `CloudStoreViewPlanSections.kt`) — all tagged `[FIX-REQUIRED]` in the allowlist for the copy owner. | `bash scripts/ci/verify-signal-honesty-copy.sh` |
| **P1** | Rule-0 glob did not protect `Vendor/libsignal`, `OpenBurnBarSignalFfi.xcframework`, or `.gitmodules` (a branch could repoint the AGPL submodule and pass). | Glob extended + de-anchored. It now **correctly flags the adopted AGPL vendoring** as a legal-gated change (L12). | `bash scripts/ci/verify-signal-rule0.sh` → flags `.gitmodules` + `Vendor/libsignal/` (intended; needs legal sign-off, not a green gate). |
| **P2** | Honesty allowlist matched by file+phrase only → a NEW over-claim sentence of an allowlisted phrase shipped unreviewed. | Allowlist is now **count-bearing** (`path ::: phrase ::: count`); a new/removed occurrence trips the gate. | scan + change a count → gate fails. |
| **P2** | Rollback drill rehearsed two kill levers (`SIGNAL_ENVELOPE_V4_DISABLED` env, `signal_envelope_v4_enabled` RC) that are **read by zero runtime code**. | Drill now greps for them and labels them **PLANNED (Phase E), not yet wired**; only the real lever (empty version Set) is asserted. | `RUN_TESTS=false bash scripts/ops/signal-rollback-drill.sh` |
| **P2** | Crypto harness pinned only the AAD vectors, never the cross-language fixtures the platform suites consume. | Added **Proof D**: sha-compares the Swift AAD fixture copy to the contract fixture (byte-identical, `f19c92aa…`) + pins the KAT sha. | `node scripts/ci/crypto-proof-harness.mjs` → 18/18. |
| **P3** | `firestore.rules` comment named the wrong function (`validateSignalEnvelopeForWrite`) and over-claimed the admin validator runs "on every admin/export path". | Comment corrected: states plainly the wired collections are owner-direct writes where the rules are the SOLE enforcement and wraps are unvalidated (acceptable only flag-OFF), and the admin validator is currently wired NOWHERE. | read `firestore.rules` ~L580. |
| **P3** | No test proved a `signalEnvelope` is rejected on a NOT-wired collection. | Added `test("L37 signalEnvelope is rejected on a not-wired collection (cli_sessions hasOnly)")` → `ok 32`. | `cd functions && npm run test:firestore-rules` |

### 6b. Confirmed findings fixed later in the native continuation

- **The big three native items (F1/F2/F3 above)** were fixed after this review. Evidence: `.agent/runs/sotasignal-full-ship-20260605/evidence/native-l37-continuation-20260605.md`. Re-run the Swift/mobile/Android commands before treating them as closed.

### 6c. Confirmed findings still not fixed / owner-gated

- **`[review-app]` "zero-knowledge" in app source** (6 files) — owner to confirm each is a non-user-facing identifier/comment vs an over-claim (allowlisted with counts so the gate tracks them).

### 6d. Shared rules collision — L41 blocker fixed, still coordinate

While I worked, the **mobile/native agent concurrently edited the SAME `firestore.rules` and `functions/scripts/test-firestore-rules.mjs`**, adding the **L41 `signal_identity_public_keys`** block (the separate Signal-identity directory). Two consequences:

1. **The L41 `string + int` bug is now fixed.** Firestore rules cannot stringify ints, so the v1 identity-key directory is intentionally fail-closed to `keyVersion == 1` and `identityKeyId == deviceId + "_1"`. The test adds a wrong-suffix negative. Evidence: `.agent/runs/sotasignal-full-ship-20260605/evidence/firestore-l41-signal-identity-rules-20260605.md`.
2. **Stomp risk remains real on `firestore.rules` + `test-firestore-rules.mjs`** because L37 and L41 edits are interleaved. The combined rules suite is currently **49/49**. Whoever changes either file next must re-run `cd functions && npm run test:firestore-rules`.

---

## 7. Where to keep digging (residual leaks the crypto does NOT close)

Per the plan's required disclosures — Signal does **not** fix these; confirm the copy/threat-model still admits them:
- Cosine-preserving cloaked vector graph (server-computable ANN).
- Deterministic keyed-HMAC search indexes (leak recurrence/co-occurrence; confirm via integrity hashes).
- Routing metadata (server-readable).
- At-rest mode has **no forward secrecy** by design.
- Trust root = manual safety-number + TOFU/pinning (no key transparency yet).
