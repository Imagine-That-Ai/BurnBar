# Threat Register — Opus 4.8 1M lane

STRIDE + privacy + supply-chain + AI/agentic. Severity reflects current (post-run-09) residual risk.

| ID | Title | STRIDE | Component | Actor | Existing controls | Residual | Sev | Status |
|---|---|---|---|---|---|---|---|---|
| THREAT-01 | Cross-user data access via callable | Elevation/Info | Cloud Functions | authed malicious user | tier-2 BOLA catalog+tests, owner-scoped rules | none found | Low | mitigated |
| THREAT-02 | Client self-grants entitlement | Tampering | Firestore entitlements | authed user | `write: if false`, server-only reconcilers | none | Low | mitigated |
| THREAT-03 | Forged/replayed Apple/Stripe billing event | Spoofing/Tampering | billing | attacker w/ JWS | pinned roots, appAccountToken binding, replay/downgrade guards, Stripe ledger | legacy no-token S2S (Info) | Low | mitigated |
| THREAT-04 | Firebase reads private user content | Info disclosure | CloudSync | cloud/insider | AES-256-GCM sealing on 6 types + session_logs | shared artifacts plaintext (OPUS-F-001); local DB plaintext (OPUS-F-004) | Medium | partial |
| THREAT-05 | Same-account ciphertext relocation | Tampering | CloudVault | account owner | path-bound AAD on conversations/chats/session_logs | other surfaces global AAD (OPUS-F-003) | Low-Med | partial |
| THREAT-06 | Privileged-input credential capture (login pw) | Spoofing/Elevation | Remote Unlock IPC | same-user/root malware | per-uid 0700 dir, client server-peer auth, peer codesign, launchd supervision | legacy /var/run lane no client auth (OPUS-F-008, root-only-writable) | Low | mitigated |
| THREAT-07 | Malicious software update | Tampering | DirectDownload updater | network/MITM | Ed25519 verify vs pinned key + SHA-256 + codesign | no spctl assess (Info) | Low | mitigated |
| THREAT-08 | Untrusted content triggers dangerous agent action | Elevation | Computer Use / RAG | malicious doc/page/tool-output | in-code approval, deny-regions, default-deny wrap, audit-before-action, 4 kill paths | none high | Low | mitigated |
| THREAT-09 | SSRF to metadata via user URL | Info disclosure | functions fetch | authed user | ssrfGuard (dotted-decimal) | alt-encoding/DNS-rebinding (OPUS-F-007); unreachable today | Low | latent |
| THREAT-10 | Full UID / PII in logs | Info disclosure | logging | log reader | scrubber on 127/127 sites, I3/I4 gates | accountDeletion console.warn (OPUS-F-005) | Low | partial |
| THREAT-11 | Stable correlator to push processor | Linking | push | APNs/FCM | I5 strips voip correlators | thread_id un-gated (OPUS-F-006) | Low | partial |
| THREAT-12 | Unbounded retention of ephemeral PII | Non-compliance | Firestore TTL | — | field-stamp + deploy-readback gate | live TTL state unverified (OPUS-U-001) | Low | needs-evidence |
| THREAT-13 | Compromised CI ships malicious release | Tampering | CI/CD | malicious PR/runner | SHA-pinned, signed/notarized/attested, no-suppressions gate, dep scanning | branch-protection ruleset unverified (OPUS-U-005); single-signer | Low-Med | needs-evidence |
| THREAT-14 | Alert fires into a void during incident | (availability/response) | ops | — | uptime checks, auto-issue | alert channel deliverability unverified (OPUS-U-003) | Medium | needs-evidence |
| THREAT-15 | Stolen device imports credentials | Spoofing | escrow | thief | device-trust approval, bootstrap confirm, revocation, Keychain WhenUnlockedThisDeviceOnly | first-vault/quorum product decision (M-008) | Low | accepted/decision |
| THREAT-16 | Quota cap evasion | Tampering | quota | authed user | server allowance ledger | ≤1h client-mirror window (OPUS-F-013) | Low | partial |

Threat-model mapping (per `docs/security/BurnBar-threat-model.md`): TM-002 (THREAT-01/02), TM-004 (THREAT-06/08), TM-006 (THREAT-04/05/15), TM-009 (THREAT-10/11/12), TM-010 (THREAT-13).
