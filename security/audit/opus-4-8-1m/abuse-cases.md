# Abuse Cases & Attack Trees — Opus 4.8 1M lane

## AC-1 — Account takeover / cross-user data access
**Goal:** read another user's data. **Tree:** (a) guess/forge callable with victim uid → blocked by `assertOwnership` + tier-2 BOLA tests; (b) write to victim Firestore path → blocked by owner-scoped rules; (c) escalate via `burnbarOperator` → claim never mintable in code. **Result:** no viable path found.

## AC-2 — Steal private chat/session content from the cloud
**Goal:** read sealed content from Firestore. **Tree:** (a) read sealed payload → AES-256-GCM, key device-only; (b) downgrade to plaintext write → session_logs allowlist (M-005) + secret denylist block it; (c) **relocate own ciphertext between docs** → possible on non-path-bound-AAD surfaces (OPUS-F-003, same-account only); (d) **read shared collaboration artifacts** → **succeeds** — they are plaintext (OPUS-F-001). **Result:** content sealed except shared artifacts (Medium) and same-account AAD relocation (Low-Med).

## AC-3 — Capture the macOS login password via Remote Unlock
**Goal:** intercept the plaintext login password in the privileged-input path. **Tree:** (a) squat the execution socket in /tmp → blocked (per-uid 0700 dir, P0-6 fixed); (b) impersonate the server on the preferred lane → blocked (client validates server peer UID+codesign); (c) wrong peer-token bypass → fixed (0x006); (d) squat legacy `/var/run` lane → requires root (root-only-writable), and that lane lacks client-side server auth (OPUS-F-008, mitigated). **Result:** prior critical (P0-6) closed; only a root-precondition residual.

## AC-4 — Ship a malicious auto-update
**Goal:** get a trojaned DMG installed. **Tree:** (a) serve a forged feed → feed unauthenticated but trust anchor is the signed DMG; (b) forge the DMG → blocked (Ed25519 vs pinned `SUPublicEDKey`); (c) tamper bytes → blocked (SHA-256 + signature over full DMG); (d) swap unsigned app → blocked (codesign verify, readonly mount). **Result:** LB-2 closed; real Ed25519 verification.

## AC-5 — Prompt-inject a Computer Use agent into a destructive action
**Goal:** make untrusted content drive a dangerous action without approval. **Tree:** (a) inject via RAG/transcript/tool-output → wrapped default-deny as untrusted evidence; (b) emit arbitrary action from model output → typed decode rejects unknown actions; (c) act in a password field → deny-region blocks even signed phone authority; (d) bypass approval → in-code gate returns `.denied`, audit-before-action fail-closed; (e) loop/burn budget → soft/hard/daily caps flip kill switch. **Result:** no path to unapproved high-impact action.

## AC-6 — Replay a billing event to revive a cancelled subscription
**Goal:** keep paid entitlement after cancellation. **Tree:** (a) resubmit old Apple JWS → `shouldOverwrite` keyed to Apple signedDate; (b) submit victim's JWS under own uid → `binding_mismatch`; (c) Stripe out-of-order replay → transactional ledger + rewind/downgrade guard + current-state re-fetch; (d) erase the watermark → fixed (`entitlements.ts:202-207`). **Result:** closed.

## AC-7 — Exfiltrate secrets via CI / supply chain
**Goal:** leak CI secrets or ship a malicious dependency. **Tree:** (a) malicious action tag → SHA-pinned + verifier; (b) malicious dep → lockfile + OSV/audit/dep-review; (c) `curl|sh` installer → blocked by verifier; (d) widen secret blast radius via qa.yml → narrowed (fixed); (e) merge unreviewed malicious PR → branch-protection ruleset unverified (OPUS-U-005) + single-signer residual. **Result:** strong, pending branch-protection confirmation.

## AC-8 — Incident with no human reached
**Goal (availability of response):** an off-hours outage that nobody is paged for. **Tree:** uptime/health detect → auto-issue filed → **alert channel** delivers? Unverified (OPUS-U-003; 06-11 found NXDOMAIN). **Result:** detection real; response reach needs evidence — the single highest-leverage operational fix.
