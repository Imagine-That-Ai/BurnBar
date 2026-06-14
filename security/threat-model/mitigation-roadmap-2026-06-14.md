# BurnBar Mitigation Roadmap — AS OF 2026-06-14

**HEAD:** `f70565fcfbf` &nbsp;|&nbsp; **Branch:** `security/iroh-host-key-pin-ttrn01` &nbsp;|&nbsp; **Baseline:** `5416ef780`

Source of truth is the current code at HEAD. This roadmap is derived only from threats whose
current status is **Open / Partial / Mitigated-in-code** and from the **newly-introduced** findings in
the 2026-06-14 status pass. Now-Fixed items are in the *Recently closed* appendix.

Status snapshot (106 threats): 1 Critical · 21 High · 40 Medium · 36 Low · 8 Info.
By status: Open 74 · Partial 21 · Mitigated-in-code 8 · Unverifiable 2 · Fixed 1.

A recurring, audit-blocking theme this pass: the prior security package
(`current-state-addendum.md`, `REMEDIATION.md`) repeatedly **claims controls that are not present at this
HEAD** — they live on the unmerged divergent branch `remediation/tech-debt-fable-2026-06-12` (commit
`6eb8340d1`, **not an ancestor of HEAD**) plus stale DerivedData. These doc-vs-code gaps are listed under
"Must fix before audit" because handing Cure53 the addendum verbatim would produce false assurance.

Each item: **id(s) | title** — current status — recommended fix — acceptance criteria.

---

## Must fix before audit

These are Critical/High live risks, or documentation that misrepresents the audited HEAD. Both must be
closed (or honestly scoped) before an external Cure53 audit.

### Doc-vs-code integrity (reconcile or re-land before sharing the package)

- **NI / T-TOOL-02, T-AI-07 | Addendum claims a dangerous-autonomy fix (`AgentSecurityPolicy.swift`) that does not exist at HEAD** — current status: **High (newly-introduced, audit-integrity)**.
  Fix: either merge the remediation branch into HEAD so the "fresh local-auth proof + per-N-action reauth cadence" control actually ships, or correct the addendum to scope the claim explicitly to the unmerged branch `6eb8340d1`.
  Acceptance: `find AgentLens -name 'AgentSecurityPolicy*.swift'` returns the file at HEAD AND its tests pass; OR the addendum/REMEDIATION wording marks T-TOOL-02/T-AI-07 as NOT-fixed-at-HEAD with the branch named. No package artifact asserts a fix absent from the audited commit.

- **NI / T-TRN-02, T-TRN-03, T-TRN-05 | Addendum cites mobile remediation files absent at HEAD (`IrohPairingAdmissionStore.swift`, `HermesGatewayVersionFloorStore.swift`, `HermesTransportFallbackGuard.swift`)** — current status: **Medium (audit-integrity)**.
  Fix: re-land the admission-pinning / version-floor / fallback-rate-alarm controls into HEAD, or strike those claims from the addendum.
  Acceptance: `git ls-tree -r HEAD` finds each cited file, OR the addendum no longer attributes those controls to HEAD.

- **NI / T-CRY-01 | Addendum claims the gateway version-floor anti-downgrade store ships in the mobile target** — current status: **Medium (audit-integrity)**.
  Fix: same as above — `HermesGatewayVersionFloorStore.swift` must exist at HEAD or the claim must be withdrawn.
  Acceptance: `git cat-file -e HEAD:OpenBurnBarMobile/Services/HermesGatewayVersionFloorStore.swift` succeeds, OR the doc is corrected.

- **NI / T-AZ-01, T-GW-05 | Addendum claims storage-rules avatar owner-only read and a gateway `targetClientId` where-clause that are not in HEAD** — current status: **Medium (audit-integrity)**.
  Fix: reconcile the addendum Material-Deltas section with the byte-identical-to-baseline `firestore.rules`/`storage.rules` at HEAD, or land the rule changes.
  Acceptance: `git diff 5416ef780 HEAD -- storage.rules firestore.rules` reflects the claimed changes, OR the addendum drops the "fixed" wording for T-AZ-01/T-GW-05.

- **NI / T-PRV-02, T-PRV-04, T-PRV-06 | Addendum/REMEDIATION assert push-queue erasure+TTL, expanded log scrubber, and an agent-notification TTL that are absent at HEAD** — current status: **Medium (audit-integrity)**.
  Fix: land the controls or correct the docs; the cited line ranges (e.g. `firestore.indexes.json:1878-1886`) do not even exist in the file.
  Acceptance: code diffs support the claims, OR the privacy-section doc claims are withdrawn.

- **NI / T-ATT-04, T-ATT-08, T-AZ-01 | Addendum attributes Mercury manifest MAC, inert download headers, and content-type allowlist to a commit not in this branch's ancestry** — current status: **Medium (audit-integrity)**.
  Fix: pin each claimed control to the exact commit it lands on; if auditing this branch, re-land or strike.
  Acceptance: the package names the precise HEAD/commit for every claimed T-ATT/T-AZ control and a reviewer on this branch can locate it.

- **NI | Committed Firebase/GCP security-evidence JSON exposes IAM topology, owner PII, project number, and full Secret Manager name inventory** — current status: **High (newly-introduced)**.
  `security/evidence/firebase-security-evidence-latest.json` is tracked by deliberate `.gitignore:197` policy and leaks `user:alberto8793@gmail.com` as `roles/owner`, project number `246956661961` (×204), the deploy SA bindings, every Secret Manager secret name (Stripe/APNS/Android-keystore/OpenRouter/MCP-HMAC/webhook), per-user secret ids embedding Firebase UIDs, and the KMS key path. `redact()` in the collector does not strip IAM `members`/`email`/resource `name`/the gcloud account stdout.
  Fix: stop tracking `security/evidence/*.json` (CI-artifact only) and purge from git history; OR extend `scripts/ops/collect-firebase-security-evidence.mjs` `redact()` to strip/hash IAM identities, project number, and resource names, then re-verify. Reconcile `docs/security/FIREBASE_SECURITY_EVIDENCE.md`'s "redacted" claim with reality.
  Acceptance: no tracked file contains owner email / raw project number / Secret Manager names; collector redaction covers IAM members + resource names; history scrubbed if the repo is public-facing.

### Live Critical/High code risks

- **T-TOOL-02 | YOLO emits `--dangerously-skip-permissions` and runs unsandboxed shell at full user privilege** — current status: **Open / Critical**.
  Fix: require a fresh local-auth proof at flag-emission / shell-exec time (not only at grant minting) and enforce a per-N-action reauth cadence on `runShellUnrestricted`; gate `isYOLOGrant` flag emission on proof freshness.
  Acceptance: a single active trusted/all-caps grant cannot run an unbounded sequence of `/bin/zsh -lc` commands without re-presenting a proof; tests cover the reauth cadence and the no-proof denial.

- **T-AI-07 | Unrestricted shell obeys injected instructions under YOLO (injection-to-RCE)** — current status: **Open / High**.
  Fix: add prevention (per-action proof / rate threshold feeding `updateKillSwitch`) ahead of the audit-only command-hash record at `OpenAICompatibleChatGatewayClient.swift:367-393`.
  Acceptance: an injected shell loop triggers an escalating signal/kill, not just N independent log lines; audit becomes prevention-backed.

- **T-TOOL-01 | External CLI agents run with no in-process policy gate** — current status: **Open / High**.
  Fix: document the accepted residual explicitly (BurnBar cannot interpose per-tool-call once a CLI is spawned) and tighten the default presets so workspace/all/YOLO require explicit opt-in; consider a broker-only execution mode for high-trust tasks.
  Acceptance: default-deny posture verified; the agency boundary is a written, accepted limitation with preset minimization.

- **T-AI-01 | CU tool results outside the 2-tool allowlist injected raw into model context** — current status: **Open / High**.
  Fix: convert `shouldWrapUntrustedComputerUseResult` from a positive 2-tool allowlist to default-deny — wrap ALL tool results (file/shell/screenshot/clipboard) as untrusted, mirror in the daemon Anthropic executor.
  Acceptance: every non-trusted tool result reaches the model wrapped; a test asserts `workspace_read_file`/`shell_run` output is wrapped.

- **T-AI-02 | Oracle "authoritative findings" inject unwrapped indexed snippets** — current status: **Open / High**.
  Fix: wrap the oracle snippet body via `LLMSafeContent.wrapUntrusted` and stop framing it as "authoritative local search results" at `ChatSessionController.swift:1609-1614`.
  Acceptance: oracle-path content is delimiter-defanged and provenance-tagged exactly like the retrieval pack; no "treat as authoritative" framing.

- **T-TOOL-03 | Grant revocation does not terminate in-flight CLI agent** — current status: **Open / High**.
  Fix: make `revokeDesktopControl` terminate spawned `Process` instances for the CLI lane (mirror the broker-lane `grantStillActive()` re-check) so revoke == kill.
  Acceptance: revoking an active YOLO CLI run terminates the subprocess; a test proves the process exits on revoke, not only on stream teardown.

- **T-TOOL-04 | Panic/kill coordinator compiled out of the MAS distribution build** — current status: **Open / High** (residual Medium).
  Fix: provide a MAS-available emergency stop (in-app panic control / lock-screen-safe kill) so the shipped MAS build is not limited to the remote/coordinator kill switch.
  Acceptance: MAS build exposes a local emergency stop; `ComputerUsePanicHaltCoordinator` (or equivalent) is reachable under `DISTRIBUTION_MAS`.

- **T-TOOL-05 | CLI lane does not tag repo/tool/web content as untrusted** — current status: **Open / High**.
  Fix: where feasible, tag content the CLI itself ingests; otherwise document the interposition boundary and minimize workspaceWrite/shell presets.
  Acceptance: the only-chat-turn-is-wrapped limitation is documented and the high-authority presets require explicit opt-in.

- **T-DMN-01 | Compromised first-party app is fully trusted by the daemon (code-sign == authZ)** — current status: **Partial / High**.
  Fix: add per-op capability attenuation on the main control socket and a daemon sandbox so a compromised signed app cannot get full RPC (run dispatch + config writes + provider creds + HID).
  Acceptance: the main socket enforces scoped capabilities, not all-or-nothing; daemon runs under a seatbelt profile limiting blast radius.

- **T-DMN-02 | Daemon runs unsandboxed as login user with broad filesystem access** — current status: **Open / High**.
  Fix: add `ENABLE_HARDENED_RUNTIME` + `CODE_SIGN_ENTITLEMENTS` to `OpenBurnBarDaemonExecutable` in `project.yml` (matching the two privileged helpers) and apply a runtime seatbelt profile.
  Acceptance: the daemon binary ships with hardened runtime + minimized entitlements + a seatbelt profile; home-dir/cred access is constrained at the OS layer.

- **T-CVS-03 / T-IOS-09 / T-AND-01 | Identity/vault private key extractable on a compromised unlocked endpoint (no SE/biometry/StrongBox binding)** — current status: **Open / High (T-CVS-03, T-IOS-09); Medium (T-AND-01)**.
  Fix: bind CloudVault/Signal-identity keys to Secure Enclave / StrongBox with per-use auth, reusing the F2 hardware-keystore pattern already in `PhoneControlSecureEnclaveKeystore.kt:121` / `PhoneControlAuthoritySigningKey.swift`. (NI: the fix pattern exists in-tree and was simply not applied to vault/Signal/relay custody.)
  Acceptance: vault/identity keys are hardware-bound and non-extractable; Keychain/AndroidKeyStore specs set `kSecAttrAccessControl`/`setUserAuthenticationRequired`/`setIsStrongBoxBacked` for these keys.

- **T-IOS-02 | Unlocked iPhone full access** — current status: **Open / High**.
  Fix: add an app-level auth gate / re-auth on sensitive surfaces at `AuthGateView.swift:88-97`.
  Acceptance: an unlocked-but-unauthenticated session cannot reach full app data without a local-auth step.

- **T-PRV-01 | VoIP/call push leaks cleartext caller display name + call graph to Apple & Google** — current status: **Open / High**.
  Fix: minimize the APNs/FCM payload — generic labels, drop `connection_id`/`paired_device_id`/`caller_name`/`caller_initial`, use a fresh per-push correlation id between queue and provider (`voipPush.ts:39-76`, `apnsSender.ts`).
  Acceptance: provider-bound push payloads carry no caller identity or stable device/connection correlators; a test asserts minimization between queue doc and provider request.

- **T-PRV-02 | Push-queue root collections never deleted on account erase, no TTL** — current status: **Open / High**.
  Fix: stamp `expireAt` on `voip_outbound`/`fcm_outbound` with a `ttl:true` field override, and enumerate the top-level push queues in `eraseUserCloudData`.
  Acceptance: account deletion removes all push-queue docs for the uid; queue docs carry a TTL; `firestore.indexes.json` has the override.

- **T-PRV-03 | Client crash reports (iOS+macOS) ship to Sentry with no scrubber/consent** — current status: **Open / High**.
  Fix: add `beforeSend`/`beforeBreadcrumb`/`maxBreadcrumbs`, set `sendDefaultPii=false`, disable screenshot/view-hierarchy/network-body breadcrumbs, and stop seeding the user id from `NSFullUserName()` before hashing (`AgentLensApp.swift:1176-1195`, `OpenBurnBarMobile/App/AppDelegate.swift:60-79`).
  Acceptance: all three client Sentry inits carry a scrubber + PII-off + bounded breadcrumbs; no real account name reaches Sentry.

- **T-SC-03 | Single CODEOWNER = no separation of duties** — current status: **Open / High**.
  Fix: add a genuine second code owner to `.github/CODEOWNERS` for sensitive paths (workflows, `firestore.rules`, release). (NI: the addendum's claimed second owner at `CODEOWNERS:29-58` does not exist; the file is 22 lines.)
  Acceptance: `.github/CODEOWNERS` names ≥2 distinct owners on sensitive paths; branch protection requires code-owner review (deployed-state, confirm out-of-band).

- **T-ATT-01 | Decompression/oversize resource exhaustion via lied-about Mercury `manifest.size`** — current status: **Open / High**.
  Fix: add a streaming byte ceiling in `fetch_blob` (`blobs.rs`) and a post-fetch `actual == manifest.size` reject before committing to the inbox; charge the daily cap against actual bytes, mirroring the cloud GCS `observedByteCount===byteCount` check.
  Acceptance: a 1KB-advertised / multi-GB-committed blob is aborted before disk-fill; a test covers the oversize/size-lie reject on the Mercury path.

---

## Should fix before launch

Medium-severity live risks that materially affect confidentiality, downgrade resistance, or privacy in
the shipping product, plus the high-value first-contact pairing residual.

- **T-TRN-01, T-PTR-03 | First-contact iroh host-key TOFU still default-off (cold-start cloud MITM)** — current status: **Partial / High**.
  Fix: wire the host-key safety-number compare UI (the `safetyCodeForConfirmation` plumbing already exists) and flip `IrohHostKeyPinEnforcementFlag.defaultEnabled` to true. (Post-pairing key-change is already always-refused.)
  Acceptance: a never-yet-pinned device requires out-of-band safety-number confirmation before admitting a server-served host key; the compare UI ships and the default is ON for store builds.

- **NI / T-TRN-01, T-PTR-03 | First-use safety-number confirmation is the only first-contact defense and has no compare UI** — current status: **Low (newly-introduced residual)**.
  Fix: same as above — the gate cannot be safely flipped ON until UI consumes `safetyCodeForConfirmation`.
  Acceptance: UI surfaces the safety code at first pairing; flag default flip is unblocked.

- **T-TRN-02 | Cloud-controlled inbound allowlist admits attacker or locks out owner** — current status: **Open / High** (impact bounded to handler reachability + DoS).
  Fix: add a local/out-of-band confirmation or admission high-water-mark over the Firestore controllers list so a compromised backend cannot silently inject/delete controller docs.
  Acceptance: a controllers-doc injection by a write-capable backend does not by itself admit a peer; owner-DoS via deletion is detectable.

- **T-TRN-03 | Attacker-induced silent downgrade iroh→Firestore** — current status: **Open / High** (metadata-exposure impact).
  Fix: add an in-code fallback-RATE alarm/threshold (the per-event `.fallbackToFirestore` audit exists but no rate gate), and consider hard-failing control-plane/CLI streams on repeated downgrade like the chat path.
  Acceptance: sustained iroh→Firestore fallback raises an alarm; control-plane downgrade is rate-gated.

- **T-CRY-01 | Gateway lane crypto downgrade v3→v2 via server-supplied version advertisement** — current status: **Open / Medium**.
  Fix: add a client-side version floor that refuses v2 once v3 has been negotiated (the `HermesGatewayVersionFloorStore` referenced by the addendum is not at HEAD — land it).
  Acceptance: a server advertising `[2]` after v3 negotiation is refused; a test covers the floor.

- **T-CRY-02 | Pi-agent relay request lane has NO sender authentication (v1 ephemeral-static wrap)** — current status: **Open / Medium**.
  Fix: add pinned-sender binding + a per-lane replay cache to `PiAgentCloudRelayHostService.decryptRelayRequest`.
  Acceptance: a relay request not bound to a pinned sender is rejected; replays are dropped.

- **T-CVS-01 | Server strips `signalEnvelope` to force unauthenticated legacy decode** — current status: **Open / Medium**.
  Fix: add a per-doc "Signal-required" pin so a stripped/absent envelope fails closed rather than falling through to legacy `sealedPayload` (`AssistantChatHistoryStore.kt:817,853-854`).
  Acceptance: removing `signalEnvelope` from a Signal-pinned doc fails closed; this lands as part of removing the legacy floor post-activation.

- **T-CVS-02 / T-AND-04 | senderNotTrusted legacy downgrade window during rollout** — current status: **Open / Medium (T-CVS-02); Partial / Medium (T-AND-04)**.
  Fix: replace the `trustedSenderPublicKeys.size > 1` heuristic with a real "published set complete" signal, and stop letting a transient `escrow_devices` fetch failure (`runCatching → size==1`) re-open legacy eligibility.
  Acceptance: single-peer/transient-fetch-failure cases no longer downgrade to unauthenticated legacy; readiness is derived from an explicit published-set marker.

- **T-CVS-04 | Weak/empty passphrase + low-iteration recovery bundle brute-forced offline** — current status: **Open / Medium**.
  Fix: raise `recoveryBundleIterations` toward OWASP 600k, add a passphrase-strength gate on export, and enforce an import-side iteration floor (`DatabaseEncryptionService.swift:148,161-166,223-240`).
  Acceptance: empty/weak passphrases are rejected on export; import refuses below-floor iteration counts.

- **T-CVS-05 | No forward secrecy for at-rest sealing** — current status: **Open / Medium** (deferred decision).
  Fix: epoch/ratchet the at-rest content-key wrap rather than wrapping to the static recipient identity key (currently a deferred decision in REMEDIATION).
  Acceptance: a future identity/vault-key compromise does not retroactively decrypt all prior sealed docs; or the deferral is re-confirmed as an explicit accepted decision.

- **T-AZ-03 | Metadata leakage in sealed cloud sync** — current status: **Partial / Medium** (accepted-by-design).
  Fix: document the cleartext-metadata (counts/timestamps/deviceIds/fingerprints) and Admin-SDK visibility as an explicit accepted property; consider minimizing high-signal fields.
  Acceptance: the accepted-by-design boundary is written and signed off; no claim implies metadata confidentiality.

- **T-AZ-04 | Plaintext secret in a non-denylisted field** — current status: **Partial / Medium**.
  Fix: broaden beyond the 12 exact top-level names toward structural sealing / allowlist-by-default, backed by client unit tests.
  Acceptance: a secret under an arbitrary/nested key is caught by defense-in-depth (client tests + rules), not only by the fixed denylist.

- **T-AZ-05 | Admin-SDK rule-bypass via callable missing ownership check** — current status: **Partial / Medium**.
  Fix: add per-endpoint BOLA/negative tests for the ~110 authScoped callables so the documented ownership convention is enforced, not just inventoried.
  Acceptance: each authScoped callable has a negative cross-tenant test; the matrix drift test stays green.

- **T-AI-06 | No content-level secret redaction before sending prompts to model providers** — current status: **Open / Medium**.
  Fix: add a redaction step on the chat prompt-assembly / provider-call path (the existing redactor is display-only at `CLIProfileStreamFailoverRunner.swift:260`).
  Acceptance: API keys/tokens in transcripts/RAG/file-reads are redacted before the provider call; a test asserts redaction on the send path.

- **T-AI-03 | Memory/RAG poisoning via parsed third-party agent logs** — current status: **Partial / Medium**.
  Fix: add write-time provenance/trust-tier + poisoned-chunk quarantine at LogParser ingestion, and close the oracle-path bypass (see T-AI-02).
  Acceptance: ingested log chunks carry a trust tier; the oracle path no longer bypasses write-time wrapping.

- **T-AI-04 | Browser SSRF via redirect / JS-nav / click after validated goto, and DNS rebinding** — current status: **Open / Medium**.
  Fix: re-validate host on every navigation (redirect/meta-refresh/JS-nav/click) and enforce resolved-IP (post-DNS) policy, not just the initial goto URL (`ComputerUseRunCoordinator.swift:785-786`, `OpenBurnBarPlaywrightDriver.swift:241-247`).
  Acceptance: a 302/meta-refresh/JS redirect to an internal/private-resolving host is blocked; resolved-IP enforcement covers DNS rebinding.

- **T-TOOL-06 | Queued grant authority public key sourced from cloud Firestore (TOFU)** — current status: **Partial / Medium**.
  Fix: strengthen first-pin trust (the controller pin-store already refuses mismatch); document dependence on pin enforcement + `firestore.rules` write protection.
  Acceptance: a pre-first-pin key seed cannot forge grants once pin enforcement is on; the residual is documented as deployed-state-dependent.

- **T-TOOL-07 | Non-trusted workspace preset authorizes autonomous shell** — current status: **Open / Medium**.
  Fix: document that codex `--sandbox workspace-write` / droid `--auto medium` confer autonomous in-workspace execution under the CLI's own sandbox, which BurnBar cannot verify; minimize these presets.
  Acceptance: the autonomous-execution-without-YOLO property is a written, minimized, accepted limitation.

- **T-PRV-04 | Server log scrubber is pattern-based; numeric/non-pattern PII bypasses** — current status: **Open / Medium**.
  Fix: move toward allowlist-by-default, add primitive-agnostic redaction (numbers/booleans), broaden provider-token patterns, and scrub free-form `String(error)` in `logCallableFailure`.
  Acceptance: numeric PII and non-prefixed provider keys are redacted; free-form errors are body-aware-scrubbed.

- **T-PRV-05 | Encrypted-search metadata: facets + posting graph + access patterns enable inference** — current status: **Open / Medium**.
  Fix: add padding/dummy postings and reduce cleartext facets (provider/device); consider oblivious access.
  Acceptance: frequency+facet analysis no longer trivially reveals providers/device/timeline; padding is in place or the residual is explicitly accepted.

- **T-AZ-06 | App Check console enforcement not provable from code** — current status: **Unverifiable / Medium** (deployed-state — see "Deployed-state evidence owed").

- **T-DMN-03 | User-writable daemon binary; pre-exec signature check is TOCTOU; app does not validate daemon** — current status: **Partial / Medium**.
  Fix: make the installed daemon binary non-user-writable (root-owned), and make the app's socket client validate the daemon's audit-token code signature symmetrically (it currently trusts only a same-uid Keychain bearer token — see NI bidirectional-validation finding).
  Acceptance: a same-uid swapped daemon cannot win the KeepAlive race and impersonate the daemon to the app; binary is not 0o755 user-writable.

- **NI / T-DMN-03 | RR-3 main-socket peer auth is one-directional; app does not validate the daemon's code signature** — current status: **Medium (newly-introduced)**.
  Fix: make the main daemon socket client perform an audit-token `SecCode` check on the daemon (as `PrivilegedInputXPCClient` already does), or correct the `BurnBarDaemonPeerAuthenticator` docstring that overstates bidirectional validation.
  Acceptance: app↔daemon validation is symmetric on the main socket, OR the docstring no longer claims bidirectional validation for that lane.

- **T-DMN-04 | Daemon does not cryptographically re-verify the phone single-use local-auth proof** — current status: **Open / Medium (High if app compromised)**.
  Fix: have the daemon independently verify the op-hash-bound Ed25519 phone proof (hold the phone verifying key) rather than trusting app integrity.
  Acceptance: a compromised app cannot satisfy the daemon's shell/system-input gate without a valid phone proof verified by the daemon.

- **T-DMN-05 | Production env escape hatch disables peer code-sig enforcement** — current status: **Partial / Medium**.
  Fix: add a regression test for the disabled path and consider removing/guarding the `*_DISABLE_PEER_CODESIG` opt-out from released binaries.
  Acceptance: the disabled-gate path is test-covered; the opt-out is not silently available to anyone who can influence the launchd environment.

- **NI | Daemon opens the shared SQLite DB in disclosed-plaintext when no SQLCipher codec is linked** — current status: **Medium (newly-introduced)**.
  Fix: ensure the shipped daemon links a `SQLITE_HAS_CODEC` SQLite (or fail-closes like the app's GRDB path) so `~/Library/.../openburnbar.sqlite` is never plaintext on disk.
  Acceptance: the daemon either encrypts the shared DB or refuses to write it; verified against the released daemon binary (deployed-state).

- **T-AND-02 | Android base-config cleartext permits HTTP to non-deny-listed hosts** — current status: **Partial / Medium**.
  Fix: implement the tracked LAN-direct TLS migration so `cleartextTrafficPermitted="true"` can be removed from `network_security_config.xml`.
  Acceptance: cleartext is removed from base-config; LAN-direct uses TLS; only deny-listed-by-default backends remain.

- **T-IOS-01 | App-Group data readable on locked device** — current status: **Open / Medium**.
  Fix: apply Data Protection (`completeUntilFirstUserAuthentication`/`complete`) to App-Group artifacts (`BurnBarWidgetSnapshot.swift:91`, `TextExpansionInbox.swift:36`).
  Acceptance: App-Group data is not readable on a locked device.

- **T-IOS-03 | Screen-privacy guard: non-mirror recordable** — current status: **Partial / Medium**.
  Fix: extend the screen-privacy guard to non-mirror capture paths.
  Acceptance: sensitive surfaces are protected against non-mirror recording.

- **T-IOS-04 | Lock-screen/APNs leak** — current status: **Open / Medium**.
  Fix: minimize lock-screen notification content (`AgentReplyNotificationService.swift:187-199`).
  Acceptance: no sensitive body/identity surfaces on the lock screen / in APNs payloads.

- **T-IOS-05 | Pasteboard token leak** — current status: **Open / Medium**.
  Fix: mark sensitive pasteboard items ephemeral/local-only and clear them (`NestHubSettingsCard.swift:584`).
  Acceptance: tokens copied to the pasteboard are not persisted/handoff-shared and are auto-cleared.

---

## Hardening

Low / Info residuals and defense-in-depth improvements with limited blast radius.

- **T-TRN-04 | Metadata exposure to cloud (NodeIds, relay URL, direct IPs, timing, sizes)** — Open / Medium → hardening. Consider NodeId rotation / metadata minimization in the pairing directory; payload stays E2E-sealed.
- **T-TRN-05 | Stale/replayed pairing record steers iOS to dead/hijacked NodeAddr** — Open / Medium. Add a per-record nonce / monotonic counter / session-challenge binding to shrink the ~3-min replay window.
- **T-TRN-06 | DoS via connection flood / post-handshake allowlist rejection** — Open / Medium. Add a per-source connection-rate limit / concurrent-handshake cap in `crates/openburnbar-iroh`.
- **T-TRN-07 | Production E2E transport on iroh 1.0.0-rc.0** — Open / Low. Track the GA release and bump off the release candidate; exact-version pins already prevent drift.
- **T-PTR-01 | Revocation leaves pre-revocation vault key un-clawed-back** — Open / Medium. Consider a claw-back / shorter survivor-rotation SLA; new wraps are already blocked at revoke.
- **T-PTR-02 | Rotation requirement starves on uneven survivor-pickup trigger coverage** — Open / Medium. Add iOS survivor rotate-pickup and per-foreground (not Devices-screen-gated) Android pickup; consider server-nudged rotation.
- **T-PTR-04 | Approve-time safety-code compare UI defaults OFF** — Open / Medium. Wire and default-on the escrow safety-code compare (`EscrowDeviceTrustSafetyCheckFlag`).
- **T-PTR-05 | TOFU first-pairing window on controller key when gate force-disabled** — Open / Low. Resist UserDefaults/MDM override of the secure-default ON gate.
- **T-PTR-06 | Client-writable `cloud_vault_key_wrappers` lacks generation-monotonicity / rotation-job binding in rules** — Open / Low. Add a monotonic `vaultGeneration` advance + rotation-job binding in `firestore.rules`.
- **T-AI-05 | Insecure output handling: model JSON rendered as missions/recommendations** — Partial / Low. Add semantic safety validation of suggested missions/actions beyond the structural envelope.
- **T-TOOL-08 | Path-based deny rules (/admin,/billing) use heuristic window-title regex** — Open / Low. Use robust URL-prefix matching for SPA routes; high-value SSRF/metadata/file/OAuth denies are already robust.
- **T-TOOL-09 | Local `grantDesktopControl` bypasses the signed `apply()` admission path** — Open / Low. Add internal defense-in-depth to `grantDesktopControl` (it currently relies on the caller's fail-closed LAContext).
- **T-TOOL-10 | `shell_run` sandbox permits general reads outside the curated deny list** — Open / Low. Move toward an allowlist for reads; `(deny network*)` already constrains exfiltration.
- **T-DMN-06 | HID root-bridge peer trusted by code-signature alone (no UID anchor)** — Open / Low. Accepted defense-in-depth; optionally add a console-user UID anchor for the root branch.
- **T-DMN-07 | Audit token read via private KVC selector (SPI fragility)** — Open / Low. Fails closed if the SPI is removed; the LOCAL_PEERTOKEN socket path is the robust primary. Monitor OS SPI availability.
- **T-DMN-08 | HPKE AEAD AAD intentionally empty (context binding via HPKE info only)** — Mitigated-in-code / Info. No action; re-run crypto tests on any change to the info-binding.
- **T-CVS-06 | Legacy v1 AAD/no-AAD open path weakens domain separation** — Open / Low. Enforce a v1-accept cutover removing the no-AAD branch once legacy docs are migrated.
- **T-CRY-03 | Anti-replay high-water-mark stored in a deletable plaintext file** — Open / Low. Add a tamper-evident/monotonic anchor outside the JSON file.
- **T-CRY-04 | Pinned public-key equality is non-constant-time** — Open / Info. Cosmetic (public keys); optionally constant-time for completeness.
- **T-CRY-05 | KCI / static-key compromise (accepted non-goal)** — Open / Low. Documented accepted non-goal; no action unless the threat model changes.
- **T-AZ-02 | Shared-artifact write into another tenant's workspace path** — Mitigated-in-code / Low. Add an emulator test + production rules-deploy proof (the binding is already enforced in rules).
- **T-AZ-07 | Operator custom-claim (burnbarOperator) trust breadth** — Unverifiable / Low. Claim-issuance custody is out of repo scope; document and gate issuance (deployed-state).
- **T-AZ-08 | Unauthenticated public HTTP endpoints** — Open / Info. Consider a per-IP rate limit; `maxInstances` is the sole spend guard today; payload is intentionally public.
- **T-GW-01 | HTTP gateway edge has no App Check; auth is bearer+PoP only** — Mitigated-in-code / Low. Accepted (non-Firebase clients); requires theft of both bearer + PoP key.
- **T-GW-02 | PoP body-hash binding covers only JSON body, not raw/multipart** — Partial / Low. Add a `req.is('application/json')` / 415 reject if a raw-body signed route is ever introduced.
- **T-GW-04 | Entitlement read fired detached before client-doc validation** — Mitigated-in-code / Info. No security impact; ordering is documented.
- **T-GW-05 | Events list filters `targetClientId` in app code, not Firestore where-clause** — Partial / Low. Add the `where('targetClientId','==',...)` constraint to remove the post-fetch-filter regression risk (same-tenant only today).
- **T-GW-06 | Stale-token index deletion is best-effort/racy** — Mitigated-in-code / Info. Authoritative `tokenHash` compare already governs; no action.
- **T-GW-07 | Non-constant-time `tokenHash !==` comparison** — Open / Info. Reuse the existing `safeEqualHex` for the tokenHash compare (trivial).
- **T-SC-01 | Mutable action tags enable CI compromise** — Mitigated-in-code / Medium. Pin set + enforcing verify gate landed; ensure the gate is a REQUIRED check on a protected branch (deployed-state).
- **T-SC-02 | Provenance lane ecosystem-deny silently no-ops** — Partial / Low. Install cargo-deny/osv-scanner in the provenance lane (or remove the misleading "passed" summary); real gates run elsewhere. Add a `deny.toml` for burnbar-remote.
- **T-SC-04 | Cargo.lock / SwiftPM / Gradle locks not OSV-scanned** — Partial / Medium. Add OSV coverage for `Package.resolved`, vendored libsignal lock, and build-helper Cargo.locks (SwiftPM is the largest gap).
- **T-SC-05 | xcframework lacks rebuild-parity gate** — Open / Low. Add a parity/diff gate if the vendoring policy ever changes to commit the binary (currently gitignored).
- **T-SC-06 | GPG checksum signing best-effort, not enforced** — Open / Medium. Add `RELEASE_SIGNING_KEY` to the strict-secret gate so unsigned checksums fail the release; cosign attestations partly compensate.
- **T-SC-07 | firebase.json predeploy runs arbitrary npm build with deploy creds** — Open / Low. Separate the credentialed deploy step from the build step; `npm ci` + deploy-from-tag already mitigate.
- **T-SC-08 | Provenance SBOM attests source tree, not as-shipped bytes** — Partial / Low. Make the standalone provenance lane attest the downloaded artifact bytes; the primary release lane already binds as-shipped bytes.
- **T-SC-09 | workflow_run runs in trusted context off external workflow success** — Open / Low. Acceptable (no untrusted-artifact execution); strengthen the tag-prefix gate if desired.
- **T-SC-10 | Agentic droid `--skip-permissions-unsafe` in CI** — Open / Low. Add an explicit `permissions: contents: read` floor to `droid-wiki-refresh.yml`.
- **T-ATT-02 | iOS received media stored plaintext at rest (no seal/quarantine/gate)** — Open / Medium. Wire capability gate + at-rest seal + quarantine + FileProtection into the iOS Mercury receive path (Mac path is hardened).
- **T-ATT-03 | Wire-manifest filename/mime/size leak metadata if frame not E2EE-sealed** — Open / Medium. Seal the advertise-frame manifest at the application layer; confidentiality currently rests on the iroh transport only.
- **T-ATT-04 | Unauthenticated Mercury manifest metadata (no MAC/signature)** — Open / Medium. Land the Mercury manifest MAC (absent at HEAD; on another branch) to bind filename/mime/size to the bytes.
- **T-ATT-05 | Content-type trust on display via extension-only `inferMime`** — Open / Low. Add receiver-side content sniffing for Mercury-received bytes; iOS has no Gatekeeper-on-open equivalent.
- **T-ATT-06 | Seal-at-rest silently skipped when no media session key (fail-open)** — Partial / Medium. iOS has no seal at all; add iOS at-rest seal and reconsider the fail-open posture when no key is negotiated.
- **T-ATT-07 | Legacy content-type denylist incomplete and largely dead** — Open / Info. Convert to an allowlist; impact minimal while sealed uploads force octet-stream.
- **T-ATT-08 | Gateway download URL lacks forced Content-Disposition/Content-Type** — Open / Low. Add `responseDisposition=attachment` + `responseType=application/octet-stream` to the v4 read signed URL.
- **NI / T-ATT family | Mercury inbox path-traversal surface mitigated only by blobHash-derived filename** — Low (newly-introduced). Sanitize/allowlist the manifest-derived extension; the blobHash base neutralizes the primary traversal vector today.
- **T-IOS-06 | Keyboard snippet injection** — Open / Low. Validate/sanitize injected snippets (`KeyboardViewController.swift:44-61`).
- **T-IOS-07 | Forced navigation via deep link** — Open / Low. Treat deep links as navigation-only (mirror Android's no-auto-submit posture).
- **T-IOS-08 | Latent keylogger (keyboard extension full-access)** — Open / Low. Minimize/justify keyboard full-access (`OpenBurnBarKeyboard/Info.plist:31-32`).
- **T-IOS-10 | Jailbreak bypass** — Open / Info. Best-effort jailbreak detection; treat as non-security-critical.
- **T-IOS-11 | Unswept files** — Open / Low. Sweep transient files (`MobileDataProtectionBootstrap.swift:5,43`).
- **T-AND-03 | Exported deep-link / widget / IME / wallpaper attack surface** — Mitigated-in-code / Low. Add a custom signature permission for widget `APPWIDGET_UPDATE` (cosmetic-only residual).
- **T-AND-05 | Remote Unlock saved-credential read not code-coupled to biometric prompt** — Mitigated-in-code / Low. Add a compile-time binding + a unit test exercising the store (OS-level user-auth binding already enforced).
- **T-AND-06 | Crash/observability pipeline may capture sensitive in-memory data** — Partial / Low. Add a programmatic Sentry `beforeSend` PII scrubber; Crashlytics defaults ON.
- **NI / T-AND-01 | Cloud-vault/Signal/relay key custody not upgraded alongside F2 hardware-keystore work** — Medium (newly-introduced). Apply the existing StrongBox/TEE + user-auth pattern to vault/Signal/relay keys (see T-CVS-03 above).
- **NI / T-AND-05 | `RemoteUnlockSavedCredentialStore.load()` blanket-catches `Throwable`** — Low (newly-introduced). Narrow the catch and surface auth-required distinctly from absence.
- **NI / T-AI-07 | `runShellUnrestricted` audit log records command hash but no injection/rate signal** — Low (newly-introduced). Feed a per-run command-count/rate threshold into `updateKillSwitch` to convert attribution into early detection.
- **NI / T-TRN | Host-key pin clear does not invalidate the in-memory PublicKeyCache** — Low (newly-introduced, robustness). Clear `PublicKeyCache` in `clearHostKeyPin` so a re-pair adopts the new key without app relaunch.
- **NI / T-SC | cosign attestations use keyless signing with no verify-time identity/Rekor policy** — Low (newly-introduced). Document/enforce a `cosign verify-attestation --certificate-identity --certificate-oidc-issuer` policy for consumers.
- **NI / T-SC | cosign SLSA-typed attest silently degrades to untyped on failure** — Info (newly-introduced). Remove the `|| cosign attest` untyped fallback so a typed-attest failure surfaces.
- **NI / T-SC | cargo-audit / cargo-deny ignore-list duplicated across files, drift-prone** — Info (newly-introduced). Single-source the RUSTSEC ignore list; add a `deny.toml` for burnbar-remote.
- **NI / T-SC | Task/addendum reference scripts/docs that do not exist (`verify-supply-chain-hardening.sh`, a second CODEOWNER)** — Info (newly-introduced). Remove the non-existent references from the package; do not treat them as evidence of implemented controls.
- **NI / T-PRV | `cloud_vault_rotation_required` FCM payload sends a stable vault-key id to Google and persists in the no-TTL/no-erasure `fcm_outbound` queue** — Low (newly-introduced). Fold into the T-PRV-02 push-queue TTL + account-erase remediation; reconsider whether `current_vault_key_id` belongs in a cleartext push.
- **NI / T-SC | PR-triggered vendored-agent-provenance job git-clones an arbitrary repo URL from a PR-modifiable manifest** — Low (newly-introduced). Pin/allowlist `manifest.forkRepository` to the expected host before cloning; require CODEOWNERS review on the manifest.
- **NI / T-SC | Cursor nightly CI-repair workflow feeds attacker-influenceable CI failure logs into an autonomous coding agent that opens PRs** — Low (newly-introduced). Wrap injected CI logs with provenance/delimiters; keep the read-only token; ensure branch protection + required checks + CODEOWNERS gate the repair-PR path.

---

## Deployed-state evidence owed

These cannot be confirmed from the repo (live IAM, console toggles, Remote Config, deployed Functions
revisions, TTL indexes, branch protection, release env). For each, BurnBar must supply out-of-band
evidence; the repo defaults are noted where they fail-closed.

- **T-AZ-06 | App Check console enforcement** — Unverifiable / Medium. Callables fail-closed in prod, but SDK/rules App Check on the Firestore/Storage datapath is a console toggle. Owed: screenshot/API proof App Check enforcement is ON for Firestore + Storage in prod.
- **T-AZ-07 | Operator custom-claim issuance custody** — Unverifiable / Low. Owed: who can mint `burnbarOperator`, and the issuance audit trail.
- **T-DMN-01 | Daemon first-party signing/notarization in production** — Owed: proof the shipped daemon is genuinely first-party-signed + notarized (the code-sign gate is only meaningful if so).
- **T-DMN-05 | Live launchd job does not set `*_DISABLE_PEER_CODESIG`** — Owed: confirmation the deployed launchd job/plist env never sets the disable flag.
- **NI (T-CVS) | Shipped daemon links a `SQLITE_HAS_CODEC` SQLite** — Owed: probe of the released daemon binary confirming the shared DB is encrypted, not plaintext.
- **T-SC-01 | Pin-verify gate is a REQUIRED check on a protected branch** — Owed: branch-protection settings showing the pin-verify and required reviews are enforced.
- **T-SC-03 | Branch protection requires (≥2) code-owner review** — Owed: branch-protection config; note even ideal protection cannot synthesize a second reviewer CODEOWNERS does not name (fix the file first).
- **T-SC-06 | `RELEASE_SIGNING_KEY` configured in the live release env** — Owed: confirmation the key is set so GPG checksums are actually signed.
- **T-SC-10 | Default `GITHUB_TOKEN` scope for the droid workflow** — Owed: repo/org default token scope (set an explicit read-only floor regardless).
- **T-PRV-02 / NI push-queue | Firestore TTL policies actually delete queue/nonce docs** — Owed: deployed TTL policy state for `voip_outbound`/`fcm_outbound`/`pop_nonces`/`high_risk_nonces`.
- **T-CRY-01 / pairing replay | `ENFORCE_APP_CHECK` and `REQUIRE_HIGH_RISK_NONCE` runtime values in prod** — Owed: deployed Functions config (code defaults fail-closed in prod and refuse to boot prod without App Check, but the high-risk-nonce path fail-opens if the flag is off and no nonce is supplied).
- **T-AND-06 / T-PRV-03 | Sentry/Crashlytics server-side scrubbing + DSN configuration** — Owed: whether DSNs are set in prod and whether the deployed projects apply server-side scrubbing/retention.
- **C1 / C2 | Legacy plaintext drain status** — Owed: confirmation `backfillPrivacyPlaintextScheduled` is deployed and has converged across all users, and that no legacy schema-1 plaintext gateway/vault docs remain (requires a production data scan).
- **T-AZ-02 | Production rules-deploy proof + emulator test** — Owed: CI emulator test for the workspace-artifact binding and proof the deployed ruleset matches HEAD.

---

## MDASH 2026-06-14 follow-up roadmap

Derived from `security/threat-model/mdash-security-scan-report-2026-06-14.md`. Each item maps to `threat-status-2026-06-14.csv` IDs `MDASH-001`–`MDASH-038`.

### Must fix before any release (P0)

- **MDASH-001 | Panic kill switch not wired to root watchdog** — Fix: route `panicHalt()` through the root kill-switch watchdog socket (`/var/run/openburnbar-killswitch-watch.sock`) instead of the app directly writing `/var/run`. Acceptance: a panic from the phone/global hotkey sets the kill flag even when the app is unprivileged; privileged input stops.
- **MDASH-002 | Remote Unlock nonce ledger at `/var/run`** — Fix: move `capabilityTokenNonceLedgerPath` to a user-writable restricted directory (e.g., `~/Library/Application Support/OpenBurnBar/RemoteUnlock/`, mode `0700`) or an atomic root-owned store the user leaf can mark consumed. Acceptance: Remote Unlock tokens verify and consume successfully in a normal user LaunchAgent context.
- **MDASH-003 | Remote Unlock issuer trust at `/Library/Application Support`** — Fix: publish issuer trust through a privileged helper or a user-writable path the root bridge reads. Acceptance: the leaf verifier loads the issuer trust material on a standard user-account install.

### Should fix before launch (P1)

- **MDASH-004 | High-risk guard gaps** — Fix: route `approveHermesGatewayDeviceGrant`, all provider credential connect/update callables, `exportUserData`, `deleteUserCloudData`, `revokeAllAccess`, and `revokeRemoteMcpClient` through `enforceHighRiskComputerUseCallableWithNonce` and `requireTrustedDeviceActionProof` where applicable. Acceptance: each listed callable rejects requests without a fresh nonce + trusted-device proof.
- **MDASH-005 | Android iroh host-key pinning** — Fix: port `IrohHostKeyPinStore` to Android, persist with Keystore-wrapped storage, force `Source.SERVER`, and add key-swap adversarial tests. Acceptance: Android refuses a swapped host key after first pin.
- **MDASH-006 | CloudVault path-bound AAD** — Fix: tighten `validCloudSealedPayload`/`validCloudSealedText` to require exact `aad == cloudVaultAADContext(...)`; update all current writers to pass explicit AAD; add negative rules tests. Acceptance: global/mismatched AAD rejected for current collections.
- **MDASH-007 | Devices push-token injection** — Fix: restrict `users/{uid}/devices` to a strict allowlist, exclude push-token fields, and route push-token writes through a server-verified callable or server-only collection. Acceptance: owner client cannot inject `fcm_token`/`voipDeviceToken`.
- **MDASH-008 | Mission claiming spoofing** — Fix: make `claimedBy` server-stamped via a Mac-signed proof callable; treat `claimedBy` as immutable/server-only in rules. Acceptance: owner client cannot claim a mission as a trusted Mac.
- **MDASH-009 | Initial `cloud_vault_state` lockout** — Fix: make initial creation server-only or gate on trusted device + vault-key-knowledge proof. Acceptance: owner client cannot create initial state when no trusted device exists.
- **MDASH-010 | RR-13 HMAC claim drift** — Fix: add `assertRemoteMcpTokenIssuerPosture()` in Functions issuers; throw in production if HMAC is configured or Ed25519 missing. Acceptance: issuer rejects HMAC-only production config.
- **MDASH-011 / MDASH-012 | Local runtime environment inheritance** — Fix: apply `ClaudeInteractiveSessionExecutor.sanitizedEnvironment()` allowlist to all agent launches and set `process.environment` in sandboxed `shell_run`. Acceptance: child processes receive only explicitly needed env vars; no `OPENBURNBAR_*` secrets.
- **MDASH-013 | iOS host-key confirmation default-on** — Fix: wire the safety-number compare UI and flip `IrohHostKeyPinEnforcementFlag.defaultEnabled = true`. Acceptance: first pairing requires out-of-band confirmation.
- **MDASH-014 | Queued grants** — Fix: surface Mac approval UI for queued high-risk grants and re-check `escrow_devices/{sourceDeviceId}.trustState` before applying. Acceptance: queued grants from revoked devices are denied; trusted-device queued grants can be approved on the Mac.
- **MDASH-015 | CloudVault rotation survivor policy** — Fix: require survivor set to equal current trusted-device set or a server-generated rotation requirement. Acceptance: one device cannot exclude all others.
- **MDASH-016 | Accessibility revocation polling** — Fix: add a 5 s timer that calls `panicHalt(source: .accessibilityRevoked)` when `AXIsProcessTrusted()` becomes false. Acceptance: mid-session Accessibility revocation halts the session promptly.
- **MDASH-017 | Remote Unlock ack ordering** — Fix: validate authority/policy before emitting the accepted result. Acceptance: no accepted result precedes validation failure.

### Hardening (P2)

- **MDASH-018–020 | Endpoint matrix integrity** — Correct trigger types, add a `highRiskComputerUse` column, and enforce BOLA test references in CI.
- **MDASH-021 | `requireHighRiskNonce` default test** — Add a mirror test asserting production default is `true`.
- **MDASH-022 | Pairing completion guard** — Require high-risk nonce + trusted-device proof for `completeHermesPairing`/`completePiAgentPairing`, or document lower-risk rationale.
- **MDASH-023 | `session_logs` 1000-expression limit** — Simplify validators or split validation into callable; re-include test in CI.
- **MDASH-024 | `cloud_vault_key_wrappers` client writes** — Make server-only or require signed attestation/job ID.
- **MDASH-025 | Android `Source.SERVER`** — Force server fetch for iroh host key.
- **MDASH-026 | VoIP displayName bound** — Bound/sanitize `displayName` before APNs/FCM.
- **MDASH-027 | Agent notification reply schema** — Write `sealedSchemaVersion:2` and add rule/callable tests.
- **MDASH-028–029 | Capability-token binding** — Bind to escrow device + attestation; verify `scopeHash`; decrement `actionBudget`.
- **MDASH-030 | Executable signature verification** — Verify code signature/Team ID after resolving agent executables.
- **MDASH-031 | Passkey rate limiting** — Add per-IP/fingerprint rate limit to `beginPasskeyAssertion`.
- **MDASH-032–033 | Gateway hardening** — Enforce `relayCapable` in attachment init; align PoP v2 query canonicalization with Python client.

### Low / documentation

- **MDASH-034–038** — Document push `threadId` exposure; consider random provider secret-ref IDs; extend CLI prompt sanitizer; fix `deleteHostedQuotaCredentials` default provider; standardize `insightsHostedAnswer` auth helper.

---

## Recently closed (appendix)

Items whose current status is **Fixed** at HEAD (excluded from the active roadmap above).

- **T-GW-03 | Path/body swap under same nonce within 5-min window** — **Fixed / Low**.
  The PoP signature binds method/path/query(v2)/bodyHash/nonce/timestamp and the nonce is single-use (transactional create with TTL), so a same-nonce method/path/body/query swap fails `verifySignature` before nonce consumption. Test-backed (`hermesGatewayPopV2.test.ts:253,274-278`), with a v1→v2 downgrade refusal. Residual owed: deployed callable-revision proof (see "Deployed-state evidence owed").

> Note: 8 threats are **Mitigated-in-code** (T-DMN-08, T-AZ-02, T-GW-01, T-GW-04, T-GW-06, T-SC-01, T-AND-03, T-AND-05) — these remain in the active roadmap (Hardening / evidence-owed) per the derivation rule, because "Mitigated-in-code" is not "Fixed" and most still owe a deployed-state or test artifact.
