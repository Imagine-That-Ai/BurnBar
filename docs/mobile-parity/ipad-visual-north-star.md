# iPad visual north star

**Status:** visual contract for the ChatGPT-quiet iOS 26 shell. Glass is shell-only (tray, inspector bars, sheets). Halt stays opaque error red, white label, ≥44 pt, never `.glass`. Canvas is paper. Cards exist only for decisions. The WebGL kernel and provider swarm never paint Inbox, Agents, Quota, You, or the iPad desk. The stream is never glassed.

**Companion:** [iphone-hero-ia.md](iphone-hero-ia.md) is the compact tray and address table. This file is the **regular-width visual contract** for BurnBar as an iPad remote-computer surface.

**Plan:** [plans/2026-08-20-iphone-remote-continuation-master-plan.md](../../plans/2026-08-20-iphone-remote-continuation-master-plan.md)

**North star:** the iPad is a **desk you can hold**. Inbox, Agents, and Quota stay columns. Watch is a live Mac viewport with a halt you can always reach. The stream is either **this frame from your Mac** or an honest empty — never a wallpaper pretending to be video.

This is not a blown-up iPhone. It is not Sidecar (the iPad is not a second Mac display). It is not Jump or Screens (those share a desktop and know nothing about agents). It is not Cursor or Claude (those steer one vendor). BurnBar already owns inbox + agents + Mercury + computer-use halt on **iroh + HPKE Auth v3**. The iPad job is to make that stack look like a workstation.

Pixel-identical UI across iPhone / iPad / Android is an accepted non-goal ([accepted-non-goals.json](accepted-non-goals.json) `nongoal.pixel-identical-ui`).

---

## What the delightful remotes actually do

Researched 2026-08-20. Exa + WebSearch + vendor docs. Tavily and X skipped (auth). GitHub had no useful public UI source for these commercial apps.

| Surface | What it gets right visually | What BurnBar must not copy |
|---|---|---|
| **Jump Desktop iPad** | Trackpad mode turns the whole glass into a mouse. Customizable modifier toolbar. Lock Mouse Pointer so the physical mouse stays inside the remote screen (`Cmd-Shift-P`, Esc to release). Fluid codecs sell sharpness, not a fake desktop. | A chrome-heavy connection center. Gaming gesture profiles. Treating the iPad as “just RDP.” |
| **Screens 5** | SwiftUI rewrite. iPad toolbar is a **pill**: collapse, swipe to any corner, expand top or bottom. Carousel toolbar ignores trackpad/mouse so it never fights the remote cursor. Touch vs Trackpad are explicit modes. | Carousel as the halt home. Pencil-only chrome. VNC-era “observe” as the hero. |
| **Microsoft Remote Desktop / Windows App** | Connection bar starts expanded, then **docks to an edge or collapses to a corner**. Session switcher is a left rail, not a modal. Direct-touch vs mouse-pointer are named modes. Zoom lives on a long-press slider, not a fake “HD” badge. | Enterprise Connection Center chrome. Direct-touch that hides the pointer while an agent is driving. |
| **Cursor iPad (Jul 2026)** | Rebuilt for the extra space: **pinned sidebar chats**, split review next to chat, full-width diffs. Inbox is work-in-progress, not a blown-up phone list. Pencil markup on a screenshot is a comment, not a drawing app. Honest about what it is: a control surface, not an IDE. | One-vendor agent loop. Cloud-agent demos as a substitute for the user’s Mac. |
| **Claude iOS (same app on iPad)** | Editorial type: serif for the assistant, sans for chrome. Persistent ~260 pt sidebar. Artifact pane ~40% on regular width. Warm parchment, one clay accent, hierarchy by size/weight not color flood. Code / Remote Control is a **session list**, not a fake terminal wallpaper. | Parchment as BurnBar skin. One-agent Code tab. Cowork “live artifacts” that are desktop-only. |
| **Astropad Workbench iPad** | Built for babysitting agents on a headless Mac mini. **Unified display** matches the iPad resolution so Terminal text is readable. Mini-map + pinch zoom. Split-screen keyboard so the Mac stays visible. 1.1 shows **macOS cursors** on iPad. 1.3 privacy curtain + PiP. LIQUID sells lossless live pixels. | Proprietary codec as a brand moment. Voice-to-Mac as the only input. Curtain / Watchdog chrome in the hero. |
| **Apple Sidecar + Universal Control + HIG** | Sidecar: iPad is a second display; Pencil is a mouse; sidebar holds modifiers; **touch is not the pointing model**. Universal Control: on iPad the pointer becomes a **finger-dot**, not a Mac arrow. HIG: highlight / lift / hover; magnetism on highlight+lift, **not** hover; **~12 pt pad on bezeled controls, ~24 pt on unbezeled**; contiguous bar hit regions; custom pointer visual weight ≈ **19 pt** circle. | Sidecar’s “iPad is the Mac’s extra screen.” Letting the iPadOS pointer morph over the Mercury canvas (that canvas is the Mac, not a control). |

Delight, in every case, is the same trick: **the host fills the glass, chrome gets out of the way, and nothing on screen lies about whether you are live.**

---

## The eight visual rules

### 1. Typography is ink, not a phone poster

The iPad is read at lap and desk distance, often with a Magic Keyboard. Claude’s lesson is editorial hierarchy: size and weight, one accent, no color shouting. Cursor’s lesson is that diffs and agent logs need **room**, not bigger type.

**Do**

- Use `MobileTheme.Typography` / `MobileScaledFont` only. Dynamic Type stays on. The a11y floor is [mobile-a11y-performance-policy.json](mobile-a11y-performance-policy.json): no raw `Font.system(size:)` on Pulse / Quota / Agents / Inbox / Watch chrome.
- Body stays ~17 pt rounded. Titles 20–28. Display 28–36 is for empty-state heroes and halt confirmations, not every heading.
- Monospace is for **halt, telemetry, quota figures, diffs, and action ticks** (`mono` / `monoSmall` / `monoTiny`). It is the instrument face, not the voice of the app.
- Agent and inbox prose can sit slightly warmer and more open than the Mac dashboard. Chrome stays sans. Do not invent a second type system.

**Don’t**

- Scale iPhone card titles up to fill the column. That is a poster, not a desk.
- Pair a 36 pt hero with a 12 pt unscaled caption. Hierarchy is one step at a time.
- Put VideoToolbox / GOP / HPKE words in the type the human reads. Those stay in logs.

### 2. Desk density — more columns, not fatter cards

Jump users who work from the sofa run **one host app at a time**. Workbench unifies every Mac display into one iPad-native resolution so Terminal is readable. Screens and MSRD spend pixels on the remote screen, not on a settings slab.

BurnBar already has the pieces: Insights rail 240–320 pt, Agents split at **≥ 720 pt** (`HermesSquareSplitLayout`), Watch overlay stages dock → split → maximize.

**Do**

- Regular width earns a **second (and, when Watch is live, third) column**. Inbox rows, agent threads, and quota rings get tighter vertical rhythm: more rows, same 44 pt touch floor.
- 8–12 pt row padding in lists. 16–20 pt section gaps. Cards only when the object is a decision (approval, pairing, halt confirm).
- Split View / Stage Manager must still read as a desk. If the column is narrower than 720 pt, drop to the compact stack. Do not squeeze three fat cards into a Slide Over.

**Don’t**

- Blow iPhone hero cards to 400 pt wide “because iPad.”
- Hide density behind glass stacks and decorative gradients. Reduced-motion already forbids looping chrome.

### 3. Column rhythm: rail · work · live

Cursor’s iPad rebuild is the column lesson: pinned chats on the left, review or diff in the main well, markup when you point. Claude keeps a persistent ~260 pt sidebar and an artifact pane at ~40%. Screens and MSRD put **session switch** on a rail and the host in the well.

BurnBar’s iPad root is already a `NavigationSplitView` (`RootNavigationView`). Agents already split list / situation room. Watch is an overlay, not a tab ([iphone-hero-ia.md](iphone-hero-ia.md)).

**Do**

| Column | Width | Holds |
|---|---|---|
| **Rail** | 240–320 pt (sidebar / Inbox list / Agents list) | Destinations, threads, session tiles. Hairline separator. No video. |
| **Work** | Remaining width | Inbox item, agent transcript, quota, Insights canvas. Readable measure ~60–80 characters for prose. |
| **Live** | Overlay: dock tile, or ~40–60% split, or maximize | Mercury + CU only. Appears when a session or share is live. Does not steal the selected rail item. |

- Align the three columns to one baseline grid (8 pt). Titles in the rail and the work column share the same first-line Y.
- When Watch is docked, the tile sits in a **safe corner** (see rule 5) and the rail+work stay fully usable.
- When Watch is split on regular width, live takes the leading ~60% and work keeps the trailing 40% — already the `AgentLiveStage` split contract. Do not invent a fourth column.

**Don’t**

- Put Mercury inside the rail as a looping thumbnail.
- Let maximize erase the selected Inbox / Agents row. The overlay covers; the selection stays.

### 4. Pointer hit targets are iPadOS chrome, not the Mac arrow

People will use a Magic Keyboard, a trackpad, a mouse, a Pencil, and a finger on the same session. Apple’s rule: the iPadOS pointer is an extra way to hit **our** controls. It does not replace touch. Universal Control turns that pointer into a finger-dot when it crosses onto iPad. Sidecar treats Pencil as a mouse and does **not** make Mac apps finger-first.

Jump’s Lock Mouse Pointer exists because the iPadOS home indicator and chrome steal clicks. Screens’ carousel **refuses** trackpad hits so the remote cursor stays owned. Workbench 1.1 draws the **macOS** cursor on the stream.

**Do**

- Touch floor stays **44 × 44 pt** (48 dp on Android). That is the a11y policy, not a suggestion.
- Pointer hit padding on **BurnBar chrome**: ~**12 pt** around bezeled controls (halt capsule, approval buttons, sidebar rows with a well), ~**24 pt** around unbezeled glyphs (octagon, keyboard, modifiers).
- Contiguous hit regions on any bar (halt strip, approval stripe, sidebar). Gaps make the pointer flash back to the 19 pt circle between buttons — HIG calls that out as a defect.
- System highlight / lift on sidebar, toolbar, and halt. Magnetism **on** for those. Magnetism **off** on the Mercury canvas and on any hover-only preview.
- Two named input modes on the canvas, same as Jump / Screens / MSRD: **Touch** (tap is a Mac click at that point) and **Trackpad** (the glass moves the Mac pointer). Pencil is a precision pointer, not a paint tool, unless the user is annotating a still they just captured.

**Don’t**

- Apply iPadOS pointer morph (highlight/lift) to pixels inside the HEVC frame. Those pixels are the Mac. Morphing them lies about what is local.
- Let the iPadOS finger-dot and the Mac arrow fight. One pointer is local chrome; the other is `currentCursor` on the stream (see `AgentLiveStage` cursor overlay). If a physical mouse is locked to the host, local chrome still accepts the finger and the halt.
- Build 28 pt “cute” icon buttons for pointer users. Padding can grow; the visible glyph can stay 12–16 pt.

### 5. Halt is always reachable

This is the rule the remote-desktop apps do not have, and the one BurnBar cannot lose. Jump can hide its toolbar. Screens can collapse to a pill. MSRD can park the connection bar in a corner. Sidecar can hide the sidebar. **None of them are driving an agent that can click your Mac.**

Computer Use already has three panic paths (phone three-finger long-press, Mac hotkey, NSWorkspace gate) plus the signed phone halt. The visual rule is: **the human can always see or land on HALT without opening a menu.**

**Do**

| Stage | Halt stays |
|---|---|
| Dock tile | Octagon on the tile (`AgentLiveStageDockTile`). Not behind “Tap to drive.” |
| Split | HALT capsule on the bottom chrome of the live column. |
| Maximize | Same capsule, above the home indicator and above the keyboard. |
| Keyboard up | Halt moves with the safe-area, or the keyboard is a split that leaves the capsule visible (Workbench’s lesson). Never under the keys. |
| Chrome collapsed | Modifier pill / connection bar may collapse. Halt does **not**. If chrome is a corner pill, halt is a **second** persistent control on the opposite safe corner, or a 44 pt capsule that stays expanded. |
| Pointer locked to Mac | Finger and Pencil can still hit halt. Esc / three-finger long-press remain. |
| Stage Manager / Split View | Halt stays inside the BurnBar scene’s safe area, not in the other app. |

- Contrast: white label on `MobileTheme.error`. Accessibility label stays “Panic halt the agent.”
- Approve / Reject may hide when there is no pending request. Halt never does while a CU or Mercury control session is live.
- Three-finger long-press remains, but it is a **backup**, not the only visible affordance.

**Don’t**

- Put halt only in `PhoneControlOptionSheet` or a “…” menu.
- Use the Screens carousel as the halt home (it hides from the pointer on purpose).
- Recycle the halt corner for keyboard, clipboard, or display presets.

### 6. No fake video

Delight here is honesty. Jump, Screens, and Workbench sell **live sharpness**. Cursor shows screenshots and cloud demos as **artifacts**, not as your machine. Claude Remote Control is a session, not a wallpaper terminal. BurnBar already refuses to draw the decoder when `currentFrame == nil` (`AgentWatchView`) and already has an awaiting-frame watchdog (`StreamStateOverlay`, 8 s then “Mac isn’t sending frames”).

**Do**

- The Watch canvas is one of three things, never a blend:
  1. **Live** — a Mercury frame whose timestamp is fresh. The Mac cursor may sit on it.
  2. **Honest empty** — editorial empty state (`AgentWatchEmptyStateView`) or a dark field + status line (“Awaiting first video frame…”, “Reconnecting”, “Mac isn’t sending frames”).
  3. **Still** — a user-captured or agent-attached screenshot, labeled as a still, used for Pencil markup (Cursor’s pattern).
- When the control stream is up and video is not, say that. Do not freeze the last GOP and call it live.
- Letterbox or pillarbox the real frame. Do not stretch a 16:9 Mac into a 4:3 Slide Over and fill the gaps with a blurred copy of the same frame.
- `liveStream` a11y label stays reserved for a decoder that is actually presenting frames.

**Don’t**

- Loop a wallpaper, a product render, a last-session thumbnail, or a “Retina preview” as the desktop.
- Crossfade a stale frame into a new session so the reconnect feels “smooth.”
- Show a synthetic terminal, a fake menu bar, or an agent-drawn Mac as the mirror.
- Use a privacy curtain, dim, or blur of the **last** frame to imply the session is still live.

### 7. Chrome yields to the host canvas

The visually delightful remotes all learned the same layout: **a thin, movable instrument strip** and a full-bleed host. Screens’ pill. MSRD’s dockable connection bar. Sidecar’s optional modifier sidebar. Jump’s top menu that can get out of the way. Workbench’s mini-map that you toggle.

BurnBar chrome on iPad is the sidebar, the Watch hairline, the approval stripe, the modifier/keyboard strip, and halt.

**Do**

- Live chrome is a **pill or hairline**, not a 88 pt toolbar. Collapse modifiers, keyboard, display, and clipboard. Do not collapse halt (rule 5) or the live/not-live mark (rule 6).
- Park collapsed chrome in a corner that does not fight the home indicator, Stage Manager ellipsis, or the docked Watch tile. MSRD had to fix the bar stuck under Stage Manager — do not repeat that.
- One accent at a time: mercury for live, error for halt, approval color for the pending stripe. The canvas stays the Mac’s colors.
- On-screen keyboard, when needed, uses a split or a raised canvas (Workbench) so the host does not vanish.

**Don’t**

- Recreate a Mac menu bar on the iPad.
- Frost the entire stream with ultraThinMaterial so the HEVC looks like a background video in a settings app.

### 8. Two pointers, one truth

Sidecar and Universal Control are the mental model to steal and then **invert**. Sidecar: iPad is the Mac’s extra display; the Mac pointer wins. Universal Control: the pointer **changes species** when it crosses — arrow on Mac, finger-dot on iPad. Jump: you can lock the mouse to the remote so iPadOS chrome cannot steal it. Screens: local carousel does not accept the trackpad. Workbench: the stream shows the **macOS** cursor.

BurnBar is the inverse of Sidecar. The Mac stays the host. The iPad is the steering wheel.

**Do**

- **Local pointer** (iPadOS / UC finger-dot / Pencil-as-pointer) hits rail, work, halt, approval, and collapsed chrome. System highlight/lift applies there.
- **Host pointer** is the Mac cursor drawn on the stream (and only when the coordinator has a cursor sample). Trackpad mode moves that cursor. Touch mode does not draw a fake iPad arrow on the Mac.
- If a hardware mouse is locked to the host (Jump’s pattern), say so in a one-line chip: “Mouse on Mac · Esc releases.” Local halt still takes a finger.
- Hover previews (Inbox peek, agent row) use HIG hover: scale/tint, **no** magnetism, **no** pointer-shape change over the stream.

**Don’t**

- Draw two arrows on the stream.
- Let UC’s finger-dot click through the HEVC as if it were a local button.
- Hide the Mac cursor and call it “direct touch” while an agent is driving. If the agent is moving the host pointer, the human needs to see it.

---

## Bindings that already exist (do not re-invent)

| Rule | Existing bind |
|---|---|
| 1 Typography | `MobileTheme.Typography`, `MobileScaledFont`, a11y policy typography |
| 2–3 Density / columns | `RootNavigationView` split, `HermesSquareSplitLayout` ≥ 720 pt, Insights rail 240–320, `AgentLiveStage` dock/split/maximize |
| 4 Pointer + touch | 44 pt floor; CU tap/scroll intents on the mirror; Pencil markup is a later Watch step, not a new app |
| 5 Halt | Dock octagon, maximize HALT capsule, three-finger long-press, signed `panicHalt` |
| 6 No fake video | `AgentWatchView` hides decoder when `currentFrame == nil`; `StreamStateOverlay` awaiting-frame watchdog |
| 7–8 Chrome / pointers | Overlay singleton; cursor overlay `allowsHitTesting(false)` |

This file does not change those types. It is the visual test a future iPad pass must pass.

---

## Out of scope

- Implementing or restyling UI.
- A second Xcode target or iPad-only app.
- Pixel match with iPhone or Android.
- Sidecar, Universal Control, or Jump as a transport. Transport stays **iroh + HPKE Auth v3 + trusted-device roots**.
- Claiming product parity. `productParityClaim` stays false.

---

## Sources

- Jump: [Getting Started — gestures](https://support.jumpdesktop.com/hc/en-us/articles/216423503-Getting-Started-Jump-Desktop-Controls-and-Gesture-Reference), [changelog (Lock Mouse, Fluid, iPad toolbar)](https://changelog.jumpdesktop.com/), [Mustafa 2026 review](https://mustafa.net/2026/03/12/jump-desktop-the-best-remote-desktop-app-for-ipad-mac-pc/)
- Screens: [Edovia — Screens 5](https://blog.edovia.com/en/introducing-screens-5-for-mac-ipad-iphone/), [iOS toolbars](https://help.edovia.com/en/screens-5/features/ios-toolbar), [cursor modes](https://help.edovia.com/en/screens-5/features/cursor-control-modes-and-other-gestures), [MacStories Screens 5](https://www.macstories.net/reviews/screens-5-an-updated-design-improved-user-experience-and-new-business-model/)
- Microsoft: [Windows App iOS/iPadOS features](https://learn.microsoft.com/en-us/azure/virtual-desktop/users/client-features-ios-ipados), [connection-bar changelog](https://learn.microsoft.com/en-us/azure/virtual-desktop/whats-new-client-ios-ipados)
- Cursor: [iPad changelog (29 Jul 2026)](https://cursor.com/changelog/ipad), [iOS mobile app](https://cursor.com/help/ai-features/mobile-app)
- Claude: [Claude Code on mobile](https://code.claude.com/docs/en/mobile), Claude iOS design notes (editorial type, ~260 pt iPad sidebar)
- Workbench: [astropad.com/product/workbench](https://astropad.com/product/workbench/), [MacStories review](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/), [input help](https://support.astropad.com/en/articles/14025802-mouse-keyboard-and-input-in-workbench), [1.3, 19 Aug 2026](https://9to5mac.com/2026/08/19/astropad-workbench-1-3-adds-faster-streaming-privacy-curtain-and-more/)
- Apple: [HIG — Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices) (12 / 24 pt padding, magnetism, 19 pt pointer), [WWDC20 — Design for the iPadOS pointer](https://developer.apple.com/videos/play/wwdc2020/10640/), [Sidecar](https://support.apple.com/en-us/102597), [Universal Control](https://support.apple.com/en-us/102459)
