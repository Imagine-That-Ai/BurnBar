# Feature Gating & Evocative Upsell — Canonical Spec

**Goal.** Across every BurnBar app (iOS/iPadOS, macOS, Android), make the features that
require **Cloud / Cloud Pro / Cloud Ultra** *clearly and desirably* denoted. When an
unentitled user touches one, present an **evocative — not aggressive — benefit-first
"unlock" moment**: a beautiful, aspirational explanation of what that feature does for
them, wearing the holographic tier aesthetic from the marketing site, with a soft path
to subscribe. The feeling is *"oh, I want that"* — never *"BUY NOW."*

This spec is the single source of truth. Copy is final and honesty-checked. Reuse the
existing premium design language (`LockedFeatureVeil`, `HolographicCrestAura`,
`FoilCTAButton`, `MercuryCrest`, `ProTheme.Membership`) — do not invent a parallel one.

---

## 1. Tone & principles

- **Aspirational, second-person, concrete.** Paint the moment the feature gives them
  ("Walk away from your desk mid-run and pick the exact same conversation up on your
  phone"), not the SKU.
- **Evocative, never nagging.** One soft CTA. Header reads "Available on Cloud Pro," not
  "Upgrade required." A quiet "Maybe later." No red, no urgency timers, no dark patterns.
- **Show, don't wall.** Prefer revealing a blurred teaser of the real feature behind the
  veil (the `LockedFeatureVeil` pattern) so they *see* what they're unlocking.
- **Honest by construction.** Use only the vetted copy below. Never claim chat is
  end-to-end encrypted (E2E is true **only** for Floo device-to-device). Agent memory is
  "sealed on-device; the server searches without reading it." The cloak is **not**
  "inversion-proof" or "fully unlinkable."
- **Consistent.** Same catalog, same anatomy, same per-tier holographic palette on all
  three platforms.

---

## 2. Tiers, entitlements, palettes

| Tier | Entitlement (server) | Price | Holographic palette (`--holo-grad`) | Crest asset |
|------|----------------------|-------|--------------------------------------|-------------|
| **Cloud** | `burnbar_pro` | $7.99/mo · $79/yr | warm ember `FFD56B→FF8A3D→FF5C8A→B06BFF` | `CloudTierCrest` / `cloud_tier_crest` |
| **Cloud Pro** | `burnbar_pro_max` | $24.99/mo · $249/yr | cool aqua `5EF0C9→38D6F3→4F8BFF→8EF0A8` | `CloudTierCrestPro` / `cloud_tier_crest_pro` |
| **Cloud Ultra** | `burnbar_ultra` (⇒ also passes all Pro gates) | $59.99/mo · $599/yr | full-spectrum `FFD56B→7DD3FC→C084FC→5EEAD4→FF9EC7` | `CloudTierCrestUltra` / `cloud_tier_crest_ultra` |

**Tier ordering:** Ultra ⊇ Pro ⊇ Cloud. A user entitled at a higher tier passes all
lower-tier gates. Prices come live from StoreKit/Play — never hardcode dollar amounts in
gating UI; the amounts above are documentation/fallback only.

---

## 3. The feature → tier benefit matrix (FINAL copy)

Each entry: **id** · required tier · one-liner (the desire line) · 3–4 benefit bullets ·
honesty guardrails. This is the data for the shared `GatedFeature` catalog.

### `cloudBackup` — BurnBar Cloud (encrypted history + backup) — **cloud**
- **One-liner:** Every agent conversation, backed up and safe — so a wiped Mac never means a lost thread.
- Your whole session history rides along, encrypted, ready to pick back up the moment you sign in on any device
- Hosted quota refresh keeps your five-hour and weekly windows current even when your Mac is asleep
- Reinstall, switch machines, or hand off to a new laptop — your runs are already there waiting
- One verified subscription lights up everything in Cloud across iPhone, iPad, and Mac
- **Honesty:** "encrypted backup," not "end-to-end encrypted" chat. Avoid "we can never see it" for chat (server-assisted search exists).

### `crossDeviceResume` — Cross-device resume — **cloud**
- **One-liner:** Start on your Mac, keep going on your phone — the conversation never drops the thread.
- Walk away from your desk mid-run and pick the exact same conversation back up on your iPhone or iPad
- No copy-paste, no re-explaining context — the agent remembers where you both left off
- Your iPhone, iPad, and Mac stay in lockstep, the same backed-up history on every screen
- **Honesty:** "conversation backup & resume." Do not imply E2E of synced content.

### `cloudSearch` — Cloud search — **cloud**
- **One-liner:** Find that one answer from three weeks ago — searchable across every device, in seconds.
- Search your entire encrypted session history from any signed-in device, not just the Mac it happened on
- That fix, that command, that explanation — surface it instantly instead of scrolling forever
- Your past work becomes a searchable library, everywhere you are
- **Honesty:** "encrypted session history, searchable everywhere." Server-assisted search — not "E2E."

### `agentControl` — Agent Control — **cloud_pro**
- **One-liner:** Hand off the busywork and watch an agent do it — every click in plain sight, every step under your grant.
- Let an agent drive a real browser to fill the form, pull the data, click through the flow while your hands stay free
- Watch every move live on your Mac or mirrored to your phone — nothing ever happens out of sight
- Approve each step, or set the lines once and let it move freely inside them; mark off-limits windows it can never touch
- Stop it instantly with a shortcut or a gesture, and read back a tamper-proof record of everything it did
- **Honesty:** Public name **"Agent Control"** (never "Computer Use" in user copy). Does nothing until you grant it; grants are per-task and expire. Full-Mac reach is direct-download only.

### `floo` — Floo (phone ↔ Mac) — **cloud_pro**
- **One-liner:** Your Mac, in your pocket — see it, reach in, and run it from your phone, end to end private.
- Open a live view of your whole desktop, or just one window, and watch a long agent run from the couch
- Reach in and take over: tap, scroll, and type — touch a field and your keyboard rises and zooms right to it
- Send a file, screenshot, or photo either direction in a tap; share one clipboard across both devices
- Call your Mac, or unlock it with Face ID — your password sealed end to end, never in a log or a server
- **Honesty:** Public name **"Floo"** (never expose the long-form name or transport/codec). E2E claim **is valid here** — own paired devices only, every connection asks first.

### `hostedMCP` — Hosted Remote MCP — **cloud_pro**
- **One-liner:** Give any agent, anywhere, a secure line into your sealed memory and tools — no Mac required.
- Your hosted endpoint lets a remote agent recall your private knowledge without anything running on your Mac
- The server runs the search and routes the tools, but never reads your content
- Always-on access from your phone, a cloud agent, or another tool — isolated to your account alone
- **Honesty:** Server "searches without reading"; text AES-256-GCM sealed on-device, vectors cloaked. Do not imply the endpoint can read content.

### `dataVault` — Data Vault / agent memory — **cloud_pro**
- **One-liner:** A private memory your agents can recall — your repo docs, notes, and chats, sealed on your device.
- Your agents quietly recall the repo docs, notes, and chat-derived memories that matter, mid-task
- Every chunk of text is sealed on your device before it leaves — the server searches it without ever reading it
- Nearest-neighbor recall finds the right memory by meaning, not by exposing a single word of your content
- Sources, chunks, and storage you control, with one tap to delete any source or purge it all
- **Honesty:** "sealed on-device; server searches without reading it." Cloak is NOT inversion-proof/fully-unlinkable. Vault key is device-only; loss = unrecoverable. Pro tier = 10 sources / 50,000 chunks / 1 GB.

### `tenXMemory` — 10× agent memory — **cloud_ultra**
- **One-liner:** Give your agents a whole second brain — 10× the private memory they can recall while they work.
- Jump from 10 sources to 100, from 50,000 memory chunks to 500,000, from 1 GB to 10 GB of recallable knowledge
- Feed in far more repo docs, notes, and chat memories so your agents stay deeply in context across big projects
- Same on-device seal and cloaked vectors — the server still searches without reading a word
- Everything in Cloud Pro stays included: Floo, Agent Control, and the same hosted action and relay allowance
- **Honesty:** The 10× is the PENSIEVE_LIMITS jump pro{10,50000,1GB}→ultra{100,500000,10GB}. Same sealing/cloak honesty. No intro trial on Ultra.

---

## 4. The components (build once per platform, reuse the existing design language)

### 4.1 `GatedFeature` catalog (shared data)
A catalog keyed by feature id carrying: `id`, `publicName`, `requiredTier`,
`oneLineBenefit`, `benefitBullets: [String]`, `iconSystemName` (SF Symbol / Compose
icon), `crestAssetName`. **iOS + macOS share one Swift catalog in `OpenBurnBarCore`**
(`Sources/OpenBurnBarCore/Membership/GatedFeature.swift`) so both apps consume identical
copy. **Android** gets a parallel Kotlin catalog (`ui/pro/GatedFeature.kt`). Copy comes
verbatim from §3.

### 4.2 `CurrentTier` resolution (unified per platform)
A single enum `CloudTier { none, cloud, pro, ultra }` with `satisfies(requiredTier)`
(higher ⊇ lower). Derive from each platform's existing predicates:
- **iOS** `HostedQuotaSubscriptionStore`: `isActiveUltra` → ultra; else `isActivePro` → pro; else `isActive` → cloud; else none.
- **macOS** `MacCloudEntitlementStore`: `isUltraActive` → ultra; else `hostedComputerUseIsActive` → pro; else `isActive` → cloud; else none.
- **Android** `HostedQuotaSubscriptionStore`: **PREREQUISITE FIX** — today `isActive` is a flat Boolean that loses the tier. Add a `currentTier: StateFlow<CloudTier>` derived from `activeProductID` + the entitlement docs (`burnbar_ultra` → ultra, `burnbar_pro_max`/computer-use → pro, `hosted_quota_sync` → cloud). All Pro/Ultra gating depends on this.

### 4.3 `TierLockBadge` (resting denotation)
The small, beautiful marker on a gated entry point (row, card, nav link). A compact
holographic tier chip: the tier's mini crest + tier name ("Cloud Pro"), with a faint
iridescent sheen — a *premium shimmer-lock*, never a grey padlock. Sizes: inline (trailing
chip on a row) and corner (overlay on a card/tile). Reduce-motion → static.

### 4.4 The unlock experience (evolve `LockedFeatureVeil` + add `FeatureUnlockSheet`)
Two presentations of the SAME anatomy, both driven by a `GatedFeature`:
- **`LockedFeatureVeil`** (full-screen features e.g. Agent Control, Pensieve search,
  Conversation Cockpit): keep the blurred-teaser pattern but make it **tier+feature
  aware** — currently it takes no tier and always says "Open Cloud." It must show the
  **required tier's** holographic crest + the feature's headline/one-liner + bullets + a
  tier-specific CTA.
- **`FeatureUnlockSheet`** (a row/button that isn't a whole screen e.g. Data Vault row,
  Floo entry, a settings card): a presented sheet (`.sheet` / `ModalBottomSheet` /
  popover) with the same anatomy.

**Anatomy (top → bottom):**
1. **Hero:** large glowing holographic crest of the **required tier** (reuse
   `HolographicCrestAura` / `TierHolographicAccent` / `TierHoloAura` at a higher, hero
   opacity ~0.35–0.5 + soft glow), a small tier chip ("CLOUD PRO"), the **feature name**
   in the serif headline, and the **one-liner** beneath.
2. **"What you'll unlock":** the 3–4 benefit bullets, each with a sparkle/checkmark icon.
3. **Footer:** a compact line with the tier + live price, a single `FoilCTAButton`
   ("Unlock with Cloud Pro" → opens the store / starts purchase), and a quiet
   "Maybe later" dismiss. Aspirational subheader: "Available on Cloud Pro."

### 4.5 The gating helper (one-liner application)
A modifier/wrapper so applying a gate at any entry point is trivial and uniform:
- **SwiftUI:** `.gatedFeature(.agentControl, tier: store.cloudTier) { /* real action */ }`
  — if `tier.satisfies(.cloud_pro)` runs the action; else presents the unlock sheet. Also
  a `.tierLockBadge(.agentControl, tier:)` for the resting chip.
- **Compose:** `Modifier.gatedFeature(GatedFeature.AgentControl, currentTier, onUnlocked)`
  + a `TierLockBadge(feature)` composable.

---

## 5. Where to apply it (entry points found in the audit)

Apply the resting `TierLockBadge` to each gated entry point, and route its tap through the
unlock experience when the user's tier doesn't satisfy the requirement. **Priority: the
high-value features that today open for everyone and fail with a raw server string.**

**iOS / iPadOS**
- `YouView.computerUseRow` → **Agent Control** (pro) — gate the row + tap.
- `YouView.dataVaultRow` + `DataVaultControlView.pensieveSyncCard` → **Data Vault** (pro).
- `PensieveMemorySearchView` → **Data Vault / memory** (pro) — full-screen veil.
- `MercuryLiveSheet` / media entry (Hermes) → **Floo** (pro).
- Cloud-tier rows (`YouView.syncDiagnosticsCard`, Streams cockpit, Insights) → ensure they use the new tier-aware veil/badge (cloud).

**macOS**
- `ComputerUseSettingsView` (Run Setup) → **Agent Control** (pro).
- `MediaPermissionsView` (screenShare/voice) → **Floo** (pro) — note `MacMediaCapabilityGate` currently hardcodes `active:true`; gate it.
- `DataControlCenterView` / `SettingsView.DataControlCenterSettingsLanding` → **Data Vault** (pro).
- `CloudStoreSettingsView.remoteMCPCard` → **Hosted MCP** (pro). Cloud cards → cloud tier.

**Android**
- `ui/control` domains: `computer_use` → **Agent Control** (pro), `pensieve` → **Data Vault** (pro), `media` → **Floo** (pro), `external_mcp` → **Hosted MCP** (pro), `conversations_chat`/`session_logs` → cloud.
- Feature screens: Agent Control live screen, media — gate with the tier-aware `LockedFeatureVeil`.
- **First** land the §4.2 `currentTier` fix so Pro gates resolve correctly.

---

## 6. Definition of done
- One shared catalog per platform-family; identical §3 copy; honesty guardrails respected (grep finds no "Computer Use" in user copy, no "inversion-proof," no "end-to-end encrypted" on chat/memory).
- A tier+feature-aware unlock experience reused everywhere (no more raw "entitlementMissing" strings at a gated tap).
- Every §5 entry point wears a `TierLockBadge` when locked and routes its tap to the unlock sheet.
- Live StoreKit/Play prices; billing/purchase/entitlement logic untouched.
- Each platform compiles green; iOS verified on device.
