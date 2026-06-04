# Claims → source matrix

Every public claim made on `burnbar.ai` traces back to repo evidence. This
matrix groups claims by page and points at the source the website draws from.
Items flagged **[verify]** still need Alberto's explicit sign-off before going
live — for example, where the App Store Connect state or the canonical GitHub
org is ambiguous in the repo today.

---

## Branding / entity

| Claim on site                                        | Source                         | Notes                                                                                                                                                                                                                                                                |
| ---------------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Privacy controller is **Imagine That AI LLC**        | `docs/PRIVACY.md:106`          | Used in footer, privacy policy, terms                                                                                                                                                                                                                                |
| Privacy contact `privacy@imagine-that.ai`            | `docs/PRIVACY.md:107`          |                                                                                                                                                                                                                                                                      |
| Site domain `burnbar.ai`                             | User confirmation (2026-05-12) | Registered through Namecheap                                                                                                                                                                                                                                         |
| Repository link `github.com/Imagine-That-Ai/BurnBar` | `git remote -v` (origin)       | **[verify]** `Ajnunezg/BurnBar` is the URL the README advertises today; the site currently points at `Imagine-That-Ai/BurnBar` because that's where the published release artifacts live. Alberto should align README + site on a single canonical URL before launch |
| License **MIT**                                      | `/LICENSE`, `gh repo view`     |                                                                                                                                                                                                                                                                      |

---

## Home (`/`)

| Claim                                                               | Source                                                                           |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| "Watch your AI agents. Before the bill." (headline)                 | Synthesized; tone matches `README.md:6`, `README.md:54-67`                       |
| Local-first developer tool                                          | `docs/MISSION.md:5`, `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5`                |
| Tracks tokens, dollars, quota                                       | `README.md:54-67`                                                                |
| Across Claude Code, Codex, Cursor, Copilot, Factory, MiniMax…       | `docs/PROVIDERS.md`, `AgentLens/Services/ProviderQuota/`                         |
| 11 providers with real usage data                                   | `AgentProvider.swift:37-49` (quotaSignalProviders), plus OpenRouter (usage-only) |
| 0 telemetry by default                                              | `docs/PRIVACY.md:21`                                                             |
| Works offline                                                       | `docs/THREAT_MODEL.md:188`                                                       |
| "Reads logs, not API keys"                                          | `README.md:57`, verbatim                                                         |
| Quote: "Your API keys never leave the providers you already trust…" | `README.md:57`                                                                   |

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

| Claim                                                                | Source                                                                                                                                                             |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cursor Agent (CLI) is a distinct provider from the Cursor editor row | `CursorAgentParser` reads `~/.cursor-agent/sessions/`; exact tokens/models/transcripts. **[verify]** confirm `docs/PROVIDERS.md` lists cursor-agent before publish |

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

| Claim                                                                                                                                                                                      | Source                                                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Free tier — full local product                                                                                                                                                             | `docs/PRIVACY.md:21,34`, `docs/HOSTED_QUOTA_SYNC.md:38-68`                                                                                                        |
| BurnBar Cloud — `$7.99/mo`, `$79/yr`, `com.openburnbar.pro.monthly`, `com.openburnbar.pro.annual`                                                                                          | `GTMMasterPlan.MD:29-34`, `functions/src/config.ts`, `functions/src/callables/stripe.ts`, `functions/src/appstore/reconciler.ts`                                  |
| BurnBar Cloud Pro — `$24.99/mo`, `$249/yr`, `com.openburnbar.proMax.v2.monthly`, `com.openburnbar.proMax.annual`                                                                           | `GTMMasterPlan.MD:29-34`, `functions/src/config.ts`, `functions/src/callables/stripe.ts`, `functions/src/appstore/reconciler.ts`                                  |
| BurnBar Cloud Ultra — `$59.99/mo`, `$599/yr`, `com.openburnbar.ultra.monthly`, `com.openburnbar.ultra.annual.v2`, entitlement `burnbar_ultra`                                              | `docs/PENSIEVE.md:11,13`, `functions/src/config.ts:106-111,171-175`, `functions/src/callables/shared.ts:114`, `functions/src/appstore/reconciler.ts:61`           |
| Cloud Ultra mirrors Cloud Pro's hosted Agent Control + relay allowance and caps (same allowance object)                                                                                    | `docs/PENSIEVE.md:188`, `functions/src/callables/knowledgeMemory.ts:104-113`                                                                                      |
| Cloud Ultra = everything in Cloud Pro plus 10× private agent memory (Pensieve limits) — Pro: 10 sources / 50,000 chunks / 1 GB; Ultra: 100 sources / 500,000 chunks / 10 GB                  | `functions/src/callables/knowledgeMemory.ts:134-137` (`PENSIEVE_LIMITS`), `docs/PENSIEVE.md:200-204`                                                                |
| Agent memory = repo docs, notes, and chat-derived memories your agents recall; text sealed on-device + cloaked vectors, server runs nearest-neighbor search without reading content (E2EE) | `docs/PENSIEVE.md:178-188`, `OpenBurnBarCore/.../CloudVaultCrypto.swift`, `tools/openburnbar-mcp-remote/src/embed.ts` (vault-key cloaking)                        |
| Legacy Hosted Quota Sync `$4.99` is grandfathered only, not a new purchase tier                                                                                                            | `GTMMasterPlan.MD:91-99`, `functions/src/callables/shared.ts`, `functions/src/appstore/reconciler.ts`                                                             |
| Cloud Pro allowance — 500 hosted actions and 50 relay-accounting GB monthly                                                                                                                | `GTMMasterPlan.MD:38-79`, `functions/src/cloudProAllowanceCore.ts`                                                                                                |
| Cloud Pro monthly caps — 2,000 hosted actions and 300 relay-accounting GB                                                                                                                  | `GTMMasterPlan.MD:38-79`, `functions/src/cloudProAllowanceCore.ts`                                                                                                |
| Top-ups — `$4.99` for 100 hosted actions, `$4.99` for 50 relay-accounting GB                                                                                                               | `GTMMasterPlan.MD:59-75`, `functions/src/cloudProAllowanceCore.ts`, `functions/src/callables/stripe.ts`                                                           |
| Hosted quota refresh, conversation backup, cloud search, and synced memory are Group A / Cloud features                                                                                    | `GTMMasterPlan.MD:28-34`, `functions/src/callables/shared.ts`                                                                                                     |
| Floo and Agent Control are Group B / Cloud Pro features                                                                                                                                    | `GTMMasterPlan.MD:28-34`, `functions/src/callables/shared.ts`, `functions/src/voipPush.ts`                                                                        |
| BurnBar Cloud monthly and annual include a 14-day introductory free trial for new subscribers; Cloud Pro and top-ups do not                                                                | `GTMMasterPlan.MD:303-312`, `GTMMasterPlan.MD:331-339`                                                                                                            |
| Refund and cancellation handling follows Apple, Google Play, or Stripe platform state                                                                                                      | `GTMMasterPlan.MD:584-593`, `functions/src/callables/stripe.ts`, `functions/src/appstore/reconciler.ts`                                                           |
| Subscription state on launch                                                                                                                                                               | `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md:13-17` says `WAITING_FOR_REVIEW` as of 2026-05-09. **[verify]** Apple has approved before the site claims iOS availability |

---

## Privacy & trust (`/privacy`)

| Claim                                                          | Source                                                                                           |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| "By default, OpenBurnBar collects nothing"                     | `docs/PRIVACY.md:21`, verbatim                                                                   |
| Local SQLite path                                              | `docs/THREAT_MODEL.md:128`, `SECURITY_PRIVACY_REVIEW.md:116`                                     |
| Daemon UNIX socket                                             | `docs/THREAT_MODEL.md:48,55`                                                                     |
| Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`        | `SECURITY.md:33-35`                                                                              |
| Firebase metadata-only default sync                            | `docs/PRIVACY.md:24-34`                                                                          |
| Chat-message + session-log backup gated on `hosted_quota_sync` | `docs/PRIVACY.md:38`                                                                             |
| iCloud container `iCloud.com.openburnbar.app`                  | `SECURITY_PRIVACY_REVIEW.md:133`, `docs/PRIVACY.md:42-44`                                        |
| App Check enforced at Firestore                                | `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md:3-7`                                                     |
| Hosted credential secrets in Google Cloud Secret Manager       | `docs/PRIVACY.md:48`, `docs/HOSTED_QUOTA_SYNC.md:140-145`                                        |
| Three trust-zone architecture diagram                          | Synthesized from `docs/THREAT_MODEL.md:48-156` + `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5-26` |
| Account deletion paths                                         | `docs/PRIVACY.md:87-92`                                                                          |
| Sentry diagnostic seed                                         | `SECURITY_PRIVACY_REVIEW.md:180`. **[verify]** matches shipping build                            |

---

## Security model (`/security`)

| Claim                                                                                         | Source                                                                                                                                                                                 |
| --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Filesystem-ACL'd UNIX socket + token auth                                                     | `docs/THREAT_MODEL.md:72`, `SECURITY.md:34`                                                                                                                                            |
| ECIES (P-256 + AES-GCM) cross-device credential escrow                                        | `docs/THREAT_MODEL.md:201-230`                                                                                                                                                         |
| App Store JWS verified against pinned Apple root CAs                                          | `docs/THREAT_MODEL.md:242-250`                                                                                                                                                         |
| Owner-scoped Firestore rules + secret-field-name denylist                                     | `docs/THREAT_MODEL.md:140,221`, `firestore.rules`                                                                                                                                      |
| Releases signed + notarized + stapled                                                         | `docs/RELEASE_MACOS.md:42-55`                                                                                                                                                          |
| Per-release SBOM + checksums + provenance JSON                                                | `docs/RELEASE_MACOS.md:43-83`                                                                                                                                                          |
| **Known limit:** direct-download macOS app is not sandboxed; Mac App Store build is sandboxed | `docs/THREAT_MODEL.md:113-124`, `docs/RELEASE_MACOS.md`                                                                                                                                |
| **Known limit:** Provider API calls aren't certificate-pinned                                 | `SECURITY_PRIVACY_REVIEW.md:94`                                                                                                                                                        |
| **Known limit:** Cursor connector tunnel routes through Cloudflare                            | `docs/THREAT_MODEL.md:152-156`                                                                                                                                                         |
| **Known limit:** HTTP gateway is loopback-only by default                                     | `SECURITY_PRIVACY_REVIEW.md:99-101` flags non-loopback bind as a risk. **[verify]** the shipping default is loopback-only                                                              |
| **Known limit:** Encryption-key recovery file                                                 | `SECURITY.md:35` describes the SOTA design; `SECURITY_PRIVACY_REVIEW.md:55-57` still flags the legacy recovery file. **[verify]** which is current in the shipping build before launch |

---

## Download (`/download`)

| Claim                                        | Source                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `v1.0` is the prepared macOS release         | `project.yml`, `src/data/site.ts`, `docs/RELEASE_MACOS.md`                                                                                                                                                                                                                                                                       |
| Latest DMG asset URL                         | `https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.0/OpenBurnBar-1.0-macOS.dmg`                                                                                                                                                                                                                                    |
| macOS Sonoma min                             | `README.md:272`, `homebrew/burnbar.rb:22`                                                                                                                                                                                                                                                                                        |
| iOS in App Store review                      | `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md:9-17`                                                                                                                                                                                                                                                                                     |
| Editor extension source-only                 | `extensions/openburnbar/README.md:7-10`                                                                                                                                                                                                                                                                                          |
| Android feature-complete, Play Store pending | `mem:reference_android_skills` / Android parity work — Android reached full iOS parity (Hermes, Floo media, messaging, missions) ~2026-05-16. Surfaces matrix status is now `beta` / "Feature-complete · Play Store pending". **[verify]** confirm device-matrix soak before claiming parity publicly; no Play Store listing yet |
| Homebrew tap not yet published               | `QUICKSTART.md:46`. Site doesn't list a brew command — intentional                                                                                                                                                                                                                                                               |

**[verify]** Before website deployment, confirm the GitHub `v1.0` release asset exists and matches
the notarized local artifact checksums.

---

## FAQ (`/faq`)

Each Q&A in `src/data/faq.ts` is derived from the docs already cited above —
no new claims are introduced. The page also emits FAQ JSON-LD via
`schema.org/FAQPage` so the answers can show in search.

---

## Items still needing Alberto's confirmation before publish

These are the recurring **[verify]** flags above, collected:

1. **Canonical GitHub URL.** README + Homebrew formula say `Ajnunezg/BurnBar`. `git remote -v` says `Imagine-That-Ai/BurnBar`. Both repos exist publicly; only the latter has shipped release artifacts. Pick one and align everything.
2. **iOS launch status.** Until Apple approves, the site copy says "in App Store review." When approved, set `SITE.iosStatus = "available on iPhone & iPad"` in `src/data/site.ts`.
3. **Store price tiers.** Site advertises Cloud at $7.99/month or $79/year, Cloud Pro at $24.99/month or $249/year, and both top-ups at $4.99. Confirm Apple, Play, and Stripe live products match; if stores set different local prices, decide whether to footnote.
4. **Marketing version.** `SITE.macReleaseLatest` / `SITE.macReleaseFile` now target `v1.0`; verify the GitHub release asset exists before deployment.
5. **Sentry / encryption-key recovery / HTTP-gateway TLS** — `SECURITY_PRIVACY_REVIEW.md` notes a few items the team intended to fix. Re-read against the current shipping build before publishing the security page.
6. **Trademark clearance for "OpenBurnBar"** is listed as a TODO in `docs/OSS_LAUNCH_CHECKLIST.md:108`. The site uses the name everywhere, so confirm clearance before going public.
7. **Team plan copy** — kept off the page until built.
8. **Floo activation state.** The `/floo` page and the surfaces matrix say "Built · rolling out." Confirm which Floo capabilities (screen view, control, file transfer, calls, remote unlock) are flag-live in the shipping build before any "available now" framing. Activation gates: `docs/runbooks/media-rollout-status.md`.
9. **Agent Control submission state.** The `/control` page says "Direct download · behind your grant" and states the Mac App Store build ships without it. Confirm the App Store Connect submission / usage-description posture matches before launch.
10. **Android parity claim.** Site now says "Feature-complete · Play Store pending." Confirm the device-matrix soak has passed before publishing the parity claim; there is still no Play Store listing.

---

## How to update a claim

1. Edit the matching data file in `src/data/` (or the page itself for one-off copy).
2. Update this matrix.
3. `npm run verify` (type-check + build + link check).
4. `firebase deploy --only hosting:marketing` from the repo root.
