# SOTA Security Research (2026) — Remediation Seed

**Lane:** Opus 4.8 (1M) · **Date:** 2026-06-16 · Sourced from current (2025–2026) primary references. Every recommendation below maps to one or more verified findings in `01-VERIFICATION-REPORT.md`.

---

## 1. OWASP Top 10 for LLM Applications 2025 → maps to V-34, V-35, Computer-Use

Current official list (Nov 2024, valid through 2026): **LLM01 Prompt Injection** (#1, unchanged), **LLM02 Sensitive Information Disclosure**, **LLM03 Supply Chain**, LLM04 Data/Model Poisoning, LLM05 Improper Output Handling, **LLM06 Excessive Agency** (up from #8), LLM07 System Prompt Leakage, LLM08 Vector/Embedding Weaknesses, LLM09 Misinformation, LLM10 Unbounded Consumption. New **OWASP Top 10 for Agentic Applications** (Dec 9 2025): Agent Behavior Hijacking, Tool Misuse, Identity/Privilege Abuse.

OWASP LLM01 mitigations for tool-using agents (explicitly defense-in-depth, "no fool-proof prevention"): constrain behavior in system prompt; **validate output format with deterministic code, not the model**; input/output filtering as *one* layer; **least privilege — app holds its own tokens, functions handled in code**; **human approval for privileged/irreversible actions**; **segregate and tag untrusted external content**; adversarial testing.

- List: https://genai.owasp.org/llm-top-10/ · LLM01: https://genai.owasp.org/llmrisk/llm01-prompt-injection/ · v2025 PDF: https://owasp.org/www-project-top-10-for-large-language-model-applications/assets/PDF/OWASP-Top-10-for-LLMs-v2025.pdf · Agentic: https://genai.owasp.org/2025/12/09/owasp-genai-security-project-releases-top-10-risks-and-mitigations-for-agentic-ai-security/

**Implication:** BurnBar hits LLM01 (untrusted screen/tool/log content → model), LLM05 (model output → real HID keystrokes), LLM06 (mouse/keyboard agent = textbook excessive agency) simultaneously. The deterministic capability gate already satisfies "least privilege in code" + "human approval"; the gaps to close are **(a) wrap/tag all untrusted content as data, not instruction (V-34)** and **(b) keep deterministic Swift authorization load-bearing over any model-side filter.**

## 2. Prompt-Injection Defense SOTA 2026 → maps to V-34, Computer-Use hardening

Consensus is unambiguous: **input filtering/classifiers alone cannot stop prompt injection** — it is architectural, so the boundary must be deterministic and survive a 100%-compromised model. Stack, weakest→strongest:

- **Spotlighting** (Microsoft) — delimiting / **datamarking** (interleave marker token through untrusted text) / encoding. Cheap hardening; degrades under adaptive attack. https://arxiv.org/pdf/2403.14720 · https://www.microsoft.com/en-us/msrc/blog/2025/07/how-microsoft-defends-against-indirect-prompt-injection-attacks
- **CaMeL — "Defeating Prompt Injections by Design"** (Google DeepMind, arXiv 2503.18813) — architectural SOTA. Dual-LLM (privileged holds tools, quarantined reads untrusted, no tool access) + capability-tag provenance + **policies in deterministic code**. ~77% of AgentDojo *with provable security*. Computer-use follow-on: arXiv 2601.09923. https://arxiv.org/abs/2503.18813
- **Meta "Agents Rule of Two"** — a session may hold at most two of {untrusted input, sensitive data, state-change/external-comms}; all three → mandate human-in-the-loop.
- **"The Attacker Moves Second"** (DeepMind+OpenAI+Anthropic, 2025) — broke 12 published defenses; static "<2%" rose to >90% under adaptive attack. Why static-benchmark claims are rejected.
- **Anthropic / Claude Computer Use** — classifiers detect injection in screenshots + steer to confirm before acting; framed as *one layer* alongside confirmation + least-privilege. https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/mitigate-jailbreaks

**Implication:** BurnBar's capability tokens ≈ CaMeL capability tags; deterministic Swift dispatch ≈ CaMeL "policies in code." Concretely: LLM *proposes* HID actions, deterministic policy *authorizes* each against the active token (no token → no keystroke); **tag provenance** and force confirmation when untrusted-derived actions touch sensitive targets; apply Rule-of-Two as a runtime invariant; add spotlighting datamarking on screen-scrape/log text as cheap defense-in-depth, never as the guarantee. **For V-34: wrap the one remaining unwrapped path (`lastAssistantMessage`) with the existing `LLMSafeContent.wrapUntrusted` and add a regression test.**

## 3. SSRF Prevention SOTA → maps to V-24

Enforce at the **socket-connect point**, not URL-string validation: accept the smallest URL component and rebuild server-side; WHATWG `URL` parse; **allow-list scheme** (https only); **DNS-pin** (resolve once, validate the IP, connect to that exact IP — defeats rebinding/TOCTOU); **allow-list the resolved IP** (deny-lists are bypass-prone); block private/loopback/link-local/ULA/multicast and **cloud metadata** (`169.254.169.254`, `metadata.google.internal`) with a validated-IP library so decimal/octal/hex/dword/IPv6-mapped encodings can't slip; **disable redirects or re-validate every hop**; short timeouts, no retries. Native `fetch`/undici takes **no `http.Agent`** — use a custom **undici `Agent({ connect: { lookup } })`** that errors unless the resolved IP passes.

- https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html · https://owasp.org/www-community/pages/controls/SSRF_Prevention_in_Nodejs · undici#2019: https://github.com/nodejs/undici/issues/2019

**Implication:** On GCP the SSRF prize is the metadata server (hands out SA tokens). The guard (V-24) is **latent today** (no user-controlled fetch host), so this is "harden before the user-URL feature lands" — build one hardened client with the undici `connect.lookup` DNS-pin, parse host as integer before range checks, redirects disabled, strict host/IP allow-list for the fixed provider set.

## 4. Local At-Rest DB Encryption on macOS (same-user threat) → maps to V-30, V-31

Be blunt: SQLCipher is still the de-facto full-file SQLite encryption standard in 2026, **but against a same-user adversary on an unsandboxed Mac there is nowhere to put the key the adversary can't also reach** (process memory via `task_for_pid`/debugger; login Keychain hands items to any same-user process once unlocked — the documented Claude-Code `security find-generic-password` case). SQLCipher's real boundary is **offline / at-rest-while-locked / file-exfiltration-without-the-key**. The OS control that actually defends at-rest is **FileVault** (same boundary, free, system-wide).

Honest recommendation: **(1) move OAuth/refresh tokens OUT of SQLite into the Keychain** (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + code-signing `SecAccessControl` ACL); (2) SQLCipher the rest only to cover at-rest/exfil and shrink blast radius — accept it does nothing against same-user runtime; (3) rely on FileVault for lock-state; (4) redact secrets from logs; short token TTLs + revocability are the real mitigation. Never store the key in a file next to the DB.

- https://www.zetetic.net/sqlcipher/design/ · Apple Keychain data protection: https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web · Signal-for-Mac mistake: https://mjtsai.com/blog/2024/07/08/signal-for-macs-encrypted-database/ · MITRE T1555.001: https://attack.mitre.org/techniques/T1555/001/

**Implication:** Don't over-invest in vendoring SQLCipher as a "fix" for V-30; the honest, high-value move is tokens→Keychain + accurate docs + the V-31 fail-closed-on-Keychain-failure correctness fix (cheap, prevents a future foot-gun if a real codec is ever linked). **Do not claim the local DB protects tokens/logs from a same-user adversary.**

## 5. Firebase App Check + Firestore (2026) → maps to V-15, V-16

Run App Check as **transport-layer defense-in-depth**: (1) **enforce per-product in the console** for Firestore after watching the metrics dashboard until traffic is "Verified" (the metrics window is the de-facto grace period); (2) **Firestore Rules CANNOT inspect App Check for the client SDK** — there is no `request.app` predicate; enforcement is at the SDK/transport edge; keep Rules on `request.auth` + shape; (3) **Callables CAN enforce in code** (`enforceAppCheck: true`, read `request.app`); (4) **replay protection** via **limited-use tokens** (`consumeAppCheckToken: true` / backend `verifyToken(token,{consume:true})`, ~5-min TTL) scoped to high-value endpoints; (5) **verify programmatically** with Admin SDK `getAppCheck().verifyToken()` and alert on non-Verified metrics.

- https://firebase.google.com/docs/app-check/enable-enforcement · https://firebase.google.com/docs/app-check/monitor-metrics · https://firebase.google.com/docs/app-check/cloud-functions · https://firebase.google.com/docs/firestore/security/rules-conditions

**Implication (corrects the audits):** V-15's "rules don't check `request.app`" is *expected* — that predicate doesn't exist for the client SDK. The repo already code-enforces App Check on callables, fails closed in prod (`config.ts` throws if disabled), and unit-tests it (`config_l3.test.ts`). The legitimate gap is **operational verification that the console toggle is on** — exactly what the K2.7 ops-verifier script targets. Add `consumeAppCheckToken` only on credit/billing/quota-mutation callables. The 30-day attestation max-age (V-16) is defensible because a 2-min single-use nonce is layered on high-risk calls.

## 6. macOS XPC / Unix-Socket Peer Authentication (2026) → maps to V-01, V-05, daemon

**Never authenticate a peer by PID** (PID reuse / `posix_spawn` race — CVE-2020-14977 class). Use the **kernel-verified audit token** (PID + `p_idversion` generation), and prefer the declarative APIs: NSXPCConnection `setCodeSigningRequirement:` (macOS 13+); XPC C `xpc_connection_set_peer_code_signing_requirement` (12+) / `…_team_identity_requirement` (13+). Manual fallback for unix sockets: `getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, …)` (**not** `getpeereid`/PID) → `SecCodeCreateWithAuditToken` (or `kSecGuestAttributeAudit`, never `kSecGuestAttributePid`) → `SecCodeCheckValidity` against a `SecRequirement`. Validate **bidirectionally**.

Requirement string shape: `identifier "…helper" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID"`.

- https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_code_signing_requirement(_:_:) · TN3127: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements · CVE-2020-14977 writeup: https://theevilbit.github.io/posts/secure_coding_xpc_part5/ · audit-token spoofing (DEFION, why declarative APIs win): https://defion.security/en/research-labs/don-t-talk-all-at-once-elevating-privileges-on-macos-by-audit-token-spoofing/

**Implication:** BurnBar already uses `LOCAL_PEERTOKEN` + `PrivilegedPeerAuthenticator` correctly on the *execution* socket — the gaps are **symmetry**: V-01 (watchdog socket honors `clear`/`activate` with no peer check — add the same `PrivilegedPeerAuthenticator` gate) and V-05 (legacy `/var/run` client writes the login password without `validateServerPeer` — add the existing check before the write). Grep the auth path for any `kSecGuestAttributePid`/`SecCodeCreateWithPID` and eliminate.

## 7. Supply-Chain / CI/CD SOTA 2026 → maps to V-25, V-26, V-27a/b

(1) **SLSA v1.0 Build L2** baseline (GitHub runners + Artifact Attestations meet it OOTB), L3 opportunistically for the macOS binary via an isolated reusable workflow. (2) **Kill long-lived SA JSON keys** — GitHub OIDC → GCP **Workload Identity Federation**, restrict the pool by numeric `repository_owner_id`. (3) **GitHub Artifact Attestations** (`actions/attest-build-provenance`, Sigstore Fulcio+Rekor); verify with `gh attestation verify`. (4) **cosign keyless** for the distributed `.dmg`/`.zip` (and if the repo is private/non-Enterprise, since native attestations are public-repo-only off Enterprise). (5) **Two-person release** — a `production` Environment with required reviewers + "prevent self-review"; ruleset on `main` requiring PR+approval+CODEOWNERS+green checks. (6) **Pin every action to a 40-char SHA** (closes the 2025 tj-actions/reviewdog mutable-tag class) + Dependabot + `dependency-review-action` + least-privilege per-job `GITHUB_TOKEN`.

- https://slsa.dev/spec/v1.0/levels · https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect · https://github.com/google-github-actions/auth · https://github.com/actions/attest-build-provenance · https://openssf.org/blog/2025/06/11/maintainers-guide-securing-ci-cd-pipelines-after-the-tj-actions-and-reviewdog-supply-chain-attacks/

**Implication:** V-25 is real and *worse* than framed (no OIDC path exists at all) → move Firebase deploy to WIF. V-26 (GPG fail-open) → emit a loud `::warning::` and keep cosign as the integrity root. V-27a → add `permissions:` blocks to the two bare workflows. V-27b → add CODEOWNERS path rules for `functions/src/security`, crypto, billing, `scripts/ci`, `Vendor/libsignal`, `firestore.indexes.json` (even single-owner, makes routing intentional). Note: solo-operator model means "two-person" is aspirational — document the compensating controls.

## 8. Capability-Based Security for Agent Actions → maps to Computer-Use, kill-switch

Authorize each action with a **capability token that carries** the narrowly-scoped, attenuatable, time-bounded right. SOTA 2026: public-key-verifiable tokens with offline attenuation + embedded policy — **macaroons** (HMAC chain + caveats; verifier holds root secret, can forge) → **Biscuit** (public-key signatures so verifiers need only the root *public* key; single-use keypair chains; embedded Datalog policy). Recipe: short-lived single-action tokens, attenuated per request, revocable via short TTL + revocation-ID list, verified by public key.

- https://research.google/pubs/pub41892/ · https://www.biscuitsec.org/ · https://doc.biscuitsec.org/reference/specifications.html

**Implication:** BurnBar's `CapabilityToken` is already the right shape (Ed25519-signed, device/attestation/scope/budget/nonce). The forward path: per-action attenuatable tokens + **kill-switch-as-revocation** (every token carries a unique ID + short TTL; kill switch publishes the ID to a revocation list the daemon consults → instant fail-closed without rotating the root key). This is the principled upgrade for V-01/V-02/V-04.

## 9. Push Notification Privacy SOTA → maps to V-21, V-22

Treat APNs/FCM as **untrusted, subpoena-able correlators**: (1) prefer a **content-free wake-up ping** — no text, no sender/recipient, no user/thread/conversation IDs; app fetches real content over its own E2EE channel and renders on-device (Signal model); (2) never put PII in payload (FCM payloads are not E2E-encrypted); (3) if content must be inline, **E2E-encrypt + decrypt on-device** (`UNNotificationServiceExtension` + `mutable-content:1` / Android `onMessageReceived`); (4) **minimize stable correlators** — where a grouping key is needed use an **opaque rotating per-event value** (e.g. `apns-collapse-id` = HMAC(event + rotating salt), never a `userId`/`threadId`); (5) assume token rotation + gov access.

- https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns · https://www.apple.com/legal/transparency/push-token.html · EFF (Apr 2026): https://www.eff.org/deeplinks/2026/04/how-push-notifications-can-betray-your-privacy-and-what-do-about-it · PETS 2024: https://arxiv.org/abs/2407.10589

**Implication:** V-21 — add `buildFcmMessage` to the I5 gate and replace the stable `thread_id`/`deep_link?threadId=`/`collapseKey=agent-{threadId}`/APNs `thread-id` with an **opaque rotating** correlator, or drop to a wake-up ping. V-22 — `androidDeviceId` in `fcm_outbound` is internal+TTL'd+erased; lowest priority.

## 10. Account Deletion / GDPR Erasure (Art. 17) SOTA 2026 → maps to V-23a

**Completeness** = erase across Auth, **Firestore recursively** (also scrub UIDs inside *other* docs and inside arrays/maps — the official extension does NOT do this), **all Storage prefixes**, **third-party processors** (Stripe — retain invoices under Art.17(3), documented; analytics; Sentry/logs), and **client local data** (SQLite + Keychain/Keystore). **Backups:** put data "beyond use," age out on a documented retention cycle, re-apply erasure on restore (EDPB 2025 CEF gap). **Audit trail w/o PII:** a tombstone/deletion receipt (`uidHash`, requestedAt, completedAt, scopes[]). **Test automatically:** an emulator integration test driven by a **deletion-scope manifest** that seeds a known UID across every collection/subcollection/Storage prefix, runs the real function, asserts **zero residual + zero orphans**; adding a collection without updating the manifest fails CI.

- https://gdpr-info.eu/art-17-gdpr/ · EDPB 2025 CEF: https://www.edpb.europa.eu/our-work-tools/our-documents/other/coordinated-enforcement-action-implementation-right-erasure_en · extension limits: https://firebase.google.com/docs/extensions/official/delete-user-data · Apple 5.1.1(v): https://developer.apple.com/news/?id=mdkbobfo · Play: https://support.google.com/googleplay/android-developer/answer/13327111

**Implication:** V-23a — replace the static `ROOT_COLLECTIONS_KEYED_BY_UID` allowlist with a **deletion-scope manifest + CI completeness test** (mirror the existing BOLA catalog-completeness pattern), so a new uid-keyed root collection fails CI unless listed or explicitly exempted.

---

## Cross-cutting takeaways

- **The deterministic capability gate is the load-bearing control** for Computer Use (satisfies LLM01/05/06; is the CaMeL-style provable boundary; is where Biscuit-style per-action tokens + kill-switch-as-revocation plug in). Model classifiers are tripwires only.
- **Move secrets to the right store**: OAuth tokens → Keychain (not SQLite); push payloads → content-free/opaque; never trust same-user encryption claims.
- **Two enforcement boundaries are commonly misplaced** and the audits stumbled on both: App Check is transport-layer (not Firestore Rules), and IPC peer auth is audit-token (not PID).
- **CI hardening is high-leverage and cheap**: WIF (kills JSON keys) + SHA-pinned actions + two-person environment + attestations.
