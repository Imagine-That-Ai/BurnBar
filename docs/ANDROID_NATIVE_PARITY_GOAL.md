# Application Overview
BurnBar is a mobile companion for an AI token-usage tracking platform. The app shows real-time spend across AI providers (OpenAI, Anthropic, Google, etc.), quota pressure, session logs, and includes an AI chat assistant called "Hermes" that answers questions about burn data.

# Architecture
The app has 5 tabs navigated via a custom floating pill-bottom nav (not system TabView): Pulse (dashboard), Burn (quota), Streams (sessions/projects/activity), Hermes (AI chat), You (settings).

# Design System
The visual identity is "Aurora" — warm gradient-driven glass-morphism. Key design tokens:
- Color palette: ember (warm orange/coral), amber (gold), blaze, whimsy, with adaptive light/dark support
- Gradients: auroraRibbon (coral→amber→mercury), heroCard, specular, mercuryFoil
- Cards: glass-morphism with .ultraThinMaterial, rounded corners (22pt hero, 16pt standard, 12pt chips)
- Typography: rounded system fonts — displayHero 44pt bold, display 28pt, title 20pt, headline 16pt semibold, body 14pt, caption 12pt, tiny 11pt, plus monospaced variants
- Spacing scale: xxs(2), xs(4), sm(8), md(12), lg(16), xl(24), xxl(32), xxxl(48)
- Animation: spring curves (response 0.35-0.42, damping 0.75-0.85), custom mercury shimmers, breathing pulses
- Each AI provider has its own brand color for rings, avatars, and chart palettes
- Haptic feedback (HapticBus) on toggles, tab changes, sheet opens, refresh

# Tabs

## Pulse (Dashboard)
- AuroraBackdrop() full-screen gradient background
- ScrollView with pull-to-refresh
- Cards in order with staggered entrance animations:
  1. CloudUpsellBanner (conditionally shown)
  2. TimelineScopePicker (day/week/month chip selector)
  3. PulseHeroBurnCard — marquee card with massive rolling number (44pt), sparkline, currency/token toggle pill, delta vs trailing average, "Streaming live from your Mac" indicator with breathing green dot, provider avatar overlay. `1M`, `1H`, and `1D` totals are computed from the live raw usage stream; `1D` starts at local midnight, while `7D` and `30D` remain Firestore rollup-backed.
  4. VelocityForecastCard — projected end-of-period spend
  5. QuotaPulseCard — provider pressure rings that navigate to Burn tab
  6. TrendAtlasCard — daily spend chart with provider/model/device summaries
  7. HermesQuickAskCard — suggested prompts, opens Hermes tab
  8. RecentSessionsStripCard — latest sessions with tap-to-detail
- Navigates to SessionDetailView, ProviderDashboardView via NavigationStack

## Burn (Quota)
- FleetHealthRing: circular progress with angular gradient (success green→warning amber→error red), center flame icon
- Provider ring strip: horizontal scroll of per-provider quota chips with progress rings, logo, remaining %
- Urgent banner for providers under 25% remaining
- Period selector (today/7d/30d/90d) with PeriodCard chips
- Per-provider expandable accordion cards: header with avatar, account count, chevron; expanded shows routing cockpit, bucket snapshots, "Open full detail" button
- Chart: Swift Charts AreaMark + LineMark with catmullRom interpolation, 180pt tall
- Mode toggle (currency/tokens) as floating circle button
- Skeleton shimmer loading state

## Streams
- Chip rail (sessions/projects/activity segments) with AuroraChipRail
- Searchable list with filters
- Each segment shows filtered TokenUsage items with model, provider, cost, timestamp
- SearchDebounced with provider/model/project/session/device filtering

## Hermes (AI Chat)
- Two-level navigation: ConversationListView → ChatView
- Conversation list shows sessions from connected Hermes host, sorted by lastActiveAt
- Cloud library sessions imported from Firestore
- Empty state with setup guide card, "Start your first conversation" CTA
- New chat FAB (floating action button with mercury gradient)
- Setup wizard (3 steps: keep Mac ready, choose host, start chatting) with numbered circles, mercury foil gradient
- ChatView: welcome block with HermesLiveGlyph, runtime info rail, model name, prompt carousel
- Streaming message bubbles with:
  - User bubbles: rounded rectangle (18pt corners, bottom-right 6pt), surfaceElevated fill
  - Assistant bubbles: rounded rectangle (18pt corners, bottom-left 6pt), surface fill, mercuryFoil stroke, MercuryShimmerOverlay
  - Assistant header: "via Hermes · model-name" with live glyph breathing dot
  - Token-per-second footer (opt-in)
  - Tool call strip with icon pills (terminal, search, globe, edit, etc.)
- Model picker sheet with favorites, provider logos, selection checkmark
- Connection sheet (Remote Relay / LAN / Local)
- Runtime sheet with settings
- Keyboard avoidance (hide nav tray while typing)
- Attachments support (photos, files)

## You (Settings)
- IdentityHero card with user avatar, display name, email
- ConnectedDevicesRow
- SettingsHubView: account management, sync health, credential transfer
- CloudStoreView for subscription management with StoreKit
- iPad-specific settings views

# Widget
- Home screen widget in systemSmall/Medium/Large/ExtraLarge + accessoryInline/Circular/Rectangular
- Shows current burn, sparkline, provider summary
- WidgetDesignSystem with compact typography

# Data Layer
- Firebase Auth + Firestore for cloud sync
- HermesService: WebSocket/REST client connecting to macOS Hermes runtime via LAN or Remote Relay
- QuotaStore, ActivityStore, DashboardStore, ProjectsStore: Observable stores with real-time listeners
- LiveActivityManager for Dynamic Island
- CloudSyncHealthStore, DevicesStore

# Key Interactions
- Pull-to-refresh with haptic start/end
- Scene phase reload on foreground
- Staggered entrance animations on Pulse
- Navigation via NavigationStack with value-typed destinations
- Sheets with presentationDetents
- Reduced motion respect via @Environment(\.accessibilityReduceMotion)

Build everything. Tests included. No placeholders. The finished product.
