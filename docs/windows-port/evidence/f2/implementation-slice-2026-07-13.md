# F2 implementation slice - 2026-07-13

Ledger row: f2-local-http-gateway, f2-local-mission-execution, f2-browser-computer-use, f2-model-proxy-router, f2-companion-cli, f2-project-code-lexical, f2-project-code-memory-store, f2-elder-wand-fusion, f2-connector-cli

The command palette now searches the full bounded local session index rather
than a fabricated twelve-row recent slice. It uses ranked FTS ids when the
database provides them, deterministic title/project/provider/session fallback
matching for older databases, cancellation on each new query, and explicit
loading, empty, and unavailable states. Activating a session carries its id
through shell navigation and selects the record in the session-log detail pane.
`SessionLogSearchTests` covers recency ordering, FTS order, metadata and
subsequence fallback, multi-term matching, and limits.

Direct-process chat now composes bounded persisted transcript context before
launching the approved CLI executable. The current user turn appears exactly
once, attachment metadata and bounded previews are carried without absolute
paths, and prior transcript text is marked as untrusted context. The focused
chat runtime suite covers ordering, duplicate-current-turn suppression,
attachment redaction, and prompt-size bounds.

The project-code JSONL parser now returns explicit blob-integrity state and the
Windows presentation/service boundary exposes bounded LSP reference lookups via
`code.references`. The API confines source files to the configured project
root, converts one-based user lines to zero-based LSP coordinates, and returns
relative reference paths. Tree-sitter symbol extraction now covers C#, Java,
Kotlin, Go, JavaScript, Rust, Swift, Python, TypeScript, TSX, C/C++/Objective-C,
JSON, Markdown, and YAML. A dedicated Windows x64/ARM64 MSVC workflow now
formats, tests, builds, and smoke-tests every grammar; its first green Windows
run and a live Windows LSP host remain separate evidence gates.

The project-code watcher now also persists a Pensieve-compatible, source-free
SQLite metadata store. Atomic refreshes record project identity, file manifests,
artifact hashes, symbols, lexical references/call edges, 2,400/240-character
chunks, parser-backed AST symbol ranges, versioned deterministic 96-dimensional
vectors, and checkpoints. A
restart restores the durable checkpoint before the legacy JSON fallback, and
`code.status` reports bounded store counters; the companion plane exposes
bounded `code.call_graph` and `code.semantic_search` operations. Full macOS
NaturalLanguage/provider embedding quality remains intentionally unclaimed;
Tree-sitter-backed symbol-range chunking is covered by the presentation suite.

The visible Projects page composes the same encrypted store as the companion
service, so its symbol list and the CLI share one durable checkpoint.

The bounded inventory now matches the macOS extension set for C/C++/Objective-C,
JSON, Markdown, and YAML; unsupported grammar formats take lexical fallback
when a Tree-sitter parser is configured.

What this proves: The current Windows checkout contains exercised implementation for the F2 seams that were previously only represented by a ledger row or a minimal core. The loopback gateway accepts bounded OpenAI-compatible completion requests, chooses an explicit healthy model route, records success/degrade metrics, caps upstream response bodies, and fails closed when no route is available. Its provider executor also has a bounded Anthropic Messages adapter for non-streaming text, image, and tool requests: system-message conversion, API-key versus OAuth bearer authentication, required version headers, OpenAI tool-definition and tool-result conversion, tool-choice mapping, normalized `tool_calls` responses, OpenAI data-URL/HTTPS image conversion, and bounded Anthropic SSE-to-OpenAI event conversion are covered; truncated streams, malformed tool payloads, unsafe image URLs, and other invalid shapes fail closed before transport. The desktop gateway composition preserves a configured bearer token or generates and persists a URL-safe 256-bit token through the platform secret store; unauthenticated loopback requires an explicit opt-out. The durable headless-run and Mission DAG services write metadata-only JSONL state, validate dependencies and approvals, recover completed steps, and expose a bounded `run.recover` companion operation for interrupted runs; app startup records only the recoverable-run count. Mission planning now validates payload bounds and graph cycles before journaling, emits a deterministic topological order, and applies a shared fixed-window rate limiter that fails closed when execution budget is exhausted. App startup composes the gateway, companion CLI, and run journal; the CLI exposes bounded health/models/run commands plus a bounded `fusion.run` hook, with only safe built-in steps enabled by default and arbitrary shell/provider work denied. Browser process mode uses a direct executable and JSON-line bridge rather than a shell; the bridge accepts both the existing method envelope and the Windows launch/navigate/evaluate/close envelope, with SSRF/DNS-rebinding guards retained. The project symbol index persists only symbol metadata, refreshes from a bounded file watcher, and can invoke the existing Rust Tree-sitter parser with Git-blob SHA verification. A long-lived `ProjectCodeMemoryService` composes that index at app startup when a project root is configured and exposes bounded `code.index`, `code.search`, `code.symbol`, `code.status`, `code.context_pack`, `code.references`, `code.call_graph`, and `code.semantic_search` companion operations. Context packs read only bounded, path-confined snippets on demand, redact common secret forms, mark source as untrusted, and never persist source text; lexical fallback remains available when the parser is unavailable. The project-code watcher now also persists a Pensieve-compatible, source-free SQLite metadata store with atomic project identity, file manifest, artifact hash, symbol, lexical reference/call-edge, 2,400/240-character chunks, versioned deterministic 96-dimensional vectors, and checkpoint updates; semantic query results return bounded file-relative offsets and hashes without source text. The connector session preflights enabled providers and exposed models before any broker, proxy, tunnel, or Cursor-settings runtime side effect; API-key validation remains in the platform secret-store step. The Windows release workflow builds and signs one parser executable per RID and requires both parser and native engine inputs before publish. Elder Wand journaling stores lifecycle metadata and SHA-256 output digests, never prompts or tool output. Focused managed-runtime (41/41 in the managed-agent-runtime project and 40/40 in the mission/runtime project), CloudSync (60/60), connector (99/99), presentation (760/760), Computer Use, bridge-policy, provider-boundary, and Rust parser tests pass. This evidence does not claim physical Windows host behavior, full macOS NaturalLanguage/provider embedding quality or AST-aware chunking parity, deeper provider/media breadth beyond the bounded image path, or public release certification; those remain separate gates.

The focused presentation suite is now **761/761** after AST-range chunking
coverage; the earlier 760/760 figure in the long implementation paragraph is
superseded by this run.

Correction to the long summary above: parser-backed AST symbol-range chunking
is implemented and tested in this revision. The remaining semantic limitation
is learned macOS NaturalLanguage/provider embedding quality, not chunk-boundary
selection.

The persisted-session restoration path and platform-producer injection seam are
covered by the CloudSync app suite (60/60). When
`OPENBURNBAR_APPCHECK_APP_ID` is explicitly configured, the WinUI app registers
the real Windows CNG/TPM producer together with the bounded `HttpClient` mint
transport before restoring OAuth. Without that switch, the desktop remains
id-token-only rather than attempting a staging mint. TPM availability,
server-side verifier acceptance, and live staging credentials remain host/account
gates; this is composition evidence, not live staging OAuth/App Check/TPM
certification.

The companion TCP plane uses the same bearer-token boundary as the gateway;
the managed-runtime suite covers missing, wrong, and accepted credentials plus
stripping the token before handlers receive the command.

Validation commands:

```text
dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore
dotnet test windows/tests/cloudsync-app/OpenBurnBar.App.CloudSync.Tests.csproj --no-restore
dotnet test windows/tests/managed-agent-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore
dotnet test windows/tests/cursor-connector/OpenBurnBar.App.CursorConnector.Tests.csproj --no-restore
dotnet test windows/tests/chat/OpenBurnBar.App.Chat.Runtime.Tests.csproj --no-restore
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ProjectCodeLexicalScannerTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~SessionLogSearchTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ElderWandFusionOrchestratorTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ProjectCodeMemoryServiceTests
dotnet test windows/tests/computeruse/OpenBurnBar.ComputerUse.Tests.csproj --no-restore
node scripts/test-playwright-bridge-guard.mjs
cargo test --manifest-path crates/project-code-static-parser/Cargo.toml
```

The continuation commits are `9219ee737e` (browser bridge protocol),
`0394a9fe03` (Elder Wand fusion command), `47b8db89b5` (provider response
bound), `1e82b11e6f` (project-code watcher/index plus companion `code.*`
operations), `bcaeb38b9e` (mission planner, payload bounds, and rate limiter),
and `3b0a7581f5` (bounded, redacted project context packs), plus `f82926fd7d`
(bounded Anthropic provider adapter) and the connector preflight validator.
Their focused tests are included in the
current local validation run. A macOS-hosted app build
reaches all managed projects but cannot execute
WinUI's Windows-only `XamlCompiler.exe`; the Windows CI/host build remains the
authoritative XAML validation surface.

The presentation suite is now 761/761 after durable project-code store,
inventory-fallback, and AST-range chunking coverage;
the focused chat runtime suite is 24/24; the Rust parser suite is 19/19. The
F1 parity ledger remains the machine-scanned 48-row source/product gate.
WPD-0009 still defines F2 True 1:1 as the full parity finish line and requires
production composition plus host evidence before these rows can be promoted.
