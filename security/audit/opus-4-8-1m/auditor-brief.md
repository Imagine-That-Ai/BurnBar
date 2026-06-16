# External Auditor Brief — Opus 4.8 1M lane

## Product & scope
OpenBurnBar/BurnBar: local-first macOS menu-bar app + iOS/Android + Firebase Cloud Functions backend + iroh P2P + Hermes LLM relay + Computer Use (agentic Mac automation) + Cloud Vault (server-blind sealed sync). Reviewed at `60faa70227` on `security/run-09-privacy-invariants-hardening`.

## Recommended review focus (highest value for an external lab)
1. **Cloud Vault sealing & AAD binding** — verify AES-256-GCM seal coverage and path-bound AAD across **all** sealed surfaces (we found partial coverage, OPUS-F-003), and the plaintext shared-artifact path (OPUS-F-001).
2. **Privileged input / Remote Unlock IPC** — the credential-bearing path (login password). Prior critical (P0-6) is fixed; verify the legacy `/var/run` lane (OPUS-F-008) and the peer-codesign/peer-token model on real sockets (`RUN_PRIVILEGED_SOCKET_REDTEAM`).
3. **Computer Use agentic boundary** — adversarial prompt-injection / confused-deputy: can untrusted content reach an unapproved high-impact action? (We assess no; an external red-team should try to break the in-code approval + deny-region + typed-decode model.)
4. **Billing entitlement pipeline** — Apple JWS + Stripe replay/downgrade/cross-user; verify the server-sole-authority property.
5. **BOLA at scale** — the 150-endpoint catalog + tier-2 tests; probe for any object-ID-bearing endpoint missing cross-user coverage.

## Setup
- Functions: `npm ci --prefix functions`; rules tests `cd firestore-rules-tests && npm run test:ci`; privacy gate `node scripts/ci/check-privacy-invariants.mjs`.
- macOS app: XcodeGen + `./scripts/test-openburnbar-app.sh` (XCTest bundle `OpenBurnBarTests`).
- Needs: a Firebase test project (or emulator), two test accounts (cross-user BOLA), a clean standard-user Mac VM (Remote Unlock + panic-halt), and a sandbox App Store / Stripe test mode.

## Known issues handed to auditors (this lane)
2 Medium (OPUS-F-001 collaboration plaintext, OPUS-F-002 macOS scrub test gap), 12 Low, 6 Info — see `findings.md`. Plus 7 deployment/operational unknowns (`open-questions.md`) that an auditor with live access should confirm: live TTLs, App Check console enforcement, alert deliverability, prod deploy currency, branch protection, Sentry DSN ship, public-claim wording.

## Areas where adversarial review is most wanted
- Same-account ciphertext relocation on non-path-bound-AAD surfaces.
- SSRF guard hardening before any user-supplied-URL fetch (OPUS-F-007).
- Supply-chain single-signer release-key compromise scenario.
- Prompt-injection chains through RAG/tool-output into Computer Use.

## Open questions for auditors
- Is first-contact iroh safety-number compare required before claiming first-contact E2E authentication? (M-018)
- Should CloudVault first-vault/rotation quorum be server-mediated? (M-008)
- What App Check attestation max-age is acceptable for high-impact callables? (M-031)
