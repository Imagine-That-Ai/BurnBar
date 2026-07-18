# macOS/Linux liquid-glass parity pass — Windows (2026-07-18)

**Scope:** make the WinUI 3 shell visually identical to the macOS (`AgentLens/`) and Linux
(`apps/linux-desktop/`) apps — the Aurora "liquid glass" look — instead of the Pensieve
ink/brass recolor it shipped with. This document is the review map, validation matrix, and
Windows-host evidence checklist for the pass.

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
     (Default=Dark Aurora slate, Light=Aurora light, HighContrast mirrors Default). Fluent
     system brushes + NavigationView brushes map onto the tokens per theme; adds the
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
3. **Shell chrome:** `Shell/AppShell.xaml` now follows the Linux TopChrome layout: one command
   deck (brand, omnibar, kernel, BURN hero, appearance, overflow) over seven equal-width tabs
   (Chat, Providers, Database, Projects, Missions, Activity, Memory). The root starts dark to
   prevent a system-light backdrop from mixing with dark resources; `ThemeService` still owns
   explicit Light/High Contrast changes. `MainWindow.xaml` keeps only a transparent drag strip,
   `FlyoutWindow.xaml` carries the radius-22 popover plate and prominent/regular/cool actions,
   and `Shell/CommandPalette.xaml` uses a glass dialog based on WinUI's required default dialog
   template.
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

- No data-model, provider, storage, security, or cloud-contract changes. Shell navigation is
  intentionally recomposed into the seven-tab TopChrome layout; existing destinations remain
  reachable through the tab strip, overflow menu, or command palette.
- Pensieve token values unchanged — Data Control Center identity kept.
- macOS/Linux app sources untouched (reference only); the shared-tree edit is additive.
- R7 accepted glass drift unchanged: no content refraction, no glass-over-glass, no
  interactive lensing (opacity-overlay stand-ins).

## Validation matrix

| Check | Result |
|---|---|
| `node --test packages/design-tokens/tokens.test.mjs` | ✅ 12/12 on macOS, including font packaging + generated-output drift |
| `xmllint --noout` over all `windows/app/OpenBurnBar.App/**/*.xaml` | ✅ 110/110 |
| `scripts/windows-port/check-xaml-token-discipline.sh` | ✅ green; negative test (planted `#FF0000`) fails closed |
| `scripts/diff-coverage-self-test.sh` + Android counterpart | ✅ generated token paths excluded/waived exactly; adjacent handwritten sources still fail closed |
| `dotnet test windows/tests/dist/OpenBurnBar.Dist.Tests.csproj` | ✅ 111/111 on macOS, including three WinUI source contracts |
| `dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj` | ✅ 796/796 on macOS |
| Cross-host `dotnet build ... -p:EnableWindowsTargeting=true` | ⚠️ managed projects compile; macOS cannot execute WinUI's Windows-only `XamlCompiler.exe` |
| WinUI x64 + ARM64 compile | ⏳ required from the fresh PR head in Windows CI |
| Physical visual verification | ⏳ fresh rerun required after the fixes below |

## Physical x64 feedback folded into the source

The flash evidence pack from commit `cbb46fe140` is historical feedback, not evidence for the
current head. It recorded 25 UI-automation routes with zero route failures and valid captures of
the live main window and tray flyout, while also finding three fail-closed defects:

1. A WPF-style `ToolTipService.ToolTip = ...` member inside a C# object initializer did not
   compile under WinUI. The canonical source now calls `ToolTipService.SetToolTip` after creating
   each tab button.
2. The v3 source placed `FontFamily` on `Grid`, which the WinUI XAML compiler rejects. The brand
   font now inherits from the root `AppShell` `UserControl` instead.
3. Ctrl+K showed only the dimmed modal backdrop because `AuroraGlassDialogStyle` replaced the
   default `ContentDialog` style without preserving its template. The style now derives from
   `DefaultContentDialogStyle`, restoring the dialog body and controls.

`WindowsVisualSourceContractTests` locks all three framework contracts. A fresh native Windows
x64 build and screenshot run must confirm the command palette, dark-default chrome, brand fonts,
Light mode, and transparency profiles before this pass can claim physical visual completion.

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
