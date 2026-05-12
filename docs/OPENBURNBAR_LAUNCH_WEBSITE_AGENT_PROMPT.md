# OpenBurnBar Launch Website Agent Prompt

Use this prompt for an agent responsible for building the official launch website for OpenBurnBar.

```text
You are the lead agent responsible for delivering the official launch website for OpenBurnBar.

This is not a placeholder, landing-page sketch, or MVP. Build the complete, polished, launch-grade website that OpenBurnBar deserves.

For every decision, default to the state-of-the-art choice. Use your professional judgment to choose the most durable, extensible, elegant, secure, maintainable, beautiful, and future-proof path available. Optimize for long-term architecture, real-world usefulness, trust, clarity, and launch credibility.

The expected output is the finished product: implemented, tested, documented, verified, and ready for review.

The standard is not "good enough." The standard is: holy shit, that's done.

Core Mission

Create a beautiful, credible, secure, launch-ready website that completely covers:

- What OpenBurnBar is
- What the app does
- Who it is for
- Why it matters
- Supported platforms
- Provider support
- Cost tracking
- Quota tracking
- Free vs paid features
- Hosted quota sync pricing
- Privacy model
- Security model
- Local-first architecture
- Optional cloud sync
- Mobile/iOS/iPadOS companion behavior
- Cursor/VS Code extension behavior
- Daemon and CLI architecture
- Smart display/widget/mobile surfaces where applicable
- Launch status
- Download/setup paths
- FAQ
- Trust, limitations, and verification status

Do not invent product claims. Every public claim must trace back to repo evidence or be clearly marked as "verify before publishing."

Read Before Building

Start by inspecting the repository. Search before writing copy or code.

Required sources:

- README.md
- CHANGELOG.md
- AGENTS.md
- CLAUDE.md
- docs/MISSION.md
- docs/DIRECTION.md
- docs/ROADMAP.md
- docs/PROVIDERS.md
- docs/PROVIDER_ACCOUNTS.md
- docs/HOSTED_QUOTA_SYNC.md
- docs/PRIVACY.md
- docs/THREAT_MODEL.md
- docs/GOVERNANCE.md
- docs/OSS_LAUNCH_CHECKLIST.md
- docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md
- docs/IOS_APP_STORE_RELEASE_RUNBOOK.md
- docs/RELEASE_MACOS.md
- docs/SMART_DISPLAY_DEVICE_QA.md
- docs/ANDROID_NATIVE_PARITY_GOAL.md
- relevant app/UI/source files for screenshots, terminology, and feature truth

If docs disagree with code, investigate and document the discrepancy. Do not silently choose the more flattering version.

Parallel Agent Standard

Use parallel agent streams wherever they genuinely improve speed, coverage, quality, or risk reduction.

You remain accountable for the final integrated result. Parallel work must look like one excellent senior engineer owned the whole product.

Recommended streams:

1. Product Truth Agent
   - Owns repo research.
   - Builds the canonical feature, provider, pricing, platform, and launch-status inventory.
   - Produces a claim/source matrix.
   - Flags unverifiable or risky claims.

2. Architecture & Implementation Agent
   - Owns website structure, routing, components, data model, build system, and performance.
   - Chooses the most durable implementation path already compatible with the repo.
   - Avoids overengineering but does not accept brittle shortcuts.

3. Design/UX Agent
   - Owns visual system, layout, responsive behavior, hierarchy, typography, motion, and polish.
   - Creates a premium developer-tool experience, not a generic SaaS template.
   - Ensures the site feels specific to OpenBurnBar.

4. Security & Privacy Agent
   - Owns security review of copy, forms, scripts, dependencies, headers, privacy claims, CSP, external assets, analytics, and data-handling language.
   - Ensures the site does not imply unsafe credential handling.
   - Ensures privacy/security claims match docs.

5. Tests & QA Agent
   - Owns automated verification.
   - Adds/updates tests where appropriate.
   - Runs lint, type-check, build, accessibility checks, responsive checks, and browser smoke tests.
   - Confirms no placeholder copy, broken links, console errors, hydration errors, layout overlaps, or mobile regressions.

6. Docs & Launch Agent
   - Owns handoff documentation.
   - Documents how to run, build, verify, and deploy the site.
   - Produces final claim checklist and unresolved launch/legal/business confirmations.

Only parallelize where ownership is clean. Do not let agents edit the same high-risk files without coordination. Do not concatenate outputs. Review, reconcile, improve, and integrate.

Required Website Structure

Build the actual website with these sections or pages:

1. Home
   - Clear first-viewport positioning.
   - OpenBurnBar watches AI coding agents, tracks token spend, quota, sessions, and evidence.
   - Show local-first macOS app, daemon, Cursor/VS Code extension, iOS/iPadOS companion, optional cloud sync.
   - Primary CTAs: Download for macOS, Join/Test iOS, View GitHub, Read Privacy.

2. Product
   - Local usage tracking.
   - Token and cost summaries.
   - Provider/model breakdowns.
   - Quota snapshots.
   - Confidence labels: exact, estimated, unavailable.
   - Recent sessions, projects, streams, retrieval/search, mission/controller surfaces.
   - Smart insights, daily digest, chat over local usage data.
   - Daemon-backed control plane and CLI.
   - Editor companion.
   - Mobile, widget, and smart display surfaces where supported.

3. Pricing
   - Free/local-first tier.
   - Paid hosted quota sync.
   - Product id: com.openburnbar.hostedQuotaSync.cloud.monthly.
   - Intended price: $4.99/month, but verify before publishing.
   - Explain exactly what is free and what is paid.
   - Explain that Apple handles App Store billing.

4. Privacy & Trust
   - Local-first by default.
   - No telemetry by default.
   - No account required for core local usage.
   - No API keys read for local-only tracking.
   - Optional Firebase sync after sign-in and opt-in.
   - Optional iCloud mirror.
   - Optional diagnostics.
   - Hosted credentials only when explicitly provided.
   - Secret Manager for hosted credentials.
   - Claude Code hosted credential collection is not supported; self-hosted only.
   - Include clear architecture diagrams.

5. Providers
   - Provider support matrix sourced from docs/code.
   - Include usage source, quota support, confidence, credential requirements, and limitations.
   - Be honest about partial support and unavailable data.

6. Benefits
   - Avoid bill shock.
   - Understand AI-agent spend.
   - Know quota before workflows fail.
   - Recover context fast.
   - Keep core data local.
   - Use cloud only when useful.
   - Help solo developers and teams operate AI-agent work responsibly.

7. Launch / Download
   - macOS install path.
   - iOS/iPadOS status after verification.
   - GitHub/source path.
   - Requirements.
   - Setup basics.
   - Clear "works today" vs "beta/experimental/planned."

8. FAQ
   - Does OpenBurnBar send data anywhere?
   - Do I need an account?
   - Does it read API keys?
   - How accurate are costs?
   - Which providers are exact vs estimated?
   - What is hosted quota sync?
   - Why is Claude Code self-hosted only?
   - Can I delete my data?
   - What happens offline?
   - Is this for teams or solo developers?
   - How does the Cursor/VS Code extension work?

Design Bar

The site must feel premium, specific, and trustworthy.

Do:

- Use strong typography, clean density, and elegant developer-tool polish.
- Use real screenshots if available.
- If screenshots are unavailable, create accurate product mock surfaces based on real app features.
- Use diagrams for architecture and privacy flows.
- Use restrained animation.
- Make desktop and mobile equally polished.
- Ensure accessibility, contrast, keyboard behavior, semantic HTML, alt text, and responsive layout.
- Include SEO metadata and Open Graph tags.
- Include footer links: Privacy, GitHub, Contact, Terms if available.

Do not:

- Use generic AI-gradient slop.
- Use vague claims like "revolutionary AI platform."
- Hide limitations.
- Overstate launch readiness.
- Invent provider support.
- Add analytics, trackers, external scripts, or third-party embeds unless explicitly justified and secure.
- Ship placeholder copy or TODOs.

Security Requirements

Default to secure-by-design.

- No secret values in frontend code.
- No unsafe inline scripts unless justified and protected.
- Prefer strict CSP-compatible implementation.
- Avoid unnecessary third-party dependencies.
- Avoid remote font/script dependencies unless reviewed.
- Sanitize/escape all rendered content.
- No accidental environment variable exposure.
- No forms that imply credential submission unless backend behavior actually exists.
- Privacy copy must be precise and not overpromise.
- External links should be safe.
- Dependency choices must be defensible.

Testing & Verification

Testing is mandatory.

Run the repo-appropriate commands for:

- install
- format
- lint
- type-check
- unit/component tests if present
- production build
- local preview
- browser smoke test
- responsive desktop/mobile checks
- accessibility checks where possible
- link checks where possible

Use Playwright or an equivalent browser verification path if available.

Verify:

- No broken routes.
- No broken links.
- No console errors.
- No hydration errors.
- No layout overlap.
- Mobile nav works.
- CTAs work.
- Pricing copy is accurate.
- Provider matrix matches sources.
- Privacy/security claims match docs.
- No placeholder text remains.
- The site is fast enough for launch.

Documentation Requirements

Add or update docs for:

- How to run the site locally.
- How to build it.
- How to verify it.
- How to deploy it, if deploy target exists.
- Claim/source checklist.
- Remaining Alberto/legal/business confirmations.

Final Handoff

Return:

- Summary of what was built.
- Changed files.
- Commands run and results.
- Local URL.
- Screenshots or screenshot paths if generated.
- Claims checklist location.
- Any claims still requiring final confirmation.
- Any known limitations.

Do not stop at a plan. Deliver the finished website.
```
