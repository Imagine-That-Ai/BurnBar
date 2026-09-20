# iPhone hero information architecture

**Status:** compact tray, keep-awake, Mercury cellular GOP abort, and the **Agents column** landed 2026-08-20. Agent Watch Live Activity Approve / Reject / Halt intents plus ActivityKit `pushType: .token` wiring landed. Cloud Functions can send ActivityKit `liveactivity` APNs from Computer Use session/action headers; named-device delivery still needs the APNs auth-key secrets. VAL-MOB stays open.

**Plan:** [plans/2026-08-20-iphone-remote-continuation-master-plan.md](../../plans/2026-08-20-iphone-remote-continuation-master-plan.md)

**North star:** the iPhone is the steering wheel for agents that still run on *your* Mac. Approvals, chat, the live screen, files, and computer-use halt stay one tap away. Transport is **iroh + HPKE Auth v3 + trusted-device roots**. This is not a daemon-RPC remote and it does not talk to `openburnbar-daemon.sock`.

---

## Compact tray (iPhone)

Four destinations. Watch is not a tab.

| Order | Tray label | Enum / route id | Screen title | Root |
|---|---|---|---|---|
| 1 (launch) | **Inbox** | `AuroraNavDestination.inbox` | Inbox | `InboxHomeView` → existing `AIInboxStore` / `AIInboxView` |
| 2 | **Agents** | `.hermes` (id stays `hermes`) | Agents | `HermesSquareSplitLayout` → compact `HermesSquareRoot`: runtime rail, Ask to Mirror, pinned (My Mac), then threads |
| 3 | **Quota** | `.burn` (id stays `burn`) | Quota | existing `BurnView` + `QuotaStore` |
| 4 | **You** | `.you` | You | `YouView` — tray label matches the screen (not “Store”) |

`AuroraNavDestination.trayDestinations(compact: true)` is the machine source of truth.

**Watch overlay** stays an app-scope singleton (`AgentWatchOverlaySingleton` + `AgentLiveStagePresenter`). A Computer Use or Mercury session auto-docks / splits / maximizes without changing the selected tab. Inbox stays underneath.

**Not in the compact tray** (reachable, not deleted):

| Surface | How you get there |
|---|---|
| Pulse | `burnbar://pulse`, `burnbar://dashboard`, You → Pulse |
| Insights | `burnbar://insights`, `burnbar://insights/{slug}`, You → Insights, Settings → Budget Center |
| Streams | `burnbar://streams`, You → Streams |
| Recap | You → Recap, or the Insights banner on compact |
| Agent Watch (manual) | You → Agent Control, `burnbar://agent-watch` / `burnbar://computer-use` |
| Ask to Mirror | Agents (row + My Mac pin), You → Mac → Ask to Mirror |
| Settings / devices / vault | You |

Regular-width iPad is a command desk, not this tray: `IPadAwayDeskNavigation` defaults to Inbox · Agents · Quota · You, with Insights / Pulse / Streams as reachable overflow. Watch is an inspector, not a tab. See [ipad-away-desk-ia.md](ipad-away-desk-ia.md).

**Agents column (compact):** runtime rail (Hermes / Pi / CLI tiles) · Ask to Mirror · pinned grid including My Mac · subtitle (current runtime + on-device / Mac-relay crumb) · `ThreadInboxStore` threads for that runtime. Overflow (toolbar ···): switch agent, The Wand, missions, resume/handoff, capability grants, rollback, search, pinned, project memory, subscriptions, discover, voice. Grokd is not in the switcher or overflow. Compact Agents is **not** wrapped in a GeometryReader — that blocked chat pushes.

---

## Compact visual contract (ChatGPT × Liquid Glass)

iPad desk stays denser ([ipad-visual-north-star.md](ipad-visual-north-star.md)). This is **compact width** only.

1. **Canvas:** system grouped / paper. Aurora mesh, ribbon, and particles are Settings → Appearance → “Aurora mesh on iPhone”, off by default.
2. **Glass budget:** floating tray (one `glassEffect` capsule), Watch halt capsule, Agents composer puck, first-run consent (`.glassProminent` / `.glass`). Not rows, not cards, not the Inbox filter. iOS 26 glass samples the live canvas — no material plate, white stroke, or sheen fill under `glassEffect`.
3. **Type:** SF Pro default. Rounded / mono only for quota figures and halt.
4. **Lists:** one large title per tab. Inbox search is the navigation drawer (not always-on). No nested glass cards. Ember is the single primary action (approve, send, halt, Allow analytics).
5. **First-run:** title + two paragraphs + system glass Allow / glass Not now. No cube, no sprites. iPhone skips the launch splash so the sheet is not stacked on the formation animation.

---

## Deep-link matrix

Scheme: `burnbar://`. Existing hosts keep working. Compact tray selection is what changed.

| URL | Compact destination | Notes |
|---|---|---|
| `burnbar://inbox` | **Inbox** tab | List. Launch-equivalent. |
| `burnbar://inbox/{id}` | **Inbox** tab + item | Push tap / P1 inbox. Opaque item id only. |
| `burnbar://hermes`, `burnbar://chat`, `burnbar://assistants`, `burnbar://pi` | **Agents** | Enum stays `.hermes`. Any assistant runtime selects the Agents tab. |
| `burnbar://assistants/{runtime}?threadId=` | **Agents** + thread | Agent-reply push. |
| `burnbar://burn`, `burnbar://quota` | **Quota** | Enum stays `.burn`. `openburnbar://headroom` is planned, not invented here. |
| `burnbar://settings` | **You** → Settings | |
| `burnbar://computer-use`, `burnbar://agent-watch`, `burnbar://agent-live` | Watch overlay / You → Agent Control | Overlay singleton, not a tab. |
| `burnbar://insights`, `burnbar://insights/{slug}` | **Insights** (reachable, not in tray) | `ShowInsightsTab` now **selects** Insights on both roots. |
| `burnbar://pulse`, `burnbar://dashboard` | Pulse (reachable) | |
| `burnbar://streams`, `burnbar://search` | Streams (reachable) | Inbox is no longer nested as the Streams launch chip. |
| `burnbar://mission/{id}` | Agents + mission console | |
| Mercury / call routes | Overlay / incoming sheet | Does not change the selected tab. |

Cold launch: `AIInboxDeepLink` and `InsightsDeepLink` stash-then-claim, same as before. A push that posts before the root mounts is not lost.

---

## Watch overlay

**Control plane is live.** Approvals, grants, signed input, three-finger panic, and the Live Activity ride `control.input` via `AgentWatchOverlaySingleton`.

**Pixels are live on one path.** A Computer Use session starts `AgentWatchHUDSession` (non-MAS) and sends `control.surface.frame` unless Mercury is already encoding `media.screen.video`. iOS admits both classes on `media.control` (same GOP window / AEAD class) and fans decoded frames into `AgentWatchOverlaySingleton` / `AgentWatchState.ingestSurfaceFrame`. Ask-to-Mirror joins the live encoder instead of opening a second starved surface. CU chrome (timeline, approval strip, panic) stays on the overlay.

Trust-mode downgrade leaves the phone as a signed `set_trust_mode` `control.input` frame. The Mac still refuses elevation. Three-finger panic (0.8s) also lives on Mercury Ask-to-Mirror. Phone camera/files use the existing iroh-blobs advertise/fetch path (`mediaBlobTransferEnabled` defaults on). Freeze-frame shares into the Hermes composer. Remote Unlock stays human-only. VAL-MOB-011 is not claimed closed.

**Lock screen / Dynamic Island.** Approve and Reject require device unlock. Halt is always allowed. Intents call `AgentWatchOverlaySingleton` (`approve` / `reject` / `panicHalt`) — the same overlay receiver as the on-screen buttons. Start uses `pushType: .token` when the running binary’s public `embedded.mobileprovision` (or bundled entitlements plist) has a resolved `aps-environment`. Missing profile / unresolved `$(APS_ENVIRONMENT)` is a named `undetectable` fallback: `pushType` is nil and the activity shows “Updates while OpenBurnBar is open”. When a token is persisted, `onComputerUseSessionLiveActivity` / `onComputerUseActionLiveActivity` send APNs `liveactivity` updates (status copy only). Ops secrets/topic: [`docs/runbooks/live-activity-apns.md`](../runbooks/live-activity-apns.md).

Stages already exist: dock → split → maximize (`AgentLiveStagePresenter`). Inbox stays selected underneath. Starting a session from an inbox item opens Watch without rewriting the tray selection.

---

## Mac-feature → iPhone address

Mapped from [docs/product-focus/FEATURE_INVENTORY.md](../product-focus/FEATURE_INVENTORY.md) macOS UI + the services those surfaces need. “Address” means where a phone user goes. Later plan steps in *italics* are named, not shipped in this foundation.

| Mac feature | iPhone address |
|---|---|
| AI Inbox | **Inbox** tab |
| Menu bar spend / quota readout | **Quota** tab; *Inbox two-line fleet + tightest-quota header* |
| Dashboard / overview lanes | You → Pulse |
| Charts atelier | Insights + Chart Studio FAB |
| Insights canvases | You → Insights |
| Subscription & quota vault | **Quota** tab (`QuotaStore` / `BurnView`) |
| Session logs / conversation cockpit | You → Streams |
| Projects + project memory | You → Streams |
| Missions + mission console | **Agents** overflow + `burnbar://mission/{id}` console sheet |
| Memory review inbox | You → Data Vault / Pensieve |
| Multi-backend chat workspace | **Agents** identity + switcher (Hermes / Pi on-device; Mac-backed CLIs via Hermes relay) |
| Elder Wand / The Wand | **Agents** overflow → The Wand |
| Control Deck | You |
| Context pack / resume / handoff | **Agents** overflow → Resume / Handoff (`CLIAgentResumeSheet`) |
| Capability grants | **Agents** overflow → Capability grants |
| Rollback | **Agents** overflow → Rollback |
| Settings search + copilot | You → Settings |
| Agents & connections / account switcher | You → Providers / Settings |
| Local gateway / Engine Room | Mac host only. Phone does not grow a daemon socket. |
| Agent Control (computer use) | Watch overlay + You → Agent Control |
| Mercury / Floo screen, calls, files | Watch overlay; *files flag + annotate-on-frame later* |
| Remote Unlock | Existing human-only Watch / Mercury path |
| Smart displays / Cast / pixel clock | You / Settings (Mac still hosts the bridge) |
| Text expansion | iOS keyboard + Settings |
| Desktop pet | Mac only |
| Appearance / live wallpaper | You / Settings |
| Cloud membership, sync, trusted devices | You |
| Data & Privacy control center | You → Data Vault |
| Spend alerts / digest | Quota + You → Settings |
| Keep Mac awake | You + live-session auto-arm (`KeepAwakeLease` / `HostReachabilityClient`). Idle pairing stays 3 min; live session extends verify to 30 min. |
| Grokd / Local D box | Mac only. Future path is sealed `HermesRelayOperation.grokdLocalBox` on Developer ID — not iOS loopback `:1337`, not `openburnbar-daemon.sock`. Not v1. |

---

## Security invariants (cannot vary)

From [docs/HERMES_COMPUTER_USE.md](../HERMES_COMPUTER_USE.md) and [docs/HERMES_MEDIA_TRANSPORT.md](../HERMES_MEDIA_TRANSPORT.md):

- Relays, Firestore, gateways: untrusted transport only
- Mac-bound CU/control: authenticated v3 HPKE envelope + trusted-device bind
- Approval is ground truth; phone trust only downgrades
- Locked Mac / loginwindow / SecurityAgent ends normal mirror and CU
- Inbox push: opaque item id + kind/priority enum only
- No daemon-RPC remote from iPhone
