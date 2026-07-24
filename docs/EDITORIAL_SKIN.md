# The Sun Lit / Paper skin (formerly "Editorial")

> Naming: the user-facing skin labels are **Sun Lit** (this skin, raw value
> `editorial`) and **Moon Lit** (the dark ember default, raw value `aurora`).
> This document predates the rename; code symbols and storage keys keep the
> `editorial`/`aurora` names throughout.

The **Sun Lit** skin folds the light, paper-bright **app.burnbar.ai console
look** ("Quiet Editorial") into the native apps as a *selectable* appearance —
**iOS, iPad, macOS, and Android**. It is **additive**: the signature dark
**Moon Lit** ember look stays the default and is untouched. Users opt in from
Settings; nothing changes for anyone who doesn't.

> Paper surfaces · ink text · one coral accent · hairlines · a light provider-logo dot-crest.

## The model: a skin axis, not a fourth appearance

Appearance and skin are **orthogonal axes**:

- **Appearance** (`System / Light / Dark`) → the OS color scheme. Unchanged.
- **Skin** (`Aurora / Editorial`) → which *palette identity* the design tokens
  resolve to. New.

`Editorial` is **light-only**: it renders its paper palette whenever the
resolving appearance is light (exactly like the web console, whose dark `:root`
is the default and whose light overrides re-point the CSS variables). Under a
**dark** appearance — an explicit `Dark` pick, or `System` on a dark OS — the
paper palette would be unreadable on dark chrome, so the tokens fall back to
the **aurora (Moon Lit) dark palette** instead of pinning the whole app to
light. The appearance mode the user picked is always honored; see
`AppSkin.resolved(for:)`, which view-level skin branches use for the same
decision. The skin choice itself is preserved and Sun Lit returns as soon as
the appearance is light again.

## How it flips everything at once

Views read **design tokens**, not raw colors, so re-pointing the tokens flips
~all UI coherently with near-zero per-view edits — the same trick the console
uses with CSS variables.

The selected skin is persisted under the single key **`appSkin`** (`AppSkin`
enum, in `OpenBurnBarCore`), read live by the dynamic color resolvers via
`AppSkin.current` — no SwiftUI/Compose context required.

| Platform | Token hook | Persistence | Settings entry |
|---|---|---|---|
| iOS / iPad | `Color(editorial:light:dark:)` in `OpenBurnBarCore/SharedModels/ThemePrimitives.swift` → flips `UnifiedDesignSystem.Colors` + `MobileTheme` (delegates) | `@AppStorage("appSkin")` | `ThemeSettingsView` + `SettingsHubView` → "App Skin" |
| macOS | `Color.adaptive(editorial:light:dark:)` in `AgentLens/Theme/ColorAdaptive.swift` → flips `DesignSystem.Colors` | `AppearanceSettings.appearanceSkin` (writes `UserDefaults.standard` + coordinator) | `AppearanceCorkboardSection` → "App Skin" (applies on **Apply & Restart**) |
| Android | `AuroraColors.updateColorsForPalette(..., appearance)` editorial branch in `ui/theme/AuroraTheme.kt` → feeds `MaterialTheme.colorScheme` + `AuroraColors.*` | `GlobalVisualSettingsAppearance` (key `appAppearance`) | `ThemePrefsAppearanceSelector` in the Theme screen |

Backdrops: Editorial renders the **light dot-crest** (see "The dot swarm &
provider glyphs" below) — the native swarm drawn transparently over paper. The
dark ember murmuration belongs to the Aurora skin. The user's Aurora swarm
choice is preserved across skins.

## Palette — single source of truth

The canonical values live in the web console at
`apps/console/styles/globals.css` (`:root`) and are mirrored verbatim into
`DesignSystemTokens.*Editorial` (Swift) and the Android editorial branch.
Locked by `OpenBurnBarCoreTests/AppSkinEditorialPaletteTests`.

| Role | Token | Value |
|---|---|---|
| Page (paper) | background | `#F6F4EF` |
| Raised paper | surface / elevated | `#FFFEFB` |
| Ink (headings) | text-primary | `#16140F` |
| Body | text-secondary | `#353027` |
| Mute | text-muted | `#6E685D` |
| The one accent (coral) | ember | `#F45B69` |
| Deep coral | blaze | `#B3243C` |
| Hairline | border | ink @ 12% (`1F16140F`, AARRGGBB) |
| Tier / success | success | `#0C7C69` |
| Tier / warning | warning | `#8A6200` |
| Destructive | error | `#B22219` |

## v1 scope & extending

- **Typography:** v1 uses native system fonts (SF Pro / New York / SF Mono on
  Apple, Roboto on Android). The console's display faces (Bricolage Grotesque,
  Geist, Newsreader) are **not bundled**; to reach 1:1 type parity later, add
  the OFL fonts to the bundle / `res/font` and point the typography tokens at
  them. The color/surface/hairline system — the load-bearing 90% — is complete.
- **Adding a token:** add `xEditorial` to `DesignSystemTokens`, pass it to the
  `Color(editorial:light:dark:)` / `Color.adaptive(editorial:…)` call, and add
  the matching value to the Android editorial branch. Update the palette test.
- **Brand/provider colors stay fixed** under every skin (they're identity, not
  theme).

## The dot swarm & provider glyphs

Every surface shows the **reconverging dot swarm** that the website made famous,
and **all provider glyphs** cycle through it — the full `AgentProvider` roster
(28 distinct logos; Cursor Agent shares Cursor's mark), interleaved with the
BurnBar Cloud crests.

**Two swarm aesthetics, one per skin:**

- **Aurora** → the dark token-ember murmuration. Now **on by default** (new
  installs are seeded into it: iOS/macOS seed `useWebsiteBackground`, Android
  defaults `BackgroundStyle` to `SWARM`). Existing explicit choices are kept.
- **Editorial** → the **light dot-crest**: provider logos drifting and
  reconverging from coloured dots on paper, like app.burnbar.ai. The native
  swarm renders transparently over paper with `forceLight`/`isTransparent`, so
  logos appear in their real brand colours and read crisply on paper. Respects
  Reduce Motion / Low Power (falls back to calm paper).

**All-glyph guarantee, per surface:**

| Surface | Where the roster lives |
|---|---|
| Marketing site (burnbar.ai) | `website/src/layouts/BaseLayout.astro` — `#bgDots` `LOGOS` + `#bgFx` `LOGO_SRCS` |
| Console (app.burnbar.ai) | `apps/console/components/DotCrestField.tsx` — `LOGOS` |
| iOS / iPad / macOS | `SwarmCanvasView` rasterises each `AgentProvider.bundledLogoName`; nil/default glyph set → all providers (initials fallback covers any logo gap) |
| Android | `SwarmSimulation` rasterises `AgentProvider.logoRes`; `swarmGlyphProviders` default = all |

Web logo assets live in `website/public/brand/providers/` and
`apps/console/public/brand/logos/` (kept in sync). Adding a provider = add its
PNG/SVG to both web dirs + the array, and (native) ship its logo asset; no other
wiring needed.

> Known parity note: the Android `AgentProvider` enum has no separate
> `cursorAgent` case, but Cursor Agent uses Cursor's exact glyph, so the mark
> still appears — no visible gap.
