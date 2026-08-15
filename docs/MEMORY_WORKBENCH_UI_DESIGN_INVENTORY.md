# Memory Workbench UI — design-system inventory

**Addendum to [`MEMORY_WORKBENCH_UI_BUILD_PROMPT.md`](MEMORY_WORKBENCH_UI_BUILD_PROMPT.md).**
Researched 2026-08-15 against `main`. This is what actually ships, so the implementer cites real
tokens instead of guessing. Where a value is quoted, it was read in the file.

> Ignore anything under `.claude/worktrees/**` — those are stale agent clones of every file below.

---

## 0. Start here: there are TWO token systems, and they disagree

**System A — Pensieve DTCG tokens.** `packages/design-tokens/` (Style Dictionary v5, `node config.mjs`)
generates five artifacts, all stamped `GENERATED … DO NOT EDIT`: `dist/css/pensieve.css` (web +
Linux), `dist/swift/PensieveTokens.swift`, `dist/compose/PensieveTokens.kt`,
`dist/winui/PensieveTokens.xaml`, `dist/winui/PensieveTokens.cs`. **This is the only true
cross-platform pipeline.**

**System B — the Apple `DesignSystem`.** Hand-maintained, larger, and **never generated from A**.
`AgentLens/Theme/DesignSystem.swift` is what 278 files import.

They disagree on geometry: Pensieve space `4/8/12/16/24/32/48` and radius `8/14/20/999`; Apple space
`2/4/8/12/16/24/32/48` and radius `6/10/16/22/9999`; the web console overrides again to
`5/8/12`. **Three radius scales ship today.**

**Do not "fix" this inside the workbench PR.** Consume the correct per-platform file (§7), build the
feature, and file the convergence separately. But know that "uniform" cannot mean "identical
numbers" until someone does.

---

## 1. Apple tokens — the real values

`AgentLens/Theme/DesignSystem.swift` (macOS canonical) · `OpenBurnBarMobile/Theme/MobileTheme.swift`
(iOS façade) → `OpenBurnBarCore/Sources/OpenBurnBarUI/Views/UnifiedDesignSystem.swift` →
`.../SharedModels/DesignSystemTokens.swift` (raw hex, three skins: `…Light`, `…Dark`, `…Editorial`).

**Colors** (light / dark / editorial):

| Token | Light | Dark | Editorial |
|---|---|---|---|
| `ember` (alias `coral`) — the one accent | `F45B69` | `FA5053` | `F45B69` |
| `amber` (alias `gold`) | `F28C38` | `FFA800` | `8A6200` |
| `blaze` | `E86100` | `E86100` | `B3243C` |
| `whimsy` (aliases `purple`, `teal`) | `6A5ACD` | `8B7FE8` | `565D68` |
| `background` | `F3E8E6` | `0D1117` | `F6F4EF` |
| `surface` | `FAF5F2` | `161B22` | `FFFEFB` |
| `surfaceElevated` | `FDF8F5` | `1F2630` | `FFFEFB` |
| `surfaceMuted` | `F2E0DA` | `1B202A` | `F0EEE7` |
| `border` / `borderSubtle` | `E8BFB5` / `F2E0DA` | `30363D` / `21262D` | `1F16140F` / `1416140F` |
| `textPrimary` / `textSecondary` / `textMuted` | `2A1816` / `6E4E48` / `9A756D` | `E6EDF3` / `8B949E` / `6E7681` | `16140F` / `353027` / `6E685D` |
| `success` / `warning` / `error` | `3A7835` / `C47800` / `D43030` | `38D898` / `FFA800` / `FA5053` | `0C7C69` / `8A6200` / `B22219` |

**Spacing** `xxs 2, xs 4, sm 8, md 12, lg 16, xl 24, xxl 32, xxxl 48` — consistent across Apple and
Android (`AuroraSpacing`).
**Radius** `sm 6, md 10, lg 16, xl 22, full 9999` — consistent Apple ↔ Android.
**Shadows** `ShadowSpec(color, radius, x, y)`: `subtle(.05, r2, y1)`, `small(.10, r4, y2)`,
`medium(.12, r8, y3)`, `cardHover(ember .40, r12, y4)`, `large(.20, r16, y6)`, `fab(amber .70, r4, y2)`.

**Typography** — fixed-point `Font.system(size:)`, `design: .rounded`:
`displayLarge 36 bold · display 28 bold · title 20 semibold · headline 16 semibold · body 14 ·
caption 12 medium · tiny 11 medium · mono 14 / 12 / 11`.
**iOS runs 2–3pt larger** for headline/body/caption/tiny (18/17/15/14). Decide deliberately whether
the workbench matches macOS or iOS on each platform, and say which in the PR.

⚠️ **`DESIGN.md` at the repo root is stale** — it documents an abandoned "Warm Charcoal / Botanical
Cream" palette. Cite `DesignSystem.swift`, never `DESIGN.md`.

---

## 2. The plate recipe — copy this verbatim

`AgentLens/Views/Charts/ChartCardView.swift:52-90` is the canonical card:

```
.padding(Spacing.lg)                                   // 16
shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)   // 16
macOS 26+:  shape.fill(accent.opacity(dark ? 0.08 : 0.04))
            .liquidGlassEffect(.regular, in: shape)
macOS 14–15: ZStack { shape.fill(.ultraThinMaterial)
                      shape.fill(surface.opacity(dark ? 0.45 : 0.55))
                      shape.fill(accent.opacity(dark ? 0.08 : 0.04)) }
.overlay(shape.stroke(accent.opacity(0.22), lineWidth: 0.75))
```

The rule in the source: **"The wash tints the light, it never paints a slab."** On 26+ the accent
wash is the *only* fill and rides on top of the glass — anything opaque underneath kills refraction.

`docs/DASHBOARD_CONTROL_CENTER_REDESIGN.md` §6.1 extends it: expanded plate (stroke `0.32` +
`shadow(accent.opacity(dark ? 0.10 : 0.05), radius: 8, y: 4)`), attention plate
(`warning.opacity(0.55)` @ lw 1.0 + 6pt dot), and — **the branch new surfaces always forget** — the
editorial skin, which is `surface` fill + 1pt `border` and **completely glass-free**. That doc calls
it *"the single most common way a new AgentLens surface ships broken."*

**Geometry from the same spec:** card radius 16 `.continuous`, card padding 16, page padding 24,
content clamp **1180**, grid gutter 12, internal stack 8, glyph well 26×26 at `Radius.sm` filled
`accent.opacity(0.14)`.

---

## 3. The glass contract

`AgentLens/Theme/LiquidGlass.swift` ⟷ `OpenBurnBarMobile/Theme/LiquidGlass.swift` (declared lockstep
mirrors). API: `liquidGlassSurface(tint:in:fallback:)` (passive plates),
`liquidGlassInteractive(...)` (clickable), `liquidGlassCircleButton(diameter:)`,
`liquidGlassEffect(_:in:)`, `LiquidGlassGroup`, `LiquidGlassWindowBlend`.

**Direct SwiftUI `glassEffect` is banned outside `Theme/LiquidGlass.swift`.**

Four invariants (`docs/LIQUID_GLASS_PARITY.md`):
1. Exactly **one** glass layer per visual cluster; grouped elements share one container.
2. Glass sits **on top of** content — chips and buttons inside a glass plate stay plain material.
3. The membership/foil world stays **glassless** (glass is the utilitarian shell's language).
4. `tint` conveys **meaning** (primary, destructive), never decoration.

User preference `liquidGlassTransparency` (Double, −1…1, default 0) with published math:
`usesClearGlass(t) = t > 0.001`; `frostScrimOpacity(t) = t<0 ? 0.9 * -t : 0`;
`fallbackPlateOpacity(t) = t>0 ? 1 - 0.78*t : 1`. **Reduce Transparency wins**: positive `t`
resolves to 0. macOS deploys to **14**, so every glass API is `#available(macOS 26, *)` gated with a
material fallback.

---

## 4. Components to reuse (do not reinvent)

**Editorial / reading** — `AgentLens/Views/Dashboard/ProjectMemoryEditorialPrimitives.swift`:
`EditorialHero` (eyebrow `.tracking(2.0)`, headline `.title2 rounded semibold`, `lineSpacing(4)`,
meta joined `"  ·  "`), `MercuryHairline` (0.5pt gradient rule; **highlight skipped under
reduce-motion**), `HermesReadingCard`, `MercuryPoolDots` (the thinking indicator — *not* a spinner),
`NumberedSectionRow`, `FootnoteCitationChip` (`[%02d]` mono + hover scale 1.02 + full a11y label),
**`EmptyEvidenceCallout`** — the honesty primitive: `"INSUFFICIENT EVIDENCE"` in `monoTiny`
`.tracking(1.6)` warning, body, then an italic line naming the fix. `CitationQuoteCard`,
`VisualChart`, `CascadeInModifier`, `HFlowLayout`.

**Navigation / organize** — `ProjectMemoryWikiPrimitives.swift`: `WikiBreadcrumb` (`›`, mono),
`WikiPivotPillRow`, `WikiTableOfContents` (`CONTENTS` + per-row `%02d` ordinal and cite counts),
`WikiSeeAlsoRail`. **This is the workbench's natural vocabulary and it is currently stranded on a
read-only lane.**

**State** — `AuroraStatePane` (iOS empty/error/loading), `EmptyStateView`, `QuotaEmptyState`,
`AgentInsightsEmptyStateView`, `UnifiedSkeletonView` (ember/amber sweep, `.linear(1.5).repeatForever`,
**gated on reduce-motion**), `EmberSkeleton`, `MercuryShimmerModifier`.

**Controls** — `GlassCard`, `GlassButton`, `GlassButtonStyle`, `UnifiedGlassCard`,
`AuroraButtonStyle` (5 roles incl. destructive), `AuroraChipRail` (matchedGeometry pill).
**`ControlSwitch`** is the on/off vocabulary on the deck: capsule button, 11pt semibold,
`.symbolEffect(.bounce, value: isOn)`, 5pt state dot, glass-interactive tint. **No stock `Toggle`,
`SwitchToggleStyle`, or `Form` appears anywhere on the deck or charts — verified zero occurrences.**

---

## 5. The workbench shell already exists — study it

`AgentLens/Views/Settings/DataControlCenter/` (6 files, 1738 lines) is the closest shipped analogue:

- `NavigationSplitView` sidebar (`.listStyle(.sidebar)`, width `min 220 / ideal 250 / max 300`,
  tier-grouped sections with 10pt heavy `.tracking(1.0)` headers, `.safeAreaInset(edge: .bottom)`
  footer) → detail = `HSplitView { inventory.frame(minWidth: 360, idealWidth: 460); inspector.frame(minWidth: 360) }`.
- A real SwiftUI **`Table(of:selection:sortOrder:)`** with `KeyPathComparator`,
  `.tableStyle(.bordered(alternatesRowBackgrounds: true))`, explicit per-column
  `.width(min:ideal:max:)`, monospaced digits for numerics, `—` for zero, per-row `.contextMenu`.
- Empty inspector = `ContentUnavailableView`.
- `PensieveTheme.tierExplanation(_:)` is the model for plain-language privacy copy.
- `DataControlCenterActions.swift` holds the **type-to-confirm** destructive pattern
  (`"Type DELETE to confirm"`).

**Density patterns to inherit** (from `InboxView.swift`): `SelectionIntent { replace, toggle, extend }`
resolved from `NSEvent.modifierFlags`; the checkbox column appears only once a multi-selection
exists; a row action applies to the whole selection when the row is part of it; a selection bar
animated with `Animation.gentle` labelled `"<title> N selected items"`; undo banner + `⌘Z`;
delete confirmation only above a count threshold.

---

## 6. Motion

`standard = .spring(response: 0.35, dampingFraction: 0.75)` · `gentle = .spring(0.4, 0.85)` (layout
shifts) · `snappy = .easeOut(0.15)` (immediate feedback) · `hover = .spring(0.25, 0.8)` ·
`mercuryShimmer = .linear(3.0).repeatForever` · `mercuryPulse = .easeInOut(1.5).repeatForever(autoreverses: true)`.

**Rule:** always `animation(_:value:)`, never bare `animation(_:)`.
Android mirrors these as `AuroraMotion` (`auroraSpring 322f/0.75`, `auroraSnap tween(150, EaseOut)`).
Reduce-motion: Apple `@Environment(\.accessibilityReduceMotion)`; Android reads
`ANIMATOR_DURATION_SCALE` into `LocalAuroraReduceMotion`; web/Linux `prefersReducedMotion()` with
live-updating body classes. **The Control Deck standard is to pass `nil` animation under
reduce-motion** — not to skip the state change.

Haptics are **iOS-only**: `Haptics` (debounced, thread-safe, respects Reduce Motion) and the
semantic `HapticBus` (`tabChange`, `primaryAction`, `threshold`, `toggle`). Android has none.

---

## 7. Per-platform theme file to import

| Platform | Import this |
|---|---|
| macOS | `AgentLens/Theme/DesignSystem.swift` + `Theme/LiquidGlass.swift` + `Theme/ThemeGlassPalette.swift` (**must branch on `AppSkin.current == .editorial`**) |
| iOS | `OpenBurnBarMobile/Theme/MobileTheme.swift` (+ `AuroraDesign.swift`, `LiquidGlass.swift`) |
| Android | `android/.../ui/theme/AuroraTheme.kt` + `ui/tokens/PensieveTokens.kt`; glass in `ui/components/LiquidGlass.kt` |
| Windows | merged in `App.xaml` in order: `Theme/Tokens.xaml` → `Typography.xaml` → `PensieveShell.xaml` → `LiquidGlass.xaml` → `GlassControls.xaml`. Style keys `LiquidGlass*Style`, `AuroraGlass*Style` |
| Linux | `apps/linux-desktop/src/styles/tokens.css` + `liquid-glass-tokens.css` + `liquid-glass.css` + `skins.css` + `adaptive-foreground.css` |
| Web console | `apps/console/styles/globals.css` + `tailwind.config.ts` (Tailwind binds only to `var(--…)` — *"we never hardcode hex"*). Utilities: `.glass-pane`, `.btn-quiet`, `.btn-accent`, `.btn-outline`, `.btn-bare` |

**`AppSkin`** (`ThemePrimitives.swift`) is the orthogonal axis: `.aurora` (default) / `.editorial`,
key `"appSkin"`, shared verbatim across platforms. **Editorial is light-locked and glass-free
everywhere.**

---

## 8. Voice and copy — enforced in code, not in a style guide

**Two banned-phrase lists exist. Obey both.**
- `OpenBurnBarInsights/SharedModels/Verdict/InsightVoiceSchemaV2.swift:180` — *"based on the data",
  "it seems that", "it appears that", "leveraging", "significant", "substantial", "notable",
  "robust", "in conclusion", "moving forward", "welcome back", "as we can see", "it is worth
  noting", "delve into", "navigating", "unleash", "unlock the potential"*, …
- `OpenBurnBarDaemon/.../AIInbox/BurnBarFounderLens.swift` — the inbox's own 17-entry list
  (*"delve", "crucial", "robust", "comprehensive", "nuanced", "landscape", "pivotal", "furthermore",
  "it looks like", "you might want to"*, …).

`InsightVoicePostProcessor` enforces it at runtime — *"The model is allowed to drift; the regex is
not."* Every surviving bullet needs ≥1 numeric token, valid citations, and an action intent from a
closed registry; if fewer than one survives it falls back to the rule-based engine, because the
rule is **never ship an empty verdict**.

The exemplar pair:
> **GOOD** — "You spent $4.12 yesterday — 28% under your 4-week average, driven by 91% cache hit on the Atlas refactor."
> **BAD** — "It seems your spending has been notable this week, with significant improvements in cache utilization."

**Honesty conventions the Daily Brief must inherit** (`InboxView.swift:207-246`,
`ControlDeckLiveFacts.swift:38-100`): `"All caught up"` · `"Last checked <when> — nothing had
changed."` · `"Last analyzed <when> · $0.003"` · `"… · rule-based brief (no model ran)"` · `"… ·
rule-based brief (model egress off)"` · `"92% of the last 24 checks found nothing to do"`. The code
comment states the rule: *"Do not name a cause the run telemetry cannot actually prove."* And
**"nil is not zero"** — an unknown count never renders as `"0"`.

From `docs/UI_DELIGHT_HANDOFF.md`: *"There is NO `.estimated` anywhere. If data isn't real, we say
so."* Confidence is `.exact | .unavailable`, nothing between.

**Destructive copy:** `.confirmationDialog(titleVisibility: .visible)` + destructive verb + a
`message:` naming consequence and reversibility. The existing memory-reject dialog is the model:
*"It won't be remembered or used in any chat. You can't undo this."* Heavy destruction uses
type-to-confirm. Wax-crimson (`seal.crimson #c5221f`) is **destructive-only** by token definition.

---

## 9. Accessibility — what's practiced, and the two gaps

**Practiced:** a central identifier registry `AgentLens/Support/AccessibilityIdentifiers.swift`
(`enum OBBAccessibilityID`, scheme `domain.element`, with normalizing factories) that UI tests bind
to — **the workbench must add `memoryWorkbench.*` there**. Header traits on eyebrows/headlines;
`children: .ignore` + synthesized label for charts; `children: .combine` for citation cards and
breadcrumbs; `accessibilityHidden(true)` for decorative rules; `.accessibilityValue("On"/"Off")` on
switches. Contrast has real machinery: `BackdropReadability.swift` (`normalTextRatio 4.5`,
`largeTextRatio 3.0`, `relativeLuminance`, `ratio`) surfaced via
`@Environment(\.backdropReadabilityProfile)` — **never seed a constant profile**.

**Gap 1 — Dynamic Type is effectively unsupported.** All Apple type is fixed-point
`Font.system(size:)` rather than relative text styles, and only 6 clamp call sites exist repo-wide.
Shipping real Dynamic Type in the workbench is a genuine improvement — scope it explicitly rather
than assuming it works.

**Gap 2 — the identifier registry is macOS-only.** No equivalent on iOS, Android, Windows, or web.

**Keyboard:** the house idiom is **zero-size shortcut buttons registered at window level** (a
shortcut declared only inside a `Menu` body isn't registered until the menu opens). Inbox precedent:
`⇧⌘A` select all, `⇧⌘D` clear, `⇧⌘P` pin, `⌃⌘A` archive, `⌘⌫` delete, `⌘Z` undo, `⌥↑/↓` reorder.
⚠️ **`⌘1`–`⌘8` are positional over `DashboardNavigationModel.primarySections` — inserting a route
renumbers every user's shortcuts.**

---

## 10. Testing gates

- **Snapshot testing exists on macOS**: `AgentLensTests/Support/SnapshotTestSupport.swift` renders
  SwiftUI to `NSImage` under explicit `NSAppearance`, animations disabled, with
  `XCTAssertAdaptiveSnapshot(of:size:named:precision:)` capturing **both** light and dark; committed
  PNGs live in `__Snapshots__/`. Suites cover adaptive colors, card layout, chat, dashboard,
  gradients, onboarding.
  ⚠️ **`openBurnBarShouldSkipVisualSnapshots()` disables it on CI** — the pixel gate is local-only
  and is *not* a merge blocker. Run it locally and attach the output.
- **Contract canary:** `OpenBurnBarWidget/WidgetDesignSystemContractCanary.swift` is a `#if DEBUG`
  view referencing every primitive so deleting one is a compile error. **Ship the workbench
  equivalent.**
- **Linux has the strongest a11y gate**: `accessibilityContract.test.tsx` parses the CSS and asserts
  the reduce-motion block contains `animation: none !important`, `transition: none !important`,
  `scroll-behavior: auto !important`, plus `prefers-contrast` and `forced-colors` blocks.
- **No lint enforces any design rule.** `.swiftlint.yml` has exactly one custom rule
  (`empty_catch_block`). Nothing blocks a hardcoded hex, a bare `glassEffect`, a stock `Toggle` on
  glass, or a missing identifier. **Adding those custom rules alongside the workbench would be a
  real contribution.**

---

## 11. What "uniform" must mean here (the divergences)

These already differ across platforms. The workbench cannot silently inherit them; for each, either
match the platform or state the deviation in the PR.

1. Two unconnected token systems (§0); the palette is hand-copied **4×** (Swift, generated XAML,
   generated Kotlin, hand-typed `--macos-*` CSS in Linux).
2. Three radius scales.
3. iOS type runs 2–3pt larger than macOS/Android.
4. **`hermesAureate` renders gold on macOS/Windows/Linux and gunmetal on iOS** from the same
   semantic token.
5. macOS `DesignSystem` duplicates hexes as literals instead of reading `DesignSystemTokens` for
   light/dark (it reads them only for editorial) — **a new token must be added in both**.
6. Shadow models differ (Apple tinted `ShadowSpec` vs Android `elevation + spotAlpha`); web/Windows/
   Linux have no shadow scale.
7. Android ships **no brand font** (system sans/mono) despite the tokens defining Outfit/Geist —
   four typefaces across five platforms.
8. The glass transparency preference is Apple-only; Android is "not yet wired."
9. Haptics are iOS-only.
10. Reduce-motion detection differs per platform (Android misses `TRANSITION_ANIMATION_SCALE`).
11. The `editorial` skin is implemented everywhere **except Windows**.
12. The accessibility-identifier registry is macOS-only.
13. Dynamic Type is effectively unsupported everywhere.
14. Visual regression is macOS-only and CI-skipped.
15. `DESIGN.md` documents a palette the code abandoned.

---

## 12. Minimum reading list

1. `docs/DASHBOARD_CONTROL_CENTER_REDESIGN.md` §2, §4, §6, §7 — the house standard for spec rigor
2. `AgentLens/Theme/DesignSystem.swift`
3. `AgentLens/Theme/LiquidGlass.swift` + `docs/LIQUID_GLASS_PARITY.md`
4. `AgentLens/Views/Charts/ChartCardView.swift:52-90` — the plate
5. `ProjectMemoryEditorialPrimitives.swift` + `ProjectMemoryWikiPrimitives.swift`
6. `AgentLens/Views/Settings/DataControlCenter/DataControlCenterView.swift` — the shell
7. `AgentLens/Views/Inbox/InboxView.swift:207-246` + `ControlDeckLiveFacts.swift:38-100` — the voice
8. `InsightVoiceSchemaV2.swift:180` — the banned-phrase list
9. `packages/design-tokens/config.mjs` — the only path to real cross-platform uniformity
