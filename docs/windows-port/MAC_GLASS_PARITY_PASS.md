# macOS/Linux liquid-glass parity pass — Windows (2026-07-18)

**Scope:** align the WinUI 3 shell with the macOS (`AgentLens/`) and Linux
(`apps/linux-desktop/`) Aurora "liquid glass" visual language instead of the Pensieve
ink/brass recolor it shipped with. This document is the review map, validation matrix, and
Windows-host evidence checklist required before claiming visual parity.

## What the review found (before)

1. **Wrong canvas:** the shell rendered the Pensieve palette (ink `#050508`, brass `#FA6B06`) —
   the Data Control Center world — not the macOS Aurora slate (`#0D1117`/`#161B22`) both the
   Mac and Linux shells use.
2. **Dark-only overrides:** `Theme/PensieveShell.xaml` had no `ThemeDictionaries`; Light mode
   painted dark ink plates (broken by design).
3. **No bundled fonts:** Outfit/Geist/JetBrains Mono/Fraunces all fell back to Segoe
   UI/Consolas; 38+ hardcoded `FontFamily="Cascadia Mono…"`.
4. **Fluent recolor surfaces:** Settings leaf pages, chat bubbles, dialogs, and onboarding
   used stock Fluent chrome with brush overrides only.

## Canonical decision

macOS is the design oracle. **Dark = Aurora dark** (slate ramp, ember `#FA5053`, amber
`#FFA800`, whimsy `#8B7FE8`); **Light = Aurora light** (coral dust `#F3E8E6`, ember `#F45B69`).
Linux's skin-level brass accent (`#fa6b06`) is its one deliberate deviation; the token group
carries both accents so aligning Linux later is a one-token skin swap. The **Data Control
Center keeps the Pensieve world** (ink/brass/mercury) — untouched except font + exact-token
swaps.

## What changed (review map, in suggested review order)

1. **Token pipeline (single source of truth):**
   - `packages/design-tokens/tokens/aurora.tokens.json` — NEW additive DTCG group: the Aurora
     dark + light ramps, the liquid-glass material recipes (tint plates/strokes/inner light/
     sheen/edge/shadows with the Linux `liquid-glass-tokens.css` alpha math baked to `rgba()`),
     macOS type scale, radius `xs 6`/`xl 22`, space `xxs 2`.
   - `packages/design-tokens/config.mjs` — shell accent alias `OBBAccentColor` now resolves to
     the macOS ember (was Pensieve brass); `OBBMonoFontFamily` prefers JetBrains Mono.
   - `packages/design-tokens/tokens.test.mjs` — new test pins the aurora group on every
     platform (CSS/XAML alpha folds/Swift/C#) and the ember accent alias.
   - Regenerated + synced in-tree copies: `windows/app/OpenBurnBar.App/Theme/Tokens.xaml`,
     `Theme/PensieveTokens.cs`, `android/…/ui/tokens/PensieveTokens.kt` (drift-guarded,
     byte-for-byte).
2. **Theme foundation:**
   - `Theme/PensieveShell.xaml` — rewritten around `ResourceDictionary.ThemeDictionaries`
     (Default=Dark Aurora slate, Light=Aurora light, HighContrast=Windows system colors). Fluent
     system brushes + NavigationView brushes map onto the tokens for Dark/Light; adds the
     theme-aware `Aurora*` alias brushes (text/accents/glass tints/strokes/selection) consumed
     via `{ThemeResource}`.
   - `Theme/LiquidGlass.xaml` — styles retargeted to the glass recipes: card radius 10 (macOS
     GlassCard), toolbar 8, pill 999; hover scale 1.015 / press 0.98 (macOS physics); ember
     alert ring; selection fill/stroke.
   - `Theme/LiquidGlass.cs` — plate/scrim palette constants only: `#161B22` plates (was
     `#1C1C1E`/`#202024`), `#0D1117` scrim (was `#0A0A0E`). No logic change.
   - `Theme/Typography.xaml` — NEW: bundled `FontFamily` resources (`AuroraDisplayFont`
     Outfit, `AuroraBodyFont` Geist, `AuroraMonoFont` JetBrains Mono, `AuroraArcaneFont`
     Fraunces — with Segoe/Cascadia fallbacks) + the macOS type scale as named TextBlock
     styles (36/28/20/16/14/12/11 + mono 28/14/12/11).
   - `Theme/GlassControls.xaml` — NEW: `AuroraGlassCard`, prominent/regular/cool glass buttons
     (prominent = ember→amber gradient stroke + gradient text, cool = frost→abyss Quit),
     icon button, toolbar pill, segmented styles, glass input (sunken + ember focus),
     info/warning/error alert pills, stat-card text, sidebar rows, divider, dialog style, and
     **implicit glass `SettingsCard`/`SettingsExpander` styles** (all Settings leaves inherit).
   - `Assets/Fonts/*.ttf` — NEW: Outfit/Geist/JetBrains Mono/Fraunces converted from the Linux
     woff2 (OFL, see `Assets/Fonts/LICENSE-fonts.txt`; Outfit name table patched so the family
     resolves as "Outfit"). Referenced `ms-appx:///Assets/Fonts/<file>#<Family>`; csproj
     copies them as Content.
   - `Theme/BrandFonts.cs` — NEW: code-behind chokepoint for the bundled families
     (`BrandFonts.Mono/Body/Display` with safe fallbacks).
3. **Shell chrome:** `Shell/AppShell.xaml` (omnibar glass pill "Search or jump to… Ctrl K",
   hardcoded `RequestedTheme="Dark"` removed so ThemeService governs), `MainWindow.xaml`
   (titlebar), `FlyoutWindow.xaml` (radius-22 popover plate, Aurora freshness/quota/section
   chrome, prominent Dashboard / regular Settings / cool Quit), `Shell/CommandPalette.xaml`
   (glass dialog), `Shell/BurnHeroControl.xaml`, `Shell/KernelSwitcherControl.xaml`,
   `Shell/SurfaceStubPage.xaml`.
4. **Surfaces:** chat (user bubble = ember→amber gradient + violet `chatUserStroke` edge;
   assistant = glass plate; atom chips/thinking view/composer), all Settings leaf pages,
   onboarding (window now registered with `ThemeService` like MainWindow; gradient →
   ember→amber; step dots/pills/dialogs), `Theme/AppearanceModeControl.xaml` (swatch tiles
   previewing each mode's canvas+accent), Dashboard sidebar/layouts, MissionControl, Quota,
   SessionLogs, Memory, Switcher, Budget, ElderWand, Insights, Components (UnifiedGlassCard
   sheen/edge → tokens; skeleton; quota strips), LiveCliStreamView.
5. **Code-behind sweep:** `StreamingBubble.xaml.cs` (Pretext pill/body brushes → macOS tokens;
   canvas font strings → JetBrains Mono/Geist), `DashboardCommandSidebar.xaml.cs`,
   `QuotaWorkspacePage.xaml.cs`, `MissionControlConverters.cs` (brush lookups → macOS tokens),
   `FlyoutWindow.xaml.cs`, `SessionLedgerSection.xaml.cs`, `UnifiedToolCallAccordion.xaml.cs`,
   `AtelierLayoutView.xaml.cs`, `SettingsViewModelHostPage.xaml.cs` (fonts → `BrandFonts.Mono`).
   Code-side lookups use the root-level theme-independent `PensieveColorMacos*`/`PensieveGlass*`
   keys because `Application.Current.Resources.TryGetValue` cannot see `ThemeDictionaries`
   entries (documented limitation; these elements stay Aurora-dark in Light mode).
6. **Discipline gate:** `scripts/windows-port/check-xaml-token-discipline.sh` + allowlist —
   fails any raw hex color or hardcoded `FontFamily` in `windows/app/**/*.xaml` outside
   `Theme/` (icon fonts + documented bespoke art colors excepted). Wired into
   `.github/workflows/pr-windows-fast.yml` (`windows-parity-ledger` job).

## Invariants preserved

- No view-model/logic/behavior changes; no binding, `x:Name`, or event-handler edits (except
  the single `OnboardingWindow.xaml.cs` constructor theme registration, mirroring MainWindow).
- Pensieve token values unchanged — Data Control Center identity kept.
- macOS/Linux app sources untouched (reference only); the shared-tree edit is additive.
- R7 accepted glass drift unchanged: no content refraction, no glass-over-glass, no
  interactive lensing (opacity-overlay stand-ins).

## Validation matrix

| Check | Result |
|---|---|
| `cd packages/design-tokens && npm test` (build + 12 token/font packaging tests incl. new aurora group + drift guards) | ✅ 12/12 on macOS |
| `xmllint --noout` over all `windows/app/OpenBurnBar.App/**/*.xaml` | ✅ 110/110 |
| `scripts/windows-port/check-xaml-token-discipline.sh` | ✅ green; negative test (planted `#FF0000`) fails closed |
| Resource-key existence sweep (every new key referenced from XAML/C#) | ✅ all present in generated/handwritten dictionaries |
| Seven portable presentation/quota/settings/shell/theme test projects (macOS host; native domain core built first) | ✅ 1,282/1,282 |
| WinUI compile + visual verification | ⛔ deferred — WinUI 3 cannot build/render on macOS; happens on the Windows dev host / `pr-windows-full.yml` (x64 + ARM64 legs) |

## Windows-host evidence checklist (G3-style)

On a Windows machine, per `windows/app/DEV_HOST_RUNBOOK.md`:

1. `dotnet build windows/OpenBurnBar.sln` (expect 0 errors; watch for XAML compiler
   resource-key warnings).
2. Run the app; screenshot **before/after pairs** vs. this branch: tray flyout, main window
   command deck, Dashboard (each layout), Chat (user/assistant bubbles + streaming),
   SessionLogs, Settings (General + Appearance), Onboarding, Command palette.
3. Theme axes: Dark / Light / HighContrast; transparency pref `t ∈ {-1, 0, +1}` (frost /
   neutral / clear); Reduced Transparency on.
4. Fonts: confirm Outfit/Geist/JetBrains Mono render (not Segoe) in the flyout header, a
   dashboard stat card, and a chat code block. If unpackaged `ms-appx` font resolution fails,
   verify via the MSIX package (`windows/packaging/`) — the ship vehicle — before falling
   back to runtime path resolution.
5. DPI 100% + 150% on the flyout (radius 22 plate, resize grip) and command deck.
6. Drop screenshots under `launch-evidence/` per the existing evidence conventions and tick
   the G3 rows in the parity ledger.

## Risks

- **Font resolution (unpackaged):** `ms-appx:///Assets/Fonts/*.ttf` references are standard
  but unpackaged apps have historically been quirky; MSIX is the guaranteed path (checklist 4).
- **Light-mode coverage:** every `Aurora*` alias has a Light value, but bespoke hardcoded
  `#E6…` NavigationView pane brushes and code-resolved `PensieveColorMacos*` brushes stay
  dark-flavored in Light mode (documented limitation, matches the pre-existing behavior).
- **Accent change blast radius:** `OBBAccentColor` flipping brass→ember recolors every
  `OBBAccentBrush` consumer (Dashboard layouts, Flyout, SessionLogs, MissionControl) — that
  is the point of the pass, and DCC is unaffected (binds `BrassCore` directly).
