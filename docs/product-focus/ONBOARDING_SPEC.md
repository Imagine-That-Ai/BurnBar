> **Status: draft input, not canon.** Produced by the product-focus agent sweep, 2026-08-16. See [../PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md](../PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md) for the corrections applied on top of this draft — in particular §"The two-beat reveal", which supersedes the S1b timing in this document.

---

# BurnBar — First-Run Onboarding Spec
## "The number is already on your disk."

**Author:** design pass, 2026-08-16 · **Target:** macOS direct-download (Developer ID) primary, MAS variant specified · **Supersedes:** `OnboardingWizardView` (7 steps), `OnboardingView` popover splash, `PetFirstRunView`, `SwitcherOnboardingWizardView`

---

## 0. The one-paragraph thesis

BurnBar has a structural advantage nothing else in this category has: **the data is already on the disk before the app is installed.** `SettingsManager.detectAvailableProviders()` runs in milliseconds and already knows Claude Code, Codex and Cursor Agent are on this Mac. Today the app spends that advantage on a pet wizard, three consent modals, and a 45-second sign-in poll (`AgentLensApp+LiveServices.swift:294-305`) before it says a single true thing. The new first run spends it on the only sentence that matters: **a percentage and a reset clock for a window the vendor will never show you.** No account, no key, no OS prompt, no wizard — one window that opens itself, holds a real number, and closes.

**Time-to-first-number target: 1.8 s to first real row, 6.0 s to full first pass, 8.0 s hard degrade to the Empty variant. Budget of 30 s is met with 22 s of headroom.**

---

## 1. Screen-by-screen table

| # | Screen | Surface / size | Trigger | Exit condition | Decisions asked | OS permissions |
|---|---|---|---|---|---|---|
| **S0** | Cold Boot | `NSStatusItem`, 22×18pt | App launch | Status item renders a real value or the scanning pick | 0 | 0 |
| **S1a** | The Reveal — *scanning* | Popover, 340×**auto** (≈300pt) | T+1.2 s, auto-present, once ever | First provider row resolves → morph to S1b | 0 | 0 |
| **S1b** | The Reveal — *landed* | Popover, 340×~420pt | ≥1 provider with a real quota bucket | User clicks anywhere / presses Esc / 45 s idle | 0 | 0 |
| **S1-E** | The Empty Reveal | Popover, 340×~460pt | 8.0 s elapsed, 0 parsed rows | User clicks "Watch for it" (default) or "Where did you look?" | 0 | 0 |
| **S1-B** | The Blocked Reveal | Popover, 340×~440pt | ≥1 detected path returns `EPERM`/sandbox denial | "Let it read `~/.codex`" → `NSOpenPanel` | 1 (framed in $) | 1 (user-selected read, MAS only) |
| **S2** | The Atlas | Dashboard window, `.quota` route, 1100×720 | User clicks the hero card in S1b | User navigates or closes; no forced exit | 0 | 0 |
| **S3** | Arm the Alert | Sheet over Atlas, 420×360 | User clicks "Tell me at 80%" (present in S1b + S2) | Confirm → `UNUserNotificationCenter` request; Cancel → no-op | 1 (threshold value, pre-filled) | 1 (Notifications, *after* value) |
| **S4** | The Second Account | Inline strip in S2, 100% × 96pt | `SwitcherDiscoveryService` finds ≥2 identities for one provider | Click "Make this the drain target" or dismiss (sticky-dismissed) | 1 | 0 |
| **S5** | The Ledger Checklist | Popover footer strip, 340×72pt | Present from S1b until all 4 done or day 7 | Self-retires | 0 | 0 |
| **S6** | Day Three | Popover banner, 340×88pt | 3rd distinct launch-day OR first alert fired | User taps "Open the digest" or dismisses | 0 | 0 |

**Screens deliberately absent from first run:** provider pill wall (36), connection status page, 4-page tour, 12-card permissions wizard, 12-toggle chat-engine page, Hermes nested wizard, pet companion, analytics consent, indexing consent, memory consent, account sign-in, any paywall, any `LockedFeatureVeil` / `FeatureUnlockSheet`.

---

## 2. Act I — The Number

### S0 · Cold Boot

The app is a menu-bar accessory. **No window opens. Nothing steals focus.** The status item is installed in `applicationDidFinishLaunching` and immediately renders one of three states.

```
┌── macOS menu bar ─────────────────────────────────────────────┐
│                                     ⛏  38% · 2h14m   ⌘  🔋  │
│                                     └────┬────┘               │
│                                    the whole product          │
└───────────────────────────────────────────────────────────────┘

 state A  scanning (0.0–1.2s)     ⛏         AnimatedMiningPickView, no text
 state B  landed  (1.2s onward)   ◐ 38% · 2h14m
 state C  no quota, has cost      ◐ $4.12 today
 state D  nothing at all          ◐          brand mark, no text, tooltip only
```

- **What's on it:** a 12pt ring glyph tinted by pressure (`success` >40%, `amber` 15–40%, `ember` <15%) + the tightest remaining percent + the reset countdown, in `DesignSystem.Typography.monoTiny`.
- **The fix this encodes:** `MenuBarLabel.swift:80` currently forces `.labelStyle(.iconOnly)` and hides today's cost in `.help(balanceTooltip)`. The number the product is *named for* never renders. The new label renders text; the tooltip becomes the *secondary* channel ("Claude Code · weekly · 38% left · resets Thu 09:00").
- **Motion:** on transition A→B the ring draws clockwise from 12 o'clock over 0.45 s (`DesignSystem.Animation.gentle`), then the existing `logoBounceScale` 1.0→1.14→1.0 spring fires once. Countdown re-renders on a 60 s `TimelineView(.periodic)` — never a 1 Hz tick in the menu bar.
- **Exit condition:** none. This is the resting state of the product forever.

---

### S1a · The Reveal — scanning

At **T+1.2 s** the popover presents itself **exactly once in the app's lifetime** (`@AppStorage("firstRun.revealPresented")`). This replaces two focus steals (pet window + dashboard) with one, and it is a popover — it does not promote the app to a Dock-icon regular app, so it costs the user nothing to dismiss.

```
┌─ popover · 340pt ───────────────────────────────┐
│                                                 │
│                  ╭───────╮                      │
│                  │   ◍   │   MercuryCrest .large│
│                  ╰───────╯   + mercuryShimmer   │
│                                                 │
│         Reading what's already here.            │  serif, 20pt
│                                                 │
│   ▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱     │  1.5pt mercury hairline
│                                                 │
│   ● Claude Code    ~/.claude/projects           │  rows appear as
│   ● Codex          ~/.codex/sessions            │  detection resolves,
│   ○ Cursor Agent   scanning…                    │  0.06s stagger
│                                                 │
│   No account. No API key. Nothing left this Mac.│  tiny, textMuted
└─────────────────────────────────────────────────┘
```

**Exact copy**
- Headline: **"Reading what's already here."**
- Subhead: *(none — the row list is the subhead)*
- Footer: **"No account. No API key. Nothing left this Mac."**
- Row states: `●` resolved (`success`), `◐` parsing (`amber`), `○` queued (`textMuted`), `⨯` blocked (`ember`)

**Controls:** none. There is no button on this screen. It is not dismissible by button because it dismisses itself by *becoming* S1b.

**Motion beat:** the mercury hairline fills left→right at the true parse fraction (bytes-parsed / bytes-budgeted from the existing watermark governor), not a fake timer. Rows slide in `.move(edge: .bottom).combined(with: .opacity)` on `DesignSystem.Animation.gentle` with a 0.06 s stagger — the same cascade grammar the Editorial Observatory uses (`CascadeInModifier`, 0.04 s), slowed slightly because there are fewer elements. Respects `accessibilityReduceMotion`: rows paint synchronously, hairline snaps.

**Exit condition:** first provider row yields a displayable quota bucket **or** a non-zero cost row → morph to S1b. Hard timeout 8.0 s → S1-E or S1-B.

---

### S1b · The Reveal — landed  ← **THE AHA**

```
┌─ popover · 340pt ───────────────────────────────┐
│  YOUR TIGHTEST WINDOW              ·  live  ●   │  eyebrow 10pt heavy, tracking 1.8
│                                                 │
│      ╭─────────╮                                │
│      │   38%   │   Claude Code                  │  ring 68pt, remaining % 22pt mono
│      │  ▰▰▰▱▱  │   Max · weekly                 │  serif 18pt / caption
│      ╰─────────╯   resets in 2h 14m             │  mono, amber if <4h
│                                                 │
│   ─────────────────────────────────────────     │  mercury hairline
│                                                 │
│   Codex          ▰▰▰▰▰▰▰▱▱▱   71%   5h · 3h02m │
│   Cursor Agent   ▰▰▰▰▰▰▰▰�substantial  pool     │
│   Antigravity    ▰▰▱▱▱▱▱▱▱▱   19%   5h · 41m   │
│                                                 │
│   ─────────────────────────────────────────     │
│                                                 │
│   3 agents · 1,204 sessions · $312 this month   │  mono tiny, textSecondary
│                                                 │
│   [  Tell me at 80%  ]        See all windows → │
│                                                 │
│  ── S5 checklist strip mounts below ────────────│
└─────────────────────────────────────────────────┘
```

**Exact copy**
- Eyebrow: **"YOUR TIGHTEST WINDOW"** · right-aligned **"live ●"** (pulses once per successful refresh)
- Hero: `38%` / **"Claude Code"** / **"Max · weekly"** / **"resets in 2h 14m"**
- Meta strip: **"3 agents · 1,204 sessions · $312 this month"**
- Primary button: **"Tell me at 80%"**
- Secondary link: **"See all windows →"**

**Copy rules that are non-negotiable**
- Never say "Welcome to OpenBurnBar." The user did not install a greeting.
- Never say "estimated" where the fidelity is `.exact`; always say it where it is `.estimated` — render a `†` after the percent that expands to "Estimated from pacing — no official meter exists for this plan." This is the `docs/PROVIDERS.md` honesty contract rendered in the UI.
- Providers with no quota signal render `substantial` / `pool` / a dash — **never a fabricated percentage.** `QuotaRefreshActor` already refuses to fabricate; the UI must match.

**What happens on each control**
| Control | Action |
|---|---|
| Hero card (whole) | Opens dashboard at `.quota` (S2). First time this opens the dashboard window at all. |
| `Tell me at 80%` | Presents **S3** as a sheet *over the popover* (no window promotion). |
| `See all windows →` | Same as hero card. |
| Any provider row | Opens `.quota` scrolled + highlighted to that provider's card. |
| Esc / click-away | Dismisses. Sets `firstRun.revealDismissedAt`. **Does not set `hasOnboarded`.** Nothing is one-way here. |

**Motion beat (the money moment, 0.9 s total)**
1. `0.00 s` — the scanning crest cross-fades out; the hero ring is drawn as a `.trim(from:0,to:0)` stroke.
2. `0.00–0.55 s` — ring animates `to:` the true fraction on `ProTheme.Motion.posterSettle` (`spring(response:0.55, dampingFraction:0.78)`). It slightly overshoots and settles — the physical "gauge lands" feeling.
3. `0.18 s` — the percentage counts up 0→38 with a `monospacedDigit` transition, finishing at 0.55 s with the ring.
4. `0.55 s` — one `NSHapticFeedbackManager.perform(.alignment)`. **Exactly one haptic in the entire first run.**
5. `0.55–0.90 s` — the three secondary rows cascade in at 0.06 s stagger.
6. `0.90 s` — `mercuryShimmer` sweeps the hairline once (single pass, not the repeating variant) and stops.
- `accessibilityReduceMotion`: no ring animation, no count-up, no shimmer; the haptic still fires; rows paint at once.

**Exit condition:** dismissal by any means. There is no "Continue."

---

## 3. The empty state (this is where most first-run designs die)

### S1-E · The Empty Reveal

Fires when 8.0 s elapse with zero parsed rows **and** zero detected provider directories. It is not a dead end; it is the most reassuring screen in the product.

```
┌─ popover · 340pt ───────────────────────────────┐
│  NOTHING HERE YET                               │
│                                                 │
│              ╭──────────────╮                   │
│              │      ◍       │   crest, still,   │
│              ╰──────────────╯   no shimmer      │
│                                                 │
│      Nothing on this Mac has burned a           │  serif 20pt
│      token yet — and I looked in 32 places.     │
│                                                 │
│   ─────────────────────────────────────────     │
│                                                 │
│   The moment Claude Code, Codex or Cursor       │  caption
│   writes its first session file, this fills in  │
│   by itself. You don't have to come back.       │
│                                                 │
│   [   Watch for it   ]                          │  borderedProminent, ember
│                                                 │
│   Where did you look?     Try it with sample →  │  caption links
└─────────────────────────────────────────────────┘
```

**Exact copy**
- Eyebrow: **"NOTHING HERE YET"**
- Headline: **"Nothing on this Mac has burned a token yet — and I looked in 32 places."**  *(the count is `ParserRegistry.registeredParsers.count`, rendered live, never hardcoded — the same discipline as the website's `PROVIDERS_PRIMARY.length` build gate)*
- Body: **"The moment Claude Code, Codex or Cursor writes its first session file, this fills in by itself. You don't have to come back."**
- Primary: **"Watch for it"**
- Link 1: **"Where did you look?"**
- Link 2: **"Try it with sample data →"**

**Controls**
| Control | Action |
|---|---|
| `Watch for it` | Arms `UsageLogArrivalWatcher` — an `FSEvents` stream over the union of detected parser roots, coalesced at 2 s. Dismisses the popover. **When the first row ever lands, the menu-bar ring draws itself and a single local notification fires: "Codex just logged its first session. 5-hour window: 96% left."** That deferred aha is the whole point of this screen. Requires notification permission → asked *here*, framed: "So I can tell you the moment it starts." If declined, the ring still draws; no notification. |
| `Where did you look?` | Opens **S1-E-paths** (below). |
| `Try it with sample data →` | Loads a read-only, clearly-labelled demo dataset into the Atlas so a stranger can see the product's shape. Banner: **"SAMPLE DATA — not your Mac."** in `warning`, non-dismissible, with `[Clear sample]`. Writes to a separate in-memory store, never `token_usage`. |

**S1-E-paths — "Where did you look?"** (sheet, 420×520)

This is the single most reassuring screen in the product and it already exists in embryo as `OnboardingConnectView.swift:88`, which renders `provider.logDirectory`. Promote that pattern here.

```
┌─ sheet · 420pt ─────────────────────────────────────────┐
│  32 PARSERS · 0 HITS                             [ ✕ ]  │
│                                                         │
│  Every path I checked, and what I found.                │
│  ─────────────────────────────────────────────────────  │
│  ○  Claude Code    ~/.claude/projects/       no such dir │
│  ○  Codex          ~/.codex/sessions/        no such dir │
│  ○  Cursor Agent   ~/.cursor/agent/          no such dir │
│  ⨯  Factory Droid  ~/.factory/sessions/      permission  │
│  ○  Antigravity    ~/Library/.../antigravity no such dir │
│  …                                            (28 more) │
│  ─────────────────────────────────────────────────────  │
│  Logs somewhere else?   [ Add a folder… ]               │
└─────────────────────────────────────────────────────────┘
```

- Rows are `path` in `monoTiny`, right-aligned status. Grouped: **Blocked** first (actionable), then **Not found**, then **Found but empty**.
- `Add a folder…` → `NSOpenPanel` (user-selected read-only; works in both build flavors) → writes a custom parser root.
- **This fixes the real bug:** today a user whose logs live in a non-default location gets "Welcome to OpenBurnBar" forever with no clue a path setting exists.

**Empty-state copy the spec deletes:** `QuotaEmptyState.swift` currently tells a zero-log user to *"Connect a provider in Settings → Connections"* — pushing them toward the sign-in the product proudly avoids, and contradicting the two adjacent empty states. Rewrite to the same "nothing has burned a token yet / I looked in N places" sentence. **One empty state, one sentence, three surfaces.**

---

### S1-B · The Blocked Reveal (MAS build, and any TCC denial)

**This is the honest caveat.** `AgentLens/Resources/OpenBurnBar.entitlements` sets `app-sandbox = false`, so the direct-download build reads `~/.claude` with **zero prompts** — the promise holds perfectly. `OpenBurnBarMAS.entitlements` sets `app-sandbox = true` with only `files.user-selected.read-only`, so on the App Store build **the zero-permission read is structurally impossible.** Do not paper over it. Design for it:

- The MAS build still shows S1b for anything readable (`~/Library/Containers` co-located agents, plus anything previously bookmarked).
- Everything else falls to S1-B, and it is asked **after** the reveal, **one provider at a time**, **framed in dollars**:

```
┌─ popover · 340pt ───────────────────────────────┐
│  YOUR TIGHTEST WINDOW              ·  live  ●   │
│      ╭─────────╮                                │
│      │   38%   │   Claude Code                  │   ← real value still shown
│      ╰─────────╯   Max · weekly · 2h 14m        │
│   ─────────────────────────────────────────     │
│   ⨯  Two more agents are behind a door.         │  ember dot
│                                                 │
│   Codex has 411 sessions in ~/.codex I can't    │  caption
│   open yet. Letting me read that folder adds    │
│   an estimated $180 to this month's picture.    │
│                                                 │
│   [ Let it read ~/.codex ]        Not now       │
└─────────────────────────────────────────────────┘
```

- **"Let it read ~/.codex"** → `NSOpenPanel` pre-navigated to the folder, `canChooseDirectories`, single grant, security-scoped bookmark persisted. One panel per provider, never batched, never before the number.
- **"Not now"** is a plain text button and is fully reversible from the Atlas' provider row forever.
- The **$180 estimate** is derived from `bytes-on-disk × observed $/byte for that parser` — an honest order-of-magnitude, labelled "estimated," never presented as fact.

---

## 4. Act II — Earned depth (same session, only if the user reaches)

### S2 · The Atlas — first visit to the quota workspace

The first time the dashboard window opens at all. It opens **directly on `.quota`**, never on `.overview`. The overview is a *destination behind the glance*, not the front door.

```
┌─ dashboard window · 1100×720 ───────────────────────────────────────────────┐
│ ⌘K                                                    [Rescan]  [Settings]  │
├──────────┬──────────────────────────────────────────────────────────────────┤
│ Quota  ● │  THE RESET ATLAS                          Sorted by urgency  ▾   │
│ Overview │  ──────────────────────────────────────────────────────────────  │
│ Sessions │                                                                  │
│ ·        │    now      +1h      +2h      +4h      +8h      +24h     +7d    │
│ ·        │    │─────────┼────────┼────────┼────────┼─────────┼────────│     │
│ (day 3+  │  Antigravity ◆41m                                               │
│  routes  │  Claude 5h        ◆1h58m                                        │
│  hidden) │  Codex 5h              ◆3h02m                                   │
│          │  Claude weekly                              ◆Thu 09:00          │
│          │  Cursor pool                                        ◆Sep 1      │
│          │  ──────────────────────────────────────────────────────────────  │
│          │  ┌────────────────┐ ┌────────────────┐ ┌────────────────┐        │
│          │  │ ◐ Claude Code  │ │ ◐ Codex        │ │ ◐ Cursor Agent │        │
│          │  │   38% weekly   │ │   71% · 5h     │ │   pool · 62%   │        │
│          │  │   alberto@…    │ │   alberto@…    │ │   team seat    │        │
│          │  │ [Tell me @80%] │ │ [Tell me @80%] │ │ [Tell me @80%] │        │
│          │  └────────────────┘ └────────────────┘ └────────────────┘        │
│          │  ── S4 second-account strip mounts here when discovered ───────  │
└──────────┴──────────────────────────────────────────────────────────────────┘
```

- **Headline:** **"THE RESET ATLAS"** · subhead **"Four vendors, one clock. Nobody else will draw you this."**
- The horizontal timeline is the copy-proof differentiator: a Claude 5-hour bucket, a Claude weekly bucket, a Codex 5-hour bucket and a Cursor pool on **one time axis**. That picture is commercially forbidden to every incumbent.
- **Sidebar on day one contains exactly three routes:** Quota, Overview, Sessions. Not eleven. Not a Control Deck. `⌘1–⌘3` only; `⌘4–⌘8` and `⌘0` are unbound until day three.
- **Motion:** diamonds settle onto the axis with `posterSettle`, 0.05 s stagger left→right, so the eye reads soonest-first. Cards cascade after.
- **Exit:** none forced. Closing the window returns to the menu bar.

---

### S3 · Arm the Alert — *the first decision the app ever asks for*

```
┌─ sheet · 420×360 ───────────────────────────────────────┐
│                                                         │
│              ╭──────╮                                   │
│              │  ◍   │       MercuryCrest .medium        │
│              ╰──────╯                                   │
│                                                         │
│        Get warned before the wall.                      │  serif 22pt
│                                                         │
│   No vendor can send you this alert, because no vendor  │  caption, textSecondary
│   can see the other three.                              │
│                                                         │
│   ─────────────────────────────────────────────────     │
│                                                         │
│   Warn me when any window drops below                   │
│                                                         │
│        ◀   ▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▱▱▱▱▱   20%   ▶            │  slider, snaps 5/10/15/20/30
│                                                         │
│   Preview:  "Claude weekly at 19%. Codex 5h at 71%."    │  live, real numbers
│                                                         │
│   ─────────────────────────────────────────────────     │
│                                                         │
│   [   Turn it on   ]                    Not now         │
│                                                         │
│   Needs permission to post notifications. Nothing else. │  tiny, textMuted
└─────────────────────────────────────────────────────────┘
```

**Exact copy**
- Headline: **"Get warned before the wall."**
- Subhead: **"No vendor can send you this alert, because no vendor can see the other three."**
- Label: **"Warn me when any window drops below"** — default **20%**, snap stops 5/10/15/20/30
- Live preview line built from the user's *actual* current buckets — this is the proof the alert is real
- Primary: **"Turn it on"** · Quiet: **"Not now"**
- Footer disclosure: **"Needs permission to post notifications. Nothing else."**

**On "Turn it on":** writes the threshold, **then** calls `UNUserNotificationCenter.requestAuthorization(options:[.alert,.sound])`. If the user denies at the OS prompt, the threshold persists and the alert renders as an in-app badge on the menu-bar ring instead — the feature degrades, it does not fail. Sheet dismisses with a checkmark morph on the button (0.3 s, `snappy`).

**On "Not now":** nothing is written, nothing is asked, the button in S1b/S2 stays available forever.

---

### S4 · The Second Account — the switcher, de-wizarded

The existing `SwitcherOnboardingWizardView` (3 steps, 520×620, its own `hasSwitcherOnboarded` flag, three entry points) is **deleted as a standalone flow** and folded into a strip that appears only when `SwitcherDiscoveryService` has actually found a second identity — i.e. only for the user it helps.

```
┌─ inline strip in S2 · full width × 96pt ────────────────────────────────┐
│  ◆  Two Claude accounts on this Mac.                                    │
│                                                                         │
│     alberto@…  (active, 38% left)    →    a.nunez@…  (untouched)        │
│                                                                         │
│     When the first one drains, one click moves Claude Code to the       │
│     second. Nothing logs out.                                           │
│                                                                         │
│     [ Make a.nunez@… the drain target ]              Not now  ·  Hide   │
└─────────────────────────────────────────────────────────────────────────┘
```

- **Headline:** **"Two Claude accounts on this Mac."**
- **Body:** **"When the first one drains, one click moves Claude Code to the second. Nothing logs out."**
- **Primary:** **"Make a.nunez@… the drain target"** → writes the drain target via `SwitcherProfileStore`, strip morphs into a one-line confirmation with an `Undo`.
- **`Hide`** is sticky (never shown again for this pair). **`Not now`** is per-session.
- **Motion:** the two identity chips are connected by an arrow that draws left→right once on appear (0.4 s, `gentle`). On confirm, the arrow reverses and the target chip takes the `success` ring.

---

### S5 · The Ledger Checklist — the only persistent nag, and it's four items

Mounts in the popover footer from S1b until complete or day 7. Collapsed to a single 24pt row showing `▰▰▱▱ 2 of 4`; expands on hover.

```
┌─ popover footer · 340×72 ───────────────────────┐
│  ▰▰▱▱   2 of 4                              ⌃  │
├─────────────────────────────────────────────────┤   (expanded)
│  ✓  See a real number                           │
│  ✓  Connect a second agent                      │
│  ○  Set a warning threshold          Set it →   │
│  ○  Let it tell you                  Allow →    │
└─────────────────────────────────────────────────┘
```

Item 4 ("Let it tell you") is the notification grant, and it is the **last** item — after three proofs of value. This is the four-item checklist the product brief asked for, with one instrumented activation event behind item 1.

---

### S6 · Day Three — the second act opens

Fires on the 3rd **distinct launch-day** or immediately after the first threshold alert fires, whichever is sooner. One banner, once.

```
┌─ popover banner · 340×88 ───────────────────────┐
│  ────── mercury hairline, one shimmer pass ──── │
│  THREE DAYS IN                                  │
│  You've burned $94 across 3 agents. There's     │
│  a pattern in it now.                           │
│  [ Show me the week ]                 Dismiss   │
└─────────────────────────────────────────────────┘
```

Tapping unbinds the day-three feature set (§5). This is the *only* place BurnBar ever uses `FoilCTAButton` in the first week, and only if the Cloud whisper variant is shown — see §5.

---

## 5. Progressive disclosure — exactly what exists when

| Day one (visible from S1b) | Day three (unlocked by S6) | Behind "Advanced" forever |
|---|---|---|
| Menu-bar percent + reset clock | Daily digest + delivery hour | Model-proxy gateway (`127.0.0.1:8317`) |
| Tightest-window hero card | AI Inbox (deterministic detectors only, one ranked list) | Five-dimensional provider router |
| Reset Atlas (quota workspace) | Overview lane + **3** charts (burn-over-time, provider mix, cache savings) | One-click routed-client wiring (9 CLIs) |
| Per-provider quota cards | Session logs browser + search | Chat workspace (all 12 backends, all 4 presentations) |
| Path audit sheet ("Where did you look?") | Projects lane | Elder Wand / The Wand |
| Manual rescan | Cloud whisper strip (first paywall contact **ever**) | Agent Control (Computer Use) |
| Pre-limit threshold (S3) | `⌘4–⌘8`, `⌘0`, Control Deck | Mercury / Floo |
| Account switch (S4, only if discovered) | Billing-API reconciliation *badge* on the number | Smart displays, pixel clock, text expansion, pet |
| Settings: **5** panes | Settings: unchanged 5 panes | Database workspace, MCP, CLI, missions, WebGL kernels, **the legacy 7-step wizard (renamed "Advanced setup")** |

**Rules that make this real, not aspirational**
1. **The gate is a single computed property**, not scattered `#if`s: `FirstRunStage.current` ∈ `{ .dayOne, .dayThree, .established }`, derived from `firstRun.distinctLaunchDays` + `firstRun.alertFiredCount`. Every route list, keyboard binding and Settings manifest filter reads it. One source of truth.
2. **No paywall surface renders before day three.** `LockedFeatureVeil`, `FeatureLockedVeil`, `FeatureUnlockSheet`, `TierLockBadge`, `FoilCTAButton` are all forbidden in `.dayOne` — enforced by a unit test that asserts the day-one view tree contains none of them.
3. **Advanced is one door, not seventeen.** Settings → *Advanced* → a single list. The Settings Copilot and the settings search engine are deleted; a 5-pane surface does not need a search engine, and shipping both was a confession.

---

## 6. Permission sequencing — the ladder

**Nothing is asked before the number. Nothing is batched. Every ask names the value it buys, in the user's own units.**

| Order | Permission | Earliest possible moment | Earned-value justification (the literal frame) | Degrade if denied |
|---|---|---|---|---|
| — | *(none)* | S0 → S1b | Reading `~/.claude` etc. needs **zero** permissions on the Developer-ID build (sandbox off). This is the whole advantage. | n/a |
| 1 | **User-selected read** (`NSOpenPanel`) — **MAS build only**, or any `EPERM` | S1-B, *after* the reveal, one provider at a time | "Codex has 411 sessions in `~/.codex` I can't open yet. Letting me read that folder adds an estimated **$180** to this month's picture." | That provider shows `blocked`; everything else works. Reversible from its card forever. |
| 2 | **Notifications** | S3 confirm, or S1-E "Watch for it" | "So I can tell you before the wall." / "So I can tell you the moment it starts." | Threshold still fires as an in-app menu-bar badge. |
| 3 | **Full Disk Access** | Only when a parser root sits under a TCC-protected root *and* the user clicked that provider | "macOS is holding `~/Library/…/Antigravity` shut. One toggle in System Settings and I can count it." Deep-links via `x-apple.systempreferences:` | Provider stays blocked, named honestly in the path audit. |
| 4 | **Accessibility / Input Monitoring** | Never in onboarding. Only on first use of text expansion, from Advanced. | *(feature-local)* | Feature off. |
| 5 | **Microphone, Camera, Screen Recording, Remote Desktop, Locked-Screen Input, Automation ×5** | **Removed from onboarding entirely.** Reachable only from Advanced → Agent Control / Floo, each asked at the moment of use. | *(feature-local)* | Feature off. |
| 6 | **Indexing consent** | Never a modal. Becomes a row in Settings → Privacy, default **off**, plus one inline prompt the first time the user types in search: "Search needs a local index of your transcripts. Build it? Nothing leaves this Mac." | Search returns filename matches only. |
| 7 | **Analytics consent** | Day three, one quiet inline card in Settings → Privacy. Never a sheet, never on launch. | Nothing collected (tri-state already treats unset ≡ declined). |
| 8 | **Memory consent** | Day three+, at first memory extraction, in-context. | No extraction. |

**Deleted from first run: 12 sequential TCC prompts, 3 chained modal sheets, 1 global hotkey grant.** Net OS prompts before the aha: **zero** on Developer-ID, **zero** on MAS (the panel comes after).

---

## 7. The aha moment, defined precisely

> **The aha is the instant a user reads a *remaining-percentage and a reset clock* for a paid plan window, next to at least one *other vendor's* window, in a single visual field, without having given the app anything.**

It is **not** "sees a dollar total" (that ships in `/usage` and in ccusage, free, 421k downloads/month). It is **not** "completes onboarding." It is the cross-vendor headroom picture, which is structurally forbidden to Anthropic, OpenAI and Cursor.

### Instrumentation that proves it

Four new cases in `OpenBurnBarCore/Sources/OpenBurnBarAnalytics/AnalyticsEvent.swift` (Tier 2, macOS-first, taxonomy-doc updated in the same PR):

| Event | Wire name | Properties | Fires when |
|---|---|---|---|
| `firstRunRevealPresented` | `firstrun.reveal.presented` | `ms_since_launch`, `variant` ∈ `landed \| empty \| blocked`, `detected_provider_count` | Popover auto-presents |
| **`firstRunAhaReached`** | **`firstrun.aha.reached`** | `ms_since_launch`, `providers_with_real_quota`, `distinct_vendors_visible`, `tightest_remaining_bucket`, `fidelity` ∈ `exact \| estimated`, `dwell_ms` | **All four conditions true simultaneously** (below) |
| `firstRunRevealDismissed` | `firstrun.reveal.dismissed` | `reason` ∈ `esc \| clickaway \| navigated \| idle`, `dwell_ms`, `aha_reached` | Popover closes |
| `firstRunChecklistAdvanced` | `firstrun.checklist.advanced` | `item` ∈ `number \| second_agent \| threshold \| notify`, `day_index` | Any checklist item completes |

**`firstrun.aha.reached` predicate — all four must hold:**
1. `providers_with_real_quota >= 1` — at least one **displayable** bucket with a non-nil `remainingPercent` (never a fabricated one).
2. `distinct_vendors_visible >= 2` — the cross-vendor claim is literally on screen. *(If only one vendor exists on the Mac, a `single_vendor: true` flag is set and the event still fires — that user can't be shown the moat, but they did get the number.)*
3. `dwell_ms >= 1200` — the popover stayed open long enough to be read, not flashed.
4. `ms_since_launch <= 30000` — the contractual budget. Values over 30 s are recorded and alarm in the dashboard.

**The activation metric, stated once, so it can be argued about:**
> **A1 = % of first launches emitting `firstrun.aha.reached` with `ms_since_launch < 30000`.** Ship target **≥ 85%** of Macs with ≥1 detected agent. Anything below 85% is a bug in the parse budget, not a copy problem.
> **A2 (day-7 retention proxy) = % of A1 users who also emit `firstrun.checklist.advanced{item:threshold}` within 7 days.** Target **≥ 40%** — this is the "will they pay for the interrupt" leading indicator.

`AnalyticsConsentStore` already treats unset ≡ declined, so **none of this leaves the Mac by default.** All four events are also written to a local `first_run_events` table so the funnel is inspectable in the Database workspace by the one person who cares (and by QA) with analytics fully off. That is the honest way to instrument a no-telemetry product.

---

## 8. Swift file manifest

### Create

| Path | Purpose |
|---|---|
| `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/TightestQuotaWindow.swift` | Pure, cross-platform derivation: `TightestQuotaWindow.tightest(across: [ProviderQuotaSnapshot], asOf: Date) -> TightestQuotaWindow?`. Reuses the existing `displayableQuotaBuckets(relativeTo:)` / `remainingPercent` / `resetsAt` primitives from `ProviderQuotaDisplayExtensions.swift` — min remaining %, tie-break earliest `resetsAt`. Feeds the menu bar, the hero card, the iOS Live Activity and the widget snapshot from **one** implementation. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunRevealModel.swift` | `@MainActor @Observable` state machine: `.scanning(fraction:) → .landed(TightestQuotaWindow, [ProviderQuotaSnapshot]) \| .empty(searchedPaths:) \| .blocked([BlockedRoot])`. Injected dependencies, zero SwiftUI — mirrors the `HermesSetupWizardController` pattern so it is unit-testable without a snapshot harness. Owns the 8.0 s degrade timer and the aha predicate. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunReveal.swift` | S1a / S1b / S1-B popover root. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunTightestWindowCard.swift` | The hero ring + count-up + `posterSettle` beat. Reused verbatim in S2. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunEmptyReveal.swift` | S1-E. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunPathAuditSheet.swift` | "Where did you look?" — promotes `OnboardingConnectView`'s path-listing pattern to a first-class surface. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunAlertArmSheet.swift` | S3, including the live real-numbers preview line. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunSecondAccountStrip.swift` | S4. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunChecklistStrip.swift` | S5. |
| `AgentLens/Views/Onboarding/FirstRun/FirstRunDayThreeBanner.swift` | S6. |
| `AgentLens/Views/Quota/ResetAtlasTimeline.swift` | The horizontal multi-vendor reset axis — the copy-proof screen. |
| `AgentLens/Services/FirstRun/FirstRunStage.swift` | The single `.dayOne / .dayThree / .established` gate every route list, key binding and Settings filter reads. |
| `AgentLens/Services/FirstRun/FirstRunActivationRecorder.swift` | Emits the four events; writes the local `first_run_events` mirror. |
| `AgentLens/Services/FirstRun/UsageLogArrivalWatcher.swift` | `FSEvents` watcher backing S1-E's "Watch for it." |
| `AgentLens/Services/FirstRun/FirstRunPermissionLadder.swift` | Owns ordering + the value-framed copy for each ask; refuses to present rung *n* before rung *n−1*'s value moment has been recorded. |
| `AgentLensTests/Active/FirstRunRevealModelTests.swift` | State machine, 8 s degrade, aha predicate (all 4 conditions, plus each negative). |
| `AgentLensTests/Active/FirstRunPermissionLadderTests.swift` | Asserts no permission can be requested before its value moment. |
| `AgentLensTests/Active/FirstRunDayOneSurfaceTests.swift` | Asserts the day-one view tree contains **zero** `FoilCTAButton` / `TierLockBadge` / `FeatureUnlockSheet` / `LockedFeatureVeil` instances, and exactly 3 sidebar routes. |
| `OpenBurnBarCore/Tests/OpenBurnBarKernelTests/TightestQuotaWindowTests.swift` | Min-selection, tie-break, `nil`-percent exclusion, elapsed-window reconciliation, `.estimated` flagging. |

### Modify

| Path | Change |
|---|---|
| `AgentLens/App/MenuBarLabel.swift` | Render `TightestQuotaWindow` as text (drop `.labelStyle(.iconOnly)`); pressure-tinted ring; 60 s `TimelineView` countdown; cost fallback; tooltip demoted to secondary detail. |
| `AgentLens/App/AgentLensApp+LiveServices.swift` | **The single highest-leverage edit.** Hoist `aggregator.refreshAll()` out of the `for _ in 0..<30 where !isSignedIn` sign-in poll + 15 s sleep (lines ~294-305) into an immediate `Task(priority:.userInitiated)` at launch. Leave `sync.uploadPending()` behind the poll where it belongs. Delete the `PetOnboardingWindowPresenter.openIfNeeded` call. Delete the unconditional `windowManager.openDashboard` on first launch. |
| `AgentLens/App/AppDelegate+StatusItem.swift` | One-shot auto-present of the popover at T+1.2 s, guarded by `firstRun.revealPresented`. |
| `AgentLens/App/OpenBurnBarWindowManager.swift` | Dashboard opens on demand only; first open lands on `.quota`, not `.overview`; no `NSApp.setActivationPolicy(.regular)` promotion during first run. |
| `AgentLens/Views/Popover/MenuBarPopoverView.swift` | Drop `&& dataStore.totalUsageSessionCount == 0` from the line-163 gate (the one-way door). Route to `FirstRunReveal` on `!firstRun.revealDismissed`. Collapse 6 drag-resizable tray sections to **2** (tightest window, quick switch) — retires the `hasResetScrambledPopoverLayoutV2` migration's whole problem class. |
| `AgentLens/Views/Popover/OnboardingView.swift` | **Delete.** Its inverted button hierarchy ("Got it" prominent = irreversible skip; "Get Started" as caption text) is replaced wholesale. |
| `AgentLens/Views/Dashboard/DashboardView.swift` | Remove all three `.onAppear` consent modals (indexing / analytics / memory) and the chain guard at ~932-942. Rewrite `overviewEmptyState` (~1306-1353) to the single shared empty sentence + path audit link, deleting "Welcome to OpenBurnBar." Keep `autoExpandTimeRangeIfNeeded()` — it is correct. |
| `AgentLens/Views/Quota/QuotaEmptyState.swift` | Replace "Connect a provider in Settings → Connections" with the shared "nothing has burned a token yet — I looked in N places" copy + `Where did you look?`. |
| `AgentLens/Views/Onboarding/OnboardingWizardView.swift` | Demote to **Advanced setup**, reachable only from Settings → Advanced. Drop the `.tour` and `.chatEngine` steps entirely. Keep `.providers`/`.connect`/`.scan` for power users who want explicit control. |
| `AgentLens/Views/Settings/GeneralSettingsView.swift` | Pass the real `aggregator` at ~line 227 — the re-entry path currently passes `nil`, so `OnboardingScanView` hangs on "Scanning…" forever. |
| `AgentLens/PetCompanion/Onboarding/PetOnboardingWindowPresenter.swift` | Gate `openIfNeeded` on `PetCompanionFeature.isEnabled` (the gate `showCompanion()` already uses), not on the bare `pet.firstRunCompleted` default. |
| `OpenBurnBarCore/Sources/OpenBurnBarAnalytics/AnalyticsEvent.swift` | Add the four `firstrun.*` cases + their `AnalyticsCategory` mappings. |
| `AgentLens/Views/Onboarding/AnalyticsConsentPromptView.swift` | Re-target from launch modal to a day-three inline Settings card. |
| `AgentLens/Views/Onboarding/Switcher/SwitcherOnboardingWizardView.swift` | Delete the standalone wizard + `hasSwitcherOnboarded`; its content becomes `FirstRunSecondAccountStrip`. |
| `AgentLens/Views/Onboarding/OnboardingTourView.swift`, `OnboardingChatEngineView.swift`, `OnboardingSystemPermissionsView.swift` | Removed from the wizard step enum. `OnboardingSystemPermissionsView` survives as the Advanced → Agent Control setup page; the other two are deleted. |

---

## 9. Design-language contract (what we reuse, and what we deliberately don't)

| Element | Source | Where used in first run |
|---|---|---|
| Warm Charcoal / Botanical Cream palette | `DESIGN.md` §Color, `DesignSystem.Colors` | Every ground. First run is **utilitarian**, not obsidian. |
| `MercuryCrest(size:.large)` + `mercuryShimmer` | `Views/Components/Pro/MercuryCrest.swift` | S1a crest, S3 crest. **Two instances total.** |
| Editorial Observatory voice (eyebrow + serif headline + mono meta strip + mercury hairline) | 2026-05-13 decision, `IntelligenceBriefScreen` | S1b, S1-E, S2, S6 |
| `ProTheme.Typography.titleSerif` / `headlineSerif` | `Theme/ProTheme.swift` | All first-run headlines |
| `ProTheme.Motion.posterSettle` | `Theme/ProTheme.swift` | The ring landing (the aha beat) |
| `DesignSystem.Animation.gentle / standard / snappy` | `DesignSystem.swift` | Cascades, sheets, button feedback |
| `AnimatedMiningPickView` | existing | S0 state A, S1a |
| `ProviderLogoView`, `ProviderQuotaIdentityOrb`, `ProviderTheme` | existing | Every provider row |
| `GlassCard` | existing | Provider cards in S2 |
| `NSHapticFeedbackManager.perform(.alignment)` | as in `FoilCTAButton` | Exactly once, at ring-settle |
| **`FoilCTAButton`** | `Views/Components/Pro/FoilCTAButton.swift` | **Never in Act I.** First appearance is S6's Cloud whisper on day three. Foil means *money*; using it on a free number would teach the user the wrong grammar. |
| **`LockedFeatureVeil` / `FeatureLockedVeil` / `FeatureUnlockSheet` / `TierLockBadge` / `TierCrestHero` / `TierHolographicCrestAccent`** | `Pro/` | **Never in first run.** No day-one surface is gated, so no gate art exists. Enforced by `FirstRunDayOneSurfaceTests`. |
| `ProTheme.Palette.obsidian` | `ProTheme.swift` | Not used. Obsidian is the paid island; the free product stays on warm charcoal. |

**Accessibility contract:** every motion beat gates on `accessibilityReduceMotion`; the hero card is one `accessibilityElement(children:.combine)` reading *"Tightest window. Claude Code, Max weekly plan, 38 percent remaining, resets in 2 hours 14 minutes."*; the ring is `accessibilityHidden` because the label carries the value; Dynamic Type clamped to `.xxLarge` in the 340pt popover; VoiceOver traversal order is hero → rows → meta → primary → secondary, asserted in test.

---

## 10. The five deletions that make this possible

Ranked by damage currently done:

1. **`PetOnboardingWindowPresenter.openIfNeeded`** — one line. A spend tracker's first sentence is currently *"choose your companion"* plus a global-hotkey grant, `activate(ignoringOtherApps:true)`, ~1 s after launch, gated only on `pet.firstRunCompleted` rather than on whether the pet feature is even on.
2. **The 45-second scan delay** — `for _ in 0..<30 where !accountManager.isSignedIn { sleep(1s) }` + a further 15 s, in front of `refreshAll()`. A signed-out stranger never satisfies the poll. The scan was never meant to be behind it; it inherited the task from `sync.uploadPending()`.
3. **The three chained consent modals** — indexing, analytics, memory, stacked before a single number is on screen. Deferred, unbundled, re-framed.
4. **The one-way door** — `MenuBarPopoverView.swift:163` hides the designed onboarding forever the moment the scan finds anything, and its only other entry (`GeneralSettingsView.swift:227`) passes `aggregator: nil` and hangs. The designed onboarding is currently both undiscoverable and broken on its fallback.
5. **The inverted button hierarchy** — `OnboardingView.swift:53-73`, where the prominent tinted button is the irreversible skip.

---

## 11. Ship gates

- `A1 ≥ 85%` on a 20-Mac internal fleet before the flag flips for direct-download.
- `TightestQuotaWindowTests` green on macOS **and** in `OpenBurnBarKernelTests` (shared kernel, so iOS Live Activity and the widget inherit the same number — no drift).
- `FirstRunDayOneSurfaceTests` proves zero paywall art and exactly 3 routes on day one.
- `FirstRunPermissionLadderTests` proves no OS prompt can be issued before its value moment is recorded.
- A manual MAS-build pass confirming S1-B renders honestly rather than claiming a zero-permission read the sandbox forbids.
- One clean-Mac video: launch → number, timestamped, under 30 s, with `screencapture` proving no prompt appeared.
