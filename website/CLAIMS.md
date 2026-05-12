# Claims → source matrix

Every public claim made on `burnbar.ai` traces back to repo evidence. This
matrix groups claims by page and points at the source the website draws from.
Items flagged **[verify]** still need Alberto's explicit sign-off before going
live — for example, where the App Store Connect state or the canonical GitHub
org is ambiguous in the repo today.

---

## Branding / entity

| Claim on site | Source | Notes |
|---|---|---|
| Privacy controller is **Imagine That AI LLC** | `docs/PRIVACY.md:106` | Used in footer, privacy policy, terms |
| Privacy contact `privacy@imagine-that.ai` | `docs/PRIVACY.md:107` | |
| Site domain `burnbar.ai` | User confirmation (2026-05-12) | Registered through Namecheap |
| Repository link `github.com/Imagine-That-Ai/BurnBar` | `git remote -v` (origin) | **[verify]** `Ajnunezg/BurnBar` is the URL the README advertises today; the site currently points at `Imagine-That-Ai/BurnBar` because that's where the published release artifacts live. Alberto should align README + site on a single canonical URL before launch |
| License **MIT** | `/LICENSE`, `gh repo view` | |

---

## Home (`/`)

| Claim | Source |
|---|---|
| "Watch your AI agents. Before the bill." (headline) | Synthesized; tone matches `README.md:6`, `README.md:54-67` |
| Local-first developer tool | `docs/MISSION.md:5`, `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5` |
| Tracks tokens, dollars, quota | `README.md:54-67` |
| Across Claude Code, Codex, Cursor, Copilot, Factory, MiniMax… | `docs/PROVIDERS.md`, `AgentLens/Services/ProviderQuota/` |
| 11 providers with real usage data | `AgentProvider.swift:37-49` (quotaSignalProviders), plus OpenRouter (usage-only) |
| 0 telemetry by default | `docs/PRIVACY.md:21` |
| Works offline | `docs/THREAT_MODEL.md:188` |
| "Reads logs, not API keys" | `README.md:57`, verbatim |
| Quote: "Your API keys never leave the providers you already trust…" | `README.md:57` |

---

## Product (`/product`)

| Claim | Source |
|---|---|
| Lives in menu bar (LSUIElement) | `README.md:342`, `AgentLens/Views/Popover/MenuBarPopoverView.swift` |
| Reads logs from `~/.claude/`, `~/.codex/`, `~/.factory/`, … | `AgentLens/Services/LogParser/`; `AgentProvider.swift` |
| Token + cost rollups today/week/month/all-time | `AgentLens/Services/UsageAggregator.swift`, `LocalMetricsAggregator.swift` |
| Quota windows: 5h, 7d, weekly, plan-tier, premium | `AgentLens/Services/ProviderQuota/`, `docs/PROVIDERS.md` |
| Insight engine + daily digest | `AgentLens/Services/InsightEngine.swift`, `DailyDigestManager.swift` |
| Daemon-first control plane | `OpenBurnBarDaemon/`, `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5-26` |
| 8-command CLI (health / controller / questions / followups / missions / mission-approve / simulator-runs / simulator-replay) | `OpenBurnBarDaemon/Sources/OpenBurnBarCLI/`, `README.md:76-86` |
| Hermes — local-index + gateway modes | `AgentLens/Views/Chat/`, `DESIGN.md:150-187` |
| Conversation Atoms | `docs/CONVERSATION_ATOMS.md` |
| Chart Studio — 10 Swift Charts + Mermaid | `docs/CHART_STUDIO.md`, `OpenBurnBarMobile/Views/ChartStudio/` |
| Hermes Realtime Relay (paid) | `docs/HERMES_REALTIME_RELAY.md`, gated on `hosted_quota_sync` entitlement |
| iOS Live Activity + Siri shortcut | `CHANGELOG.md:522-525, 672-673` |
| Smart-display surfaces (Nest Hub + ULANZI Pixel Clock) | `AgentLens/Services/Cast/`, `AgentLens/Services/SmartHub/`, `docs/SMART_DISPLAY_DEVICE_QA.md` |
| Honest confidence labels (exact / estimated / unavailable) | `docs/PROVIDERS.md`, every provider row |

---

## Providers (`/providers`)

Whole-page source: `src/data/providers.ts` mirrors `docs/PROVIDERS.md` plus the
`QuotaRefreshActor.adapters` registry in `AgentLens/Services/ProviderQuota/QuotaRefreshActor.swift`.

| Claim | Source |
|---|---|
| Provider matrix rows (Claude Code, Codex, OpenAI, Copilot, Cursor, Factory, MiniMax, Z.ai, Warp, Ollama, Kimi, OpenRouter, Anthropic, Aider, Forge) | per-adapter source files under `AgentLens/Services/ProviderQuota/` and the audits in `docs/PROVIDER_USAGE_DATA_REFERENCE.md` / `docs/PROVIDER_DATA_AUDIT.md` |
| Claude Code / Codex are self-hosted only | `functions/src/index.ts:600-605`, `docs/HOSTED_QUOTA_SYNC.md:11-18` |
| Anthropic admin-key gotcha | `docs/PROVIDERS.md:44`, `docs/research-provider-usage-apis.md:189` |
| Cursor + Factory rely on session cookies | `docs/PROVIDERS.md:37-38`, `docs/PROVIDER_DATA_AUDIT.md:39-51` |
| Z.ai endpoint is undocumented | `docs/research-provider-usage-apis.md:269-272` |
| Warp requires a spoofed User-Agent | `docs/PROVIDERS.md:39`, `docs/PROVIDER_USAGE_DATA_REFERENCE.md:453-455` |
| OpenRouter is the only vendor that returns dollar cost | `docs/research-provider-usage-apis.md:236` |
| Gemini AI Studio has no programmatic quota API | `docs/PROVIDER_DATA_AUDIT.md:127-130` |
| Detection-only providers (Cline, Roo Code, Kilo Code, Augment, Windsurf, Goose, OpenClaw, Gemini CLI) | `AgentLens/Services/ProviderQuota/StubQuotaAdapter.swift:1-11` |

Site notes that `PROVIDERS.md` is stale on Kimi today — code ships
`KimiQuotaAdapter` and the audit doc upgrades Kimi to `.exact`. The website
treats Kimi as exact, which matches the running code.

---

## Pricing (`/pricing`)

| Claim | Source |
|---|---|
| Free tier — full local product | `docs/PRIVACY.md:21,34`, `docs/HOSTED_QUOTA_SYNC.md:38-68` |
| Cloud subscription `com.openburnbar.hostedQuotaSync.monthly` | `OpenBurnBarMobile/Models/HostedQuotaSubscriptionStore.swift:61`, `OpenBurnBarMobileTests/Resources/OpenBurnBarHostedQuota.storekit:27`, `functions/src/config.ts:75` |
| `$4.99` / month | `OpenBurnBarMobileTests/Resources/OpenBurnBarHostedQuota.storekit:15`, `docs/HOSTED_QUOTA_SYNC.md:184-188`. **[verify]** the actual App Store Connect price tier in production matches |
| Apple App Store auto-renewing subscription | `OpenBurnBarHostedQuota.storekit:28,31` |
| No introductory offer / no free trial | `OpenBurnBarHostedQuota.storekit:19` |
| Hosted Codex quota refresh — 30/day, 300/month per account | `docs/HOSTED_QUOTA_SYNC.md:287-288, 583` |
| Conversation backup gated on entitlement | `docs/PRIVACY.md:38` |
| Hermes Realtime Relay gated on entitlement | `docs/HERMES_REALTIME_RELAY.md:10,53` |
| Cancellation language — `Settings → Apple ID` | `OpenBurnBarMobile/Views/Store/CloudStoreView.swift:182` |
| Refunds via reportaproblem.apple.com | Apple's standard policy; site does not invent a custom policy |
| Yearly plan "coming soon" — kept off the site | `OpenBurnBarMobile/Views/Store/CloudStoreView.swift:172-179`. **[verify]** stays off-site until built |
| Subscription state on launch | `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md:13-17` says `WAITING_FOR_REVIEW` as of 2026-05-09. **[verify]** Apple has approved before the site claims iOS availability |

---

## Privacy & trust (`/privacy`)

| Claim | Source |
|---|---|
| "By default, OpenBurnBar collects nothing" | `docs/PRIVACY.md:21`, verbatim |
| Local SQLite path | `docs/THREAT_MODEL.md:128`, `SECURITY_PRIVACY_REVIEW.md:116` |
| Daemon UNIX socket | `docs/THREAT_MODEL.md:48,55` |
| Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | `SECURITY.md:33-35` |
| Firebase metadata-only default sync | `docs/PRIVACY.md:24-34` |
| Chat-message + session-log backup gated on `hosted_quota_sync` | `docs/PRIVACY.md:38` |
| iCloud container `iCloud.com.openburnbar.app` | `SECURITY_PRIVACY_REVIEW.md:133`, `docs/PRIVACY.md:42-44` |
| App Check enforced at Firestore | `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md:3-7` |
| Hosted credential secrets in Google Cloud Secret Manager | `docs/PRIVACY.md:48`, `docs/HOSTED_QUOTA_SYNC.md:140-145` |
| Three trust-zone architecture diagram | Synthesized from `docs/THREAT_MODEL.md:48-156` + `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5-26` |
| Account deletion paths | `docs/PRIVACY.md:87-92` |
| Sentry diagnostic seed | `SECURITY_PRIVACY_REVIEW.md:180`. **[verify]** matches shipping build |

---

## Security model (`/security`)

| Claim | Source |
|---|---|
| Filesystem-ACL'd UNIX socket + token auth | `docs/THREAT_MODEL.md:72`, `SECURITY.md:34` |
| ECIES (P-256 + AES-GCM) cross-device credential escrow | `docs/THREAT_MODEL.md:201-230` |
| App Store JWS verified against pinned Apple root CAs | `docs/THREAT_MODEL.md:242-250` |
| Owner-scoped Firestore rules + secret-field-name denylist | `docs/THREAT_MODEL.md:140,221`, `firestore.rules` |
| Releases signed + notarized + stapled | `docs/RELEASE_MACOS.md:42-55` |
| Per-release SBOM + checksums + provenance JSON | `docs/RELEASE_MACOS.md:43-83` |
| **Known limit:** macOS app is not sandboxed | `docs/THREAT_MODEL.md:113-124` |
| **Known limit:** Provider API calls aren't certificate-pinned | `SECURITY_PRIVACY_REVIEW.md:94` |
| **Known limit:** Cursor connector tunnel routes through Cloudflare | `docs/THREAT_MODEL.md:152-156` |
| **Known limit:** HTTP gateway is loopback-only by default | `SECURITY_PRIVACY_REVIEW.md:99-101` flags non-loopback bind as a risk. **[verify]** the shipping default is loopback-only |
| **Known limit:** Encryption-key recovery file | `SECURITY.md:35` describes the SOTA design; `SECURITY_PRIVACY_REVIEW.md:55-57` still flags the legacy recovery file. **[verify]** which is current in the shipping build before launch |

---

## Download (`/download`)

| Claim | Source |
|---|---|
| `v0.1.2-beta.12` is the latest published macOS release | `gh release list` |
| Latest DMG asset URL | `https://github.com/Imagine-That-Ai/BurnBar/releases/download/v0.1.2-beta.12/OpenBurnBar-0.1.2-beta.12-macOS.dmg` |
| macOS Sonoma min | `README.md:272`, `homebrew/burnbar.rb:22` |
| iOS in App Store review | `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md:9-17` |
| Editor extension source-only | `extensions/openburnbar/README.md:7-10` |
| Android in development, no Play Store yet | `docs/ANDROID_NATIVE_PARITY_GOAL.md`, `android/app/AGENTS.md` |
| Homebrew tap not yet published | `QUICKSTART.md:46`. Site doesn't list a brew command — intentional |

**[verify]** Marketing-version mismatch: `project.yml` says `0.1.3-beta.1`,
README repeats that, but the latest *published* release is `v0.1.2-beta.12`.
Site currently points to the published release; bump on publish.

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
3. **App Store Connect price tier.** Site advertises $4.99/month. Confirm the live tier matches; if Apple sets a different tier in some locales, decide whether to footnote.
4. **Marketing version.** When a fresh tag (`v0.1.3-beta.1` or later) is cut, bump `SITE.macReleaseLatest` / `SITE.macReleaseFile` in `src/data/site.ts`.
5. **Sentry / encryption-key recovery / HTTP-gateway TLS** — `SECURITY_PRIVACY_REVIEW.md` notes a few items the team intended to fix. Re-read against the current shipping build before publishing the security page.
6. **Trademark clearance for "OpenBurnBar"** is listed as a TODO in `docs/OSS_LAUNCH_CHECKLIST.md:108`. The site uses the name everywhere, so confirm clearance before going public.
7. **Yearly plan / team plan copy** — kept off the page until built.

---

## How to update a claim

1. Edit the matching data file in `src/data/` (or the page itself for one-off copy).
2. Update this matrix.
3. `npm run verify` (type-check + build + link check).
4. `firebase deploy --only hosting:marketing` from the repo root.
