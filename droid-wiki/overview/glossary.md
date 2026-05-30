# Glossary

Project-specific terms used throughout the codebase and documentation.

## A–C

**AgentLens** — the internal name for the macOS app target. The shipping product name is OpenBurnBar.

**AgentProvider** — the Swift enum (`AgentLens/Models/AgentProvider.swift`) that enumerates every supported AI provider. Each case carries `iconName`, `displayName`, `logDirectory`, and `filePattern`.

**ALPN** — Application-Layer Protocol Negotiation. Used by the iroh P2P transport to identify protocol channels: `openburnbar/1` for relay framing, `openburnbar/mercury/audio/1` for Mercury audio datagrams.

**Antigravity / Z.ai** — a provider supported by `AntigravityParser.swift`. Also referred to as "Z.ai" in routing contexts.

**ANN** — Approximate Nearest Neighbor. The optional vector search step in `SearchService` that supplements lexical FTS candidates with semantic candidates from `chunk_embeddings`.

**ApprovalSheet** — the `ComputerUseApprovalSheet` SwiftUI view that presents a pre-action screenshot and three buttons (Reject+Halt, Reject, Approve) for Computer Use agent actions.

## D–F

**Daemon** — `OpenBurnBarDaemon`, a Swift Package background agent launched via launchd. Owns provider routing, mission control, run journal, connector plane, and browser plane. Communicates with the app over a Unix domain socket using JSON-RPC.

**DerivedData** — the local Xcode build output directory (`.derived-data/` in the repo root, not the system DerivedData). Set by the Makefile.

**DesignSystem** — `AgentLens/Theme/DesignSystem.swift` and related files. Defines the complete color, typography, spacing, radius, and animation token system. All views must use these tokens; raw values are a lint violation.

**Editorial Observatory** — the visual design language used for the Insights screen and Project Memory detail sheets. Characterized by eyebrow labels, mono ordinals (01/02/03), mercury hairlines, cascade-in animations, and footnote citation chips.

## G–I

**GRDB** — a Swift SQLite library used for all local persistence. OpenBurnBar does not use Core Data.

**HermesParser** — the largest parser file (~41 KB, `AgentLens/Services/LogParser/HermesParser.swift`), responsible for parsing Hermes agent session logs.

**InsightEngine** — `AgentLens/Services/InsightEngine.swift`, the rule-based engine that generates insight cards (spend spikes, cache efficiency, model switches, anomaly detection).

**iroh** — a Rust-based P2P connectivity library used for device-to-device communication (Mercury calls, Agent Watch screen mirror, phone-as-controller). The Rust crate lives at `crates/openburnbar-iroh/`. iOS uses the xcframework; Android uses the AAR from `Vendor/openburnbar-iroh.aar`.

## J–M

**JSON-RPC** — the wire protocol used between the macOS app, CLI, and daemon, carried over a Unix domain socket.

**Keychain** — used exclusively for secrets (API keys, auth tokens, connector credentials). Nothing sensitive lives in UserDefaults or files.

**LogParser protocol** — `AgentLens/Services/LogParser/LogParserProtocol.swift`. Defines `var provider: AgentProvider` and `func parse() async throws -> [TokenUsage]`. All parsers are `Sendable`.

**Mercury** — the P2P media subsystem for file transfer, screen sharing, and 1:1 voice calls. Uses iroh transport with Ed25519 pairing. The wire format adds cursor metadata bits to the `MediaFrame` header for Agent Watch.

**Mission control** — the daemon-backed runtime for project registry, scheduled reviews, question/followup workflows, and agent mission dispatch. Intentionally `Experimental` tier.

## N–Q

**OpenBurnBarCore** — a Swift Package (`OpenBurnBarCore/`) containing the shared wire types, protocols, and schema models used by both the macOS app and the daemon.

**OpenBurnBarDatabase** — `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift`, the single GRDB database class. Defines all migrations, table schemas, FTS5 indexes, and vector embedding tables.

**OpenBurnBarMobile** — the iOS/iPadOS companion app (`OpenBurnBarMobile/`). Handles Agent Watch, Mercury calls, Computer Use remote control, and chat.

**Parser checkpoint** — the position (file offset, inode, modification date) stored per parser run so the aggregator only reads new log entries on subsequent sweeps.

**Projection pipeline** — the background job queue that takes raw conversation rows and projects them into `search_documents`, `search_chunks`, FTS5 tables, and vector embeddings. Managed by `ProjectionPipelineService.swift`.

**ProviderQuota** — the subsystem in `AgentLens/Services/ProviderQuota/` that fetches and caches per-provider API quota data. Displayed in the dashboard and used for budget governance.

## R–S

**retrieval_health** — a SQLite table that tracks health status for each subsystem of the retrieval pipeline (parser/import, discovery, projection, lexical, semantic, rebuild, collaboration, insight rollups).

**RoutedClientWiringSentry** — `AgentLens/Services/CLIBridge/RoutedClientWiringSentry.swift`, the guard that validates provider routing wiring before a CLI bridge session starts.

**SearchService** — `AgentLens/Services/SearchService.swift` (~54 KB). Executes the two-pass retrieval pipeline: lexical FTS candidates + optional ANN semantic candidates → bounded rerank → source hydration → RBAC/visibility filters.

**SwitcherDiscoveryService** — `AgentLens/Services/SwitcherDiscoveryService.swift` (~41 KB). Discovers provider account slots, validates credentials, and manages the account switcher flow.

## T–Z

**TokenUsage** — the core data model for a single usage event. Fields include provider, model, input/output/cache tokens, cost, session path, and timestamp.

**UniFFI** — Mozilla's Universal Foreign Function Interface framework, used to generate Swift and Kotlin bindings from the iroh Rust crate.

**UsageAggregator** — `AgentLens/Services/UsageAggregator.swift`. Orchestrates all parsers, manages checkpoints, and writes `TokenUsage` rows to the local database. `UsageAggregatorParsers.swift` (~96 KB) contains the bulk of parser logic for smaller providers.

**UsageStore** — `AgentLens/Services/DataStore/UsageStore.swift` (~82 KB). The GRDB store for usage events, rollup aggregates, and quota snapshots.

**VoIP push** — APNs VoIP push (PushKit on iOS) and high-priority FCM data messages (Android) used to wake devices for incoming Mercury calls.

**XcodeGen** — used to maintain the Xcode project file. `project.yml` is the source of truth; `OpenBurnBar.xcodeproj` is generated. Run `xcodegen generate` after editing `project.yml`.
