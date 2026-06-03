# OpenBurnBar Privacy Policy

**Last updated: June 3, 2026**

## Summary

OpenBurnBar is local-first software. It reads files your AI coding agents leave on your own disk. No data is collected, transmitted, or sold by default. Paid cloud features are optional and require explicit sign-in, settings, and entitlement checks.

---

## What OpenBurnBar Does

OpenBurnBar reads session log files that AI coding agents (Claude Code, Codex, Factory Droid, Cursor, Kimi, Windsurf, and others) write to your local disk. It uses this data to estimate token consumption and API spend, and displays that information to you inside the app.

**OpenBurnBar does not read your API keys by default.** Local usage tracking reads usage logs, not credentials. If you choose hosted quota refresh, you explicitly provide provider credentials for that feature; OpenBurnBar stores only redacted account labels in Firestore and stores the secret material in Google Cloud Secret Manager.

For Claude Code specifically, local quota tracking does **not** read Claude Code's macOS Keychain credential item and does **not** read or rewrite `~/.claude/.credentials.json`. OpenBurnBar uses Claude's statusline payloads and local JSONL usage logs for the default Claude path, so it should not ask for your login keychain password to access Claude credentials.

---

## Data Collection

**By default, OpenBurnBar collects nothing.** All processing happens on your device. No telemetry, no analytics, no crash reports, no usage data is transmitted anywhere unless you explicitly opt in.

### Optional Firestore Cloud Sync (opt-in only)

If you choose to sign in with Google or Apple and enable cloud sync, OpenBurnBar may store the following in Firebase (Google Cloud):

- Usage row summaries (token counts, cost estimates, timestamps, provider names)
- Provider account metadata and quota snapshots (redacted labels, provider IDs, refresh status, limits, remaining quota)
- In-app chat thread metadata (thread IDs, timestamps, counts; titles/previews/message bodies are sealed when backed up)
- Conversation/session routing metadata and sync watermarks (private recall fields are sealed)
- CLI session snapshot routing metadata (private action labels, touched files, and Mac snapshot paths are sealed)
- Rollback request routing/status metadata (private rollback scope and error text are sealed)
- Approval-policy, agent-identity, and subscription-topic sync metadata (private labels, paths, globs, persona text, and topic labels are sealed)
- Encrypted text-expansion snippets, including sealed titles, triggers, bodies, scopes, and keyed trigger hashes
- Encrypted BurnBar Pro session-log search metadata, including sealed titles/snippets and keyed token/semantic hashes
- Shared artifact metadata and revisions for collaboration features
- Sync state metadata

Cloud sync is **disabled by default**. You can disable it at any time in Settings. Disabling sync does not affect local data.

### Optional Text Expansion Snippets

Text expansion snippets are user-authored phrases that expand from `&&name` triggers. Static snippets can contain whatever you type into them, so treat them like local notes. When cloud sync is enabled, OpenBurnBar stores snippet title, trigger, body, and scope as Cloud Vault encrypted fields in Firestore, plus a keyed trigger hash used for duplicate matching. Firestore rules reject plaintext snippet fields.

LLM rewrite snippets are previewed before insertion and use only OpenBurnBar-owned thread context. Global macOS expansion, iOS keyboard expansion, and Android IME expansion insert static snippets only.

### Optional Chat and Session Backup (paid entitlement)

OpenBurnBar can back up chat message content and session history only after you explicitly enable the relevant backup setting. Hosted cloud backup writes for chat message bodies, conversation metadata, session-log manifests, session-log chunks, and Hermes relay traffic require an active `burnbar_pro` entitlement or a legacy active `hosted_quota_sync` entitlement.

Chat threads, mobile assistant chats, CLI session mirrors and snapshots, rollback request scopes/errors, approval-policy labels/paths/globs, agent identity persona text, subscription topic labels, mobile mission prompts/results/events, text snippets, and conversation recall metadata are sealed on device with the Cloud Vault key before Firestore receives them. Firestore keeps routing/count metadata such as ids, runtimes, timestamps, status, message counts, and vault key ids, but rules reject the old plaintext title/preview/message/prompt/result/path/scope/persona/topic fields on those collections.

The Hermes Gateway — the optional bridge that lets an external coding agent exchange messages with your phone through BurnBar Cloud — is end-to-end sealed per pairing. When you pair an agent, your phone and the agent each publish a relay public key and pin the other's on first use; every message body, sender name, and attachment file (and the file's bytes) is encrypted to the recipient device's relay key before BurnBar Cloud receives it. The server stores and forwards only ciphertext and never reads gateway message text, sender names, or attachment file names; attachment bytes are uploaded as ciphertext with no file name in their storage path. BurnBar Cloud sees only routing metadata (client ids, destination ids, sequence numbers, timestamps), the public relay keys, and — for the optional human-in-the-loop oversight gate — a coarse tool-name category, never the agent's free-text command (the command detail travels sealed over the same message channel). Once your phone has pinned an agent's relay key, it refuses to display any later reply that arrives unsealed, so the server can neither read your gateway messages nor forge one.

BurnBar Pro searchable hosted session logs are also encrypted on device before upload. Full session bodies are sealed with AES-GCM and uploaded to Firebase Storage as ciphertext. Firestore stores encrypted titles/snippets/previews, non-secret hashes, HMAC token hashes, keyed semantic hashes, and opaque semantic posting edges for matching. OpenBurnBar servers can keep the index fresh and run encrypted token/semantic matching, but they do not receive the vault key, plaintext embeddings, or plaintext needed to decrypt session bodies, titles, or snippets. Apps and explicitly configured MCP tools decrypt matching results locally after the device has an allowed wrapped vault key.

Backed-up chat and session ciphertext may contain prompts, assistant responses, file paths, project names, model names, code snippets, and other content present in your local agent logs or in-app chats. Do not enable these backup settings for repositories or conversations you do not want stored in Firebase, even as encrypted data.

### Optional iCloud Mirror

The legacy raw iCloud session-file mirror is disabled in current builds. OpenBurnBar does not create new raw `SessionMirror` copies until a sealed iCloud archive format ships. Existing users may still have old mirrored files in their personal Apple iCloud Drive app container; run `scripts/privacy/scrub-icloud-session-mirror.sh` for a dry-run inventory and `scripts/privacy/scrub-icloud-session-mirror.sh --apply` to remove those legacy raw copies from this Mac's iCloud Drive folder.

### Hosted Quota Refresh and Provider Credentials (opt-in, paid entitlement)

If you add a hosted quota account, OpenBurnBar may send provider authentication material that you explicitly provide to OpenBurnBar-operated Firebase/Google Cloud infrastructure. The Firestore document stores only non-secret metadata and a redacted label. Secret values are stored in Google Cloud Secret Manager and are used by Cloud Functions or the hosted quota runner to refresh quota snapshots. Hosted quota refresh requires a valid subscription entitlement and may be rate limited.

### Hosted MiniMax LLM Answers (opt-in, paid entitlement)

If you use the BurnBar-hosted Intelligence Brief fallback, OpenBurnBar sends a bounded briefing prompt and privacy-filtered usage digest through Cloud Functions to the hosted LLM provider path. This requires BurnBar Pro. Users who connect their own model or stay in local/privacy mode do not need to use the hosted fallback.

### Optional Diagnostics (opt-in only)

If you enable crash reporting or diagnostics, anonymized crash reports may be sent to Sentry. This is disabled by default.

### Optional Computer Use Audit Notarization (opt-in only)

If you choose to notarize a Computer Use audit session, OpenBurnBar submits only the 32-byte SHA-256 digest of your local `chain.jsonl` audit file to an OpenTimestamps calendar service and stores the returned `.ots` proof beside your local audit chain. During a support dispute, you may optionally send the `.ots` proof and chain file to OpenBurnBar so the server-side `validateOpenTimestampsProof` function can cross-check the session head and verify the proof through the configured OpenTimestamps verifier service. Screenshots and full action descriptors remain local unless you explicitly include them in an audit export.

---

## Data We Never Collect

- Your API keys or credentials for local-only usage tracking
- The plaintext content of your source code or agent conversations unless you explicitly send it through an optional hosted LLM/provider path. Chat/session cloud backup stores ciphertext; the legacy raw iCloud mirror is disabled for new writes.
- Personal identifying information beyond what your Apple or Google account provides for sign-in
- Any data from other applications
- Payment card numbers; subscriptions are handled by Apple, Google Play, or Stripe

---

## Third-Party Services

When cloud sync is enabled:

| Service | Purpose | Privacy Policy |
|---------|---------|----------------|
| Firebase / Google Cloud | Authentication, optional Firestore sync, Cloud Functions, Secret Manager, hosted quota infrastructure | [firebase.google.com/support/privacy](https://firebase.google.com/support/privacy) |
| Apple iCloud | Legacy personal iCloud Drive mirror cleanup and future sealed archive support | [apple.com/legal/privacy](https://www.apple.com/legal/privacy/) |
| Apple App Store / StoreKit | Subscription purchase, entitlement verification, and billing status | [apple.com/legal/privacy](https://www.apple.com/legal/privacy/) |
| Google Play Billing | Android subscription purchase and entitlement verification | [policies.google.com/privacy](https://policies.google.com/privacy) |
| Stripe | Web subscription checkout, customer portal, entitlement webhook processing | [stripe.com/privacy](https://stripe.com/privacy) |
| OpenTimestamps calendar servers | Optional Computer Use audit-chain timestamping; receives only a 32-byte hash | [opentimestamps.org](https://opentimestamps.org/) |
| OpenRouter / MiniMax | Optional BurnBar Pro hosted LLM fallback for Intelligence Brief answers | [openrouter.ai/privacy](https://openrouter.ai/privacy) / [minimax.io/privacy](https://www.minimax.io/privacy) |
| Sentry | Optional crash reporting | [sentry.io/privacy](https://sentry.io/privacy) |

---

## Children's Privacy

OpenBurnBar is a developer tool intended for adults. We do not knowingly collect data from children under 13.

---

## Your Rights

You can:
- **Delete all local data** by removing the OpenBurnBar app and its support files
- **Delete cloud data** by signing out and selecting "Delete my data" in Settings → Account
- **Disable all optional features** at any time in Settings
- **Remove hosted quota credentials** by deleting the provider account from OpenBurnBar
- **Delete legacy iCloud mirrored files** from your iCloud Drive app container

---

## Changes to This Policy

If we make material changes, we will update the "Last updated" date above. Continued use after changes constitutes acceptance.

---

## Contact

For privacy questions or data deletion requests:

**Imagine That AI Limited Liability Company**
Email: privacy@imagine-that.ai
GitHub: [github.com/Imagine-That-Ai/BurnBar/issues](https://github.com/Imagine-That-Ai/BurnBar/issues)
