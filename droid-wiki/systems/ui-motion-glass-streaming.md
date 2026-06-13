# UI Systems: Membership Motion, Liquid Glass, Streaming Throttle

Three intentional, load-bearing UI contracts landed 2026-06-11/12. Each has
invariants that LOOK like accidents to a fresh reader — this page is the
authority on why they exist. Violating any of them re-introduces a measured,
user-visible regression.

## 1. Hermes streaming commit throttle (iOS)

`HermesService` (`OpenBurnBarMobile/Services/HermesService.swift`) commits
streaming TEXT to the `@Observable` `messages` array at most every **80 ms**
(`streamCommitInterval`), because per-token commits re-evaluate the whole chat
list and visibly drop frames against the swarm background.

Invariants — all verified by an adversarial audit (2026-06-12):
- Text deltas are the ONLY throttled mutation. Every structural event
  (tool calls, reasoning, refusal, cards, usage, model id, stop, errors)
  commits immediately. A new structural event type MUST commit immediately —
  there is no compile-time enforcement; this is the contract.
- The first chunk of every assistant message commits instantly
  (`isFirstChunk == text.isEmpty` is load-bearing: tool-use iterations share
  one `lastStreamCommit` and never reset it).
- Every exit path — success, throw, cancel — commits the staged message
  unconditionally; no trailing text can be lost.
- While `isStreaming`, the UI uses the cheap `HermesInlineMarkdown` renderer,
  skips shimmer, and caches source-link extraction; the rich Pretext renderer
  takes over on completion (the swap is animated, 0.18 s).
- The `\.hermesStreamingActive` environment caps the **swarm/editorial skins**
  at ~20 fps (`WebsiteBackgroundView.throttledFrameRate`, unit-tested in
  `HermesStreamingSwarmThrottleTests`). The default Aurora mesh is already
  paused at `.subtle` visibility in chat — the env is a no-op there by design.
  Known cosmetic trade-off: the swarm's per-frame stepping means it runs
  slower (calmer) while streaming; intentional.

**Do NOT restore per-token freshness, per-token spring scrolls, or rich
rendering during streaming.**

## 2. Liquid Glass (iOS 26+, deployment target 17)

Two principled systems coexist — do not merge or duplicate them:
- `OpenBurnBarMobile/Theme/LiquidGlass.swift` — shape-level adapters
  (`liquidGlassSurface` / `liquidGlassInteractive` / `liquidGlassCircleButton`
  / `liquidGlassEffect` / `LiquidGlassGroup`) for shell chrome, all routed
  through the user transparency preference (`LiquidGlassTransparency`,
  Frosted ⟷ System ⟷ Clear). Mirrored byte-for-byte in
  `AgentLens/Theme/LiquidGlass.swift` — keep in lockstep.
- `OpenBurnBarMobile/Views/Aurora/LiquidGlassFallback.swift` (`.auroraGlass`)
  — variant-tinted content cards (sheen + edge personality).

Rules (each violation produced a real shipped bug at least once):
1. **Glass cannot sample other glass.** Exactly ONE glass layer per visual
   cluster. A reusable component rendered inside an `AuroraGlassCard` must use
   its material branch — `ProviderAuroraAvatar(glassInCard: true)` is the
   canonical escape hatch; `IdentityHero` documents the pattern.
2. Nothing opaque or material UNDER `.glassEffect` on the iOS 26 path; washes
   and tints ride ON the glass shape.
3. `interactive()` only on genuinely tappable elements.
4. Siblings that show glass simultaneously share one `LiquidGlassGroup`
   whose spacing matches the layout spacing.
5. **Brand boundary:** the membership foil world (ProTheme.Membership, foil
   cards, FoilCTAButton, tier cards, certificate) never wears glass — glass
   appears there only in system chrome (✕ close buttons, sheet material).
6. Pre-26 fallbacks preserve the intended material look; Reduce Transparency
   clamps "clearer" to system default (never force-frosts — the OS handles
   that), Reduce Motion stills every sweep/spark/breathe.

## 3. Membership motion language (paywall surfaces)

Primitives live in `OpenBurnBarMobile/Views/Store/CloudTierComponents.swift`:
`HoloSheenSweep` (periodic off-canvas glint — never a marquee),
`HoloSparksOverlay` (20 fps tier-colored dust), `TierCrestEmblem` (breathing
crest), plus `CloudTier.holoStops/holoGradient` palettes.

Contracts:
- Catalog copy (`GatedFeature`, spec §3) is verbatim and honesty-checked;
  persuasion lives in PRESENTATION only. The Kotlin catalog mirrors it.
- Annual value framing is COMPUTED (`monthlyEquivalentDisplayPrice`,
  `annualFreeMonths`, `CloudTierCard.annualSealText`) — never hardcoded; the
  currency's native precision is used (JPY shows no sub-units). Pinned by
  `HostedQuotaSubscriptionStoreTests`.
- Prominent foil seals use dark `letterpress` ink in both color schemes
  (cream-on-gold fails WCAG AA in light mode).
- The Pro serif voice (`ProTheme.Typography`) scales with Dynamic Type via
  UIFontMetrics — keep `relativeTo:` styles when adding tokens.
- `FoilCTAButton` owns the tap haptic; callers must not add their own.
- Tier cards deliberately disable the card shimmer (`enableShimmer: false`) —
  crest breathe + CTA glow + seal glints are the per-card motion budget.
