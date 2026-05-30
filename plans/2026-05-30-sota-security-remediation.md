# SOTA Security Remediation Plan (Corrected) — OpenBurnBar Privileged Input & Remote Control Surface

**Status:** Planning complete. Ready for execution approval.
**Owner:** Alberto + security reviewer.
**Date:** 2026-05-30.
**Supersedes:** the prior "SOTA Security Remediation Mega Plan" draft (Grok session). This version keeps that draft's (largely accurate) *diagnosis* and corrects its *prescriptions* after a code-level adversarial review. See **§ Corrections from the prior draft** for the diff and rationale.
**Bar:** SOTA for a consumer/pro tool with remote privileged execution. Every decision defaults to the most durable, platform-native, least-privilege, fail-appropriate choice — and **explicitly rejects complexity the threat model does not require.**

---

## TL;DR

- The prior draft correctly found that input synthesis happens on **three channels** with **three different (or zero) authorization stories**, and that two of them sit *outside* the Computer Use audit/gate/panic system. Verified true against source.
- The single exploitable issue — **any non-sandboxed process running as the logged-in user can drive arbitrary HID keyboard/mouse input via the VirtualHID bridge socket** (auth is UID-only), bypassing TCC and the entire CU safety system — is a **P0** and is fixable in ~1–2 days, **decoupled** from any large refactor.
- The prior draft buried that P0 inside a multi-month program, proposed one defense the platform does not support (`request.app` in `firestore.rules`), specified the wrong auth primitive (a crypto handshake where the attacker and the legit caller share a UID), and reached for heavyweight machinery (Merkle/Trillian log, mandatory live central policy service, TLA+ gate) the use case does not need.
- This plan: **P0 fast-track first**, then a corrected, right-sized durable program built on the substantial primitives that **already exist** (App Attest / Play Integrity / DeviceCheck App Check providers, Ed25519 + monotonic-counter + intent-hash phone-control validation, per-session BLAKE3 hash chain, audit export writer, OpenTimestamps function, callable `enforceAppCheck` in 55 places, TypeSpec schema-sync).

---

## Baseline reconciliation (honesty about where we start)

Two scores are in circulation and must be reconciled or reviewers won't trust the scope:

- The team's own tracked **overall security score is 8/10** (`docs/TECHNICAL_READINESS.md`), dominated by the well-hardened cloud/callable side (App Check enforced on callables in code; 51/51 callable logging; Firestore enforcement on; SQLCipher; structured rules).
- The prior draft's **4.5/10 (computer-use/remote surface 2.5/10)** is the honest **sub-score for the privileged-input + remote-control surface only**, which is the newest, highest-risk addition and the subject of this plan.

**Both are right at different altitudes.** This plan targets the 2.5→9 lift on the privileged-input/remote surface specifically; it does **not** re-litigate already-booked wins in `docs/AUDIT_CLOSURE_SOTA_2026-05-28.md` and `docs/SOTA_REMEDIATION_PROGRESS.md`. Known, separately-tracked debt that this plan touches only opportunistically: **68 empty `catch {}`** and **745 `try?`** in Services/daemon (`docs/TECH_DEBT_METRICS.md`).

---

## Ranked vulnerability register (verified, with exploitability)

Each row was confirmed by reading the cited source on `hardening/sota-100`.

| ID | Severity | Finding | Evidence | Exploitability |
|----|----------|---------|----------|----------------|
| **V0-1** | **P0** | VirtualHID bridge authenticates callers by UID only; any non-sandboxed console-user process can connect and synthesize arbitrary keyboard/mouse via the broad `"input"` op | `OpenBurnBarVirtualHIDBridgeMain.swift:194-206` (`getpeereid` → `peerUID==consoleUser.uid`); `:180-183`→`:306-333` (`dispatch`); socket `chmod 0600` console-user `:147-151` | **High where Remote Unlock is provisioned.** Bridge is a persistent LaunchDaemon. A console-user process with **no TCC Accessibility grant** drives global input → **TCC bypass**, fully **unaudited / ungated / unkillable** by CU |
| **V0-2** | **P0** | Root `RemoteAccessAgent` socket uses the same UID-only `validatePeer`; reachable by console user | `OpenBurnBarRemoteAccessAgentMain.swift:231-240`, `:178-180` | Same class as V0-1, on the root-privileged binary |
| **V1-1** | **P1** | Bridge `"input"` op is fully general (arbitrary text, any key/shortcut, pointer move/click/scroll) — far broader than the Remote-Unlock action set it exists to serve | `…BridgeMain.swift:306-333`; sole caller `RemoteUnlockVirtualHIDInputClient.swift:15-40` | Widens blast radius of V0-1; violates least-privilege for the unlock domain |
| **V1-2** | **P1** | Kill/panic paths live in the **app process** and converge on an in-process callback; they do not reach the input leaf (bridge), so a panic cannot guarantee the leaf stops | `ComputerUsePanicHaltCoordinator.swift` (hotkey/NSWorkspace/RemoteConfig → one `halt` closure) | A wedged/forked driver of the bridge survives an app-side panic |
| **V1-3** | **P1** | Phone-control envelopes verify Ed25519 + monotonic counter + intent-hash, but have **no TTL/expiry and no attestation binding**; "trusted" can mean unlimited | `PhoneControlAuthorityValidator.swift:11-96` (no `expires`/TTL/attestation) | A compromised-but-paired device replays scope indefinitely within counter rules |
| **V1-4** | **P1** | Audit chain is tamper-evident but cannot independently prove **completeness** ("no actions after panic P") without an anchored, signed head | `ComputerUseAuditChain.swift` (hash chain); `ComputerUseAuditExportWriter.swift` (export exists); `functions/src/computerUseOpenTimestamps.ts` (anchoring exists but not wired as a completeness proof) | Disputes ("nothing happened after the kill") not provable offline today |
| **V2-1** | **P2** | 68 empty `catch {}` / 745 `try?` in privileged Services/daemon reduce failure visibility on validation/Keychain/panic/RPC paths | `docs/TECH_DEBT_METRICS.md` | Silent degradation; not directly exploitable |
| **V2-2** | **P2** | Firestore App Check enforcement is verified by a **human** launch gate, not automatically | `scripts/commercial-launch-gate.mjs`, `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md` | Regression risk if the console toggle is ever flipped off |
| **V2-3** | **P2** *(functional, not security)* | Developer-ID release lane omits keychain-access-groups / iCloud / Apple-Sign-In that the code uses; risk is **silent feature degradation**, not a vuln | `OpenBurnBarRelease.entitlements` vs `OpenBurnBar.entitlements`; usage in `AccountManager.swift`, `AccountSwitcherSupport.swift`, `AgentLensApp.swift` | Release build may lose account-switching/iCloud/sign-in unless gated gracefully |
| **V2-4** | **P2** | Build/release below SLSA provenance + signed attestations for a tool that can synthesize input | `release.yml`, `pr-harness.yml` | Supply-chain tampering harder to detect/attribute |

---

## Guiding principles (corrected SOTA defaults)

1. **Least privilege is the goal, not "feature parity across lanes."** Fewer entitlements/capabilities is *better*. We never expand the TCB to "remove divergence." (Corrects prior draft's entitlements framing.)
2. **Platform-native authentication over bespoke crypto.** For local IPC between first-party binaries, authenticate the peer by **code signature via its audit token** (`LOCAL_PEERTOKEN` → `SecCode` + designated requirement), not a key handshake — because the legitimate caller and local malware share the same UID, so any shared secret is equally readable by both.
3. **Policy as a locally-verifiable artifact in fail-sensitive paths.** The Remote Unlock leaf must verify a signed, single-use, short-TTL **capability token offline** — never depend on a live central service to type the unlock password. (Corrects prior draft's "every leaf must consult a central live PDP," which re-introduces the documented `RemoteAccessAgent` crash-loop failure mode.) A live policy service is acceptable only for the **post-unlock Computer Use domain**, where fail-closed is the right default.
4. **Right-size verifiability.** This audit is **single-writer, per-session, bounded**. A tamper-evident **hash chain + signed head + external anchor** proves everything we need (integrity, prefix, completeness-given-anchor). We **reject** a Merkle/Trillian verifiable log: its inclusion/consistency proofs solve a multi-writer, high-volume, partial-disclosure problem we do not have.
5. **Attestation is anti-clone/anti-tamper, not authorization.** App Attest / Play Integrity prove the request comes from a genuine, unmodified instance of our app on a genuine device. They do **not** prove human intent and do **not** stop a compromised-but-genuine device. Lead the compromised-controller defense with **short TTLs, per-action scope+approval, server velocity/anomaly caps, and kills that reach the leaf**; use attestation as a necessary gate, not the headline.
6. **Two policy domains, never merged.** Computer Use (agent-driven, post-unlock) and Remote Unlock (human-only, at lock/loginwindow, protects the login password) have separate profiles, token types, action sets, audit categories, and threat trees. The bridge enforces the **domain tag** of the token it receives. (Kept from prior draft — correct.)
7. **Kills reach the leaf and survive crashes.** At least one kill path must be checked by the input leaf on every dispatch and must survive app/daemon crash (local flag set by an always-on watchdog). Remote Config stays as defense-in-depth.
8. **Prove the vuln before building the defense.** Every P0/P1 gets a failing red-team PoC first, which becomes the regression test.
9. **Property-based + exhaustive harness is the formal gate.** Optional small TLA+/Alloy of the abstract pairing/grant/panic protocol as living documentation only — never a phase gate that bit-rots.
10. **Defense of the human over power of the feature.** When in doubt, choose safer; scope expands later behind stronger controls.

---

## Phase P0 — Close the exploitable hole (standalone PR, ~1–2 days, ship before the program)

**This does not wait on any refactor.** It is the permanent-enough fix and is within reach now.

**P0.a — Peer code-signature authentication on both privileged sockets** *(V0-1, V0-2)*
- Add a shared `PrivilegedPeerAuthenticator` (in `OpenBurnBarRemoteAccessAgentCore`, reused by both the bridge and the root agent).
- On `accept`, obtain the peer's audit token: `getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &auditToken, &len)`.
- Build a `SecCode`: `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: Data(bytes:…)] as CFDictionary, [], &code)`.
- Validate against a compiled designated requirement: `SecCodeCheckValidity(code, [], requirement)` where `requirement` ≈ `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "com.openburnbar.*"` and the caller is hardened-runtime + library-validation enabled. Reject otherwise with a new high-severity audit event `privileged_socket_peer_rejected`.
- Keep the existing UID check as a cheap first gate; code-sign is the authority. (TOCTOU-safe: the audit token identifies the exact peer process at connect time.)
- Add the canonical Team ID / DR as a single constant (none exists centrally today; `AccountManager.swift` only references `teamIdentifier` for keychain prefixing).

**P0.b — Constrain the bridge `"input"` op** *(V1-1, partial now / completed in WS1)*
- Gate the general `"input"` op behind a per-request **domain-tagged, signed, single-use capability token** (see WS2 token spec). Until WS2 lands, **fail-closed**: accept only the action kinds Remote Unlock actually issues, and reject `type`/`shortcut`/arbitrary-key unless they are part of the certified unlock sequence.
- Emit a bridge audit event for every accepted/rejected `"input"` dispatch so this channel stops being audit-dark.

**P0.c — Proof-of-vulnerability + regression test** *(Principle 8)*
- Add a red-team test target that, as a plain console-user process **without** Accessibility, connects to `/var/run/openburnbar-virtual-hid.sock` and attempts `"input"`. Assert it **succeeds before P0.a/b** (documented) and **is rejected after**. Mirror for the root-agent socket.

**P0 gate:** PoC flips from success→rejected; existing Remote Unlock certification + CU scenarios still pass; the legitimately-signed first-party caller still works; new audit events fire. Merge as its own PR with its own runbook note.

---

## The durable program (corrected workstreams)

### WS1 — Minimal-TCB isolation & entitlements *(builds on P0)*
- Refactor privileged input execution toward a **minimal launchd/XPC input-execution service** holding only `hid.virtual.device` + audit-append rights (no network, no broad FS, no Keychain beyond its own sealed material). Migrating bridge↔caller IPC to **XPC** gives audit tokens natively and simplifies P0.a.
- Reduce the root agent to a **narrow launcher + token requester**; move dangerous work into the smallest audited component.
- Hardened runtime + library validation on all first-party binaries (this is what makes peer code-sign auth meaningful — it blocks injection into the signed caller).
- **Entitlements (recategorized as release-engineering, not a vuln):** verify and test **graceful degradation** of keychain-access-groups / iCloud / Apple-Sign-In features in the Developer-ID lane. Embed a Developer-ID provisioning profile **only** for a capability that is both essential and otherwise unavailable. Default stays **minimal entitlements** (least privilege). Add a release-lane smoke test asserting no silent feature breakage.

### WS2 — Capability tokens & attestation *(V1-1, V1-3)*
- Define `CapabilityToken` (COSE/CBOR or compact JSON) in `OpenBurnBarComputerUseCore`, schema-synced via `tools/schema-sync/`:
  `{ domain: "remote_unlock"|"computer_use", nonce, issuedAt, expiresAt(short TTL), allowedActionKinds, scopeHash, actionBudget, boundEscrowDeviceId, attestationHashBlake3? }`, Ed25519/Secure-Enclave-signed.
- **Remote Unlock domain:** issuer key provisioned at certification, stored in Secure Enclave; token minted **only when a pending attested unlock request exists**; **single-use** (nonce tracked); verified **offline by the leaf** (signature + TTL + nonce-unseen + action∈allowed). No live service in the unlock path.
- **Computer Use domain:** tokens minted by the in-process PDP/`ComputerUseRunCoordinator`, attestation-bound, short-TTL, scope-hashed; verified at the leaf. Fail-closed acceptable here.
- **Attestation:** reuse the **existing** App Attest (iOS/macOS), DeviceCheck fallback, and Play Integrity (Android) providers — wire their assertions into grant issuance + high-risk actions. Right-size per Principle 5: pair with TTL + per-action approval + server velocity caps.
- Extend `PhoneControlAuthorityValidator` to require token TTL + attestation binding **in addition to** its existing Ed25519 + counter + intent-hash checks. Propagate revocation of escrow devices/grants.

### WS3 — Verifiable audit (anchored hash chain, NOT Merkle) *(V1-4)*
- Keep `ComputerUseAuditEntry` chain. Add a **signed head**: Ed25519/SE signature over `{sessionId, lastEntryIndex, headHashHex, closedAt}`.
- **Anchor** the signed head via the existing `computerUseOpenTimestamps.ts` (+ optional RFC-3161 / witness cosign for high-value sessions). Completeness ("no actions after panic P") is proven by the **anchored head**, not by tree proofs.
- Ship a **standalone verifier** (Swift package target + CLI in `OpenBurnBarCLI`; optional TS/WASM port only if a browser verifier is genuinely wanted) that, given the exported entries + anchor: re-derives the chain, checks every `parentEntryHashHex` link, verifies the head signature, verifies the external timestamp, and asserts "no entry index > N." No trust in the originating Mac or any online service.
- Export already exists (`ComputerUseAuditExportWriter`); add the verifier + a user/runbook guide.

### WS4 — Cloud defense-in-depth (corrected mechanism) *(V2-2)*
- **Do NOT add `request.app` to `firestore.rules`** — Firestore App Check is console-enforcement-only; `request.app` does not exist in Firestore rules. Keep rules doing `request.auth`, owner scoping, shape/secret validation.
- Route every high-risk CU mutation (grant issuance, budget override, escrow registration) through **callables with `enforceAppCheck`** (already used 55× in `functions/src` — extend to any uncovered CU paths) + **App-Attest-bound custom claims** verified server-side.
- **Automate** the Firestore App Check enforcement check in `commercial-launch-gate.mjs` (replace the human-only gate with a probe/Management-API check); fail the gate on misconfiguration.

### WS5 — Supply chain & release *(V2-4)*
- **SLSA build provenance via GitHub Actions OIDC + cosign attestations** for release artifacts; SBOM + VEX in every PR + release; `cargo-deny` and per-ecosystem equivalents on every build.
- **Explicitly de-scope bit-for-bit reproducibility of the notarized artifact** (post-sign ticket stapling + secure timestamps make it infeasible) — document the rationale; pursue pre-signing-payload reproducibility only where practical.

### WS6 — Process, formal properties, governance *(V2-1, cross-cutting)*
- **Property-based + in-code exhaustive FSM explorer** over approval/trust/panic/grant as the CI gate, asserting invariants: "no input action after any panic source for the session"; "revoked/expired/attestation-failed grant produces no effect and is audited"; "trust only downgrades without explicit approval"; "a Remote Unlock token is single-use and domain-locked." Optional small TLA+ of the abstract protocol as doc only.
- **Kills reach the leaf** (V1-2): the input leaf checks a local kill flag on every dispatch; an always-on launchd watchdog can set it; survives app/daemon crash. Remote Config stays defense-in-depth. Add the "nuke all grants + force local-only + evidence package" operator runbook with timing/SLOs.
- Opportunistically drain empty-catch/`try?` debt (V2-1) on the privileged paths this plan touches; update `TECH_DEBT_METRICS.md`.
- Threat model revision: separate trees for "compromise of the unlock password" vs "general desktop pwn"; DFDs per channel; residual-risk table; signed by owner + reviewer.
- Security review checklist in the PR template for any CU/remote/privileged change.

---

## Phased execution & gates

- **P0 (now, standalone):** as above. Gate = PoC success→rejected + no regression.
- **Phase 1 = WS1 + WS5 start:** minimal-TCB isolation, hardened runtime, entitlement graceful-degradation; SLSA provenance scaffolding. Gate = notarized build runs all CU + Remote Unlock certification scenarios; isolation tests prove no broad FS/network/Keychain in the input service; entitlement smoke test green.
- **Phase 2 = WS2:** capability tokens + attestation binding + TTL/revocation. Gate = expired/revoked/attestation-failed token denies control and is audited (harness); unlock path verified offline with no live-service dependency; "trusted" requires recent attestation + explicit scope confirmation; perf acceptable.
- **Phase 3 = WS3 (parallel):** anchored signed head + standalone verifier. Gate = sample export independently proves "no actions after panic" and "this is the complete authorized prefix" using only exported artifacts + verifier.
- **Phase 4 = WS4:** callable `enforceAppCheck` coverage + attestation-bound claims + automated launch-gate check. Gate = emulator + security tests pass; launch gate fails on a misconfigured project.
- **Phase 5 = WS6 + WS5 close:** property/exhaustive harness as gate, leaf-reaching kills, threat model, runbooks, debt drain, red-team run. Gate (final) = full `make ci` green incl. new security jobs; red-team scenarios (compromised phone, post-panic, peer-spoof of the socket, attestation bypass, coordinator crash mid-dispatch) all fail to break invariants; owner + security-reviewer sign-off.

---

## Verification ("holy shit, that's done")

- **P0 PoC** demonstrably blocked, locked in as a regression test, on both sockets.
- An unprivileged console-user process **cannot** synthesize input, and every accepted/rejected privileged dispatch is **audited**.
- Independent, offline audit verification proves integrity, prefix, and **completeness-after-panic** from exported artifacts alone.
- Expired/revoked/attestation-failed control attempts are denied and audited; a kill reaches and stops the **leaf**, surviving an app/daemon crash, in a timed runbook drill.
- Release build notarizes and runs the full CU + Remote Unlock certification matrix with documented, tested graceful degradation in the Developer-ID lane (no silent feature loss).
- Launch gate passes on clean projects and fails on misconfigured ones automatically.
- A reviewer unfamiliar with the code can, in <30 min with the threat model + 1–2 source files + the verifier, explain the input TCB, the two domains, "what happens on phone compromise after trusted pairing," and how to prove nothing happened after a kill.

---

## Explicitly de-scoped / rejected (with rationale)

| Prior-draft item | Decision | Why |
|---|---|---|
| Add `request.app` checks to `firestore.rules` | **Rejected** | Firestore App Check is console-enforcement-only; `request.app` is a Cloud Functions construct. Correct mechanism (callable `enforceAppCheck`) already done — extend it instead |
| "Cryptographic client authentication" handshake on the bridge socket | **Replaced** | Caller and local malware share a UID, so any shared secret is equally readable. Use peer **code-signature** auth (audit token → `SecCode` + DR) |
| Merkle/Trillian verifiable log + WASM verifier | **Replaced** | Single-writer, per-session, bounded log. Anchored signed hash chain + standalone verifier proves all required properties with far less complexity |
| Mandatory **live** central Policy Decision Service in the unlock path | **Replaced** | Re-introduces the documented `RemoteAccessAgent` crash-loop failure that made unlock unreachable. Use locally-verifiable single-use tokens; reserve a live PDP for the post-unlock CU domain |
| "Eliminate dev/release entitlement divergence" via embedded profiles | **Recategorized** | It's a functionality/QA matter, not a vuln; adding entitlements expands the TCB. Verify graceful degradation; keep least privilege |
| "Attestation everywhere" as the headline control-compromise defense | **Right-sized** | Attestation stops clones/tampering, not compromised-genuine devices. Lead with TTL + per-action approval + server caps + leaf-reaching kills |
| TLA+/Alloy as a phase gate | **Demoted** | Hand-maintained specs bit-rot. Property-based + exhaustive in-code harness is the gate; TLA+ optional doc |
| Bit-reproducible **notarized** builds | **De-scoped (documented)** | Infeasible post-sign. Target SLSA provenance + cosign attestations instead |

---

## Success metrics

- CU/remote surface sub-score 2.5 → **9+/10** with evidence (PoC regression, offline verifier output, red-team report, automated gate).
- The P0 hole is closed within the first PR, before the broader program — no window where the elegant fix is the only thing standing between users and an exploitable socket.
- A diligence team can be walked through the input TCB, the two domains, and the proof story in a day and come away reassured.

**Next step after approval:** ship Phase P0 as a standalone PR (peer code-sign auth + constrained `"input"` op + PoC regression test), then begin Phase 1 (WS1 isolation) + WS5 provenance scaffolding in parallel.
