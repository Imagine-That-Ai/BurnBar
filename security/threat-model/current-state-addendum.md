> **CONFIDENTIAL -- BurnBar security package.** Current-state addendum prepared June 14, 2026. Share with Cure53 out-of-band; do not publish.

# Current Worktree Addendum -- June 14, 2026

## Snapshot

The original threat-model corpus in this directory was independently code-verified at commit `5416ef780`. This addendum spot-validates material security deltas in the current dirty worktree at HEAD `6eb8340d1` on branch `remediation/tech-debt-fable-2026-06-12`.

Use this file as a superseding delta, not as proof of deployment. The working tree is dirty and contains unmerged/uncommitted security remediation. A control below is therefore only a **current-code mitigation** until it is merged, tested in CI, deployed where applicable, and verified against live production state.

Additional implementation pass: the current worktree now removes dangerous spawned-CLI autonomy flags from every build, keeps unrestricted shell behind bounded local reauth, strips ambient environment from restricted shells and spawned third-party CLIs, wires mobile security-control sources into the Xcode target, and passes focused macOS/mobile/Android/server/security test slices. This does not prove production deployment.

## How To Read This Package

- The existing `_evidence/` files, generated threat register, and claim matrix remain useful as the baseline evidence corpus.
- Findings listed in this addendum supersede stale headline wording for the named threat IDs.
- When sharing with Cure53, disclose both states: the original corpus identified the issue; the current worktree contains the mitigation; deployment and release status still need proof.
- Do not use current-code mitigations as user-facing claims until the associated tests and deployed-state checks are complete.

## Material Current-Code Deltas

| Area | Prior package state | Current worktree evidence | Current-code effect | Residual risk / proof owed |
|---|---|---|---|---|
| Iroh host-key trust (`T-TRN-01`, `T-PTR-03`) | iOS host key was in-memory TOFU only; compromised cloud could substitute the Mac host key after app restart. | `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/IrohHostKeyPinStore.swift:7-45,122-153,196-213`; `OpenBurnBarMobile/Services/IrohRelay/FirestoreIrohPairingPublicKeyProvider.swift:11-19,57-76`; tests at `OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests/IrohHostKeyPinStoreTests.swift:22-130`. | Phone pins the first observed host key to Keychain, scopes it by `uid|roleId`, refuses later mismatches, and fails closed on malformed/unreadable/unwritten pins. | First-use safety-number enforcement is flag-gated and default off until UI is wired. First-contact cloud MITM remains a High audit focus; post-first-pin substitution is mitigated in current code. |
| Push privacy and erasure (`T-PRV-01`, `T-PRV-02`) | VoIP/FCM pushes included cleartext caller name and stable correlators; root push queues had no TTL and were not deleted on account erase. | `functions/src/callables/voipPush.ts:47-58,62-85`; `functions/src/voipPush.ts:27-43,63-105`; `functions/src/accountDeletion.ts:122-132`; `firestore.indexes.json:1878-1886`. | Push payloads use generic caller labels, remove `connection_id` / `paired_device_id`, use fresh `correlationId`, stamp `expireAt`, and account deletion enumerates root push queues by `uid`. | Need CI/test evidence, deployed TTL index proof, and live APNs/FCM payload capture. Provider-side retention still exists by design for the reduced payload. |
| Avatar object authorization (`T-AZ-01`) | Authenticated users could read other users' profile photo object path. | `storage.rules:16-27`. | Direct avatar reads are owner-only; cross-user display must use a signed URL after a server-side visibility check. | Need Storage rules emulator coverage and deployed rules readback. |
| Hermes Gateway request hardening (`T-GW-02`, `T-GW-05`, `T-ATT-07`, `T-ATT-08`) | PoP write body-hash lacked explicit JSON content-type rejection; event targeting filter was app-layer only; legacy attachment content-type control was denylist; signed download URL did not force inert content type/disposition. | `functions/src/callables/hermesGateway.ts:204-245,1131-1159,1189,1269,1289,1485,1590,1733-1743,1769`. | Signed write routes reject non-JSON bodies; event query constrains `targetClientId`; legacy attachment media types are allowlisted; download signed URLs force `application/octet-stream` and `attachment`. | Need Gateway integration tests and deployed callable revision proof. |
| Firestore rule hardening (`T-AZ` family) | Several sealed collections and wrapper paths relied on weaker shape constraints. | `firestore.rules:647,1111-1123,1380,1428,1533,2271-2280,2728,2853`. | Sealed plaintext-like fields are forbidden on covered paths, workspace paths bind to caller ownership, key-wrapper IDs are deterministic, wrapper owner-delete is closed, and iroh pairing/control docs remain server-owned. | Need emulator tests for every changed path and production rules deployment proof. Admin SDK callable authority remains outside rules. |
| Server log scrubbing (`T-PRV-04`) | Server scrubber was pattern/key based with narrower provider-token coverage. | `functions/src/logging.ts:15-44,47-59,87-118`. | Expanded provider-token patterns and sensitive-key redaction regardless of primitive type. | Still not a substitute for drop-by-default logging; client Sentry remains the live High privacy gap. |
| Supply-chain gates (`T-SC-02`, `T-SC-03`, `T-SC-04`, related) | Provenance ecosystem-deny could no-op; CODEOWNERS had no second reviewer on sensitive surfaces; Rust/Swift OSV coverage was missing. | `.github/CODEOWNERS:29-58`; `.github/workflows/supply-chain-provenance.yml:23-37,46-92,120-158,232-284`; `.github/workflows/rust-sast.yml:100-124`; `.github/workflows/workflow-lint.yml:49-57`; `scripts/ci/verify-supply-chain-hardening.sh:60-75`. | Current workflows add tighter `workflow_run` provenance checks, bind attestations to published artifacts, install/assert cargo-deny and OSV Scanner before ecosystem-deny, add Rust/Swift OSV scanning, and require a second CODEOWNER on sensitive paths. | Need GitHub team existence, live branch protection requiring code-owner review, CI green readback, and proof all workflows are actually required before merge/release. |
| Dangerous agent autonomy and ambient process secrets (`T-TOOL-02`, `T-AI-07`, `T-TOOL-10`) | Trusted/YOLO grant paths could emit dangerous external CLI flags without local-auth proof in non-distribution builds; reauth cadence could remain stuck requiring proof after a successful proof; restricted shell and spawned CLI children could inherit parent-process secrets through environment variables. | `AgentLens/Services/CLIBridge/AgentSecurityPolicy.swift`; `AgentLens/Services/CLIBridge/CLIArgumentBuilder.swift`; `AgentLens/Services/CLIBridge/CLIExecutableResolver.swift`; `AgentLens/Services/CLIBridge/CLIProcessStreamRunner.swift`; `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift`; `AgentLensTests/Active/AgentSecurityPolicyTests.swift`; `AgentLensTests/Active/CLIBridgeTests.swift`; `AgentLensTests/Active/AgentToolBrokerShellAuditTests.swift`; focused `xcodebuild test` macOS security slices. | Vendor dangerous-autonomy flags are no longer emitted in any build. Trusted/workspace grants use sandboxed/approval modes. The unrestricted shell still requires bounded local reauth before use. Restricted in-app shell invocations and spawned third-party CLI agents receive allowlisted child environments instead of inheriting `OPENBURNBAR_*`, cloud, GitHub, SSH-agent, or CI secrets from the parent process. | External CLI agents still cannot be fully interposed once delegated; BurnBar can constrain flags and environment before launch, but cannot inspect every in-process CLI action after handoff. |
| Mobile security-control target wiring (`T-TRN-02`, `T-TRN-05`, `T-CRY-01`, `T-ATT-04`) | Several remediation sources existed in the repo but were not compiled into the mobile app target, so controls/tests were not Xcode-enforced. | `OpenBurnBar.xcodeproj/project.pbxproj`; `OpenBurnBarMobile/Services/IrohRelay/IrohPairingAdmissionStore.swift`; `OpenBurnBarMobile/Services/Media/MercuryManifestMAC.swift`; `OpenBurnBarMobile/Services/HermesGatewayVersionFloorStore.swift`; `OpenBurnBarMobile/Services/Hermes/HermesTransportFallbackGuard.swift`; focused mobile `xcodebuild test`. | Mobile app target now compiles pairing admission pin/high-water checks, Mercury manifest MAC validation, Hermes gateway version-floor anti-downgrade, and relay fallback-rate alarm controls. | Full mobile suite and CI still need to run; first-contact pairing confirmation remains product/UI-gated. |

## Current Top 10 Risks After These Deltas

| # | ID | Risk | Current severity |
|---|---|---|---|
| 1 | `T-DMN-01` / `T-DMN-02` | The daemon treats first-party code signature as authorization and runs unsandboxed; one signed-app RCE can become broad local agency. | High |
| 2 | `T-TOOL-01` / `T-TOOL-05` / `T-TOOL-07` | External CLI agents still cannot be fully interposed once delegated; BurnBar must treat in-CLI behavior as a residual agency boundary. | High |
| 3 | `T-CVS-03` / `T-IOS-09` | CloudVault and identity keys remain extractable from a compromised unlocked endpoint; no PFS/PCS limits the blast radius. | High |
| 4 | `T-TRN-01` / `T-PTR-03` | Current code pins post-first-use iroh host keys, but first-contact safety-number verification is flag-gated and not UI-complete. | High |
| 5 | `T-PRV-03` | Client telemetry privacy still requires full macOS+iOS consent/scrubber review and production Sentry configuration proof. | High |
| 6 | `T-AZ-05` / `T-AZ-06` / deployed-state unknowns | Admin SDK/IAM/App Check/Remote Config live state is outside the repo and can weaken otherwise-correct rules. | High/Medium |
| 7 | `T-SC` family | Current supply-chain hardening is better, but live GitHub governance, required checks, and CI success are not proven. | High/Medium |
| 8 | `T-IOS-01` / `T-IOS-06` | Apple Developer portal capabilities and shared keychain access-group state require live portal proof. | Medium/High |
| 9 | `T-CVS-05` / `T-CRY-05` | Epoching, KCI posture, forward secrecy, and post-compromise recovery remain product/crypto decisions rather than complete guarantees. | Medium |
| 10 | Provider/model paths | Provider retention, model-output trust, and user-routed data handling still need deployment configuration proof and adversarial review. | Medium |

## Controls Now Implemented In Current Code But Not Yet Deployment-Proven

1. Phone-side iroh host-key Keychain pinning and mismatch refusal.
2. Generic push payloads, per-push correlation IDs, Firestore TTL fields, and account-deletion cleanup for root push queues.
3. Owner-only direct avatar reads in Storage rules.
4. Gateway JSON content-type enforcement, query-level event targeting, attachment media allowlist, and inert signed download response headers.
5. Firestore sealed-field deny rules, workspace owner binding, deterministic key-wrapper doc IDs, and wrapper delete closure.
6. Expanded server log scrubber patterns and sensitive-key redaction.
7. Second CODEOWNER entries on sensitive surfaces, tighter provenance workflow gates, cargo-deny / OSV fail-closed assertions, and Rust/Swift OSV coverage.

## Still-Open Must-Fix Controls

1. Keep `--dangerously-skip-permissions` and `--dangerously-bypass-approvals-and-sandbox` permanently un-emitted; keep `runShellUnrestricted` behind explicit, auditable user intent and bounded local-auth reauthorization.
2. Finish deterministic in-process policy enforcement for every local tool dispatch and terminate in-flight agents on revoke.
3. Wrap every tool result, oracle/RAG snippet, CLI prompt contribution, and memory retrieval as untrusted data before it re-enters model context.
4. Add client-side Sentry scrubbers, explicit `sendDefaultPii:false`, consent gating, and remove real-name-derived macOS identity seeds.
5. Wire and enable the iroh host-key safety-number confirmation UI for first contact.
6. Secure Enclave / biometry-bind iOS vault and escrow keys where the UX requires stronger stolen-unlocked-device resistance.
7. Add Mercury streaming byte ceilings and post-fetch manifest-size equality checks.
8. Produce deployed-state evidence for App Check, IAM/KMS, Remote Config, branch protection, CODEOWNER review enforcement, TTL indexes, alerting, backups, and live Functions revisions.

## Safe Current-State Wording

Safe: "The current worktree contains mitigations for post-first-use iroh host-key substitution, push payload minimization, push queue TTL/erasure, avatar owner-only reads, several Gateway request-hardening gaps, and supply-chain CI hardening. These controls still require merge, CI, deployment, and live-state verification before they are audit-claim-ready."

Unsafe: "The iroh pairing problem is fully fixed," "push metadata is private," "Cure53 can ignore supply chain," "branch protection enforces two-person review," or "production has these controls" unless live evidence is supplied.
