# Adversarial Audit Handoff — Signal at-rest sealing (SOTASIGNAL items 3/4/5)

**You are a skeptical, dogged, adversarial reviewer. Trust nothing in this document or in the
commit messages. Every "verified / done / SOUND / GREEN" claim below is a claim made by the
*builder* — your job is to independently reproduce or break it.** The builder already missed
**three P0s** in its own first self-audit (see §9), so assume more are hidden.

Security-critical: this is an **end-to-end-encryption at-rest** feature. The adversary you must
model is the **BurnBar server itself** (honest-but-curious AND malicious) — it holds every
device's *public* identity key and fully controls all stored Firestore documents.

---

## 1. The original mission (audit AGAINST THIS, not against the diffs)

- **Item 3 — production wiring:** Pensieve, mobile chats, CLI mission writes **actually
  producing** Signal-sealed payloads (with Signal-first read + legacy fallback).
- **Item 4 — L41 runtime:** real runtime flows wired — publish prekeys, claim prekeys, session
  metadata, key rotation, revocation/rewrap.
- **Item 5 — activation:** do NOT flip production flags; then ring rollout + live rollback drill.

The builder's own verdict: **NOT DONE against this plan** (foundation + Apple crypto + gating
done; Pensieve dead, L41 unwired, CLI half, Android parity missing, activation held). Confirm
this is the *floor* of the problems, not the ceiling.

---

## 2. Where everything is

- **Repo / remote:** `origin` = `https://github.com/Imagine-That-Ai/BurnBar.git`. `gh` is authed
  as `Ajnunezg`. Base integration branch: **`signal/phase2`** (tip `24d922939`).
- **Worktree under audit:** `/private/tmp/burnbar-signal-wiring-20260605` (an isolated git
  worktree; currently on `signal/phase2-crossdevice-senderauth`). The main checkout is
  `/Users/albertonunez/Documents/Windsurf/BurnBar` — **do NOT edit it** (other agents run there).
- **PRs:**
  - **#279 — MERGED** into `signal/phase2` (merge `24d922939`): the wiring + L41 server runtime +
    native client stores + P0-1 sender-auth + kill switch + readiness + all first-round
    remediation. This is the bulk of the work; audit the *merged* `signal/phase2`.
  - **#280 — OPEN, HELD, DO-NOT-DEPLOY** (base `signal/phase2`, head `signal/phase2-activation-flip`
    @ `3a45e0bc8`): the `conversations_chat`-only activation flip (registry `sealingScheme`).
  - **#281 — OPEN** (base `signal/phase2`, head `signal/phase2-crossdevice-senderauth` @
    `e970af43d`): cross-device sender-auth verification on the two main Apple read paths.
- **Ledger:** `.agent/runs/sotasignal-wiring-runtime-activation-20260605/` — `GOAL.md`,
  `implementation-notes.html` (timeline of what was done + claimed), `evidence/`.
- **Key commits:** `0766a4e7b` wiring · `61dd61136`+`059a72e15` first remediation · `f189be18e`
  sender-auth · `1468e8d3f` kill switch · `41c5ee1d6` canonicalization · `e970af43d` cross-device.

---

## 3. Environment / reproduction gotchas (you WILL hit these)

1. **Vendor symlinks (Swift builds):** `Vendor/libsignal` + the two xcframeworks are NOT in the
   worktree. To build Swift you must symlink them from the main checkout:
   ```bash
   cd /private/tmp/burnbar-signal-wiring-20260605
   ln -sfn /Users/albertonunez/Documents/Windsurf/BurnBar/Vendor/libsignal Vendor/libsignal
   ln -sfn /Users/albertonunez/Documents/Windsurf/BurnBar/Vendor/OpenBurnBarSignalFfi.xcframework Vendor/OpenBurnBarSignalFfi.xcframework
   ln -sfn /Users/albertonunez/Documents/Windsurf/BurnBar/Vendor/OpenBurnBarIroh.xcframework Vendor/OpenBurnBarIroh.xcframework
   ```
   **CRITICAL:** `Vendor/libsignal` is a registered submodule path — the symlink BREAKS all `git`
   commands ("expected submodule path not to be a symbolic link"). **Remove the symlinks +
   `mkdir -p Vendor/libsignal` before any `git status/diff/commit`.** The builder shuffled these
   constantly; if `git` errors, this is why.
2. **Android SDK:** `export ANDROID_HOME=/Users/albertonunez/Library/Android/sdk` before any
   `./gradlew`. The SDK is real but not wired into the worktree (`local.properties` absent), so a
   stripped shell — e.g. a subagent's — will fail with "SDK location not found". A `BUILD FAILED`
   piped through `tail` shows `GRADLE_EXIT=0` (that's `tail`'s exit, not gradle's) — **don't trust
   piped exit codes; grep for `BUILD SUCCESSFUL/FAILED`.**
3. **SourceKit "No such module 'Firebase*'/'LibSignalClient'" diagnostics are FALSE POSITIVES**
   from the stale index — command-line `swift build`/`xcodebuild` resolve them. Only trust actual
   build output, not IDE diagnostics.
4. **functions deps:** `cd functions && npm ci` if `node_modules` is absent.
5. **`apps/console` has no `node_modules` here** — you cannot run its `tsc` in the worktree;
   `gen/domains.ts` typing was only verified by-construction (the builder added the optional field
   to the interface). **Independently verify the console build elsewhere.**

---

## 4. Reproduce the builder's "all green" claims (do NOT trust them — run them)

```bash
WT=/private/tmp/burnbar-signal-wiring-20260605
# functions
cd $WT/functions && npx tsc --noEmit && npx vitest run            # claim: tsc 0, 356 pass
cd $WT/functions && npm run test:firestore-rules                  # claim: 51/51
# data-domains + activation parity
cd $WT/packages/data-domains && node codegen.mjs && node --test   # claim: 22/22 (gen must be clean)
cd $WT && bash scripts/ci/verify-signal-activation-parity.sh      # claim: GREEN, fail-closed
# Swift crypto core (needs symlinks from §3)
cd $WT/OpenBurnBarCore && swift test --filter OpenBurnBarSignalCoreTests   # claim: 8/8
# apps (needs symlinks)
cd $WT && xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
cd $WT && xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' CODE_SIGNING_ALLOWED=NO
# Android (needs ANDROID_HOME)
cd $WT/android && ANDROID_HOME=/Users/albertonunez/Library/Android/sdk ./gradlew :app:testDebugUnitTest --tests "com.openburnbar.data.cloud.*"
```
**Run the suite on the MERGED `signal/phase2` (`git checkout signal/phase2`), not just the worktree
branch** — verify the merge into the (advanced) base didn't introduce a semantic break. The builder
claims the merge added only one unrelated CI commit; confirm with
`git log --oneline signal/phase2-wiring-runtime..origin/signal/phase2`.

---

## 5. The central security claim to BREAK (highest priority)

**Claim:** "The P0-1 server-forgery hole is closed; the at-rest envelope is sender-authenticated;
a malicious server cannot get a forged envelope accepted." Files:
`OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift`
(`senderAuthSignedMessage`, `sealPayload`, `openPayload`),
`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`
(`CloudVaultSignalSenderAuth`).

Try to forge. Specifically:
1. **Is there ANY read path that opens a `signalEnvelope` WITHOUT verifying `senderAuth`?** Grep
   every caller of `openSignalPayloadIfPresent` and `OpenBurnBarSignalAtRest.openPayload` on all
   platforms. The core `openPayload` REQUIRES `senderAuth` + a pinned key — but does every WRAPPER
   enforce it, or does any path decode the envelope directly / bypass the wrapper?
2. **Pinned vs wire key:** verification must use `trustedSenderPublicKeys[senderIdentityKeyId]`,
   NEVER the wire `senderIdentityKeyB64`. Grep for every read of `senderIdentityKeyB64` — there
   should be ZERO on the open path. Confirm.
3. **Downgrade/strip:** an envelope with `senderAuth` absent must fail closed (`senderAuthMissing`)
   → caller falls back to legacy. Confirm the fallback is to the SECRET-keyed legacy
   `sealedPayload` (non-forgeable), not to anything the server controls.
4. **Replay across path/uid:** the signed message embeds the HPKE `info` (= path binding). Confirm a
   valid (signature, ciphertext) replayed to a different docId/uid/collection fails — AND that the
   reader recomputes `info` from the *expected* binding, not the wire binding.
5. **Signed-message completeness:** read `senderAuthSignedMessage` byte-for-byte. Is EVERY
   trust/decryption-affecting field signed? It signs domain∥info∥payloadCiphertextB64∥(sorted
   wraps `id`+`sealedContentKeyB64`). Is anything mutable-but-unsigned (e.g. `recipientIdentityKeyB64`
   inside a wrap, `schemaVersion`, `contentKeyLength`, `payloadAADLabel`)? Construct a mutation that
   changes behavior without breaking the signature.
6. **ANDROID HAS NO SENDER-AUTH.** Android neither signs nor verifies `senderAuth`. So: (a) an
   Android-written envelope has no `senderAuth` → an Apple reader rejects it → falls to legacy (ok);
   (b) **an Apple-written envelope read on Android is opened WITHOUT sender verification** → Android
   is forgery-vulnerable for any signal-first read. Confirm Android's `CloudVaultCrypto.openSignalPayload`
   ignores `senderAuth` entirely. This means the forgery fix is **Apple-only** — the cross-platform
   claim is FALSE. (Builder acknowledges this in SECURITY.md; verify it's the ONLY platform gap.)
7. **No cross-language KAT exists.** The builder claims the signed message is "byte-identical across
   languages" (length-prefixed + NFC + byte-sorted) but there is **no Kotlin implementation and no
   Swift↔Android signature KAT**. Treat "cross-language byte-stable" as UNPROVEN.

---

## 6. The "gated/inert, no production change" claim to BREAK

**Claim:** "All wiring is inert in production; nothing seals until the registry `sealingScheme`
flip AND the Remote Config kill switch are both on." Gate: `signalSealingIsEnabled`.
- iOS `OpenBurnBarMobile/Services/MobileCloudVaultSignalPayloads.swift`, Mac
  `AgentLens/Services/MacCloudVaultSignalPayloads.swift`, Android
  `android/.../data/cloud/AndroidCloudVaultSignalPayloads.kt`.
- Verify: on `signal/phase2` (NOT the flip branch) NO domain has
  `sealingScheme == "signal-hpke-identity-seal-v1"` (`packages/data-domains/registry.json` — only
  `pensieve` = `cloudvault-aesgcm-v2`). The flip is ONLY on #280.
- Verify the kill switch AND-logic: scheme set is necessary but not sufficient; the per-domain RC
  flag `signal_at_rest_<domainID>_enabled` defaults OFF. **iOS/Mac read Firebase Remote Config
  directly; Android reads an injected `signalAtRestActivationProvider` that is NEVER WIRED →
  defaults `false` forever.** Confirm: (a) Android genuinely cannot seal even if the registry is
  flipped (provider nil → false); (b) there is no other code path that sets that provider; (c) no
  committed RC template sets the flag true (parity check #3 + grep `signal_at_rest_.*_enabled`).
- **Dual-write floor:** every producer must write the legacy AES-GCM `sealedPayload`
  UNCONDITIONALLY and `signalEnvelope` only additively. Grep each producer; find any path that
  writes `signalEnvelope` without also writing `sealedPayload`, or that aborts the legacy write on
  a signal-seal failure (the builder claims all producers now "fail open" — verify each catch).

---

## 7. Confirm the known gaps (then look for MORE the builder missed)

The builder admits these. Confirm each with code, then probe adjacent areas:
1. **Pensieve produces NOTHING.** `OpenBurnBarDaemon/.../PensieveKnowledgeWatcher.swift`,
   `OpenBurnBarMobile/Models/DataVaultStore.swift`, the MCP shim — zero `signalEnvelope`. The only
   producer `AgentLens/.../KnowledgeSyncService.swift` has no caller. → item 3 Pensieve unmet.
2. **L41 runtime dead-on-arrival.** `functions/src/callables/signalPrekeyDirectory.ts`
   (publish/claim/session/rotation/watermark) + `signalActivationReadiness.ts` + native stores
   `OpenBurnBarSignalCore/OBBSignalProtocolStore.swift`/`OBBSignalPreKeyGenerator.swift` — grep for
   ANY native/web client caller; builder claims none. → item 4 unmet. Also verify the claim-txn is
   actually atomic + double-claim-safe (`claimSignalPrekeyBundle`) and that `recordSignalSession`
   really fail-closes `peerUid===owner` + rejects `gateway-transport`.
3. **CLI mission RESULT (`sealedStatePayload`) never signal-sealed.** Grep `sealedStatePayload` for
   any `signal`. → item 3 CLI half-done.
4. **Cross-device readers:** #281 wired only conversations + mobile chats on Apple. `MobileAssistantChatReader`
   (Mac reads phone chats) + `CLIAgentMissionRequestListener` still pass no trusted-sender set →
   cross-device sender-auth still inert there.
5. **Rewrap is planning-only** — revoking a device does NOT re-seal existing at-rest docs; a revoked
   device keeps read access. Confirm `signalDirectoryRuntime.ts` only flips session status.
6. **firestore.rules `validSignalAtRestEnvelope`:** `senderAuth` is only **type-bounded** (`is map`),
   NOT field-validated — the builder cut it back because the `cli_agent_mission_requests` rule hit
   the **1000-expression-per-evaluation limit**. Probe: (a) can a malformed/oversized `senderAuth`
   smuggle anything past the rules (it carries no plaintext, but confirm)? (b) **Did adding any
   field push OTHER rules near/over the 1000-expr limit?** Plant a valid write on the heaviest rules
   and confirm they still evaluate. (c) Is the path-binding (`validSignalAtRestEnvelope` collection/
   docId/uid) actually enforced for `chat_threads` + `conversations` (the two added in this work)?

**New angles the builder did NOT deeply check — go here:**
- The `signalSealedCollections` "honesty guard" (registry + parity + `registry.test.mjs`): can it be
  gamed (declare a collection sealed that has no producer, or vice-versa)? It's documentation +
  subset check only — there is NO static proof a producer exists per listed collection.
- `keyVersion` ROTATION: identity rotation (v2+) — does sender-auth verification survive a rotated
  sender key? Is `keyVersionLabel` consistently written (builder noted Swift omitted it; rules
  mandate it for v≥2)? Find rotation round-trips that break.
- The self-exclusion guard (`identityKeyId == localIdentity.identityKeyId { continue }`) — confirm
  it's in ALL THREE Swift resolvers (Mac/Mobile/KnowledgeSync) + the iOS/Android equivalents. It was
  MISSING from `KnowledgeSyncService` and added late — assume the same class of bug elsewhere.
- The best-effort read resolver (#281) uses `try? atRestRecipients` which is **all-or-nothing**: one
  trusted device missing an identity → resolver returns ONLY {local} → ALL cross-device reads fall
  back to legacy (not just the missing peer's). Is that the intended/claimed behavior, or a silent
  coverage cliff?
- Storage / Firestore.indexes.json (`one_time_prekeys`, `kyber_prekeys` composite indexes) — match
  the actual queries? Any unindexed query that will fail at runtime?
- `panic.ts` + `computerUseSecurity.ts` revocation — does the partial-failure surfacing actually
  reach alerting, or is it swallowed?

---

## 8. Per-dimension adversarial checklist (the original audit rubric)

- **Correctness:** does it satisfy items 3/4/5? (No — prove the specific unmet parts.) Any producer
  that *appears* wired but never runs in prod (gate off + no caller)?
- **Architecture:** three near-identical Swift recipient/seal adapters (Mac/Mobile/KnowledgeSync) —
  drift risk (already caused the self-exclusion miss). Should be hoisted to `OpenBurnBarSignalCore`.
- **State/persistence:** Mac producers use `merge:true` — confirm stale `signalEnvelope` is deleted
  on gate-off/unseal (`FieldValue.delete`); find any field that can outlive its `sealedPayload`.
- **Edge/failure:** empty recipients, >32 wraps (`tooManyRecipients`), missing identity, malformed
  envelope, huge payloads, N-device fan-out (per-write Firestore round-trips in `atRestRecipients`).
- **Testing:** are tests meaningful or do they assert builder-friendly happy paths? The Mac at-rest
  producer + the cross-device resolver (#281) have NO direct unit test (build-verified only). The
  server claim-txn double-claim is asserted but not emulator-tested. Add the missing tests.
- **Docs:** `SECURITY.md` "Signal at-rest sealing — status and activation gates" is the canonical
  gate list. Verify it matches reality (no over-claims) and is complete.

---

## 9. The builder's track record (weight your skepticism accordingly)

In its FIRST self-audit the builder concluded "safe by construction, no P0 breakage." A deeper
adversarial workflow then found **three P0s it had missed**:
1. producer seal threw BEFORE the legacy write → one stale device halts ALL cloud backup;
2. `firestore.rules` rejected the new `signalEnvelope` field for `chat_threads`/`conversations`
   (denial-of-backup at activation);
3. the at-rest envelope had **no sender authentication** (server-forgeable) — the headline.

All three were later fixed, but the lesson stands: **the builder's "it's fine" is unreliable.** A
cross-model review (Claude workflow + a Codex pass that did not complete) declared the sender-auth
"SOUND", but only Claude actually returned a verdict — treat even that as a claim to re-derive, not
a result to trust.

---

## 10. Suggested audit method (be dogged)

1. Reproduce §4 on the merged `signal/phase2`. Any red → start there.
2. Spend the most time on §5 (forgery) and §6 (inertness) — the two claims that, if false, are
   catastrophic. Try to actually construct a forged envelope a reader accepts, and try to make a
   producer seal in "production" (gate off) state.
3. Confirm §7 known gaps, then chase the "new angles" + rotation + the rules expression-limit.
4. For anything you can't break, write down the exact reason it's safe (file:line), so the next
   reviewer doesn't re-litigate. For anything you break, file it with a repro.
5. Default to "refuted/unsafe until proven" on every claim. The standard is not "looks fine" — it's
   "I tried hard to break it and here is exactly why it held or didn't."

Do NOT flip any production flag, do NOT merge #280, and do NOT edit the main checkout.
