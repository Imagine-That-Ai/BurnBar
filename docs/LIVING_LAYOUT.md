# The living layout

How every BurnBar surface decides what to do with the space it is given, on all
six platforms.

This is a **principles** contract, not a component library. macOS, iOS, iPadOS,
Android, Windows, and Linux each express it with their own native layout and
animation systems. What they share is the reasoning and the numbers — which is
what makes them one product rather than six ports of one screenshot.

Companion documents: [`docs/MAC_DASHBOARD_LAYOUTS.md`](MAC_DASHBOARD_LAYOUTS.md)
is the per-layout thesis table and its enforced rules; this document is how any
of those theses gets rendered into a real window.

---

## 1. The problem this exists to solve

A Home surface on a 1900×950 window with three short cards in the top-left
corner and everything else blank. Three independent causes, and fixing any one
alone makes the result worse rather than better:

| Cause | Shape it takes | Why the obvious fix fails |
|---|---|---|
| **Vertical** | A scroll container top-anchors its content. Short content leaves the bottom 40% blank — not scrollable, not filled, absent. | Adding a trailing spacer or stretching the last card fills the hole with *air wearing a card's clothes*. |
| **Horizontal** | A reading-width cap (`maxWidth: 820`) applied to the **composition**, parking one narrow column mid-canvas. | Removing the cap gives a 1900pt line of body text, which is unreadable. |
| **Density** | A hard `prefix(6)` truncating a list regardless of available room. | Fixing vertical and horizontal first just makes a *bigger* hole, because there is nothing real to put in it. |

Density is the one that matters most and gets noticed least. **Space must be
filled with more of the truth**, and only what is left after that becomes
breathing room.

---

## 2. Fit, Feed, Breathe

The resolution order. The order *is* the design.

### Fit — does everything clear its floor?

Every region declares a **floor**: the height below which it is not worth
rendering. Sum the floors plus the gutters.

- **Fits** → continue to Feed.
- **Does not fit** → the surface scrolls, and every region hugs its content.

Ambient furniture (an activity ribbon, a decorative strip) may be withheld here
to make content fit. **Content is never withheld.** A short window makes a
surface scroll; it does not make an inbox item disappear, because then the
surface is lying about what is waiting.

### Feed — spend the slack on real rows

Regions that render lists declare a **row appetite**: how many rows the data
actually has, how many to show before any slack is spent, what one row costs,
and a ceiling past which the list stops being a glance and becomes a different
screen.

Slack buys rows **round-robin in priority order** — one row each per lap. Not
first-come: a twelve-row ladder must not swallow the budget before a two-row
ladder beside it is granted a single line.

Two hard rules:

- **Never invent filler.** A region can only be fed rows that exist in the data.
  "Fill the space" must never become "fabricate content".
- **Respect the ceiling.** Past some count a list should send the user to the
  full surface rather than printing 400 rows on a dashboard.

### Breathe — what is left becomes space

Only now. Remaining slack is distributed to regions that declared a **stretch**
weight. If nothing declared one, it is spread in proportion to each region's
ideal height, so the composition scales up while preserving the relative weights
the designer chose.

**The invariant:** resolved heights plus gutters account for every point of the
canvas. Any shortfall is a visible hole.

---

## 3. Width is not one number

A **reading measure** is a property of a paragraph. A **composition width** is a
property of a page. Conflating them is what strands a narrow column in the middle
of a wide window.

- The container spans the canvas.
- **Prose inside it** is held to a comfortable line length — roughly 620pt for
  display faces (a large face fits *fewer* characters per comfortable line, not
  more), 680pt for body, 760pt for editorial serif.
- Past a breakpoint the composition **reflows into columns** rather than
  capping. Two columns once each can still hold a comfortable line plus the
  gutter; three when there is genuinely room.
- Column thresholds carry **hysteresis**. A window drag parked on a threshold
  reports sub-pixel changes, and a hard cutoff makes the composition flicker
  between one and two columns every frame. Hold the current count inside a dead
  band on either side.
- A region may **span** the full width above the column area when its rule
  demands it — a command field that must be "first and largest", an instrument
  row, a header whose figures are meant to be read against each other. A
  spanning band is **rigid**: slack belongs to the columns below, because
  stretching a header band is the air-wearing-a-card's-clothes move again.

---

## 4. Motion

The vocabulary is small on purpose, and each entry names a **job**, not a curve.
"Use `settle` when a region resizes" is a rule a reviewer can enforce; "use a
0.42 spring" is a number someone will nudge.

| Token | Job |
|---|---|
| `settle` | A region changing size or position — the layout itself moving. |
| `arrive` | Content entering, staggered when it arrives as a group. |
| `depart` | Content leaving. Faster than it arrived. |
| `tick` | A value changing inside a frame that is not moving. |
| `pulse` | An ambient heartbeat proving the system is live. |

The numbers live in **`packages/design-tokens/tokens/pensieve.tokens.json`**
under `motion`, and generate to Swift, Kotlin, C#, WinUI XAML, and CSS. Raw
numbers rather than platform animation objects, for the same reason the colour
tokens are hex strings: a number crosses a language boundary and a
`SwiftUI.Animation` does not.

```
settleResponseMs 420   settleDamping 0.88     arriveResponseMs 340
arriveDamping 0.80     arriveRisePx 18        arriveScale 0.97
departMs 160           departScale 0.98       staggerStepMs 60
staggerCapMs 240       tickMs 300             pulsePeriodMs 1400
pulseFloor 0.55        reducedMs 180
easeSettle  cubic-bezier(0.22, 1, 0.36, 1)
easeArrive  cubic-bezier(0.34, 1.32, 0.44, 1)
```

Notes that are easy to get wrong:

- **`settle` is damped harder than `arrive`.** Overshoot on a *value* reads as
  life; overshoot on a *layout edge* reads as wobble, because the eye tracks a
  plate's edge far more precisely than the middle of a number.
- **`depart` is faster than `arrive`.** Arriving content is news and earns a
  beat; departing content is a decision already made and should get out of the
  way.
- **Arrival rises a fixed distance** (18pt), not "off the top edge". Edge-based
  slides travel the view's own height, so a chip and a 400pt card in one list
  arrive at visibly different speeds.
- **Stagger cannot live in a transition.** A transition describes shape; only an
  animation carries a delay. Pair the two at the call site.
- **Springs are canonical; the beziers are the web/WinUI approximation.** Use the
  spring form wherever the platform has real springs (SwiftUI, Compose).

### Reduce Motion is a different vocabulary, not a dimmer

Springs become fades. Stagger becomes simultaneous. Repeating ambient animation
does not run at all — it has no honest reduced form. Every helper must carry that
branch itself, so honouring the setting is the default rather than something each
call site has to remember.

---

## 5. Living data

Motion has to be *earned by the system*, not decorative. A surface should move
because something underneath it moved.

- Values transition rather than snap (`tick` + a numeric content transition).
- Rows arriving animate in; neighbours reclaim the space of rows leaving by
  being in the same animated stack, not by anyone computing an offset.
- Ambient signals stay shallow. A heartbeat that swings hard stops being ambient
  and becomes an alert — and then a real alert has nowhere louder to go.

**Check the cadence before designing the motion.** A dashboard cannot feel alive
if the data behind it updates every ten minutes, and no amount of easing fixes
that. Know the real update rate of every stream you are animating.

---

## 6. Per-platform expression

Same reasoning, native execution. Do not port another platform's widget tree.

| Platform | Expression |
|---|---|
| **macOS** | `LivingSpaceBudget` (pure solver, in `OpenBurnBarUI` so iOS shares it) + `HomeLivingLayout` (renderer). `MotionTokens` in `OpenBurnBarUI`. Reference implementation. |
| **iOS / iPadOS** | SwiftUI. Same `MotionTokens`. Size classes and `NavigationSplitView` for iPad multi-pane; compact is touch-first and dense without cramping. |
| **Android** | Jetpack Compose. `PensieveTokens.kt` motion values into `spring(dampingRatio:stiffness:)`, `animateContentSize`, `AnimatedVisibility`, `LookaheadScope` for continuous reflow. `WindowSizeClass` for breakpoints. |
| **Windows** | WinUI 3 / Windows App SDK. `PensieveTokens.cs` + `Tokens.xaml`. Grid with star rows that actually receive a height, `ItemsRepeater` over hand-built stacks, composition animations. |
| **Linux** | Tauri 2 + React 19. CSS custom properties `--motion-*`, CSS grid with `minmax`/`auto-fit`, container queries, and `prefers-reduced-motion`. |

Windows note: the shipped Windows main window renders the **Linux React bundle**
in WebView2. The WinUI `DashboardPage` is a fallback shell. Work on the React
surface reaches both platforms.

---

## 7. The bar

- No unexplained empty space.
- No layout jump that the user cannot trace — things arrive from where they came
  from and leave toward where they went.
- No lifeless data dump where motion could carry meaning.
- No motion for its own sake. Every animation reinforces hierarchy, orientation,
  or the fact that something real changed.
- Dense when useful. Spacious when *intentional* — and "intentional" means a
  decision someone can point at, not a container that forgot to fill.
