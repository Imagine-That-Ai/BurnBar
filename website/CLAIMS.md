# Claims → source matrix

Every public claim made on `burnbar.ai` traces back to repo evidence. This
matrix groups claims by page and points at the source the website draws from.
Items flagged **[verify]** still need Alberto's explicit sign-off before going
live — for example, where the App Store Connect state or the canonical GitHub
org is ambiguous in the repo today.

---

## Branding / entity

| Claim on site                                        | Source                                                | Notes                                                                                                                                                                                                                                                                |
| ---------------------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Privacy controller is **Imagine That AI LLC**        | `docs/PRIVACY.md:106`                                 | Used in footer, privacy policy, terms                                                                                                                                                                                                                                |
| Privacy contact `privacy@imagine-that.ai`            | `docs/PRIVACY.md:107`                                 |                                                                                                                                                                                                                                                                      |
| Site domain `burnbar.ai`                             | User confirmation (2026-05-12)                        | Registered through Namecheap                                                                                                                                                                                                                                         |
| Repository link `github.com/Imagine-That-Ai/BurnBar` | `git remote -v` (origin)                              | **[verify]** `Ajnunezg/BurnBar` is the URL the README advertises today; the site currently points at `Imagine-That-Ai/BurnBar` because that's where the published release artifacts live. Alberto should align README + site on a single canonical URL before launch |
| License **AGPL-3.0-only**                            | `/LICENSE`, `NOTICE`, `docs/legal/agpl-compliance.md` | Historical MIT notice preserved in `LICENSES/MIT-legacy.txt`; public repo metadata still needs live readback before launch.                                                                                                                                          |

---

## Home (`/`)

| Claim                                                                                                                  | Source                                                                                               |
| ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| "Watch your agents. Before the bill." (headline)                                                                       | Approved copy 2026-08-13 (Alberto); lived in `website/src/pages/index.astro`                         |
| "Your agents don't send a receipt. We do. Live in the menu bar, from local logs. No telemetry. No account." (hero sub) | Approved copy 2026-08-13 (Alberto); `SITE.description` + homepage hero                               |
| Local-first developer tool                                                                                             | `docs/MISSION.md:5`, `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5`                                    |
| Tracks tokens, dollars, quota                                                                                          | `README.md:54-67`                                                                                    |
| Across Claude Code, Codex, Cursor, Copilot, Factory, MiniMax…                                                          | `docs/PROVIDERS.md`, `AgentLens/Services/ProviderQuota/`                                             |
| Provider count in the stat band (computed from `PROVIDERS_PRIMARY.length`, not hardcoded)                              | `website/src/data/providers.ts` (`PROVIDERS_PRIMARY`); per-row evidence in the matrix sections below |
| 0 telemetry by default                                                                                                 | `docs/PRIVACY.md:21`                                                                                 |
| Works offline                                                                                                          | `docs/THREAT_MODEL.md:188`                                                                           |
| "Reads logs, not API keys"                                                                                             | `README.md:57`, verbatim                                                                             |
| Quote: "Your API keys never leave the providers you already trust…"                                                    | `README.md:57`                                                                                       |

---

## Product (`/product`)

| Claim                                                                                                                        | Source                                                                                        |
| ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Lives in menu bar (LSUIElement)                                                                                              | `README.md:342`, `AgentLens/Views/Popover/MenuBarPopoverView.swift`                           |
| Reads logs from `~/.claude/`, `~/.codex/`, `~/.factory/`, …                                                                  | `AgentLens/Services/LogParser/`; `AgentProvider.swift`                                        |
| Token + cost rollups today/week/month/all-time                                                                               | `AgentLens/Services/UsageAggregator.swift`, `LocalMetricsAggregator.swift`                    |
| Quota windows: 5h, 7d, weekly, plan-tier, premium                                                                            | `AgentLens/Services/ProviderQuota/`, `docs/PROVIDERS.md`                                      |
| Insight engine + daily digest                                                                                                | `AgentLens/Services/InsightEngine.swift`, `DailyDigestManager.swift`                          |
| Daemon-first control plane                                                                                                   | `OpenBurnBarDaemon/`, `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5-26`                         |
| 8-command CLI (health / controller / questions / followups / missions / mission-approve / simulator-runs / simulator-replay) | `OpenBurnBarDaemon/Sources/OpenBurnBarCLI/`, `README.md:76-86`                                |
| Hermes — local-index + gateway modes                                                                                         | `AgentLens/Views/Chat/`, `DESIGN.md:150-187`                                                  |
| Conversation Atoms                                                                                                           | `docs/CONVERSATION_ATOMS.md`                                                                  |
| Chart Studio — 10 Swift Charts + Mermaid                                                                                     | `docs/CHART_STUDIO.md`, `OpenBurnBarMobile/Views/ChartStudio/`                                |
| Hermes Realtime Relay (paid)                                                                                                 | `docs/HERMES_REALTIME_RELAY.md`, gated on `hosted_quota_sync` entitlement                     |
| iOS Live Activity + Siri shortcut                                                                                            | `CHANGELOG.md:522-525, 672-673`                                                               |
| Smart-display surfaces (Nest Hub + ULANZI Pixel Clock)                                                                       | `AgentLens/Services/Cast/`, `AgentLens/Services/SmartHub/`, `docs/SMART_DISPLAY_DEVICE_QA.md` |
| Honest confidence labels (exact / estimated / unavailable)                                                                   | `docs/PROVIDERS.md`, every provider row                                                       |

---

## Floo (`/floo`)

Floo is the marketing name for the phone ⇄ Mac companion experience (internally
"Mercury"). Per Alberto's direction the public site never exposes the internal
codename or any transport/codec/protocol detail — only the benefit and the
safety promise. The name + both expansions live in one place,
`src/data/capabilities.ts` (`FLOO`), so they change in a single edit.

| Claim                                                                   | Source                                                                                                                                                                                                                                                  |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| See your Mac's screen (full desktop or one window) on iPhone/iPad       | `AgentLens/Services/Media/ScreenCapturePipeline.swift`; Agent Watch surfaces                                                                                                                                                                            |
| Control the Mac from the phone (tap / scroll / type)                    | ComputerUse phone-as-controller intent path                                                                                                                                                                                                             |
| Keyboard rises + zooms to the focused field ("Smart Text / Smart Zoom") | `AgentLens/Services/ComputerUse/.../SmartZoomContextProvider.swift`; `mem:project_smart_text_double_tap`                                                                                                                                                |
| Send files either direction, resumes on drop                            | `AgentLens/Services/Media/` file transfer; `MediaFileTransferServiceFactory`                                                                                                                                                                            |
| Voice / video call between devices, rings when app closed               | `AgentLens/Services/Media/...VoIPCallTrigger.swift`; CallKit + push wake                                                                                                                                                                                |
| One shared clipboard (paste to Mac / grab from Mac)                     | `AgentLens/Services/ComputerUse/Mac/RemoteClipboardController.swift`                                                                                                                                                                                    |
| Unlock a locked Mac from the phone with Face ID / Touch ID              | `RemoteUnlock*` (sealed credential, biometric-gated); `mem:project_media_setup_handoff`                                                                                                                                                                 |
| Promise: only your own paired devices                                   | pairing/trust model in IrohRelay pairing stores (transport name kept off-site)                                                                                                                                                                          |
| Promise: end-to-end encrypted, we can't read it                         | sealed-credential + E2E relay design                                                                                                                                                                                                                    |
| Promise: every connection asks first; one tap ends it                   | consent/ringing + panic-halt paths                                                                                                                                                                                                                      |
| Status — "Built · rolling out"                                          | `mem:project_media_rollout` (all 7 phases source-complete 2026-05-15); real-world activation gates in `docs/runbooks/media-rollout-status.md`. **[verify]** which Floo capabilities are flag-live in the shipping build before claiming "available now" |

---

## Agent Control (`/control`)

Public name for the Computer Use capability family (Phases 8–13). Site copy is
benefit-first and trust-first; it deliberately omits implementation detail
(browser-driver name, input API, audit-chain mechanics) and says "tamper-proof
record" rather than naming the construction.

| Claim                                                               | Source                                                                                                                                       |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Watch the agent work, live, on Mac or mirrored to phone             | Agent Watch (read-only mirror + action log)                                                                                                  |
| Agent drives a real browser for you                                 | Browser computer-use (7 tool kinds; pre-action evidence screenshots)                                                                         |
| Agent can use the Mac itself when granted                           | Mac system input + accessibility inspector                                                                                                   |
| Approve each step, or trust within limits you set                   | Trust modes (manual / step / trusted) + scope rules                                                                                          |
| Off-limits windows / sites / screen areas; deny always wins         | Scope rules + deny registry + on-screen deny regions                                                                                         |
| Tamper-proof record of every action                                 | Content-addressed audit chain on disk                                                                                                        |
| Promise: nothing without your grant; grants are per task and expire | Agent capability grants (reset on backend/thread switch)                                                                                     |
| Promise: instant stop (shortcut / phone gesture / lock screen)      | Three independent panic-halt paths                                                                                                           |
| Promise: the Mac App Store build ships without it entirely          | Computer Use compiled out of MAS build (`#if DISTRIBUTION_MAS`)                                                                              |
| Status — "Direct download · behind your grant"                      | Phases 8–13 source-complete behind flags. **[verify]** App Store Connect submission / usage-description state before any "available" framing |

---

## Providers (`/providers`)

Whole-page source: `src/data/providers.ts` mirrors `docs/PROVIDERS.md` plus the
`QuotaRefreshActor.adapters` registry in `AgentLens/Services/ProviderQuota/QuotaRefreshActor.swift`.

Provider counts on the home page and providers page are now computed from
`PROVIDERS_PRIMARY.length` / `PROVIDERS_DETECTED.length` rather than written as
prose, so the headline numbers can never drift from the data again. Adding or
removing a row updates every count automatically.

| Claim                                                                | Source                                                                                                                                                                                                                                                                                                                                                                  |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cursor Agent (CLI) is a distinct provider from the Cursor editor row | `OpenBurnBarCore/Sources/OpenBurnBarCore/Services/LogParser/CursorAgentParser.swift:5-15` reads `~/.cursor-agent/sessions/` (transcript/chat_history JSONL + summary.json); registered in `ParserRegistry.swift:15`. Token counts are char-estimates (`TokenExtractionUtility`, lines 195-219) — the site labels the row **estimated**, not exact (verified 2026-07-11) |

### Newer provider rows (verified against parsers/adapters 2026-07-11)

| Claim (providers.ts row)                      | Source                                                                                                                                                                                                                      |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Xiaomi MiMo — exact cost, quota `yes`         | `OpenBurnBarCore/.../ProviderQuota/MimoQuotaAdapter.swift:38-114`; region hosts + `tp-` key prefix in `SharedModels/ProviderEndpointProfileRegistry.swift:131-149`; registered `QuotaRefreshActor.swift:96`                 |
| Antigravity — estimated cost, quota `partial` | Parser `OpenBurnBarCore/.../LogParser/AntigravityParser.swift:5-13` (transcript JSONL, `heuristicEstimate` provenance :320-321); quota `AntigravityQuotaAdapter.swift:84,194-196` (community-estimated caps, `.estimated`)  |
| DeepSeek — balance-only (cost `unavailable`)  | `OpenBurnBarQuotaAdapters.swift:104-203` — `GET api.deepseek.com/user/balance` credit buckets; no usage parser exists (`AgentProvider.swift:69` pins `deepseek-no-local-logs`)                                              |
| OpenCode — exact cost, quota `partial`        | `AgentLens/Services/UsageAggregatorParsers+More.swift:413-455` reads `~/.local/share/opencode/opencode.db` (exact per-message tokens/cost); quota is a local plan-pressure estimate (`OpenCodeQuotaAdapters.swift:258-296`) |
| Hermes — exact cost, quota `no`               | `OpenBurnBarCore/.../LogParser/HermesParser.swift:15,50-90` reads `~/.hermes/state.db` + session snapshots; exact usage buckets preferred (:268-284); no quota adapter registered                                           |
| Pi Agent — exact cost, quota `no`             | `AgentLens/Services/UsageAggregatorParsers+More.swift:782-813` reads `~/.pi/sessions/*.jsonl`; exact when inline `usage` blocks present, estimate otherwise                                                                 |
| xAI (Grok) — estimated cost, quota `yes`      | Parser `OpenBurnBarCore/.../LogParser/GrokParser.swift:5-9,103-104` (`~/.grok/sessions/`); quota `XAIQuotaAdapter.swift:7-60` (Management API prepaid balance/usage + SuperGrok event-log pacing)                           |

| Claim                                                                                                                                               | Source                                                                                                                                                       |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Provider matrix rows (Claude Code, Codex, OpenAI, Copilot, Cursor, Factory, MiniMax, Z.ai, Warp, Ollama, Kimi, OpenRouter, Anthropic, Aider, Forge) | per-adapter source files under `AgentLens/Services/ProviderQuota/` and the audits in `docs/PROVIDER_USAGE_DATA_REFERENCE.md` / `docs/PROVIDER_DATA_AUDIT.md` |
| Claude Code / Codex are self-hosted only                                                                                                            | `functions/src/index.ts:600-605`, `docs/HOSTED_QUOTA_SYNC.md:11-18`                                                                                          |
| Anthropic admin-key gotcha                                                                                                                          | `docs/PROVIDERS.md:44`, `docs/research-provider-usage-apis.md:189`                                                                                           |
| Cursor + Factory rely on session cookies                                                                                                            | `docs/PROVIDERS.md:37-38`, `docs/PROVIDER_DATA_AUDIT.md:39-51`                                                                                               |
| Z.ai endpoint is undocumented                                                                                                                       | `docs/research-provider-usage-apis.md:269-272`                                                                                                               |
| Warp requires a spoofed User-Agent                                                                                                                  | `docs/PROVIDERS.md:39`, `docs/PROVIDER_USAGE_DATA_REFERENCE.md:453-455`                                                                                      |
| OpenRouter is the only vendor that returns dollar cost                                                                                              | `docs/research-provider-usage-apis.md:236`                                                                                                                   |
| Gemini AI Studio has no programmatic quota API                                                                                                      | `docs/PROVIDER_DATA_AUDIT.md:127-130`                                                                                                                        |
| Detection-only providers (Cline, Roo Code, Kilo Code, Augment, Windsurf, Goose, OpenClaw, Gemini CLI)                                               | `AgentLens/Services/ProviderQuota/StubQuotaAdapter.swift:1-11`                                                                                               |

Site notes that `PROVIDERS.md` is stale on Kimi today — code ships
`KimiQuotaAdapter` and the audit doc upgrades Kimi to `.exact`. The website
treats Kimi as exact, which matches the running code.

---

## Pricing (`/pricing`)

| Claim                                                                                                                                                                                      | Source                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Free tier — full local product                                                                                                                                                             | `docs/PRIVACY.md:21,34`, `docs/HOSTED_QUOTA_SYNC.md:38-68`                                                                                                                                                         |
| BurnBar Cloud — `$7.99/mo`, `$79/yr`, `com.openburnbar.pro.monthly`, `com.openburnbar.pro.annual`                                                                                          | `GTMMasterPlan.MD:29-34`, `functions/src/config.ts`, `functions/src/callables/stripe.ts`, `functions/src/appstore/reconciler.ts`                                                                                   |
| BurnBar Cloud Pro — `$24.99/mo`, `$249/yr`, `com.openburnbar.proMax.v2.monthly`, `com.openburnbar.proMax.annual`                                                                           | `GTMMasterPlan.MD:29-34`, `functions/src/config.ts`, `functions/src/callables/stripe.ts`, `functions/src/appstore/reconciler.ts`                                                                                   |
| BurnBar Cloud Ultra — `$59.99/mo`, `$599/yr`, `com.openburnbar.ultra.monthly`, `com.openburnbar.ultra.annual.v2`, entitlement `burnbar_ultra`                                              | `docs/PENSIEVE.md:11,13`, `functions/src/config.ts:106-111,171-175`, `functions/src/callables/shared.ts:114`, `functions/src/appstore/reconciler.ts:61`                                                            |
| Cloud Ultra mirrors Cloud Pro's hosted Agent Control + relay allowance and caps (same allowance object)                                                                                    | `docs/PENSIEVE.md:188`, `functions/src/callables/knowledgeMemory.ts:104-113`                                                                                                                                       |
| Cloud Ultra = everything in Cloud Pro plus 10× private agent memory (Pensieve limits) — Pro: 10 sources / 50,000 chunks / 1 GB; Ultra: 100 sources / 500,000 chunks / 10 GB                | `functions/src/callables/knowledgeMemory.ts:134-137` (`PENSIEVE_LIMITS`), `docs/PENSIEVE.md:200-204`                                                                                                               |
| Agent memory = repo docs, notes, and chat-derived memories your agents recall; text sealed on-device + cloaked vectors, server runs nearest-neighbor search without reading content (E2EE) | `docs/PENSIEVE.md:178-188`, `OpenBurnBarCore/.../CloudVaultCrypto.swift`, `tools/openburnbar-mcp-remote/src/embed.ts` (vault-key cloaking)                                                                         |
| Legacy Hosted Quota Sync `$4.99` is grandfathered only, not a new purchase tier                                                                                                            | `GTMMasterPlan.MD:91-99`, `functions/src/callables/shared.ts`, `functions/src/appstore/reconciler.ts`                                                                                                              |
| Cloud Pro allowance — 500 hosted actions and 50 relay-accounting GB monthly                                                                                                                | `GTMMasterPlan.MD:38-79`, `functions/src/cloudProAllowanceCore.ts`                                                                                                                                                 |
| Cloud Pro monthly caps — 2,000 hosted actions and 300 relay-accounting GB                                                                                                                  | `GTMMasterPlan.MD:38-79`, `functions/src/cloudProAllowanceCore.ts`                                                                                                                                                 |
| Top-ups — `$4.99` for 100 hosted actions, `$4.99` for 50 relay-accounting GB                                                                                                               | `GTMMasterPlan.MD:59-75`, `functions/src/cloudProAllowanceCore.ts`, `functions/src/callables/stripe.ts`                                                                                                            |
| Hosted quota refresh, conversation backup, cloud search, and synced memory are Group A / Cloud features                                                                                    | `GTMMasterPlan.MD:28-34`, `functions/src/callables/shared.ts`                                                                                                                                                      |
| Floo and Agent Control are Group B / Cloud Pro features                                                                                                                                    | `GTMMasterPlan.MD:28-34`, `functions/src/callables/shared.ts`, `functions/src/voipPush.ts`                                                                                                                         |
| No public introductory offer is promised; the active purchase surface shows price, cadence, tax, and renewal terms before confirmation                                                     | `website/src/components/PricingPlans.astro`, `website/src/pages/pricing.astro`, active Stripe Checkout / App Store purchase sheet                                                                                  |
| Web Stripe and App Store purchases are available; Android purchase availability waits for the public Play Store listing                                                                    | `website/src/data/site.ts`, `website/src/data/faq.ts`, `website/src/pages/pricing.astro`                                                                                                                           |
| Refund and cancellation handling follows Apple, Google Play, or Stripe platform state                                                                                                      | `GTMMasterPlan.MD:584-593`, `functions/src/callables/stripe.ts`, `functions/src/appstore/reconciler.ts`                                                                                                            |
| Subscription state on launch                                                                                                                                                               | **Verified live 2026-07-11**: iTunes Lookup API returns OpenBurnBar 1.0 (`com.openburnbar.app`, id 6766366964) released 2026-05-26 — the app is on the App Store; `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md` is stale |

---

## Privacy & trust (`/privacy`)

| Claim                                                          | Source                                                                                           |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| "By default, OpenBurnBar collects nothing"                     | `docs/PRIVACY.md:21`, verbatim                                                                   |
| Local SQLite path                                              | `docs/THREAT_MODEL.md:128`, `docs/reviews/SECURITY_PRIVACY_REVIEW.md:116`                        |
| Daemon UNIX socket                                             | `docs/THREAT_MODEL.md:48,55`                                                                     |
| Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`        | `SECURITY.md:33-35`                                                                              |
| Firebase metadata-only default sync                            | `docs/PRIVACY.md:24-34`                                                                          |
| Chat-message + session-log backup gated on `hosted_quota_sync` | `docs/PRIVACY.md:38`                                                                             |
| iCloud container `iCloud.com.openburnbar.app`                  | `docs/reviews/SECURITY_PRIVACY_REVIEW.md:133`, `docs/PRIVACY.md:42-44`                           |
| App Check enforced at Firestore                                | `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md:3-7`                                                     |
| Hosted credential secrets in Google Cloud Secret Manager       | `docs/PRIVACY.md:48`, `docs/HOSTED_QUOTA_SYNC.md:140-145`                                        |
| Three trust-zone architecture diagram                          | Synthesized from `docs/THREAT_MODEL.md:48-156` + `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5-26` |
| Account deletion paths                                         | `docs/PRIVACY.md:87-92`                                                                          |
| Sentry diagnostic seed                                         | `docs/reviews/SECURITY_PRIVACY_REVIEW.md:180`. **[verify]** matches shipping build               |
| Opt-in Amplitude usage analytics, off by default               | `docs/PRIVACY.md` § Optional Usage Analytics; `website/src/pages/legal/privacy-policy.astro` §5  |

---

## Security model (`/security`)

| Claim                                                                                         | Source                                                                                                                                                                                              |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Filesystem-ACL'd UNIX socket + token auth                                                     | `docs/THREAT_MODEL.md:72`, `SECURITY.md:34`                                                                                                                                                         |
| ECIES (P-256 + AES-GCM) cross-device credential escrow                                        | `docs/THREAT_MODEL.md:201-230`                                                                                                                                                                      |
| App Store JWS verified against pinned Apple root CAs                                          | `docs/THREAT_MODEL.md:242-250`                                                                                                                                                                      |
| Owner-scoped Firestore rules + secret-field-name denylist                                     | `docs/THREAT_MODEL.md:140,221`, `firestore.rules`                                                                                                                                                   |
| Direct-download releases signed + notarized + stapled                                         | `docs/RELEASE_MACOS.md:42-55`; the `/download` button serves the first-party `downloads.burnbar.ai` host (Cloudflare R2 custom domain, verified live 2026-08-30)                                    |
| Direct-download per-release SBOM + checksums + provenance JSON                                | `docs/RELEASE_MACOS.md:43-83`; branded-host assets verified SHA-256-identical to the immutable GitHub v1.0.40+repair.36 release assets (2026-08-30)                                                 |
| **Known limit:** direct-download macOS app is not sandboxed; Mac App Store build is sandboxed | `docs/THREAT_MODEL.md:113-124`, `docs/RELEASE_MACOS.md`                                                                                                                                             |
| **Known limit:** Provider API calls aren't certificate-pinned                                 | `docs/reviews/SECURITY_PRIVACY_REVIEW.md:94`                                                                                                                                                        |
| **Known limit:** Cursor connector tunnel routes through Cloudflare                            | `docs/THREAT_MODEL.md:152-156`                                                                                                                                                                      |
| **Known limit:** HTTP gateway is loopback-only by default                                     | `docs/reviews/SECURITY_PRIVACY_REVIEW.md:99-101` flags non-loopback bind as a risk. **[verify]** the shipping default is loopback-only                                                              |
| **Known limit:** Encryption-key recovery file                                                 | `SECURITY.md:35` describes the SOTA design; `docs/reviews/SECURITY_PRIVACY_REVIEW.md:55-57` still flags the legacy recovery file. **[verify]** which is current in the shipping build before launch |

---

## Memory MCP (`/memory`)

Every figure and every sentence on this page reads from
`website/src/data/memory.ts`. That file carries the source path for each block
in a comment, and the page renders a `Source ·` line under each section, so the
claim and its evidence ship together. Edit the data file; the page and this
table follow.

The page covers the **whole local MCP server**, not just its memory engine:
all 94 tools it registers — the 68 `burnbar_*` memory, code-intelligence,
session-search and spend tools, plus the 26 `ministry_*` / `castle_*` /
`bench_*` agent-launcher and benchmarking tools — the nine capability
switches that gate them, and the fan-out surfaces alongside the memory
story. `scripts/test-memory-copy.mjs` reads `server.py` and refuses to build
a page that has drifted from it in either direction, across every tool the
server registers, not just the `burnbar_*` ones.

### Product mechanics

| Claim                                                                                                                                                                                                                                         | Source                                                                                                                                                                                                                                                                             |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **gate** · "37 MCP tools" (hero, meta description, verification step 1)                                                                                                                                                                       | `tools/openburnbar-mcp/server.py` — `MEMORY_TOOLSET`, counted (37 entries), served when `BURNBAR_MCP_TOOLSET=memory`. The meta description derives it rather than spelling it, because the gate strips tags and would never have seen a hardcoded numeral in an attribute          |
| **gate** · "The same server carries **94** tools in total" (hero, first paragraph)                                                                                                                                                            | `server.py` — every `@mcp.tool()` definition: 68 `burnbar_*` + 26 orchestration. Asserted both ways — the total must be printed as the total, and the `burnbar_*` subset must never be printed as "in total". An earlier revision opened on 63 while § 11 of the same page said 89 |
| Works with Claude Code, Cursor, Codex CLI, Claude Desktop, Hermes                                                                                                                                                                             | `tools/openburnbar-mcp/README.md` §§ Cursor / Codex CLI / Hermes Agent / Claude Desktop; repo `.mcp.json`                                                                                                                                                                          |
| Store path `~/Library/Application Support/OpenBurnBar/openburnbar-memory.sqlite`                                                                                                                                                              | `tools/openburnbar-mcp/README.md` § Local memory engine                                                                                                                                                                                                                            |
| Bodies + history bodies AES-256-GCM sealed; key mode 0600; DB and WAL/SHM sidecars 0600                                                                                                                                                       | `tools/openburnbar-mcp/README.md` § Encrypted at rest                                                                                                                                                                                                                              |
| Works without the daemon; a signed install rejecting the process is a status, not an error                                                                                                                                                    | `tools/openburnbar-mcp/README.md` § Works without the daemon; `docs/superpowers/2026-09-02-memory-mcp-v2-design.md` §1                                                                                                                                                             |
| Seven-stage write pipeline (ingest → extract → gate → injection screen → reconcile → store → recall)                                                                                                                                          | `docs/superpowers/2026-09-02-memory-mcp-v2-design.md` §4.1; `tools/openburnbar-mcp/memory_engine/`                                                                                                                                                                                 |
| Ingest is idempotent on the input's content hash                                                                                                                                                                                              | `tools/openburnbar-mcp/README.md` § Automatic collection — **Idempotent**                                                                                                                                                                                                          |
| Secret policies `redact` (default) / `reject` / `retain`; gate covers tags, entities, metadata, `source_path`                                                                                                                                 | `tools/openburnbar-mcp/README.md` § Secrets and PII                                                                                                                                                                                                                                |
| `retain` is capability-gated, hidden from default recall, never mirrored, and never exported by default — the one path that returns the verbatim text is an export asked for by name, with `sensitive_read` granted and `include_secrets` set | `tools/openburnbar-mcp/README.md` § Experimental: retain secrets. The page says "not exported by default", never "never leaves the device" — the stronger phrasing was in an earlier revision and is not what the README supports                                                  |
| Injection sentinels in any field quarantine the row; quarantined rows are excluded from recall                                                                                                                                                | `tools/openburnbar-mcp/README.md` § Untrusted recall boundary                                                                                                                                                                                                                      |
| Hybrid recall: BM25 + vectors, reciprocal-rank fusion, then salience rerank                                                                                                                                                                   | `docs/superpowers/2026-09-02-memory-mcp-v2-design.md` §4.2                                                                                                                                                                                                                         |
| `RRF k=60`, lexical weight 0.6, semantic weight 1.0                                                                                                                                                                                           | `tools/openburnbar-mcp/memory_engine/constants.py` — `RRF_K`, `RRF_LEXICAL_WEIGHT`, `RRF_SEMANTIC_WEIGHT`                                                                                                                                                                          |
| Twelve kinds and their salience weights, verbatim                                                                                                                                                                                             | `tools/openburnbar-mcp/memory_engine/constants.py` — `KINDS`, `KIND_WEIGHTS`                                                                                                                                                                                                       |
| Personal-scope kinds (`preference`, `profile`, `relationship`) follow you across projects                                                                                                                                                     | `constants.py` — `PERSONAL_KINDS`; `README.md` § `burnbar_recall`                                                                                                                                                                                                                  |
| 30-day half-life for `event`/`todo`, 365 days otherwise                                                                                                                                                                                       | `constants.py` — `SHORT_HALF_LIFE_KINDS`, `HALF_LIFE_DAYS_SHORT`, `HALF_LIFE_DAYS_LONG`                                                                                                                                                                                            |
| **gate** · Access boost capped at 1.5×                                                                                                                                                                                                        | `memory_engine/engine.py` — `compute_salience`'s `min(1.5, …)`, parsed by invariant 3. It lives in the engine rather than in `constants.py`, and until this PR it sat inside a gate-checked-looking block with no gate on it                                                       |
| Duplicates collapse above cosine 0.92 or Jaccard 0.75                                                                                                                                                                                         | `constants.py` — `DEDUP_COSINE`, `DEDUP_JACCARD`                                                                                                                                                                                                                                   |
| `SessionEnd` hook: prose only, 400 messages / 200,000 chars, 20-second budget, exit 0, nine statuses                                                                                                                                          | `tools/openburnbar-mcp/README.md` § Automatic collection from Claude Code sessions                                                                                                                                                                                                 |
| "The first session end on a new machine usually memorizes nothing" (stated, not hidden)                                                                                                                                                       | `tools/openburnbar-mcp/README.md` § Automatic collection — the bootstrap paragraph, verbatim in substance                                                                                                                                                                          |
| Pro models: five `memory-*` purposes, no key in the engine, 15-minute scoped bearer, degrades locally                                                                                                                                         | `tools/openburnbar-mcp/README.md` § Pro models (opt-in)                                                                                                                                                                                                                            |

### Measurements (the `/memory#proof` bench)

The page labels each figure **Pinned** or **Measured, not pinned**. A pinned
figure has a committed assertion that fails CI if it regresses; an unpinned one
needs a local model and says so on the page.

| Figure on the page                                          | Command                                       | Pin                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------------------------------------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Extraction recall **0.667** (20 of 30)                      | `eval_memory.py --extraction --provider none` | `tools/openburnbar-mcp/tests/test_eval_extraction.py` — `RECALL_FLOOR = 0.65`                                                                                                                                                                                                                                                                             |
| Extraction precision **1.0**                                | same run                                      | _not pinned_ — labelled as such on the page                                                                                                                                                                                                                                                                                                               |
| **1** invented fact across 7 empty conversations            | same run                                      | `test_eval_extraction.py` — `emptyCaseFacts <= 2`                                                                                                                                                                                                                                                                                                         |
| **0** credential leaks into an extracted fact               | same run                                      | `test_eval_extraction.py` — `leaks == 0`                                                                                                                                                                                                                                                                                                                  |
| **gate** · **25 of 25** credential shapes detected raw      | `eval_memory.py --gate`                       | `test_eval_extraction.py::test_gate_matrix_detects_every_raw_shape` — `len(matrix) == 25` **and** every row's `raw` column. The count is pinned as of this PR; it was `>= 12`, which pinned the completeness and left the total free to drift. `test-memory-copy.mjs` parses `_secret_shapes()` and holds the page to the same number from the other side |
| Four encoded gaps, named individually                       | `eval_memory.py --gate`                       | `tools/openburnbar-mcp/README.md` § Gate coverage — the same four, verbatim                                                                                                                                                                                                                                                                               |
| Hybrid recall@5 **0.90**, MRR **0.678**                     | `eval_memory.py --provider auto`              | _not pinned_ — needs local Ollama `nomic-embed-text`; the page says so                                                                                                                                                                                                                                                                                    |
| Rules-only reconciliation agreement **0.42** on 64 cases    | `eval_memory.py --judge`                      | `test_eval_extraction.py::test_rules_baseline_on_judge_gold_is_recorded`                                                                                                                                                                                                                                                                                  |
| Gold-set sizes: 36 conversations, 64 judge cases            | `tools/openburnbar-mcp/eval/*.json`           | `test_eval_extraction.py` — `cases >= 25`, `len(cases) >= 60`                                                                                                                                                                                                                                                                                             |
| **gate** · Adversarial gate: 8 caller-controlled placements | —                                             | `tests/test_gate_adversarial.py` — `BODY_CONTEXTS + AUX_CONTEXTS`, parsed by `test-memory-copy.mjs` and compared to `GATE_PLACEMENTS`                                                                                                                                                                                                                     |

### The device boundary

| Claim                                                                                                                                                              | Source                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Transcripts read locally, written locally, never uploaded — including by the session hook                                                                          | `tools/openburnbar-mcp/README.md` § Automatic collection — **Privacy**                                          |
| Cloud models for memory: two consents, own key or own CLI subscription, **BurnBar receives nothing**                                                               | `docs/PRIVACY.md:83-85`                                                                                         |
| Encrypted backup: sealed blob, opaque keyed-hash id, keyed source hashes, kind, review status, three timestamps — and nothing else, enforced by the server's rules | `docs/PRIVACY.md:87-93`                                                                                         |
| Retained secrets, unreviewed memories, injection-flagged memories and repository knowledge never leave                                                             | `docs/PRIVACY.md:91`                                                                                            |
| **Not shipped:** cross-device pull and merge. Backup is on `main`; the pull half is in review                                                                      | `docs/superpowers/plans/2026-09-03-memory-blind-sync.md` § Shipping shape — PR 1 shipped, PR 2 is the pull half |

The page states the unshipped half explicitly rather than omitting it, in its
own visually distinct "Not shipped" lane. Do not promote that lane to
"available" until the pull PR is merged and `docs/PRIVACY.md` describes device
sync as live.

**A second precedent, named rather than left implicit.** Item 7 of the pricing
rules above sets one: _"Team plan copy — kept off the page until built."_
`/memory` takes the other route and ships an explicit "Not shipped" lane. Both
are legitimate and the difference is the reader's expectation, not our
comfort: silence is right when nobody is looking for the feature, and a named
absence is right when the surrounding section would otherwise imply the
feature exists — a boundary diagram with backup on it invites the question
"and the way back?", so the page answers it. The rule is the same either way:
never render an unshipped thing as available, and let the gate hold the line
(`test-memory-copy.mjs` invariant 7 refuses three overclaim phrasings). When
in doubt between the two, prefer silence; a named absence needs a lane of its
own and a gate behind it.

### Stated limits

`/memory#limits` publishes eight limits with sources: lexical-only recall
without an embedding provider, the conservative extractor, the 0.42 rules
baseline, the four encoded gate gaps, plaintext vectors and metadata on disk,
macOS-only support, the parts of the server that assume the OpenBurnBar app is
present, and the "adjacent tooling · best-effort support" level from
`tools/openburnbar-mcp/README.md` § Support level. Six more limits are stated
inside the sections they belong to rather than deferred to the end — one each
for time, forget, review, code intelligence, sessions, and each surface in
§ The rest of the server. If any of these is fixed, remove it from
`src/data/memory.ts` in the same PR that fixes it.

### Coverage round — the whole server, not the highlights

The first pass covered the memory core and named six of the server's tools.
This round makes the page's coverage claim literal and mechanical: `/memory`
now describes every product surface the server has, and
`website/scripts/test-memory-copy.mjs` fails the build if the page and
`tools/openburnbar-mcp/server.py` disagree about what exists.

**What the gate watches, and what it does not.** This is the sentence a
reviewer uses to decide where to spend their attention, so it says the true
thing rather than the flattering one. `scripts/test-memory-copy.mjs`
mechanically enforces the tool atlas and the numbers around it: every tool
`server.py` registers, the capabilities named at its denial sites, the
condition that reaches a guarded one, its memory-toolset mark, the counts the
page prints, the capability table, the retrieval constants, each measurement
inside its own card, and the two gate-coverage figures. It does **not** read
`_write.py`, `_read.py`'s audit labels, the resume shapes or the code tiers —
those are traced by hand to the file named beside them and re-read when that
file changes. Rows in the subsections below say which they are:

- **gate** — a script reads both sides and fails the build if they disagree.
- **source** — traced by hand to the named file; this ledger is the pin, and
  a reviewer re-reading that file is the check.
- **editorial** — our own words, derived from the rows around them and stated
  deliberately rather than implied.

Unmarked rows in those subsections are **source**.

#### Time and supersession (`/memory#time`)

| Claim                                                                                                                                                                                                                                         | Source                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Memories carry `valid_from`; a retired one carries `valid_to` and `superseded_by`, and stays readable in history                                                                                                                              | `tools/openburnbar-mcp/memory_engine/_write.py` (the `memories` insert and `_retire`); `_read.py`                                                                                                                                    |
| Restating a fact reinforces the existing row rather than adding a second one                                                                                                                                                                  | `memory_engine/_write.py` — the exact-duplicate branch and `_reinforce`                                                                                                                                                              |
| A changed value on the same subject retires the old row and keeps its history                                                                                                                                                                 | `memory_engine/_write.py` — supersession; `tools/openburnbar-mcp/README.md` § Cross-store lifecycle                                                                                                                                  |
| A negation retires the fact and stores nothing                                                                                                                                                                                                | `README.md` § Cross-store lifecycle — negation/`DELETE`                                                                                                                                                                              |
| A, then B, then A again brings the retired row back under its original id                                                                                                                                                                     | `README.md` § Structured refusals, verbatim in substance                                                                                                                                                                             |
| An expired duplicate is reactivated (`UPDATE`, `reactivated: true`)                                                                                                                                                                           | `README.md` § Structured refusals                                                                                                                                                                                                    |
| Re-remembering rejected text returns `NONE` with `PREVIOUSLY_REJECTED`; editing text into another row's text returns `DUPLICATE_BODY`                                                                                                         | `README.md` § Structured refusals                                                                                                                                                                                                    |
| History carries wrapped before/after bodies plus `decidedBy` (`rules` or `judge:<provider>/<model>`) and a rationale                                                                                                                          | `README.md` § Reconciliation judge; `server.py burnbar_memory_history`                                                                                                                                                               |
| A quarantined or rejected memory reports `bodiesRedacted` and withholds its bodies from **both** revision surfaces — `burnbar_memory_history` and `burnbar_memory_timeline` — so the weaker, unscoped one is not a way past the gate decision | `server.py burnbar_memory_history` / `burnbar_memory_timeline` docstrings; `memory_engine/_read.py history` / `timeline`; `tests/test_memory_timeline.py` — `test_a_quarantined_memory_does_not_hand_its_body_to_the_history_either` |
| **gate** · 30-day half-life for `event`/`todo`, 365 otherwise, access boost capped at 1.5×                                                                                                                                                    | `memory_engine/constants.py` — gate-checked against the page (invariant 3)                                                                                                                                                           |
| `expires_at` is validated rather than allowed to become an immortal row; `immutable` rows are never retired                                                                                                                                   | `README.md` § Structured refusals; `tests/test_memory_judge.py:83-84`                                                                                                                                                                |
| **editorial** · **Stated limit:** supersession needs a cue, so the rules prefer to add — this is the 0.42 on the same page                                                                                                                    | `eval_memory.py --judge`; `README.md` § Reconciliation judge table                                                                                                                                                                   |

#### Forget and deletion (`/memory#forget`)

| Claim                                                                                                                                                 | Source                                                                                                                                                                                                                      |
| ----------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One `burnbar_forget` empties five tables — memory, vector, history, relations, vault                                                                  | `memory_engine/_read.py` — `forget()` returns exactly `["memory", "vector", "history", "relations", "vault"]`. `_purge()` reaches them with seven `DELETE`s and an `UPDATE`, so the page counts tables and never statements |
| It also deletes the replay receipt pointing at the memory and clears `superseded_by` on rows behind it                                                | `memory_engine/_read.py` — `_purge()`                                                                                                                                                                                       |
| The audit event is label-only: `local hard delete · vault purged · history purged · vectors purged`                                                   | `memory_engine/_read.py` — the `audit_event(... labels=[...])` call, verbatim                                                                                                                                               |
| The daemon mirror is forgotten by the daemon's own content-derived id; a never-mirrored row reports `skipped`                                         | `README.md` § Works without the daemon; `server.py burnbar_forget`                                                                                                                                                          |
| An unreachable daemon leaves a metadata-only tombstone that keeps the id and project path and clears on `localDeleted: true`                          | `README.md` § Works without the daemon                                                                                                                                                                                      |
| `burnbar_forget_all` is two-step: `wouldDelete` + `selectionToken`, then `confirm="DELETE"` + that token, refused with `SELECTION_CHANGED`            | `server.py burnbar_forget_all` docstring; `README.md` § Tools                                                                                                                                                               |
| Supersession, negation, quarantine and confirmed bulk deletion each forget the daemon mirror                                                          | `README.md` § Cross-store lifecycle                                                                                                                                                                                         |
| `burnbar_cloud_delete_project_memory` hard-deletes the hosted sealed snapshot and returns a content-free tombstone receipt; local stays authoritative | `README.md` § Local memory engine (cloud paragraph); `server.py` docstring                                                                                                                                                  |
| In the app's backup lane, deleting a memory writes a forget receipt carrying only opaque hashes and a coarse reason                                   | `docs/PRIVACY.md:93`                                                                                                                                                                                                        |
| **editorial** · **Stated limit:** a forget cannot reach an export you already took, or the transcript the memory came from                            | Editorial, derived from the above — deliberately stated rather than implied                                                                                                                                                 |

#### Review, analytics and audit (`/memory#review`)

| Claim                                                                                                                                                                                                                                                                           | Source                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The quarantine queue is `burnbar_memory_list(review_status="quarantined")`, with free-form values and injection-bearing metadata keys wrapped                                                                                                                                   | `README.md` § Untrusted recall boundary; `server.py` docstring                                                                                                                                                                                        |
| `burnbar_memory_review` locks the row and `expected_updated_at` refuses a decision made against a stale read                                                                                                                                                                    | `README.md` § Tools; `server.py burnbar_memory_review` docstring                                                                                                                                                                                      |
| `burnbar_memory_analytics` reports counts by kind / scope / sensitivity / review status, embedding coverage, vault entries, policy                                                                                                                                              | `README.md` § Tools; `server.py` docstring                                                                                                                                                                                                            |
| `burnbar_audit_trail` returns the label-only hash chain with chain verification                                                                                                                                                                                                 | `README.md` § Tools                                                                                                                                                                                                                                   |
| A recall that returns results appends **one** label-only `memory.recall_serve` row naming the ids it served — the trail is a record of writes plus one row per read, not a request log                                                                                          | `server.py burnbar_recall` / `burnbar_audit_trail` docstrings; `memory_engine/_read.py`; `tests/test_memory_timeline.py` — `test_a_recall_appends_exactly_one_audit_row`                                                                              |
| `burnbar_memory_doctor` covers store, encryption, embeddings, policy, audit chain, daemon mirror and code index, and resumes an auxiliary secret sweep via `aux_scan_cursor`                                                                                                    | `server.py burnbar_memory_doctor` docstring                                                                                                                                                                                                           |
| A merged revision's `writerDevice` is an opaque device token (`^[A-Za-z0-9_.:-]{1,128}$`) or it is not stored at all — the merge decision counts `writerDeviceRejected` and the fact still lands, so remote prose never reaches plaintext `meta_json` or the timeline unwrapped | `memory_engine/constants.py REMOTE_WRITER_DEVICE_RE`; `_sync.py _screen_remote_row`; `server.py burnbar_memory_timeline` docstring; `tests/test_memory_timeline.py` — `test_a_hostile_writer_device_is_dropped_at_screening_and_the_fact_still_lands` |
| The doctor reports occupied lineage hold slots (`OPEN_LINEAGE_HOLDS`, count and oldest `firstSeen`) — report-only, because releasing a slot is the sync path's decision                                                                                                         | `memory_engine/_admin.py doctor`; `tests/test_memory_doctor.py` — `test_an_occupied_lineage_hold_queue_is_visible_in_the_doctor_report`                                                                                                               |
| `burnbar_memory_doctor` is report-only unless `apply=True`, which requires `memory_write` and prunes exactly two things — aged orphan bodies and aged parked supersedes whose age it can prove. It never writes a watermark or the daemon-owned inbox                           | `server.py burnbar_memory_doctor` docstring and its denial site; `tests/test_memory_doctor.py` — `test_doctor_apply_is_refused_without_memory_write`, `test_apply_never_deletes_an_unapplied_inbox_row`                                               |
| **gate** · AI Inbox items and Founder Plans are readable from the MCP; bodies need `sensitive_read`, listings do not                                                                                                                                                            | `server.py burnbar_inbox_*` docstrings and their denial sites — gate-checked                                                                                                                                                                          |
| **editorial** · **Stated limit:** nothing auto-approves; an unreviewed row stays out of recall                                                                                                                                                                                  | `README.md` § Untrusted recall boundary                                                                                                                                                                                                               |

#### Code intelligence (`/memory#code`)

| Claim                                                                                                                                                                                   | Source                                                                                                                                     |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Eleven code tools; the index is local-only and project-partitioned                                                                                                                      | `server.py` (`burnbar_index_project` … `burnbar_explore`); `README.md` § Local memory engine — Project Code Memory                         |
| Git exclude-standard ignore semantics, blob/commit SHA stamping, manifest-backed delta indexing, Git-fingerprint Project ID v2 with path aliases                                        | `README.md` § Local memory engine, verbatim in substance                                                                                   |
| Secret-bearing files are rejected before persistence, using the shared Swift/Python scanner corpus                                                                                      | `README.md` § Local memory engine                                                                                                          |
| Tiers `exact_lsp` / `static_tree_sitter` / `lexical_fallback`; `OPENBURNBAR_CODE_LSP_COMMANDS` enables the exact tier; the Rust helper is built by `setup.sh`, not the memory bootstrap | `README.md` § Local memory engine; § Setup                                                                                                 |
| **gate** · Code-index writes are daemon-required, `local_write`-gated and fail-closed with no SQLite fallback                                                                           | `README.md` § Local memory engine — gate-checked as `local_write` on `burnbar_index_project` / `burnbar_watch_project` / `burnbar_explore` |
| Returned source text is wrapped as untrusted content                                                                                                                                    | `README.md` § Local memory engine                                                                                                          |
| **editorial** · **Stated limit:** `semanticAvailable=false` until a real local embedding provider; call graphs are lexical-tier                                                         | `README.md` § Local memory engine; `server.py burnbar_search_code` / `burnbar_call_graph` docstrings                                       |

#### Sessions across harnesses (`/memory#sessions`)

| Claim                                                                                                                                                       | Source                                                                      |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| FTS over titles and transcripts of indexed sessions from every harness; `burnbar_list_providers` names them                                                 | `README.md` § Tools; `server.py` docstrings                                 |
| Local semantic session search returns a structured `unavailable` rather than empty results                                                                  | `README.md` § Tools — `burnbar_semantic_search_conversations`               |
| `burnbar_resume_conversation` returns one of `native` / `ported` / `error`, is print-only by default, and writes a 0600 briefing                            | `README.md` § Local memory engine (resume paragraph); `server.py` docstring |
| **gate** · `burnbar_spawn_resume` is a deliberate second call, gated on `spawn_process`                                                                     | `README.md` § Local memory engine; gate-checked capability                  |
| Hosted encrypted session search derives trapdoors locally, sends only opaque hashes, decrypts on device                                                     | `README.md` § Local memory engine (cloud paragraph); `docs/PRIVACY.md:57`   |
| **editorial** · **Stated limit:** full plaintext, chat rows and ported briefings need `sensitive_read`; a ported resume is a briefing, not a state transfer | gate-checked capability; `README.md` resume paragraph                       |

#### The rest of the server (`/memory#server`)

| Claim                                                                                                                                                                                                                                                                                              | Source                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| **gate** · Twelve spend and budget tools — query, status, forecast, audit, and the three write tools                                                                                                                                                                                               | `README.md` § Tools; gate-checked against the atlas                                                          |
| The ledger writer is daemon-first over the UNIX socket with a file-locked JSONL fallback; the same idempotency key never double-counts                                                                                                                                                             | `README.md` § Local memory engine (the writer paragraph)                                                     |
| Hermes proxy sidecar: stdlib-only, OpenAI-compatible, forwards SSE / tool calls / auth / models verbatim, one ledger row per completed response, `--no-estimate` to skip guessing                                                                                                                  | `README.md` § Hermes proxy sidecar                                                                           |
| Castle: a worker counts as landed only when the done marker exists, the runtime parser says no error, and worktree HEAD differs from the recorded base SHA; dashboard green comes from `landsCommit`                                                                                               | `README.md` § Castle multi-runtime fan-out                                                                   |
| Project Memory snapshots resolve local-first with a hosted encrypted fallback decrypted on device; uploads are sealed payloads under vault-derived opaque ids. The card says **2 local + 2 hosted** because the atlas groups the hosted pair under _Encrypted cloud_, where their capability lives | `README.md` § Local memory engine (cloud paragraph); `server.py` docstrings                                  |
| **gate** · **26 `ministry_*` / `castle_*` / `bench_*` orchestration tools, listed in the atlas under their own three headings — Ministry, Castle, Bench**                                                                                                                                          | `server.py` — gate-checked (`ORCHESTRATION_TOOL_COUNT`), same set-equality check as the 63 `burnbar_*` tools |

#### The tool atlas (`/memory#atlas`)

The page's strongest claim is coverage — **"all 89 tools"**, not "all 63
tools" — so it is the one most tightly gated. An earlier version of this page
listed 63 `burnbar_*` tools and called that "all", while `server.py` also
registered 26 `ministry_*` / `castle_*` / `bench_*` tools the atlas never
mentioned. `scripts/test-memory-copy.mjs` invariants 8 to 17 now make the
following true by construction, over every tool the server registers
regardless of prefix; a build fails otherwise.

| Claim                                                                                                                                                                                                                                                                                                                                 | Source and enforcement                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 89 tools total — 63 `burnbar_*` plus 26 `ministry_*` / `castle_*` / `bench_*` — every one listed, none invented                                                                                                                                                                                                                       | `server.py` **every** `@mcp.tool()` definition ↔ `TOOL_ATLAS`, **set equality in both directions**, not scoped to a name prefix                                                                                                                                                                                                                                                                                               |
| 32 of the 89 marked as the memory toolset; Castle/Ministry/Bench are never marked as such                                                                                                                                                                                                                                             | `server.py` `MEMORY_TOOLSET` ↔ each entry's `memory` flag, per tool — `MEMORY_TOOLSET` never names a `ministry_*` / `castle_*` / `bench_*` tool, so this also proves none is mismarked                                                                                                                                                                                                                                        |
| The capability shown on each tool                                                                                                                                                                                                                                                                                                     | the capabilities named at that tool's `_capability_denial("<tool>", "<cap>")` and `_local_memory_write_authority("<tool>", …)` sites                                                                                                                                                                                                                                                                                          |
| A capability reached only under a condition is published **with** that condition — `burnbar_recall` and `burnbar_memory_get` need sensitive read _with `include_secrets`_; `burnbar_memorize` needs spawn and model extract _when an LLM extractor is named_; four `ministry_*` / `castle_*` tools need spawn _with `prove_headless`_ | the denial site's own syntax. A call reached through `if <condition> and (denied := …` or from inside a nested block is guarded and must carry a `capsWhen` note naming the condition; a note without a guarded site fails too. Eight guarded capabilities across seven tools. Without this the atlas read as "the flagship recall tool is behind an off-by-default capability", which is both wrong and worse than the truth |
| Nine capability switches and the environment variable that enables each                                                                                                                                                                                                                                                               | `server.py` `LOCAL_MCP_CAPABILITY_ENV` ↔ the page's `CAPABILITIES` table                                                                                                                                                                                                                                                                                                                                                      |
| Every capability a published tool depends on is explained on the page                                                                                                                                                                                                                                                                 | cross-checked between `TOOL_ATLAS[].caps` and `CAPABILITIES`                                                                                                                                                                                                                                                                                                                                                                  |
| Every atlas tool actually renders in the built HTML                                                                                                                                                                                                                                                                                   | read out of `dist/memory/index.html`, not out of the source                                                                                                                                                                                                                                                                                                                                                                   |
| `BURNBAR_TOOL_COUNT` (63) + `ORCHESTRATION_TOOL_COUNT` (26) sum to what `server.py` registers (89), and the atlas heading prints that sum                                                                                                                                                                                             | `server.py` `@mcp.tool()` count, split on the `burnbar_` prefix, ↔ the two constants and their sum                                                                                                                                                                                                                                                                                                                            |
| Each tool's one-line description                                                                                                                                                                                                                                                                                                      | `tools/openburnbar-mcp/README.md` § Tools row where one exists, the tool's docstring otherwise — _editorial, not gate-enforced beyond "a description exists and is not a stub"_                                                                                                                                                                                                                                               |

Negative-tested, eight ways, each producing exit 1 with the specific message:
dropping a `burnbar_*` tool from the atlas, dropping a Castle tool from the
atlas, inventing a `burnbar_*` tool, inventing an orchestration tool,
understating a capability, mismarking a Castle tool as memory-toolset,
drifting the count, and naming the wrong environment variable.

#### Platforms (`/memory#setup`)

| Claim                                                                                                           | Source                                                                                                  |
| --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| macOS is the supported platform; store defaults to Application Support, daemon mirror and Pro gateway are macOS | `tools/openburnbar-mcp/README.md` § Setup; § Local memory engine                                        |
| The engine is plain Python 3.11+ (3.12 preferred), no Rust toolchain for the memory bootstrap                   | `README.md` § Setup, verbatim in substance                                                              |
| **Windows and Linux are not supported and not tested**; the repo's Linux port plan is a plan, not a platform    | `README.md` has no Windows/Linux support statement; `docs/LINUX_PORT_MASTER_PLAN.md` is a plan document |
| Support level: adjacent tooling, best-effort, not required to build or run the core surfaces                    | `README.md` § Support level, verbatim in substance                                                      |

The copy gate asserts the page names Windows and Linux explicitly and refuses
three shapes of "runs on Windows/Linux" phrasing. If a port ships, that
assertion is what will tell whoever writes the announcement that this page
needs editing.

#### Newly stated limits

`/memory#limits` gains two entries: **macOS today, and only macOS**, and
**part of the server assumes the OpenBurnBar app is there** — the session
index, spend tools, inbox and Project Memory snapshots read what the app and
daemon produce, and on a signed install that database is SQLCipher-encrypted,
so those tools go through the daemon socket or report that they cannot. The
memory engine itself still needs none of that, and the page keeps saying so.

---

## MCP integration (`/mcp`)

Existing page; this PR added navigation, accessibility and one signpost. New claims:

| Claim                                                                                                                                  | Source                                                                        |
| -------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| "This page is about transports … the local server is a product in its own right"                                                       | Editorial framing; the split matches `/memory`                                |
| The signpost names what `/memory` covers that `/mcp` does not — memory, time, deletion, code index, session search, and the tool atlas | Each of those sections exists on `/memory` and is sourced in the tables above |
| `/memory`'s crossref says `/mcp` covers which tools each hosted channel exposes, and that the local atlas is a different, larger set   | `/mcp`'s own channel tool lists; `server.py` for the local set                |
| Cross-links to `/memory` and `/memory#setup`                                                                                           | Internal routes, verified by `check-links.mjs`                                |

---

## Download (`/download`)

| Claim                                        | Source                                                                                                                                                                                                                                                                                                     |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Current public macOS DMG                     | `website/src/data/site.ts`; `https://downloads.burnbar.ai/OpenBurnBar-1.0.40+repair.36-macOS.dmg` — SHA-256 verified against the immutable GitHub v1.0.40+repair.36 release asset (2026-08-30)                                                                                                             |
| Branded direct-download lane live            | `website/src/data/site.ts`, `docs/RELEASE_MACOS.md`; `downloads.burnbar.ai` is an Active Cloudflare R2 custom domain (bucket `openburnbar-downloads`); `website/scripts/test-download-provenance.mjs` pins and live-checks the branded DMG URL                                                             |
| macOS Sonoma min                             | `README.md:272`, `homebrew/burnbar.rb:22`                                                                                                                                                                                                                                                                  |
| iOS on the App Store (v1.0, 2026-05-26)      | iTunes Lookup API for `com.openburnbar.app` (checked 2026-07-11); store page https://apps.apple.com/us/app/openburnbar/id6766366964                                                                                                                                                                        |
| Editor extension source-only                 | `extensions/openburnbar/README.md:7-10`                                                                                                                                                                                                                                                                    |
| Android feature-complete, Play Store pending | Historical 2026-05-16 source-complete milestone (Hermes, Floo media, messaging, missions). **Not a current product-parity claim** — `docs/mobile-parity/mobile-parity-ledger.md` has `productParityClaim=false` and physical/store rows stay blocked. **[verify]** device-matrix soak; no Play listing yet |
| Homebrew tap not yet published               | `QUICKSTART.md:46`. Site doesn't list a brew command — intentional                                                                                                                                                                                                                                         |

Before website deployment, `npm run test:download-provenance --prefix website` must prove the
exact customer-facing DMG URL is live. The audited URL is pinned to
`https://downloads.burnbar.ai/OpenBurnBar-1.0.40+repair.36-macOS.dmg`; changing the public DMG URL must
update that pin in the same PR, after the replacement artifact is published and verified.

---

## FAQ (`/faq`)

Each Q&A in `src/data/faq.ts` is derived from the docs already cited above —
no new claims are introduced. The page also emits FAQ JSON-LD via
`schema.org/FAQPage` so the answers can show in search.

---

## Items still needing Alberto's confirmation before publish

These are the recurring **[verify]** flags above, collected:

1. **Canonical GitHub URL.** README + Homebrew formula say `Ajnunezg/BurnBar`. `git remote -v` says `Imagine-That-Ai/BurnBar`. Both repos exist publicly; only the latter has shipped release artifacts. Pick one and align everything.
2. **iOS launch status.** Resolved 2026-07-11 — the app is live (v1.0, released 2026-05-26); `SITE.iosStatus` now reads "on the App Store" and `SITE.iosAppStoreUrl` links the store page.
3. **Store price tiers.** Site advertises Cloud at $7.99/month or $79/year, Cloud Pro at $24.99/month or $249/year, and both top-ups at $4.99. Confirm Apple, Play, and Stripe live products match; if stores set different local prices, decide whether to footnote.
4. **Marketing version.** Resolved 2026-08-30 — the branded `downloads.burnbar.ai` host is
   live (Active Cloudflare R2 custom domain) and `SITE.macDownloadBaseUrl` /
   `SITE.macUpdateBaseUrl` now point at it; every v1.0.40+repair.36 artifact was streamed through the
   branded host and SHA-256-matched against the immutable GitHub release assets.
5. **Sentry / encryption-key recovery / HTTP-gateway TLS** — `docs/reviews/SECURITY_PRIVACY_REVIEW.md` notes a few items the team intended to fix. Re-read against the current shipping build before publishing the security page.
6. **Trademark clearance for "OpenBurnBar"** remains an unchecked legal-owner item in `docs/OSS_LAUNCH_CHECKLIST.md:148`. Public-facing app, repository, and website surfaces already use the name, so this is a current release-risk review—not a future "before going public" task. Automated repository checks cannot substitute for counsel/owner sign-off.
7. **Team plan copy** — kept off the page until built.
8. **Floo activation state.** The `/floo` page and the surfaces matrix say "Built · rolling out." Confirm which Floo capabilities (screen view, control, file transfer, calls, remote unlock) are flag-live in the shipping build before any "available now" framing. Activation gates: `docs/runbooks/media-rollout-status.md`.
9. **Agent Control submission state.** The `/control` page says "Direct download · behind your grant" and states the Mac App Store build ships without it. Confirm the App Store Connect submission / usage-description posture matches before launch.
10. **Android parity claim.** Site now says "Remediation in progress · Play Store pending." Do not publish a full-parity claim; `productParityClaim` stays false and physical/store/VoiceOver rows stay blocked. There is still no Play Store listing.

---

## How to update a claim

1. Edit the matching data file in `src/data/` (or the page itself for one-off copy).
2. Update this matrix.
3. `npm run verify` (type-check + build + link check).
4. `firebase deploy --only hosting:marketing` from the repo root.
