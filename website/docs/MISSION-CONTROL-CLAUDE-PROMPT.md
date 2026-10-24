# Claude Cloud — Mission Control by BurnBar

Work in the BurnBar repository on the Mission Control product page. Read the current `AGENTS.md` first. Owner correction: Mem0 is retired; do not use or connect it, even if an older instruction says otherwise.

Refine `website/src/pages/mission-control.astro` into a beautiful, elegant, Apple-like Liquid Glass product and download experience. The current implementation is a working starting point, not a visual ceiling. Use confident composition, excellent type, generous but purposeful space, translucent depth, subtle warmth and precise interaction. Make it feel native to the BurnBar family while giving Mission Control its own identity. Avoid a generic SaaS template, repetitive feature tiles, decorative graphs, fabricated screenshots and oversized empty sections.

## Product you are presenting

Mission Control is a native macOS and separate iOS control room for a person's own computing environments: their Mac and explicitly configured remote machines. It brings connection state, permitted actions and durable task results into one place.

There are two separate repositories/editions. The private personal edition uses an explicit owner profile. The portable edition starts blank: no environments, tokens, copied account sessions or original owner's infrastructure. This public-facing page focuses on the portable edition.

The intended Mac distribution is a DMG containing the application and its bundled service. Users should not need a separately installed Python or Node runtime. The iPhone client is a separate build; a DMG does not install an iPhone app. It pairs with an owner-managed authenticated HTTPS service, with pairing credentials stored in Keychain.

First use should feel simple: open the app, give the setup brief to an existing trusted agent, review/import its proposed profile, connect, then see actual results. Configuration is reviewed data. Approved diagnostic probes and task actions have separate roles. Actions are named, explicit executable/argument pairs with finite timeouts. Existing SSH identities stay on the machine that owns them. A configured environment is not automatically reachable, authenticated or ready to run tasks.

The product provides orchestration, not an AI subscription or additional cloud entitlement. Do not imply universal compatibility, unlimited capacity, automatic purchasing, copied account access, arbitrary command access or guaranteed reliability.

## Existing source of truth

- Product page: `website/src/pages/mission-control.astro`.
- Interactive, clearly labeled illustration: `website/src/components/mission-control/ControlRoomPreview.astro`.
- Full copied Po'dex token foundation: `website/src/data/mission-control-tokens.json`.
- Token provenance: `website/public/mission-control/token-provenance.json`.
- Release validation and token mapping: `website/src/data/mission-control.ts`.
- Public release manifest: `website/public/mission-control/release.json`.
- Release gate regression tests: `website/test/mission-control.test.ts`.
- Agent setup brief: `website/public/mission-control/agent-setup.md`.
- Self-hosted Space Grotesk and Space Mono: `website/public/mission-control/fonts/`.
- Font licenses: `website/public/mission-control/licenses/`.
- Existing site shell: `website/src/layouts/BaseLayout.astro`, `website/src/components/Header.astro`, `website/src/components/Footer.astro`.

Use the actual Po'dex type roles, spacing, dimensions, radii, elevation and motion foundation. Brand accents are pink `#FF7EB6`, orange `#FFB347` and canary yellow `#FFEA70`. Inherit readable neutrals and semantic states. Use darker foreground variants where pastel small text would fail contrast. Keep token provenance intact and use the shared source rather than inventing parallel token files or hardcoded values throughout components. Fonts are already self-hosted: do not add remote font requests.

## Visual and interaction direction

Make the control room the central idea. A person should immediately understand that they move between their environments and remain in charge of what runs. Native swipe/scroll, keyboard and clear selection affordances should work together. Show genuinely different portrait and landscape compositions: portrait is focused and within thumb reach; landscape makes room for navigation, active environment and context. Do not merely shrink the desktop layout.

Create a coherent product mark, wordmark treatment and warm visual language that could extend naturally to an app icon, DMG and first launch. Prefer a thoughtful restrained design over more effects. Use real screenshots only when the image and its provenance are available. Otherwise label illustrations as concepts/previews and avoid live-looking metrics, healthy status badges or task claims that have not been observed.

Preserve the current navigation entry in the existing BurnBar product menu, mobile menu and footer. Keep the page within the existing layout and CSP. Do not rewrite unrelated product pages, Po'dex or the entire site shell.

## Release truth is a hard requirement

The download CTA is driven by the checked-in release manifest and `isPublicRelease`. At the time this brief was written, the public release is in preparation. Never change verification flags to make the design look complete.

A public download requires a real version, supported macOS/architectures, HTTPS artifact URL, SHA-256, verified Developer ID signature, accepted notarization, stapled ticket, verified public download, clean installation check, release notes and verification timestamp. Keep the tests that withhold incomplete releases. A private repository or development-signed DMG is not an anonymous public download.

For a pending release, show an honest preparation state and useful agent setup documentation. For a verified release, show the actual download, requirements, installation instructions, release notes and checksum. Do not invent a price, release date, testimonial, usage number, public repository link or App Store listing. macOS 14+ and Apple silicon/Intel are the current build targets; a separate iOS 17+ client exists, but no App Store release is claimed.

## Required content

Explain one place for a person's environments, agent-assisted setup with review, explicit permitted actions, actual state/results, the blank portable edition, the separate private personal edition, no included AI subscription, Mac requirements, distribution status and iPhone pairing. Keep a real support path: `support@burnbar.ai`. Never expose private host profiles, tokens, addresses, personal screenshots or credentials.

Do not add analytics, forms, newsletters, cookies, purchases or new services. Existing site-wide consent behavior belongs to the site shell; do not expand it. Preserve normal TLS, Keychain, SSH host-key and OS permission boundaries.

## Validation and handoff

Run the narrow release tests, Astro check/build, changed-file lint/format checks, typography and reduced-motion gates. Regenerate the Firebase CSP hashes using the existing script if markup changes require it; inspect the diff so no origins or unsafe policy allowances are introduced. Verify links and the pending-release state. Test phone portrait, phone landscape, tablet and desktop; light/dark; keyboard selection/focus; reduced motion; and horizontal overflow. Capture screenshots of the final page at meaningful sizes.

Report what changed and what actually passed. Distinguish a built page from a deployed page, and a verified signed release from a development artifact. Do not deploy, change DNS, publish a release, broaden access or buy services. Deliver a reviewable branch/PR following the repository's current instructions.
