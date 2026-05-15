# OpenBurnBar Privacy Policy

**Last updated: May 15, 2026**

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
- In-app chat thread metadata (thread IDs, titles/previews when enabled, timestamps, counts)
- Conversation/session metadata and sync watermarks
- Encrypted BurnBar Pro session-log search metadata, including sealed titles/snippets and keyed token/semantic hashes
- Shared artifact metadata and revisions for collaboration features
- Sync state metadata

Cloud sync is **disabled by default**. You can disable it at any time in Settings. Disabling sync does not affect local data.

### Optional Chat and Session Backup (paid entitlement)

OpenBurnBar can back up chat message content and session history only after you explicitly enable the relevant backup setting. Hosted cloud backup writes for chat message bodies, conversation metadata, session-log manifests, session-log chunks, and Hermes relay traffic require an active `burnbar_pro` entitlement or a legacy active `hosted_quota_sync` entitlement.

BurnBar Pro searchable hosted session logs are encrypted on device before upload. Full session bodies are sealed with AES-GCM and uploaded to Firebase Storage as ciphertext. Firestore stores encrypted titles/snippets/previews, non-secret hashes, HMAC token hashes, keyed semantic hashes, and opaque semantic posting edges for matching. OpenBurnBar servers can keep the index fresh and run encrypted token/semantic matching, but they do not receive the vault key, plaintext embeddings, or plaintext needed to decrypt session bodies, titles, or snippets. Apps and explicitly configured MCP tools decrypt matching results locally after the device has an allowed wrapped vault key.

Backed-up chat and session data may include prompts, assistant responses, file paths, project names, model names, code snippets, and other content present in your local agent logs or in-app chats. Do not enable these backup settings for repositories or conversations you do not want stored in Firebase.

### Optional iCloud Mirror (opt-in only)

If you enable iCloud session mirroring, OpenBurnBar copies selected local session log files into your personal Apple iCloud Drive app container. This is separate from Firebase and uses Apple iCloud storage under your Apple ID. Mirrored files can contain prompts, assistant responses, file paths, and code snippets because they are copies of the original session logs.

### Hosted Quota Refresh and Provider Credentials (opt-in, paid entitlement)

If you add a hosted quota account, OpenBurnBar may send provider authentication material that you explicitly provide to OpenBurnBar-operated Firebase/Google Cloud infrastructure. The Firestore document stores only non-secret metadata and a redacted label. Secret values are stored in Google Cloud Secret Manager and are used by Cloud Functions or the hosted quota runner to refresh quota snapshots. Hosted quota refresh requires a valid subscription entitlement and may be rate limited.

### Hosted MiniMax LLM Answers (opt-in, paid entitlement)

If you use the BurnBar-hosted Intelligence Brief fallback, OpenBurnBar sends a bounded briefing prompt and privacy-filtered usage digest through Cloud Functions to the hosted LLM provider path. This requires BurnBar Pro. Users who connect their own model or stay in local/privacy mode do not need to use the hosted fallback.

### Optional Diagnostics (opt-in only)

If you enable crash reporting or diagnostics, anonymized crash reports may be sent to Sentry. This is disabled by default.

---

## Data We Never Collect

- Your API keys or credentials for local-only usage tracking
- The content of your source code or agent conversations unless you explicitly enable chat/session backup or iCloud mirroring
- Personal identifying information beyond what your Apple or Google account provides for sign-in
- Any data from other applications
- Payment card numbers; subscriptions are handled by Apple, Google Play, or Stripe

---

## Third-Party Services

When cloud sync is enabled:

| Service | Purpose | Privacy Policy |
|---------|---------|----------------|
| Firebase / Google Cloud | Authentication, optional Firestore sync, Cloud Functions, Secret Manager, hosted quota infrastructure | [firebase.google.com/support/privacy](https://firebase.google.com/support/privacy) |
| Apple iCloud | Optional session-log mirroring in your personal iCloud Drive container | [apple.com/legal/privacy](https://www.apple.com/legal/privacy/) |
| Apple App Store / StoreKit | Subscription purchase, entitlement verification, and billing status | [apple.com/legal/privacy](https://www.apple.com/legal/privacy/) |
| Google Play Billing | Android subscription purchase and entitlement verification | [policies.google.com/privacy](https://policies.google.com/privacy) |
| Stripe | Web subscription checkout, customer portal, entitlement webhook processing | [stripe.com/privacy](https://stripe.com/privacy) |
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
- **Delete iCloud mirrored files** from your iCloud Drive app container

---

## Changes to This Policy

If we make material changes, we will update the "Last updated" date above. Continued use after changes constitutes acceptance.

---

## Contact

For privacy questions or data deletion requests:

**Imagine That AI Limited Liability Company**
Email: privacy@imagine-that.ai
GitHub: [github.com/Imagine-That-Ai/BurnBar/issues](https://github.com/Imagine-That-Ai/BurnBar/issues)
