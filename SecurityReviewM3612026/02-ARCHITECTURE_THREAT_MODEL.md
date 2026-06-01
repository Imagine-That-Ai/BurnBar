# BurnBar / OpenBurnBar — Architecture & Threat Model (Second-Opinion Edition)
**Date:** 2026-06-01
**Reviewer:** Claude (Sonnet 4.6) second-opinion edition
**Status:** Provisional — specialist subagents in flight. The system map and trust boundary table below are derived from direct code/docs reading; the deep analysis arrives after specialists return.
**Cross-reference:** `docs/THREAT_MODEL.md` (team's authoritative product-wide model) + `docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md` + `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md` + `plans/2026-05-30-sota-security-remediation.md`.

## 1. System map (text diagram)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ User's Mac (single-user, all components run as the logged-in user)          │
│                                                                              │
│  ┌────────────────┐      UNIX socket (0600 + per-launch token)   ┌────────┐  │
│  │  macOS App     │◄────────────────────────────────────────────►│Daemon  │  │
│  │  (AgentLens)   │      JSON-RPC, local only                     │(launchd)│ │
│  └─────┬──────────┘                                                └───┬────┘  │
│        │                                                              │       │
│        │  ┌──────────────────────────┐                                │       │
│        ├──│ macOS Keychain            │◄──── secrets ─────────────────┘       │
│        │  └──────────────────────────┘                                        │
│        │                                                                      │
│        │  ┌──────────────────────────┐  canonical (local-first)               │
│        ├──│ Local SQLite (GRDB)      │  optional SQLCipher at rest           │
│        │  └──────────────────────────┘                                        │
│        │                                                                      │
│        │  ┌──────────────────────────┐  opt-in                                │
│        ├──│ Firebase (cloud)         │────► Firestore, Auth, App Check        │
│        │  └──────────────────────────┘                                        │
│        │                                                                      │
│        │  ┌──────────────────────────┐  opt-in                                │
│        └──│ iCloud Documents         │────► Apple iCloud                      │
│           └──────────────────────────┘                                        │
│                                                                              │
│  ┌──────────────────────────┐  same-UID UNIX socket                          │
│  │ VS Code / Cursor         │◄── daemon RPC ──────────────────────────────┘  │
│  │ Extension                │  (gated by workspace trust)                    │
│  └──────────────────────────┘                                                │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────┐        │
│  │ PRIVILEGED HELPERS (post-P0) — XPC Mach services + thin adapters  │       │
│  │  • PrivilegedInputExecution (hid.virtual.device, no FS/Keychain)  │       │
│  │  • VirtualHIDBridge (legacy UNIX socket adapter, forwards over XPC)│      │
│  │  • RemoteAccessAgent (launcher-only, no HID/Keychain)             │       │
│  │  Peer auth: code-sign via LOCAL_PEERTOKEN + SecCode + DR            │       │
│  │  Watchdog: openburnbar-privileged-input-killswitch-watchdog        │       │
│  └──────────────────────────────────────────────────────────────────┘        │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
        │                                                  │
        │ Iroh (QUIC + E2EE between endpoints,             │ HTTPS / Firebase SDK
        │ relays see metadata only)                        │
        ▼                                                  ▼
┌────────────────────────┐  ┌────────────────────────────────────────────┐
│ iOS App                │  │ Cloud Functions (TypeScript, GCP)          │
│ (OpenBurnBarMobile)    │  │  • onCallProduction wrappers               │
│  iroh via Rust core    │  │  • App Check + bound attestation claim      │
│  Hermes Iroh host      │  │  • Owner-scoped Firestore rules             │
└────────────────────────┘  │  • Apple JWS verification pipeline          │
                           │  • High-risk callable wrappers              │
┌────────────────────────┐  │  • Resilience wiring (providerFetch)        │
│ Android App            │  │  • OTS anchoring                            │
│ (Kotlin + Rust core)   │  │  • Hermes Gateway (bespoke HTTP/SSE/attach) │
│  iroh via Rust AAR     │  └────────────────────────────────────────────┘
└────────────────────────┘                       │
                                                  ▼
                                ┌────────────────────────────────────┐
                                │ Iroh relays (first-party + public)  │
                                │  • Sees NodeIds, patterns, timing,   │
                                │    volumes; cannot decrypt payload   │
                                │  • Browser/WASM clients may use      │
                                │    relayed traffic (different         │
                                │    metadata + cost profile)          │
                                └────────────────────────────────────┘
```

## 2. Trust boundary table

| Boundary | From | To | Trust direction | Enforcement today | Residual risk |
|---|---|---|---|---|---|
| TB-1 | macOS app | Daemon (UNIX socket) | App → Daemon | 0600 socket + per-launch token from launchd `EnvironmentVariables`; request size cap 64 KB; Codable deserialize | Same-UID local malware with token (inherent); token via launchd plist (root user can read) |
| TB-2 | Same-UID other process (e.g., extension, malware) | Daemon | → Daemon | Same as TB-1 | Same-UID local malware |
| TB-3 | App or daemon | Privileged helper (VirtualHID bridge, RemoteAccessAgent) | → helper | getpeereid (UID) + code-sign via LOCAL_PEERTOKEN + SecCode + DR (post-P0) | First-party-signed malware; hardened runtime + library validation are the binding constraints |
| TB-4 | Privileged helper | Hardware (HID, AX, display) | helper → OS | TCC permissions (Accessibility, Screen Recording); hardened runtime; library validation; capability token at WS2 layer (in progress to universal) | Code-sign bypass; compromised first-party binary |
| TB-5 | App | macOS Keychain | ↔ | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | Same-UID code execution; Keychain reset/migration loses encrypted DB key |
| TB-6 | App | Local SQLite | ↔ | GRDB default; optional SQLCipher with `PRAGMA key` + `PRAGMA cipher_version` check; key in Keychain | Plaintext default if user doesn't enable encryption |
| TB-7 | App / mobile | Firebase (cloud) | ↔ | TLS; Firebase Auth (Google + Apple); App Check; owner-scoped Firestore rules; secret denylist | Console App Check must be enforced; callables must use `onCallProduction`; OpenAPI drift |
| TB-8 | Mobile (iOS/Android) | Mac (Iroh P2P or relayed) | ↔ | QUIC + E2EE between endpoints; relay sees metadata; signed pairing records with freshness | Post-pairing app-layer authz must be explicit; transport-layer rate limiting |
| TB-9 | Mobile (paired) | Mac privileged input leaf | mobile → Mac | Ed25519 + monotonic counter + intent-hash + 300s lifetime + attestation param + escrow-device check; capability token (WS2) | Compromised paired device; replay within counter window; attestation binding universality |
| TB-10 | App | iCloud | opt-in | Apple-managed encryption in transit + at rest; iCloud Documents | Apple compromise; conflict copies; user Apple ID compromise |
| TB-11 | Cloud Function | Provider APIs (Stripe, Apple ASC, Sentry, Slack, etc.) | → provider | Resilience wiring (`providerFetch`); bounded parsers; webhook signature validation | Provider compromise; CISA KEV on transitive deps |
| TB-12 | Mac/iOS/Android | Iroh relay | → relay | Encrypted transport; metadata observable | Relays see NodeIds, patterns, timing, volumes; cost blowup for high-bandwidth |
| TB-13 | User | App onboarding | user → app | UI-driven consent; explicit toggles for opt-in features | Social engineering; UI confusion between view and control |
| TB-14 | Cloud admin | User data | admin → user | Sentry `beforeSend` redaction; Cloud Logging filters; operator `burnbarOperator` claim for `ops/**` only | Insider threat; data exfiltration via legitimate admin paths |
| TB-15 | Self-hosted / CLI-only | User's own network | self → self | No OpenBurnBar cloud | User's own OS/network/hygiene |

## 3. Top 20 assets ranked by sensitivity

| Rank | Asset | Where | Why sensitive | Primary protection |
|---|---|---|---|---|
| 1 | OpenBurnBar Iroh private key (Ed25519) | macOS Keychain | Loss = identity theft in Iroh network; signed pairing record forgery | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; Secure Enclave where possible |
| 2 | Escrow P-256 private key (per device) | macOS / iOS Keychain | Decrypts all credentials transferred between devices | Keychain + rotation |
| 3 | Provider API keys (Anthropic, OpenAI, etc.) | macOS Keychain + opt-in cloud | Spend + model access; exfil = financial + brand risk | Keychain; secret denylist in Firestore rules; never plaintext in sync |
| 4 | Computer Use audit chain | Local + OTS | Tamper-evidence of every privileged action | BLAKE3 hash + signed head + OTS anchor |
| 5 | Capability tokens (WS2) | In-flight, short-TTL | Single-use + signed + scope-hashed | Ed25519 sign; nonce ledger; attestation binding |
| 6 | Signed pairing records (`IrohPairingRecordDoc`) | Firestore | Identity of a paired peer | Mac sole writer; freshness window; signature verify |
| 7 | Encrypted session backup key | macOS Keychain | Loss = unrecoverable DB; exfil = full history decryption | Keychain + opt-in only |
| 8 | Privileged helper code-signing identity (Developer ID) | Apple-issued | Compromise = first-party-signed malware | Hardware-backed; notary + staple |
| 9 | OpenBurnBar launchd env token (daemon auth) | launchd plist 0600 | Possession = full daemon RPC | Per-launch rotation; launchd env (not argv) |
| 10 | Apple App Store JWS verification (Apple root CAs) | Vendored in `functions/src/appstore/verifier.ts` | Tamper = forged subscription state | SHA-256 pin; cold-start tamper check |
| 11 | Firebase custom claims (`burnbarOperator`) | Server-minted only | Minted client-side = admin-plane takeover | Server-only mint path; rules enforcement |
| 12 | Phone authority envelope (Ed25519 + counter) | In-flight | Replay = control re-grant | Counter + TTL + intent hash + attestation |
| 13 | iOS Keychain access groups / shared keychain | iOS | Misuse = cross-app read | Least-privilege entitlement |
| 14 | Encrypted chat bodies (hosted) | Firestore sealed | Exfil = full chat history | AES-GCM device key; sealed index |
| 15 | Log parser inputs (all 17 parsers) | Local FS | Source of indirect prompt injection | Whitelist roots (`~/.claude/`, etc.); untrusted-content wrapping downstream |
| 16 | Hermes Gateway bearer tokens | Server-minted, custom | Stolen = remote control via Gateway | Short TTL + scope + rate limit; tier consistency review |
| 17 | OAuth refresh tokens (Firebase) | Firebase SDK | Long-lived; exfil = account takeover | SDK-managed; App Check; re-auth on sensitive ops |
| 18 | Stripe live secret key (Cloud Functions) | GCP Secret Manager | Exfil = billing fraud | Secret Manager; IAM least privilege; alerts on unusual spend |
| 19 | OpenAI / Anthropic / provider API keys in Cloud Functions | GCP Secret Manager | Same as above | Same as above |
| 20 | SBOMs + cosign attestations | Public release artifacts | Loss = supply-chain confidence | Re-attest on each release; verify in CI |

## 4. Top 20 abuse cases

| # | Abuse case | Preconditions | Primary impact | Existing mitigation | Residual risk |
|---|---|---|---|---|---|
| 1 | Same-UID malware drives VirtualHID bridge | Console-user malware; pre-P0 | Full TCC bypass; arbitrary input | Code-sign peer auth + WS2 capability tokens (in flight) | First-party-signed malware; WS2 universality gap |
| 2 | Compromised paired phone issues control intent | Phone compromised post-pairing; valid signature; counter in window | Full remote control without further user action | Ed25519 + counter + TTL + intent hash + attestation | Replay within window; attestation universality |
| 3 | Stolen post-pairing Iroh record (NodeId + sig) | Keychain exfil or local FS read | Unauthorized screen/control if app-layer authz weak | WS2 tokens + escrow trust + scope (in flight) | Post-pairing authz contract must be explicit |
| 4 | Hermes Gateway approve with weaker auth tier | Valid Auth + App Check (no bound attestation) | High-tier grant via Gateway | App Check + entitlement | Tier inconsistency (prior Finding C2) |
| 5 | CLI Link userCode brute-force | Public endpoint; 27-43M space × 10 min | Complete link; issue Remote MCP grant | SHA-256 secret hash | No general rate limit; small window |
| 6 | Rapid pairing complete floods | Auth + App Check; no per-uid quota | Resource exhaustion; grant spam | Per-action last-timestamp | No general facade |
| 7 | Log parser RAG poisoning → agent secret exfil | Attacker writes file in `~/.claude/` or shared log | Indirect prompt injection; secret leak | Whitelist paths; untrusted-content wrappers (in flight) | Universal coverage; vision model on screenshot |
| 8 | Webpage extract via Playwright browser CU | Attacker-controlled site visited by agent | Prompt injection via HTML/Markdown | Per-action approval; scope/deny | Untrusted-content tag universality |
| 9 | MCP server returns poisoned tool output | Compromised or malicious MCP | Tool output overrides instructions | `LLMSafeContent` wrappers | Coverage gap; tool broker enforcement |
| 10 | Model-switch event spoof | Client-side model id tampering | Wrong model in use; cost blowup | Server-authoritative model routing | Verify per-flow |
| 11 | Stale iroh pairing record replay (cross-platform freshness diff) | Old record; lenient receiver window | Connection from revoked/stale peer | Freshness constant on receiver; revocation cascade | Cross-platform consistency (Swift 3m vs 24h) |
| 12 | Authority envelope counter replay | Counter rollback or state reset | Control input after user thought revoked | Monotonic `lastSeen` persisted on success | In-memory state in some code paths |
| 13 | Relay flood (cost + metadata) | Authenticated peer; no transport-layer cap | Bandwidth cost; metadata exposure | App-layer budgets; irohMonitoring | Transport-layer cap missing |
| 14 | Daemon UNIX socket same-UID abuse | Same-UID malware with launchd env read | Full daemon RPC; log access; provider keys in Keychain | 0600; token; 64KB cap | Code-sign not yet on local socket |
| 15 | Public `latestRouterRundown` App Check drift | Anyone with internet | Control-plane drift signal; possible future data leak | None | Drift between OpenAPI and reality |
| 16 | Sentry or Cloud Logging leak (tickets, tokens, screenshots) | Verbose error or log path | PII / secret exfil | PII scrubbing | Coverage gap; redaction verification |
| 17 | Supply-chain compromise of release DMG | Compromised CI or signing identity | First-party-signed malware | cosign + OIDC; SBOM | Uniform coverage gap |
| 18 | Compromised npm dep (providerFetch etc.) | Dependency confusion or typosquat | Code execution in Cloud Functions | `cargo-deny`, `npm audit`, OSV | Pinned Actions gap; rapid CVE window |
| 19 | Malicious self-hosted MCP or community plugin | User installs | Daemon/Keychain access; local exfil | Local gateway least privilege | Self-hosted guidance gap; community MCP gate |
| 20 | Insider threat via legitimate admin path | Cloud admin / Sentry access / Cloud Logging | Mass user data exfil | Redaction; operator-claim split | Operational visibility gap |

## 5. Security assumptions that must be proven or removed

1. **Local-first state is canonical.** Verify by checking that cloud sync never overrides local state and that deletion purges everywhere.
2. **Privileged socket peer auth is sufficient.** Verify by running the live red-team probe (`OpenBurnBarPrivilegedSocketRedTeamProbe`) with a first-party-signed binary.
3. **Capability tokens are universal on every "input" path.** Verify by grep + runtime trace.
4. **Phone authority envelopes are always attestation-bound at high tier.** Verify by static check.
5. **Kills reach the leaf and survive crashes.** Verify by chaos drill (kill -9 the app, see if the input leaf still blocks).
6. **Pairing record freshness is uniform.** Verify by constant cross-check.
7. **App-layer protocol on top of Iroh is versioned.** Verify by reading the framing code.
8. **Transport-layer rate limiting exists at the Iroh layer.** Verify by reading `IrohRelayRequestHandler` and equivalents.
9. **Log redaction is universal.** Verify by injecting a fake ticket/token into every known log path.
10. **Public claims match the architecture.** Verify by mapping every public sentence to code:line.
11. **The same-UID local malware residual is communicated honestly.** Verify by reading the in-app and website copy.
12. **OpenAPI reflects the actual callable surface.** Verify by regenerating OpenAPI from code.

## 6. Cross-references

- **Prior review:** `security-review-2026-06-01/EXECUTIVE_SUMMARY.md` (Grok 4.3) — top risks align.
- **Foundational SOTA work:** `plans/2026-05-30-sota-security-remediation.md` — the team's own ranked vuln register + corrected workstreams.
- **Authoritative threat models:** `docs/THREAT_MODEL.md`, `docs/security/*` — all referenced and not duplicated here.
- **SOTA frameworks:** `08-SOTA_GAP_ANALYSIS.md` — primary-source-cited.
- **Product-specific requirements:** `09-BURNBAR_SPECIFIC_REQUIREMENTS.md` — the normative bar.
