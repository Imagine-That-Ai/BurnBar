# BurnBar — Full Feature Inventory (196)

Generated 2026-08-16 by a 21-agent sweep of the repo. Every row was read out of source, not docs.

`Maturity` is the agent's code-level judgement (stubs, TODOs, dead flags, test presence), **not** the doc's claim.

`Verdict` is filled where the consolidated ranking reached that feature; blank rows inherit their group's verdict and are candidates for Labs/Settings/delete.


**Maturity split:** shipped 149 · partial 36 · experimental 6 · stub-or-dead 5

**Discoverability split:** obvious 100 · buried-in-settings 55 · hidden 24 · undiscoverable 17


## BurnBar macOS app UI (AgentLens/Views + AgentLens/App)

| Feature | What it does | Maturity | Gated | Discoverability | Verdict |
|---|---|---|---|---|---|
| **Menu bar readout + resizable tray popover** | Status-bar brand mark showing today's spend/tokens; left-click opens a resizable, reorderable tray of insight/summary/provider/Mercury/chat/quick-switch sections. | shipped | free | obvious | core |
| **Dashboard window, command deck bar and ⌘K palette** | Main window with sidebar + command-deck route bar covering 12 sections, ⌘1–⌘8 / ⌘0 shortcuts, and a ⌘K palette that navigates and searches sessions. | shipped | free | obvious |  |
| **Usage overview lanes with six switchable layout concepts** | Overview page of stat cards, live cost curve, narrative card and provider/model/activity/credential/project-spend lanes, rendered in one of six layout themes (classic, au | shipped | free | obvious | supporting |
| **Charts atelier** | Full-page gallery of 14 usage charts (burn over time, provider/model mix, cache savings, heatmap, forecast, outliers…) that can be reordered, resized, hidden, with an opt | shipped | free | obvious |  |
| **Insights canvases** | Three-pane workspace (canvas library · canvas grid + natural-language composer · inspector) that builds agent-generated insight widgets over local usage, with a verdict p | shipped | free | obvious |  |
| **Subscription & quota vault** | Quota page with a provider constellation hero, urgency/sort filter rail, per-account subscription cards, and a reset atlas showing when each limit rolls over. | shipped | free | obvious | core |
| **Session logs browser** | Two-pane indexed conversation browser with filters/grouping, a transcript detail pane, per-device icons, cloud-source consent, and a resume-conversation sheet. | shipped | free | obvious |  |
| **Database workspace (story / atlas / system)** | Three-mode explorer over the local corpus: a narrated 'story' view, an 'atlas' corpus/retrieval browser with aggregate substring counts, and a 'system' table inspector wi | shipped | free | obvious | cut-or-hide |
| **Projects view with project memory** | Groups usage by project (merging local scan + controller projects) and opens editorial 'project memory' sheets with Hermes-written briefs, wiki primitives and mini visual | shipped | free | obvious |  |
| **Missions lane and mission console** | Flight-ops lane listing controller missions with state/project filters, burn totals, an authoring sheet, plus a floating gauge FAB that opens a separate mission console w | shipped | free | obvious |  |
| **AI Inbox** | Proactive analyst inbox: prioritized items with active/attention/saved/resolved/archived filters, manual drag ordering, pin/tag/category, bulk actions, a detail inspector | shipped | free | obvious | supporting |
| **Memory review inbox** | Human approval gate for memories extracted from chats: pending items can be approved into the injectable set or rejected, and approved ones revoked. | shipped | free | obvious |  |
| **Multi-backend chat workspace** | Full-canvas chat over 12 backends (Codex, Claude, Hermes, Pi, Droid, Forge, Antigravity, Cursor, Junie…) with a thread rail, cmux-style pane tiling, pop-out window, float | shipped | free | obvious | cut-or-hide |
| **The Elder Wand (multi-model fusion) + fusion spend receipts** | Configure a panel of analysis models plus a judge that answer hard prompts in parallel, save it as a named preset, and inspect what each fusion run cost via a receipt mod | shipped | cloud_pro | buried-in-settings |  |
| **The Wand (agent fan-out cast)** | Composer sheet that dispatches a prompt to N parallel agent workers with per-tier caps (free 1 / Cloud 3 / Pro 8 / Ultra 16), scoped command and file-edit permissions, an | shipped | cloud | hidden |  |
| **Control Deck** | Operator home that renders every shipped feature as a live tile grouped into Cast/Spend/Know/Watch/Reach/House, each showing real status and a one-click switch or drill-i | shipped | free | buried-in-settings |  |
| **Context pack export** | Assembles a portable context pack around a session or time range and exports/copies it formatted for a chosen target agent (Claude, Codex, …). | shipped | free | hidden | power-user-only |
| **First-run onboarding wizard** | Seven-step guided setup: pick providers, connect, first scan, product tour, system permissions, chat engine choice, completion — plus separate Hermes and account-switcher | shipped | free | obvious |  |
| **Settings search + Settings Copilot** | Weighted search over a ~140-item settings manifest with deep-link anchors, plus an agentic copilot that answers questions and proposes confirmable setting changes. | shipped | free | obvious |  |
| **Agents & connections (provider accounts, CLIs, runtimes)** | Manage cloud provider keys, wire ~14 local CLIs to the gateway, run the provider-plan wizard (provider → auth → credential → strategy → confirm), and manage local runtime | shipped | free | obvious | supporting |
| **Account switcher (browser + CLI profiles)** | Create isolated browser (Chrome/Safari) and CLI (Codex/Claude/OpenCode…) profiles, set per-provider drain targets, and swap the active profile from Settings or the menu-b | shipped | free | obvious | core |
| **Local model proxy / gateway** | On/off hero for a local OpenAI-compatible gateway with copyable endpoint, routing strategy (exact-model failover vs provider-family), live model catalog with rename/add-c | shipped | free | obvious | supporting |
| **Agent Control (computer use)** | Lets an agent drive the Mac or a browser under per-action approval, with a scope-rule editor, a live session panel, an audit chain and a three-step permissions setup wiza | partial | cloud_pro | buried-in-settings | cut-or-hide |
| **Mercury / Floo — screen share, calls, file transfer** | Phone↔Mac screen mirroring, voice/video calls and attachment transfer, with an app-level incoming-call sheet, floating call HUD, consent store and a capability-framed per | shipped | cloud_pro | buried-in-settings |  |
| **Smart displays & Cast** | Cast the BurnBar readout to a Chromecast/Nest Hub via a 5-step setup wizard, configure Nest Hub and Pixel Clock cards (reorderable), and repair a broken display from the  | shipped | free | buried-in-settings |  |
| **Text expansion snippets** | Create && triggers with static or LLM-generated bodies, validate/dedupe triggers, test them in a sandbox field, and sync them across devices. | shipped | free | buried-in-settings |  |
| **Desktop pet companion** | Floating desktop companion with a bundled pet catalog and form picker, a reaction brain, drag-and-drop attachments, a chat bubble backed by any enabled agent, and a summo | shipped | free | obvious |  |
| **Appearance: themes, WebGL backdrops, live desktop wallpaper** | Theme/menu-bar/background settings with a live preview card, a 30-kernel WebGL2 window backdrop plus per-kernel substrate picker, glass transparency, and rendering the to | shipped | free | buried-in-settings |  |
| **BurnBar Cloud membership, sync and trusted devices** | Sign-in and plan store (free/Cloud/Pro/Ultra) with backup progress, hosted quota refresh, hosted Remote MCP client list, cross-device sync, and a trusted-device list with | shipped | cloud | obvious |  |
| **Data & Privacy control center** | Governance workbench over 12 data domains: sortable inventory table by encryption tier/count/bytes/retention, a sealed-fraction basin, per-domain inspector, export-all, r | shipped | cloud_pro | buried-in-settings |  |
| **Spend alerts, daily digest and notification channels** | Budget thresholds and spend alerts evaluated locally, a daily digest with a delivery hour, plus local notifications, Telegram bot delivery and calendar holds/snooze windo | shipped | free | buried-in-settings | core |
| **Engine Room (daemon) and app updates** | Daemon lifecycle status with crash-loop detection and repair, gateway host/port/token plumbing, controller refresh cadence, plus version display, automatic-update and rel | shipped | free | buried-in-settings | supporting |

## backend-services (AgentLens/Services, OpenBurnBarDaemon, OpenBurnBarCore shared modules, tools/openburnbar-mcp*)

| Feature | What it does | Maturity | Gated | Discoverability | Verdict |
|---|---|---|---|---|---|
| **Multi-provider AI agent coverage (36 providers)** | Tracks token usage, cost, and remaining quota across 36 named AI coding agents/providers, each labelled exact / estimated / unavailable. | shipped | free | obvious |  |
| **Local usage aggregation pipeline** | Scans agent session logs on disk, extracts per-turn tokens/cost/model, and writes them into the canonical token_usage ledger. | shipped | free | obvious | core |
| **Live provider quota / rate-limit refresh** | Polls 23 provider adapters for remaining quota, plan tier, credits, and 5h/7d rate-limit windows, with pacing and coalescing. | shipped | free | obvious | core |
| **Vendor billing/usage API reconciliation** | Pulls authoritative org usage from Anthropic, OpenAI, GitHub Copilot, OpenRouter, Ollama, Z.ai and MiniMax and reconciles it against locally parsed rows. | shipped | free | buried-in-settings | supporting |
| **Local model-proxy gateway (127.0.0.1:8317)** | Runs an OpenAI/Anthropic-compatible HTTP gateway in the daemon serving /v1/chat/completions, /v1/responses, /v1/messages, /v1/models, /health and /metrics. | shipped | free | obvious | supporting |
| **Five-dimensional provider router with quota-drain failover** | Scores and ranks candidate routes on capability, cost, latency, trust and policy-fit, then fails over across credentials when a provider drains or cools down. | shipped | free | buried-in-settings | supporting |
| **The Elder Wand — model-fusion router** | Fans one prompt to a panel of up to 8 models in parallel, has a judge model cross-examine their answers, then has the originating model write the synthesis. | shipped | cloud_pro | obvious |  |
| **One-click routed-client wiring for external CLIs/IDEs** | Edits Claude Code, Codex, OpenCode, Forge, Droid, Grok, Antigravity, Cursor and Prime Agent config files in place so they route through the local gateway. | shipped | free | buried-in-settings | supporting |
| **Daemon socket RPC surface (177 methods, 18 domains)** | An always-on local daemon exposes an authenticated Unix-socket RPC API covering usage, chat, search, memory, code, missions, inbox, media, computer use, config, membershi | shipped | free | hidden |  |
| **openburnbar-cli headless command surface** | Terminal client for the daemon: health, run, resume, search, recall, index/watch, controller, missions, questions, followups, devices, capabilities, diagnostics, chat, ac | shipped | free | hidden | power-user-only |
| **Local MCP server (68 tools)** | A Python MCP server exposing BurnBar's database and daemon to Codex, Claude, Cursor and Hermes as 68 tools, fail-closed by capability. | shipped | free | hidden | power-user-only |
| **Hosted remote MCP (mcp.burnbar.ai)** | A Node stdio shim that fronts the hosted MCP endpoint with OAuth token rotation and client-side decryption of sealed search results and knowledge. | shipped | cloud_pro | buried-in-settings |  |
| **Hybrid conversation search (FTS + vector + rerank)** | Indexes every parsed transcript into search_documents/chunks, then answers queries with lexical FTS candidates fused with ANN semantic candidates and a cross-encoder rera | shipped | free | obvious | paid-upsell |
| **Agent memory (extract, recall, forget, audit)** | Extracts durable memories from chat transcripts with an LLM, stores them with embeddings, and serves recall/forget/audit/analytics to agents. | shipped | cloud_pro | buried-in-settings | power-user-only |
| **Project Code Memory (code index, symbols, references, call g** | Indexes and watches a repo, then answers code search, get-symbol, find-references, call-graph, diagnostics, explore and context-pack queries. | shipped | free | hidden | power-user-only |
| **AI Inbox — daemon-resident background analyst** | Wakes 288x/day, runs deterministic detectors over recent work, and only then optionally calls a model to surface findings, plans and replies. | shipped | free | obvious | supporting |
| **CLI agent bridge, tool broker and managed runtimes** | Spawns and streams provider CLIs as chat backends, brokers their tool calls through a sandbox policy, and supervises local agent gateways (Hermes :8642, Pi Agent :8765). | shipped | free | obvious |  |
| **Session resume, handoff and context-pack export** | Resumes a past agent session natively where the handle can be validated, otherwise writes a 0600 markdown handoff package with transcript, key files, commands and a trust | shipped | free | obvious |  |
| **Zero-knowledge cloud sync and Cloud Vault** | Uploads usage rows, conversation bodies, quota snapshots, budgets, memories and knowledge to Firestore sealed client-side, with keyed search hashes instead of plaintext. | shipped | cloud | obvious | paid-upsell |
| **Agent Control (computer use)** | Lets an agent drive the Mac or a Playwright browser under a scoped capability grant, with per-step approvals, a live watch HUD, panic halt and a tamper-evident audit chai | shipped | cloud_pro | obvious |  |
| **Floo — phone/Mac mirroring, control, transfer and calls** | Screen/camera/mic capture with hardware encode, remote input, bidirectional file transfer, VoIP call trigger and remote unlock over an iroh/relay transport. | shipped | cloud_pro | obvious | cut-or-hide |
| **The Wand — parallel multi-agent fan-out** | Casts one job to N parallel workers, routing each to a fitting model across connected providers and running each in its own branch. | shipped | cloud | obvious | cut-or-hide |
| **Mission Control (projects, questions, followups, missions)** | Daemon-side CRUD, approval flow, DAG scheduling, journaling and notifications for managed AI runs. | experimental | free | buried-in-settings | cut-or-hide |
| **Budget rules, gate, ledger and forecast** | Evaluates every routed request against spend rules before it goes out, tracks the running total from token_usage, forecasts overrun and notifies. | shipped | free | obvious | supporting |
| **Insights, daily digest and charts** | Derives cost-change, rank-movement, model-shift and cache-efficiency insights from usage, renders chart snapshots, and pushes a scheduled daily digest notification. | shipped | free | obvious |  |
| **Automatic session titles and summaries** | Sweeps unsummarized sessions and calls an LLM through a provider fallback chain to write a title and summary, with cost estimation and queueing. | shipped | free | buried-in-settings |  |
| **Connector plane and browser tools** | Daemon-hosted outbound connectors (HTTPS-only, SSRF-hardened) plus a browser tool service with fetch, open and a Playwright engine. | shipped | free | buried-in-settings |  |
| **System-wide text expansion** | A CGEvent session tap that swallows a trigger keystroke and types an expansion anywhere on macOS, with encrypted snippet storage on Linux. | shipped | free | obvious |  |
| **Smart displays, Cast and Home Assistant** | Serves a live quota/spend dashboard to Chromecast/Nest Hub over a local HTTP bridge, drives AWTRIX pixel clocks, and integrates Home Assistant automations. | shipped | free | buried-in-settings |  |
| **Account/profile discovery and CLI auth switching** | Discovers signed-in identities across 16 CLI agents and browser profiles, then switches which account a CLI runs under. | shipped | free | obvious | core |
| **Encrypted store, recovery bundles and data control** | SQLCipher-encrypted local database with migration backups, recovery bundle export/import, privacy inventory/export/deletion and retention policy. | shipped | free | buried-in-settings |  |
| **In-app updater, telemetry and consent-gated analytics** | Channel-aware DMG/Homebrew/source updater with signature verification, plus local operational metrics and tri-state opt-in analytics. | shipped | free | obvious |  |

## mobile-and-ambient (iOS/iPadOS app, widgets, keyboard, Live Activities, Siri, Android, smart displays, device-to-device relay)

| Feature | What it does | Maturity | Gated | Discoverability | Verdict |
|---|---|---|---|---|---|
| **Pulse dashboard (live burn mirror)** | Five-tab Aurora phone app whose Pulse tab mirrors Mac-published spend/token rollups with a live 1M/1H/1D stream and forecast cards. | shipped | free | obvious |  |
| **Burn tab quota pressure** | Per-provider quota rings, fleet-health dial, urgency banners and expandable routing cockpit cards, sorted by how close each bucket is to empty. | shipped | free | obvious | core |
| **Streams conversation cockpit** | Faceted search over hosted, encrypted agent transcripts with on-device decrypt of titles/snippets/bodies plus project and session detail. | shipped | cloud | obvious |  |
| **Hermes chat client with on-device tools** | Full streaming LLM chat on the phone (Hermes/Pi runtimes) with model picker, attachments, tool-call pills, and three on-device tools the model can invoke. | shipped | free | obvious |  |
| **CLI-agent chat routed to the Mac** | Start a Codex / Claude Code / Droid / Forge / OpenClaw / Antigravity chat from the phone; the paired Mac executes it and streams events back into the same thread. | shipped | free | obvious |  |
| **Resume / cross-provider handoff of a Mac session** | Pick a mirrored CLI session on the phone and restart it on the Mac — natively for providers that support resume, or as a handoff package into a different provider. | shipped | free | buried-in-settings |  |
| **Fan-out mission composer ("the Wand")** | Write one brief on the phone, pick several agent runtimes, choose a routing wand, and dispatch a parallel fleet with merge strategy, depth, and command/file-edit permissi | shipped | cloud | buried-in-settings |  |
| **Agent approval inbox with "always" policies** | Sticky strip of pending agent approval asks with approve/deny plus "yes always for this class" rules that sync across devices via Firestore. | shipped | free | obvious |  |
| **AI Inbox with privacy-preserving push** | Ranked inbox of things needing the human, pushed as an opaque item id + kind/priority enum so the notification server can never read the sealed content. | shipped | free | obvious |  |
| **Agent-reply push notifications and deep links** | FCM banners when a Mac-backed agent replies, with runtime/provider badge and a deep link straight into the thread, plus per-agent subscription topics. | shipped | free | obvious |  |
| **Agent Watch live stage (Mac → phone mirror)** | App-scope overlay that auto-opens the moment the Mac starts a Computer Use session: live surface frames, an action timeline, approvals, trust-mode badge and panic halt. | shipped | cloud | obvious |  |
| **Phone control of the Mac (signed input)** | Send taps, scrolls, typed text, and keyboard shortcuts to the paired Mac as Ed25519/Secure-Enclave-signed authority envelopes over a sealed iroh control.input stream. | partial | cloud | buried-in-settings |  |
| **Remote Unlock of a locked Mac** | Human-only lane to unlock a paired, locked Mac from iPhone/iPad/Android over the Mercury control stream, with credentials never touching logs, Firestore, or agent surface | experimental | cloud | hidden |  |
| **Mercury screen-share viewer with trackpad control** | Full-bleed hardware-decoded Mac screen mirror on the phone with a glass trackpad surface, remote keyboard, smart text zoom, cursor overlays, PiP, and live stats. | shipped | cloud | buried-in-settings |  |
| **Mercury 1:1 calls (Mac ⇄ phone)** | VoIP audio/video calling between the Mac and the phone over iroh QUIC, with CallKit incoming sheets, self-PiP, mic/camera capture, and iPad multi-cam. | shipped | cloud | buried-in-settings |  |
| **Mercury file transfer + camera capture** | iroh-blobs file send/receive between Mac and phone with per-partner save preferences, protected inbox, transfer history, and in-app camera capture. | partial | cloud | buried-in-settings |  |
| **Live Activities and Dynamic Island** | Three ActivityKit surfaces: today's burn ticker, an active-session cost/elapsed ring, and Agent Watch (app name, last action, action count, approval-pending dot with inli | shipped | free | obvious | core |
| **iOS home and lock-screen widgets** | Six widget families — hero small, cost sparkline medium, dashboard large/XL, plus inline/circular/rectangular lock-screen — fed from an App Group snapshot the app writes. | shipped | free | obvious | supporting |
| **Siri / App Intent burn status** | One App Intent — "What's my burn today?" — returning a spoken sentence with today's cost, token volume, and provider count. | partial | free | undiscoverable |  |
| **Custom keyboard with snippet expansion** | A full third-party iOS keyboard: text-expansion snippets synced live over an App Group Darwin notification, swipe typing, spell-check autocorrect, predictive text, and ha | shipped | free | buried-in-settings |  |
| **Chart Studio (LLM-authored charts)** | Floating-FAB studio where the assistant turns a prompt into a chart spec, rendered natively (Swift Charts), as ASCII canvas, or as a Mermaid diagram, with a standard gall | shipped | free | obvious |  |
| **Budget center and enforcement** | Set spend budgets and rules on the phone; blocked sends render a BudgetBlockedCard and a status chip rather than failing silently. | shipped | free | buried-in-settings |  |
| **Data Vault control center** | Per-domain encryption control, audit timeline, recovery, and panic actions over the user's cloud vault, with an iPad split-view treatment. | shipped | free | buried-in-settings |  |
| **Pensieve E2EE memory search** | Semantic search over private memory where the query is embedded and cloaked on-device, the server runs ANN over vectors it cannot read, and hits are decrypted locally. | partial | cloud | hidden |  |
| **System permission concierge** | The Mac's macOS permission prompts (Accessibility, Screen Recording, etc.) are classified and forwarded to the phone as a signed grant sheet, with an inline pill on the m | shipped | cloud | obvious |  |
| **Agent capability grants from the phone** | Grant or revoke an agent's desktop capabilities (read, write, shell, browser, export) for a thread from the phone, minted through server-owned authority callables. | shipped | cloud | obvious |  |
| **Rollback agent file edits from the phone** | Browse the Mac-published per-session snapshot index and submit a sealed rollback request the Mac claims and applies, down to a single file. | shipped | free | hidden |  |
| **Nest Hub / Chromecast smart-display dashboard** | Mac runs a local HTTP bridge page and a Cast (Bonjour + TLS channel) client that puts live quota/spend on a Nest Hub; the phone can discover, pick, and re-cast remotely v | shipped | unknown | buried-in-settings |  |
| **Pixel clock / AWTRIX LED matrix** | Drives an AWTRIX LED-matrix desk clock with per-provider agent run status (running/completed/failed), including firmware flashing and button-input handling. | shipped | unknown | hidden |  |
| **Android quick-settings tile, live wallpaper, IME** | Android-only ambient surfaces: a BurnBar quick-settings tile with a translucent quick-glance activity, two live-wallpaper services (data-driven swarm + Living Themes), an | shipped | free | buried-in-settings |  |
| **Living Themes and wallpaper generator** | Generate animated, usage-reactive wallpapers and app skins on the phone (WebGL/Metal kernel backdrops, swarm backgrounds, constellation fields), deep-linkable per theme. | shipped | free | buried-in-settings |  |
| **Provider connection wizard and credential transfer** | Add provider accounts directly from the phone (auth method, cloud vs self-hosted runner, credential entry) plus import Mac-published encrypted credential envelopes with a | shipped | free | obvious |  |

## Non-Apple + editor surfaces (windows/, apps/linux-desktop/, apps/console/, apps/pensieve-experience/, extensions/, gateway/, hermes_cli/, crates/, homebrew packaging)

| Feature | What it does | Maturity | Gated | Discoverability | Verdict |
|---|---|---|---|---|---|
| **Windows WinUI 3 desktop app** | Full C#/.NET WinUI 3 port of the Mac app: 1,402 .cs files (~224K LOC), 112 XAML views, 146 projects in one solution. | partial | free | undiscoverable |  |
| **SharedUi host — Linux React shell rendered on Windows** | The Windows app's primary window hosts the exact apps/linux-desktop React bundle in WebView2, backed by a portable C# dispatcher serving ~80 LinuxShellBridge commands. | partial | free | hidden |  |
| **Windows parity ledger + anti-false-green scanner** | 51-row machine-checked ledger mapping every macOS route to a Windows peer, with a scanner that rejects 'Authored' statuses and greps Real rows for stub/sample/demo tokens | shipped | free | buried-in-settings |  |
| **Windows x64 + ARM64 CI suite** | Path-filtered workflow that builds the full solution and runs the whole C# test suite natively on windows-latest and windows-11-arm. | shipped | free | buried-in-settings |  |
| **Windows MSIX packaging + Ed25519-pinned auto-update** | MSIX/portable-zip/winget/Chocolatey manifests plus an updater core that verifies an Ed25519 signature against a pinned key independent of the Authenticode cert. | partial | free | undiscoverable |  |
| **Windows Computer-Use subsystem** | Capability-token issuer/verifier (Ed25519, attestation-bound, single-use nonce), tamper-evident audit hash-chain, triple kill-switch, and a ViGEm virtual-HID input path. | partial | unknown | buried-in-settings |  |
| **Windows CloudSync + CloudVault crypto + App Check** | Dependency-light C# port of the Firestore REST gateway, the zero-knowledge CloudVault E2EE crypto, and a TPM-backed Firebase App Check client. | partial | cloud | hidden |  |
| **Windows SQLCipher storage layer** | Opens the same Mac-produced encrypted database with the pinned compatibility-4 cipher profile and exposes a DataStore-shaped read/write seam. | shipped | free | hidden |  |
| **Windows device/service integrations (Cast, Home Assistant, S** | Portable net8.0 protocol cores (CASTV2 framing, mDNS parse/build, HA REST, SmartHub bridge, RFB/media wire codecs) each with a thin Windows socket/capture adapter. | partial | unknown | buried-in-settings |  |
| **Windows Pretext text-layout + Win2D particle engine** | Method-for-method C# port of the macOS PretextEngine over an offscreen WebView2, plus a platform-agnostic particle/substrate renderer with a headless perf harness. | partial | free | hidden |  |
| **Linux desktop app (Tauri 2 + React 19)** | Tauri 2 shell with ~25 route surfaces (chat, quota, database, projects, missions, memory, pet, Mercury, SmartHub, text expansion) in ~70K LOC of TypeScript. | partial | free | undiscoverable |  |
| **Linux typed Tauri command bridge** | 150 #[tauri::command] handlers behind ~8K LOC of typed TypeScript decoders covering daemon data, computer use, media, tray, wallpaper, recovery, and native pickers. | partial | free | hidden |  |
| **Linux parity ledger + certification preflight** | 40 product requirements x 7 minimum-support environments, each requiring a current-HEAD attestation bound to artifact hashes before it can go green. | shipped | free | buried-in-settings |  |
| **Linux nightly desktop-environment matrix + macOS soak compar** | Nightly run across Ubuntu GNOME X11/Wayland, Fedora KDE Wayland, and Arch wlroots, plus a 30-minute matched-workload soak compared against macOS. | partial | free | buried-in-settings |  |
| **Linux packaging (deb/rpm/AUR/Flatpak/systemd/IME)** | Full packaging set: .desktop entries, systemd user units, AUR PKGBUILD with install hooks, Flatpak manifest, ibus/fcitx5 IME contracts, and an installed-manifest attestat | partial | free | undiscoverable |  |
| **Linux release + signed update feed** | Release pipeline producing an Ed25519-signed, sigstore-attested Linux package set with SBOM and OpenVEX provenance. | experimental | free | undiscoverable |  |
| **BurnBar Console (app.burnbar.ai)** | Next.js 15 / React 19 static-export member Data & Privacy Control Center with 8 routes, deployed to Firebase Hosting. | shipped | cloud | obvious |  |
| **Browser device-trust escrow + CloudVault E2EE** | P-256 ECDH + HKDF-SHA256 + AES-256-GCM escrow flow, wire-compatible with the Swift CloudVaultCrypto, with a non-extractable device key in IndexedDB and optional WebAuthn  | shipped | cloud | obvious |  |
| **Transparency Inventory + panic revoke** | One row per registry data domain with encryption-tier badge, a yours-vs-server view-flip that frosts what the server can actually see, retention, and view/export/delete a | shipped | cloud | obvious |  |
| **Usage profile page** | Member activity page: lifetime stat row, contribution heatmap of daily tokens, streaks, 90-day trend, and provider/model breakdowns from usage_rollups/all_time. | partial | cloud | obvious |  |
| **Console /experimental backdrop kernel gallery** | Internal gallery for selecting among WebGL backdrop kernels, with hero preview and per-kernel tiles. | experimental | free | hidden |  |
| **OpenBurnBar Cursor / VS Code extension** | Local-first sidebar companion (webview panel + Health/Runs/Run Detail views, 11 commands) talking to the local daemon over RPC, with workspace-trust gating on edits and t | partial | free | undiscoverable |  |
| **Extension analytics with tri-state consent** | Amplitude recorder gated behind unset/granted/declined consent stored in ExtensionContext.globalState, mirroring the Swift AnalyticsConsentStore, plus a Manage Usage Anal | stub-or-dead | free | buried-in-settings |  |
| **Safari agent browser extension** | MV3 extension (nativeMessaging, scripting, page-world runner, localhost-only host permissions) letting an agent ask, act, and approve inside a real Safari session. | experimental | unknown | undiscoverable |  |
| **Pensieve experience prototype** | Standalone static HTML/CSS/JS design prototype for the Pensieve memory product — canvas basin substrate, rail navigation, recall and surfaces modules. | experimental | free | undiscoverable |  |
| **openburnbar-domain-core (shared Rust business logic)** | Dependency-light Rust workspace (domain-core + UniFFI + wasm) owning quota parsing, CloudVault AAD/framing/rewrap, and the deterministic search transform, with unsafe_cod | shipped | free | hidden |  |
| **burnbar-remote (remote desktop / screen-share substrate)** | Nested Cargo workspace with a UniFFI facade exporting readiness, permission checks, dimension scaling, and the adaptive-quality controller for the media path. | partial | unknown | hidden |  |
| **openburnbar-iroh (QUIC peer transport)** | Tiny 8-function UniFFI surface over iroh QUIC — endpoint bootstrap with a persisted secret key, dial, accept, shutdown — with length-prefixed JSON framing and wire-versio | shipped | unknown | hidden |  |
| **openburnbar-media (Linux Mercury capture/decode)** | GStreamer-backed Linux capture and decode pipelines for Mercury — portal-backed PipeWire-to-Opus outbound audio and opusdec/autoaudiosink inbound playback. | partial | unknown | hidden |  |
| **project-code-static-parser** | Tree-sitter-based static parser binary backing the Project Code Memory feature. | partial | unknown | undiscoverable |  |
| **Homebrew cask formula** | A cask pointing at the macOS release DMG with a zap list for app-support, cache, and preferences. | stub-or-dead | free | undiscoverable |  |
| **gateway/, hermes_cli/, tui_gateway/ — orphaned bytecode** | Three top-level directories containing zero tracked files and zero source files — only stale __pycache__ from an unrelated Hermes CLI / WhatsApp-QQ bot gateway project. | stub-or-dead | free | undiscoverable |  |

## monetization

| Feature | What it does | Maturity | Gated | Discoverability | Verdict |
|---|---|---|---|---|---|
| **BurnBar Cloud tier ($7.99/mo · $79/yr)** | Entry paid tier; entitlement doc burnbar_pro. Sold via StoreKit, Play Billing, and Stripe Checkout. | shipped | free | obvious | core |
| **BurnBar Cloud Pro tier ($24.99/mo · $249/yr)** | Mid paid tier; entitlement doc burnbar_pro_max. Unlocks Floo, Agent Control, Data Vault, Elder Wand, 8-wide Wand. | shipped | cloud_pro | obvious |  |
| **BurnBar Cloud Ultra tier ($59.99/mo · $599/yr)** | Top paid tier; entitlement doc burnbar_ultra. Only real differentiators: 10x Pensieve limits, 16-wide Wand, higher fusion-search cap. | partial | cloud_ultra | buried-in-settings |  |
| **Legacy Hosted Quota Sync SKU (grandfathered)** | hosted_quota_sync entitlement from the retired $4.99 SKU; still honored everywhere but no longer sold in any catalog. | shipped | cloud | undiscoverable |  |
| **Top-up: 100 hosted Agent Control actions ($4.99)** | Consumable IAP that credits 100 prepaid hosted Agent Control actions to the current Cloud Pro/Ultra month. | shipped | cloud_pro | buried-in-settings |  |
| **Top-up: 50 Floo relay GB ($4.99)** | Consumable IAP adding 50 prepaid relay-accounting GB to the current Cloud Pro/Ultra month. | shipped | cloud_pro | buried-in-settings |  |
| **Top-up: Elder Wand hosted searches (100 for $4.99 / 500 for ** | Two consumable IAPs crediting hosted web_search runs for Elder Wand Fusion in the current month. | shipped | cloud_pro | buried-in-settings |  |
| **Apple StoreKit 2 purchase rail (iOS + macOS)** | Full StoreKit 2 buy/restore with a server-minted appAccountToken bound to the Firebase UID before Product.purchase(). | shipped | free | obvious |  |
| **Google Play Billing rail (Android)** | BillingClient 9.1.0 SUBS + INAPP flows with server verification via verifyGooglePlayBurnBarProSubscription and RTDN reconciliation. | shipped | free | obvious |  |
| **Stripe Checkout web rail (burnbar.ai/subscribe)** | Signed-in web checkout for Cloud / Cloud Pro / Ultra monthly or annual plus top-ups, with webhook-driven entitlement writes. | shipped | free | obvious |  |
| **Apple JWS verifier + App Store Server reconciler** | Pins three Apple root CA SHA-256 fingerprints, verifies bundleId and OCSP, then reconciles against the App Store Server API. | shipped | free | undiscoverable |  |
| **Server-only entitlement documents** | users/{uid}/entitlements/* is client-readable and client-unwritable; only Cloud Functions (Admin SDK) mint them. | shipped | free | undiscoverable |  |
| **Cloud Pro allowance ledger + monthly caps** | Per-month reservation ledger for hosted actions (500 incl / 2000 cap), relay GB (50 / 300), and fusion searches, with top-up crediting. | shipped | cloud_pro | buried-in-settings |  |
| **Tier-aware paywall UI system (veil, sheet, badge, modifiers)** | Shared GatedFeature catalog rendered as TierLockBadge, FeatureUnlockSheet, and FeatureLockedVeil with per-tier holographic palettes. | partial | free | obvious |  |
| **Hosted quota refresh (Cloud)** | Server-side provider quota polling so 5-hour and weekly windows stay current while the Mac is asleep. | shipped | cloud | obvious | paid-upsell |
| **Encrypted session backup + cloud search (Cloud)** | Sealed conversation/session-log backup with server-assisted encrypted search and the faceted conversation cockpit. | shipped | cloud | obvious |  |
| **Intelligence Brief / hosted Insights (Cloud)** | Server-generated cross-agent insights, retros, forecasts, and narrated story cards. | shipped | cloud | obvious |  |
| **Hermes realtime relay (Cloud)** | Standalone relay service that verifies a Firebase token then requires an active hosted_quota_sync or burnbar_pro entitlement per connection. | shipped | cloud | hidden |  |
| **Hosted Remote MCP (mcp.burnbar.ai)** | Always-on OAuth-protected MCP endpoint giving remote agents a line into sealed memory and tools with no Mac running. | shipped | cloud_pro | buried-in-settings |  |
| **Data Vault / Pensieve agent memory (Cloud Pro)** | On-device-sealed agent memory with hosted cloaked-vector recall, tier-capped at 10 sources / 50k chunks / 1 GB (Ultra 10x). | shipped | cloud_pro | obvious |  |
| **Agent Control (Cloud Pro)** | Supervised agent computer-use with per-task grants, live mirroring, instant halt, and a tamper-evident action record. | shipped | cloud_pro | obvious |  |
| **Floo phone-to-Mac control (Cloud Pro)** | Live desktop/window view, touch takeover, file transfer, shared clipboard, calls, and remote unlock from the phone. | shipped | cloud_pro | obvious |  |
| **The Elder Wand model-fusion router (Cloud Pro)** | Fans one prompt to a panel of up to eight models, has a judge cross-examine them, then synthesizes a final answer. | partial | cloud_pro | obvious |  |
| **The Wand parallel fan-out caps (Free 1 / Cloud 3 / Pro 8 / U** | Per-cast parallel-worker ceiling enforced in Firestore rules, Functions, and both client composers from one shared table. | shipped | cloud | obvious |  |
| **Hermes gateway chat routes (Cloud Pro)** | Server-brokered agent chat gateway destinations and message routing, gated at Cloud Pro. | shipped | cloud_pro | buried-in-settings |  |
| **CLI link + Pi agent relay (Cloud)** | Links a CLI session or a Pi-class agent to the account through Cloud-gated callables. | shipped | cloud | buried-in-settings |  |
| **Linux cloud replica sync (UN-GATED)** | pushLinuxCloudReplicas / pullLinuxCloudReplicas sync usage, conversations, session_logs, text_expansion, and roaming_profile with auth + App Check only. | shipped | free | hidden |  |
| **Windows subscription management (stub)** | UpgradeToPremium() returns a failure string pointing at an account portal; Windows has no purchase rail. | stub-or-dead | unknown | buried-in-settings |  |
| **Direct-download Mac purchase gap** | StoreKit IAP only works in the DISTRIBUTION_MAS build; the Sparkle direct-download Mac app has no in-app buy fallback. | partial | free | obvious |  |
| **Restore purchases / cross-platform entitlement recovery** | AppStore.sync() then currentEntitlements walk, then direct entitlement-doc read, then server-resolved tier fallback. | shipped | free | buried-in-settings |  |
| **Legacy hosted_media_sync SKU (honored, never sold)** | com.openburnbar.hostedMediaSync.monthly grants Floo media in firestore.rules but appears in no client purchase catalog. | partial | cloud_pro | undiscoverable |  |

## First-run experience (macOS app: launch → onboarding → menu bar popover → dashboard first number)

| Feature | What it does | Maturity | Gated | Discoverability | Verdict |
|---|---|---|---|---|---|
| **Step 0 — Launch: menu bar icon, no number** | App starts as a menu-bar accessory; the status item renders an icon-only brand mark with cost hidden in a hover tooltip. | shipped | free | obvious |  |
| **Step 1 — "Set Up Pet Companion" window hijacks first launch** | Before anything else, a 4-step desktop-pet wizard opens and force-activates the app, asking the user to pick a pet, pick an answering agent, and grant a global summon hot | shipped | ? | obvious |  |
| **Step 2 — Full dashboard window auto-opens** | The complete multi-pane dashboard (command deck + sidebar + detail) opens itself on first launch and promotes the app to a Dock-icon regular app. | shipped | ? | obvious |  |
| **Step 3 — Dashboard overview empty state (zero logs)** | With zero sessions the overview renders "Welcome to OpenBurnBar / Start a session with any AI agent and click the refresh button" plus a "Scan for Sessions" button. | shipped | ? | obvious |  |
| **Step 4 — "Index conversation history?" alert** | An immediate modal alert on dashboard appear asking permission to index conversation history for search and chat. | shipped | ? | obvious |  |
| **Step 5 — Analytics opt-in sheet** | A second modal, "Help improve OpenBurnBar", asking the user to enable privacy-preserving usage analytics. | shipped | ? | obvious |  |
| **Step 6 — Memory consent sheet** | A third modal, "Remember useful details from your chats?", chained to appear only after the indexing and analytics decisions are settled. | shipped | ? | obvious |  |
| **Step 7 — The first automatic scan (~45 s after launch)** | The startup scan is queued behind a 30×1 s poll waiting for sign-in that never succeeds for a signed-out user, then a further 15 s sleep, before `refreshAll()` runs. | partial | ? | undiscoverable |  |
| **Step 8 (branch) — Menu bar popover onboarding splash** | Clicking the menu bar icon shows a 340pt splash ("Look up. That's the app.") — but only while the app has zero sessions AND onboarding is unfinished. | shipped | ? | hidden |  |
| **Step 8a — The splash's primary button is the skip** | "Got it" is the prominent tinted button and permanently dismisses onboarding; "Get Started" — the one that opens the wizard — is plain caption-sized text below it. | shipped | ? | obvious |  |
| **Wizard 1/7 — "Choose your agents" (36 provider pills)** | A scrolling flow-layout cloud of every AgentProvider case as a tappable pill, detected ones sorted first with a 6pt green dot. | shipped | ? | obvious |  |
| **Wizard 2/7 — "Connection status"** | Read-only Ready / Needs-attention lists showing each selected provider's log directory path, with reassurance copy that missing paths are fine. | shipped | ? | obvious |  |
| **Wizard 3/7 — "Scanning logs" (the only unskippable step)** | Kicks off `refreshAll()` on appear and shows per-provider parser health; the Skip button is deliberately hidden here and Continue is disabled while refreshing. | partial | ? | obvious |  |
| **Wizard 4/7 — 4-page feature tour** | Four dot-paginated marketing cards: Dashboard, Session Logs, Projects, Hermes Chat. | shipped | ? | obvious |  |
| **Wizard 5/7 — Mac permissions wizard (12 sequential TCC promp** | A one-card-at-a-time walk through Microphone, Camera, Screen Recording, Accessibility, Remote Desktop, Locked-Screen Input (system extension + admin prompt), Full Disk Ac | shipped | ? | obvious |  |
| **Wizard 6/7 — "Choose chat engines"** | Twelve toggles for chat backends (Codex, Claude Code, Hermes, Pi Agent, OpenClaw, OpenClaude, OMP, Droid, Forge, Antigravity, Cursor Agent, Junie), a default-engine picke | shipped | ? | obvious |  |
| **Wizard 7/7 — Completion summary** | Green checkmark plus "Found N sessions across M providers" (or "You're all set" with an empty-history warning), then Open Dashboard / Stay in menu bar. | shipped | ? | obvious |  |
| **Menu bar popover — 6 resizable, reorderable tray sections** | Once onboarding is dismissed, the popover shows header + update banner + quota bar + Insights/Summary/Providers/Mercury/Chat/QuickSwitch sections + cloud upsell strip + a | shipped | ? | obvious |  |
| **Menu bar popover — zero-log empty states** | With no data the popover shows "Welcome to OpenBurnBar / Click Scan to import sessions" in the providers section and "No connected providers" in the quota bar. | shipped | ? | obvious |  |
| **Dashboard navigation — 11 routes, 8 command-deck sections, 1** | The auto-opened dashboard exposes overview, insights, charts, database, projects, missions, session logs, memory, inbox, chat, quota plus a Control Deck of every feature, | shipped | ? | obvious |  |
| **Settings — 17 panes across 6 sections, 75 indexed items** | The Settings window ships 17 tabs grouped into 6 sidebar sections, with a 75-entry search manifest and a Settings Copilot to help navigate it. | shipped | ? | obvious |  |
| **Wizard re-entry — Settings → Operator Model → "Run Setup Wiz** | The only durable way back into onboarding, buried in a Settings detail pane, and it re-opens the wizard with a nil aggregator. | partial | ? | buried-in-settings |  |
| **Parallel wizard — Account Switcher onboarding (3 steps)** | A separate 520×620 wizard for multi-account switching, reachable from three different UI entry points, with its own 18-provider ordering list. | shipped | ? | buried-in-settings |  |

## Claimed identity & strategy (README.md, docs/MISSION.md, docs/DIRECTION.md, docs/ROADMAP.md, DESIGN.md, website/CLAIMS.md, website/src/pages/**)

| Feature | What it does | Maturity | Gated | Discoverability | Verdict |
|---|---|---|---|---|---|
| **Agent spend meter (the origin product)** | macOS menu-bar app that reads local agent session logs and shows tokens, dollars, and quota windows across providers. | shipped | free | obvious |  |
| **Local-first memory / retrieval / workflow OS** | The docs' declared north star: a local retrieval substrate over conversations and artifacts that becomes the operating layer for multi-agent work. | partial | free | buried-in-settings |  |
| **BurnBar Router (Fire Hydrant / model-identity failover gatew** | Local OpenAI-compatible gateway that fails over between accounts while refusing to change the canonical model ID. | shipped | free | obvious |  |
| **Hermes — assistant over your own data** | In-app chat grounded in the local SQLite store, with tappable Conversation Atoms, Chart Studio rendering, and an encrypted realtime relay. | shipped | free | obvious |  |
| **Floo — phone and Mac, joined** | Public name for the Mercury phone-to-Mac companion: screen view, remote control, file transfer, calls, shared clipboard, and remote unlock. | partial | cloud_pro | obvious |  |
| **Agent Control — let an agent use the computer** | Public name for Computer Use: an agent clicks, types and drives a real browser or the Mac itself under per-task grants with a tamper-proof action record. | partial | cloud_pro | obvious | cut-or-hide |
| **MCP integration platform (local + hosted mcp.burnbar.ai + st** | Three MCP channels exposing OpenBurnBar history to any MCP client — free local SQLite server, hosted encrypted endpoint, and a decrypting local shim. | shipped | cloud | buried-in-settings |  |
| **Pensieve — private E2EE agent memory (the Ultra SKU)** | Sealed-on-device knowledge memory of repo docs, notes and chat-derived memories that agents recall over hosted nearest-neighbor search. | partial | cloud_ultra | buried-in-settings |  |
| **The Wand — parallel multi-agent casting** | One job fanned out to N parallel agent workers, each in its own branch, routed by live quota; parallelism is the headline tier differentiator (1/3/8/16). | partial | free | obvious |  |
| **Daemon control plane / Mission Control** | Local JSON-RPC daemon owning project registry, questions, followups, missions, scheduled reviews, replay, connectors and browser tooling, plus an 8-command CLI. | partial | free | hidden |  |
| **Ten-surface platform fleet** | macOS, Linux, iOS/iPadOS, Android, Cursor/VS Code extension, CLI, daemon, widgets, smart displays (Nest Hub, Ulanzi) and MCP, all claimed to speak one daemon. | partial | free | obvious |  |
| **Machine-checked trust and crypto claims engine** | AGPL source, the Horcrux sealed-envelope layer, a pinned libsignal rollout, and marketing copy generated from a crypto registry that fails the build on drift. | shipped | free | obvious |  |
| **Daily Model Board rundown (content/editorial product)** | A dated archive of model-landscape rundowns produced by a board of models, published under /router/daily. | stub-or-dead | free | buried-in-settings |  |
| **Four-tier cloud subscription business** | Free Local at $0 plus BurnBar Cloud $7.99, Cloud Pro $24.99 and Ultra $59.99 per month, billed via Stripe Checkout or the App Store, with two $4.99 top-ups. | shipped | free | obvious |  |
