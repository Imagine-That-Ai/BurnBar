# OpenBurnBar Privacy Policy

**Last updated: July 10, 2026**

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

Chat threads, mobile assistant chats, CLI session mirrors and snapshots, rollback request scopes/errors, approval-policy labels/paths/globs, agent identity persona text, subscription topic labels, mobile mission prompts/results/events, text snippets, and conversation recall metadata are sealed on device with the Cloud Vault key before Firestore receives them. New text-snippet and approval-policy writes use path-bound sealed-text schema v2 AAD, so ciphertext for one user/document/field cannot be replayed into another. Firestore keeps routing/count metadata such as ids, runtimes, timestamps, status, message counts, and vault key ids, but rules reject the old plaintext title/preview/message/prompt/result/path/scope/persona/topic fields on those collections.

The Hermes Gateway — the optional bridge that lets an external coding agent exchange messages with your phone through BurnBar Cloud — is end-to-end sealed per pairing. When you pair an agent, your phone and the agent each publish a relay public key and pin the other's on first use; every message body, sender name, and attachment file (and the file's bytes) is encrypted to the recipient device's relay key before BurnBar Cloud receives it. The server stores and forwards only ciphertext and never reads gateway message text, sender names, or attachment file names; attachment bytes are uploaded as ciphertext with no file name in their storage path. BurnBar Cloud sees only routing metadata (client ids, destination ids, sequence numbers, timestamps), the public relay keys, and — for the optional human-in-the-loop oversight gate — a coarse tool-name category, never the agent's free-text command (the command detail travels sealed over the same message channel). Once your phone has pinned an agent's relay key, it refuses to display any later reply that arrives stripped of that protection, so BurnBar Cloud cannot read your gateway messages and a downgraded reply is rejected rather than shown. Risky agent actions are additionally gated behind an approval you confirm on a trusted device of your own, so a tampered command cannot run unattended.

BurnBar Pro searchable hosted session logs are also encrypted on device before upload. Full session bodies are sealed with AES-GCM and uploaded to Firebase Storage as ciphertext. Firestore stores encrypted titles/snippets/previews, non-secret hashes, HMAC token hashes, keyed semantic hashes, and opaque semantic posting edges for matching. OpenBurnBar servers can keep the index fresh and run encrypted token/semantic matching, but they do not receive the vault key, plaintext embeddings, or plaintext needed to decrypt session bodies, titles, or snippets. Those search structures are not magic: deterministic keyed hashes and cloaked vectors can still reveal structural patterns such as repeated terms, co-occurrence, approximate vector geometry, document counts, and access timing. Sensitive/private memory recall should use the local-only path when available; server-assisted ANN recall is an explicit opt-in with this disclosure. Apps and explicitly configured MCP tools decrypt matching results locally after the device has an allowed wrapped vault key.

Cloud Vault key wrapping is client-verified before new device access is granted: a trusted local root pins its own Signal identity, and future devices must carry a signature chain over their escrow public key and Signal identity fingerprint before Mac, iOS, or Android will wrap vault keys to them. Cloud Vault device revocation is complete only after a surviving trusted device rotates the vault key, verifies the survivor trust chains, and finishes the local rewrap job. The rewrap job covers the sealed root document classes listed above, encrypted session-log storage blobs, and nested sealed mission event envelopes. Revocation stops a device from receiving new wrappers immediately, but no system can claw back plaintext a revoked device already cached. OpenBurnBar does not claim a revoked device is removed from previously stored ciphertext until the rotation job reaches `complete`. Separately, revoking a device removes its vault access but does not instantly invalidate that device's existing Firebase sign-in token: for up to the token's lifetime (about one hour) the revoked device can still read **non-end-to-end** account data it already had access to (usage rows, presence, routing metadata). It cannot read your end-to-end sealed content (chats, session logs, missions) without the vault key it no longer receives.

Android credential transfer uses a v2 split-token protocol. The cloud stores only a public `ct_...` transfer handle, owner/expiry/claim state, and an AES-GCM ciphertext envelope; the human-visible token also contains a separate device-local secret half that is never sent to Firestore, Cloud Functions, logs, Sentry, backups, or BOLA fixtures. The ciphertext key is derived on device from that secret, and the AEAD AAD binds the payload to `credential_transfers:v2:<ownerUid>:<transferId>`, so an operator with full Firestore/Admin state cannot decrypt the credential transfer from metadata alone. Legacy 12-character Android transfer codes are not accepted after this upgrade; users must recreate any unconsumed legacy transfer. This Android v2 path is separate from Mac/iOS credential escrow, which continues to use random `escrow_grants` / `escrow_envelopes` document IDs and ECIES to a recipient device key.

Backed-up chat and session ciphertext may contain prompts, assistant responses, file paths, project names, model names, code snippets, and other content present in your local agent logs or in-app chats. Do not enable these backup settings for repositories or conversations you do not want stored in Firebase, even as encrypted data.

### Optional iCloud Mirror

The legacy raw iCloud session-file mirror is disabled in current builds. OpenBurnBar does not create new raw `SessionMirror` copies until a sealed iCloud archive format ships. Existing users may still have old mirrored files in their personal Apple iCloud Drive app container; run `scripts/privacy/scrub-icloud-session-mirror.sh` for a dry-run inventory and `scripts/privacy/scrub-icloud-session-mirror.sh --apply` to remove those legacy raw copies from this Mac's iCloud Drive folder.

### Hosted Quota Refresh and Provider Credentials (opt-in, paid entitlement)

If you add a hosted quota account, OpenBurnBar may send provider authentication material that you explicitly provide to OpenBurnBar-operated Firebase/Google Cloud infrastructure. The Firestore document stores only non-secret metadata and a redacted label. Secret values are stored in Google Cloud Secret Manager and are used by Cloud Functions or the hosted quota runner to refresh quota snapshots. Hosted quota refresh requires a valid subscription entitlement and may be rate limited.

### Hosted Fusion Web Search (opt-in, paid entitlement)

Elder Wand Fusion can run live web searches through OpenBurnBar's servers when you invoke the hosted search tool. Your search query text is sent from Cloud Functions to a hosted search subprocessor — Perplexity (primary) or Tavily (fallback) — using OpenBurnBar-held API keys, so those keys never touch your device. Only the query string leaves our servers; your own API keys, chat history, session logs, and file contents are never included. Hosted Fusion search requires BurnBar Cloud Pro or Ultra and is metered per month.

### Hosted MiniMax LLM Answers (opt-in, paid entitlement)

If you use the BurnBar-hosted Intelligence Brief fallback, OpenBurnBar sends a bounded briefing prompt and privacy-filtered usage digest through Cloud Functions to the hosted LLM provider path. This requires BurnBar Pro. Users who connect their own model or stay in local/privacy mode do not need to use the hosted fallback.

The hosted request's `context.digest.providers[].topInferredTaskTitles` and `context.digest.models[].topInferredTaskTitles` compatibility fields are always empty arrays. Raw inferred task titles remain on device and contribute only to closed `useCaseHistogram`, `agentFocusSignals`, and `modelFocusSignals` taxonomy outputs. Each `context.digest.operatingActions[]` entry contains only `id`, an optional opaque per-digest `projectID`, `occurredAt`, a closed `kind` value (`approval`, `rollback`, `deployment`, `data_control`, `computer_use`, `model`, `tool`, `workflow`, or `other`), and a fixed `summary` label derived from that closed kind. Raw action types and operator- or user-authored action summaries are not included. The client reapplies this transformation at the hosted network boundary without changing the on-device request used by local features.

### Optional Cloud Models for Memory (opt-in, paid entitlement)

BurnBar Pro members can let the on-device memory engine use cloud models for extraction, reconciliation, embeddings, reranking, and "ask my memory" answers. This is off by default and requires two opt-ins: the base memory consent and a separate "Cloud models for memory" consent in **Settings → Privacy**. When it is on, the OpenBurnBar daemon on your Mac sends **redacted memory facts and your questions** — never raw transcripts, never anything the secret filter caught, never your sealed vault — **directly from your Mac to the provider you picked**, on your own API key or your own CLI subscription (Claude Code or Codex). **OpenBurnBar receives nothing:** no BurnBar server is in that path, and the only record is a content-free, hash-chained audit event stored on your Mac (purpose, provider, byte counts, outcome). By default only providers that promise no retention are used; OpenRouter requests are sent with `data_collection: deny`. A daily spend cap you set is enforced locally, and a fleet kill switch (`memory_cloud_models_enabled`) can disable the feature remotely without touching your memories.

### Optional Memory Backup and Device Sync (opt-in, paid entitlement)

If you turn on "Back up approved memories" in **Settings → Privacy**, the memories you have approved — including the ones the Memory MCP learns while you work — are replicated to your own Firestore namespace **end-to-end encrypted**. The body, kind, scope, confidence and citations of every memory are sealed on your Mac with a key held only in your Keychain and wrapped for each of your own devices; OpenBurnBar has no copy of that key and cannot decrypt any of it.

What a stored memory document actually contains: the sealed blob, an opaque identifier that is a keyed hash rather than anything readable, keyed hashes of the sources the memory came from, its kind, its review status, and three timestamps. What it never contains, enforced by the server's own security rules rather than by client good behaviour: the memory text, the body, the citations, any embedding or vector, your tags, your entities, your metadata, or your project names and paths. Secrets you asked BurnBar to retain never leave the device at all, and neither do memories awaiting your review, memories BurnBar flagged as prompt injection, or repository knowledge.

Turning the feature off stops all replication; deleting a memory writes a forget receipt that carries only opaque hashes and a coarse reason. This lane requires an active paid entitlement and is off by default.

### Optional Diagnostics (opt-in only)

If you enable crash reporting or diagnostics, anonymized crash reports may be sent to Sentry. This is disabled by default.

### Optional Usage Analytics (opt-in only)

If you enable analytics in **Settings → Analytics**, OpenBurnBar sends privacy-preserving product-usage events to Amplitude to help us understand which features are used and where flows break. This is **disabled by default** — the Amplitude SDK never initializes and no events are sent or buffered until you explicitly opt in. Events carry only feature identifiers, enumerated outcomes (e.g. success/failure), and counts/durations bucketed to coarse ranges — never your conversation content, prompts, responses, API keys, provider secrets, file paths, or message bodies. You can turn analytics off at any time; revoking consent stops all future sends immediately and flushes nothing.

### Optional Computer Use Audit Notarization (opt-in only)

If you choose to notarize a Computer Use audit session, OpenBurnBar submits only the 32-byte SHA-256 digest of your local `chain.jsonl` audit file to an OpenTimestamps calendar service and stores the returned `.ots` proof beside your local audit chain. During a support dispute, you may optionally send the `.ots` proof and chain file to OpenBurnBar so the server-side `validateOpenTimestampsProof` function can cross-check the session head and verify the proof through the configured OpenTimestamps verifier service. Screenshots and full action descriptors are not part of notarization, and remain local unless you explicitly include them in an audit export.

### What Agent Control (Computer Use) can see, and where it goes

This section exists because the sentence above is easy to read more broadly than it is meant. It is about *audit notarization only*. The agent data path is different, and we would rather state it plainly than let you infer something flattering and untrue.

When you grant Screen Recording, Accessibility or Automation and then run an agent:

- **No BurnBar server is in that path.** Nobody at BurnBar can see your screen. We do not receive, store, or proxy your screen contents.
- **What the agent reads goes to the model provider you already configured** — the same provider already receiving your prompts. A screenshot the agent requests, and the accessibility labels it reads to know what it is clicking, are tool results, and tool results are sent to that provider. If you are running a local model, they stay on this Mac; if you are running a hosted one, they go there.
- **During Agent Watch, frames go peer-to-peer to your own paired device**, not through us.
- **Every action is written to a hash-linked audit log on this Mac**, which you can read, verify, and export. Shell commands your agents run inside their own CLI are recorded by the system log rather than this chain.
- **Nothing starts on its own.** An agent only sees or touches your Mac inside a session you start, and by default every action stops for your approval. `Control-Option-Command-.` halts a session instantly from anywhere, as does locking your Mac.
- **Revoking is immediate.** Turning off Accessibility in System Settings halts a running session within about five seconds.

OpenBurnBar never asks macOS for any of these permissions until you have asked for that capability by name inside the app, and it always explains what the dialog means before macOS shows it. See [`PERMISSION_TRUST_ARCHITECTURE.md`](PERMISSION_TRUST_ARCHITECTURE.md).

---

## Data We Never Collect

- Your API keys or credentials for local-only usage tracking
- The plaintext content of your source code or agent conversations unless you explicitly send it through an optional hosted LLM/provider path. Memories replicated for backup or device sync are sealed on your device with a key we never hold, so their content is not readable by us either. We also never receive it when you enable cloud models for memory and pick a provider: that traffic goes from your Mac to the provider you chose. Chat/session cloud backup stores ciphertext; the legacy raw iCloud mirror is disabled for new writes.
- Personal identifying information beyond what your Apple or Google account provides for sign-in
- Any data from other applications
- Payment card numbers; subscriptions are handled by Apple, Google Play, or Stripe

---

## Third-Party Services and Data Subprocessors

The third parties below act as OpenBurnBar's data subprocessors. Each one receives data only when you opt into the feature named in its row — several are reached only after cloud sync or a paid entitlement is enabled. Every hosted egress path here uses OpenBurnBar-held credentials, never your own provider keys.

| Service | Purpose | Data shared | Privacy Policy |
|---------|---------|-------------|----------------|
| Firebase / Google Cloud | Authentication, optional Firestore sync, Cloud Functions, Secret Manager, hosted quota infrastructure | Account identifiers, opt-in usage/quota metadata, sealed (end-to-end encrypted) content blobs, and provider secrets held in Secret Manager | [firebase.google.com/support/privacy](https://firebase.google.com/support/privacy) |
| Apple iCloud | Legacy personal iCloud Drive mirror cleanup and future sealed archive support | Legacy local session-mirror files inside your own iCloud container | [apple.com/legal/privacy](https://www.apple.com/legal/privacy/) |
| Apple App Store / StoreKit | Subscription purchase, entitlement verification, and billing status | Purchase receipts and entitlement status | [apple.com/legal/privacy](https://www.apple.com/legal/privacy/) |
| Google Play Billing | Android subscription purchase and entitlement verification | Purchase tokens and entitlement status | [policies.google.com/privacy](https://policies.google.com/privacy) |
| Stripe | Web subscription checkout, customer portal, entitlement webhook processing | Billing/customer and subscription identifiers and payment status; card numbers are entered with and retained by Stripe, never OpenBurnBar | [stripe.com/privacy](https://stripe.com/privacy) |
| Perplexity | Primary provider for opt-in hosted Fusion (Elder Wand) web search | Your search query text only — no account keys, chat, session logs, or file contents | [perplexity.ai/hub/legal/privacy-policy](https://www.perplexity.ai/hub/legal/privacy-policy) |
| Tavily | Fallback provider for opt-in hosted Fusion web search | Your search query text only — no account keys, chat, session logs, or file contents | [tavily.com/privacy](https://www.tavily.com/privacy) |
| OpenRouter / MiniMax | Optional BurnBar Pro hosted LLM fallback for Intelligence Brief answers | Your Intelligence Brief question plus a privacy-bounded usage digest containing opaque per-digest ordinal project tokens (project_1, project_2, …), provider identifiers and display names, model identifiers, aggregate token/cost totals, quota bucket metadata, public model benchmark data, closed use-case/focus taxonomy signals, and operating-action IDs/timestamps with optional opaque project IDs plus closed kind/fixed-label pairs — `providers[].topInferredTaskTitles` and `models[].topInferredTaskTitles` are always empty; no raw transcripts, provider keys, file bodies, conversation message bodies, inferred task titles, raw action types, operator- or user-authored action summaries, cleartext project folder names, or guessable project hashes | [openrouter.ai/privacy](https://openrouter.ai/privacy) / [minimax.io/privacy](https://www.minimax.io/privacy) |
| OpenRouter | Optional Memory Pro cloud models (extraction, reconciliation, embeddings, rerank, answers) | Only when you enable cloud models for memory and choose this provider; redacted memory text and questions, sent with `data_collection: deny`; BurnBar receives nothing | [openrouter.ai/privacy](https://openrouter.ai/privacy) |
| Vercel AI Gateway | Optional Memory Pro cloud models | Only when you enable cloud models for memory and choose this provider; redacted memory text and questions; BurnBar receives nothing | [vercel.com/legal/privacy-policy](https://vercel.com/legal/privacy-policy) |
| Anthropic | Optional Memory Pro cloud models (API key or your Claude Code subscription) | Only when you enable cloud models for memory and choose this provider; redacted memory text and questions; BurnBar receives nothing | [anthropic.com/privacy](https://www.anthropic.com/privacy) |
| OpenAI | Optional Memory Pro cloud models (API key or your Codex subscription) | Only when you enable cloud models for memory and choose this provider; redacted memory text and questions; BurnBar receives nothing | [openai.com/policies/privacy-policy](https://openai.com/policies/privacy-policy) |
| OpenTimestamps calendar servers | Optional Computer Use audit-chain timestamping | Only a 32-byte SHA-256 hash of your local audit file | [opentimestamps.org](https://opentimestamps.org/) |
| Sentry | Optional crash reporting | Anonymized crash reports and stack traces — no content, keys, or secrets | [sentry.io/privacy](https://sentry.io/privacy) |
| Amplitude | Optional, opt-in product-usage analytics | Feature names, enumerated outcomes, and bucketed counts/durations — no content, keys, or secrets | [amplitude.com/privacy](https://amplitude.com/privacy) |

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

Account deletion is fail-closed across Firestore, Cloud Storage, Secret Manager,
and Firebase Authentication. OpenBurnBar does not report deletion complete or
remove the Firebase Auth identity while a Cloud Storage prefix or hosted secret
still needs cleanup. A failed attempt keeps any not-yet-erased data and minimum
server-side retry evidence while a durable write barrier prevents cached
sessions from recreating data; refresh tokens are revoked before cleanup and a
scheduled job resumes interrupted work. The server-only receipt stores a
SHA-256 UID hash, canonical intent/completion evidence, and cleanup
counts/categories, not object paths or external secret names. A minimal
tombstone uses the Firebase UID as its document identifier solely so Firestore
and Storage rules can deny that identity. See the
[account erasure runbook](runbooks/account-erasure.md) for statuses and operator
recovery.

---

## Changes to This Policy

If we make material changes, we will update the "Last updated" date above. Continued use after changes constitutes acceptance.

---

## Contact

For privacy questions or data deletion requests:

**Imagine That AI Limited Liability Company**
Email: privacy@imagine-that.ai
GitHub: [github.com/Imagine-That-Ai/BurnBar/issues](https://github.com/Imagine-That-Ai/BurnBar/issues)
