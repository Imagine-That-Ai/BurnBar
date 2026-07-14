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
formats, tests, builds, and smoke-tests every grammar. Hosted workflow
29299426836 passed the x64 tests/smoke and ARM64 build. A live Windows LSP host
is optional precision/deployment evidence; the bundled Tree-sitter parser is
the WPD-0003 F2 contract.

The project-code watcher now also persists a Pensieve-compatible, source-free
SQLite metadata store. Atomic refreshes record project identity, file manifests,
artifact hashes, symbols, lexical references/call edges, 2,400/240-character
chunks, parser-backed AST symbol ranges, versioned deterministic 96-dimensional
vectors, and checkpoints. A
restart restores the durable checkpoint before the legacy JSON fallback, and
`code.status` reports bounded store counters; the companion plane exposes
bounded `code.call_graph` and `code.semantic_search` operations. The Windows
selectable index providers match macOS: deterministic local or OpenAI with the
same three models. macOS BGE remains unavailable because no model is bundled,
and its NaturalLanguage provider is a separate memory fallback rather than a
selectable index provider. Tree-sitter-backed symbol-range chunking is covered
by the presentation suite.

The visible Projects page composes the same encrypted store as the companion
service, so its symbol list and the CLI share one durable checkpoint.

The bounded inventory now matches the macOS extension set for C/C++/Objective-C,
JSON, Markdown, and YAML; unsupported grammar formats take lexical fallback
when a Tree-sitter parser is configured.

What this proves: The current Windows checkout contains exercised implementation for the F2 seams that were previously only represented by a ledger row or a minimal core. The loopback gateway accepts bounded OpenAI-compatible completion requests, chooses an explicit healthy model route, records success/degrade metrics, caps upstream response bodies, and fails closed when no route is available. Its provider executor also has a bounded Anthropic Messages adapter for non-streaming text, image, and tool requests: system-message conversion, API-key versus OAuth bearer authentication, required version headers, OpenAI tool-definition and tool-result conversion, tool-choice mapping, normalized `tool_calls` responses, OpenAI data-URL/HTTPS image conversion, and bounded Anthropic SSE-to-OpenAI event conversion are covered; truncated streams, malformed tool payloads, unsafe image URLs, and other invalid shapes fail closed before transport. The desktop gateway composition preserves a configured bearer token or generates and persists a URL-safe 256-bit token through the platform secret store; unauthenticated loopback requires an explicit opt-out. The durable headless-run and Mission DAG services write metadata-only JSONL state, validate dependencies and approvals, recover completed steps, and expose a bounded `run.recover` companion operation for interrupted runs; app startup records only the recoverable-run count. Mission planning now validates payload bounds and graph cycles before journaling, emits a deterministic topological order, and applies a shared fixed-window rate limiter that fails closed when execution budget is exhausted. App startup composes the gateway, companion CLI, and run journal; the CLI exposes bounded health/models/run commands plus a bounded `fusion.run` hook, with only safe built-in steps enabled by default and arbitrary shell/provider work denied. Browser process mode uses a direct executable and JSON-line bridge rather than a shell; the bridge accepts both the existing method envelope and the Windows launch/navigate/evaluate/close envelope, with SSRF/DNS-rebinding guards retained. The project symbol index persists only symbol metadata, refreshes from a bounded file watcher, and can invoke the existing Rust Tree-sitter parser with Git-blob SHA verification. A long-lived `ProjectCodeMemoryService` composes that index at app startup when a project root is configured and exposes bounded `code.index`, `code.search`, `code.symbol`, `code.status`, `code.context_pack`, `code.references`, `code.call_graph`, and `code.semantic_search` companion operations. Context packs read only bounded, path-confined snippets on demand, redact common secret forms, mark source as untrusted, and never persist source text; lexical fallback remains available when the parser is unavailable. The project-code watcher now also persists a Pensieve-compatible, source-free SQLite metadata store with atomic project identity, file manifest, artifact hash, symbol, lexical reference/call-edge, 2,400/240-character chunks, versioned deterministic 96-dimensional vectors, and checkpoint updates; semantic query results return bounded file-relative offsets and hashes without source text. The connector session preflights enabled providers and exposed models before any broker, proxy, tunnel, or Cursor-settings runtime side effect; API-key validation remains in the platform secret-store step. The Windows release workflow builds and signs one parser executable per RID and requires both parser and native engine inputs before publish. Elder Wand journaling stores lifecycle metadata and SHA-256 output digests, never prompts or tool output. Focused managed-runtime (41/41 in the managed-agent-runtime project and 40/40 in the mission/runtime project), CloudSync (60/60), connector (99/99), presentation (760/760), Computer Use, bridge-policy, provider-boundary, and Rust parser tests pass. This evidence does not claim physical Windows host behavior, live provider/account acceptance, deeper provider/media breadth beyond the bounded image path, or public release certification; those remain separate gates.

The focused presentation suite is now **761/761** after AST-range chunking
coverage; the earlier 760/760 figure in the long implementation paragraph is
superseded by this run.

Correction to the long summary above: parser-backed AST symbol-range chunking
is implemented and tested in this revision. The selectable embedding contract
also matches macOS; live provider/account acceptance remains a staging gate.

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

## Model Proxy settings and Elder Wand catalog continuation

The persisted Model Proxy enable/host/port/token fields now drive the real app
listener, with explicit environment overrides retained for automation. Listener
normalization is portable and tested, and unauthenticated mode is constrained to
the resolved loopback bind rather than trusting the preference alone. The app
keeps its internal router composition when the external listener is disabled or
cannot bind. The settings leaf exposes an explicit shared-runtime restart so
listener, companion CLI, auth token, fusion, and project-memory consumers rotate
together instead of silently waiting for a process relaunch.

The gateway model document now carries provider and route-eligibility metadata,
and the production Elder Wand page projects the active route graph rather than
an empty catalog. It excludes the synthetic unconfigured route, selects an
executable duplicate model route when one exists, and preserves disabled catalog
entries for advertised but unroutable endpoints.

The superseding focused runs are **69/69** for managed runtime, **774/774**
for presentation, and **151/151** for settings view-models. The macOS
app-boundary build compiled all 26 referenced
managed projects before reaching the expected Windows-only XAML compiler
boundary. Exact scope and residual host/staging claims are recorded in
`docs/windows-port/evidence/f2/model-proxy-settings-live-catalog.md`.

## Persisted Project Code workspace continuation

The Projects page now owns a persisted Windows folder-picker selection instead
of reading `OPENBURNBAR_PROJECT_ROOT`. Selecting a folder explicitly enables
indexing and atomically prepares a replacement `ProjectCodeMemoryService`; a
failed initial refresh restores the previous folder and indexing preference.
The page and companion operations consume that one app-owned service. Per-root
JSON fallback metadata moves out of the selected repository and into a hashed
path below `%LOCALAPPDATA%\OpenBurnBar\ProjectCode\indexes`.

Refresh and disposal are serialized across direct, parser-backed, and watcher
paths. A wholly unavailable parser process falls back to the lexical index, and
the lexical inventory, symbol pass, and durable-store artifact pass all skip
file/directory reparse points so nested junctions cannot escape the selected
workspace. The focused root controls adapt for narrow layouts and surface
selection, unavailable, applying, success, and error states.

The superseding local runs are **778/778** for presentation and **166/166** for
settings view models. Formatting checks and `xmllint` pass. The app build again
compiled all referenced managed assemblies before the expected macOS inability
to execute Windows `XamlCompiler.exe`; Windows-host XAML/render interaction
evidence remains required. Exact scope and commands are recorded in
`docs/windows-port/evidence/f2/project-code-root-selection.md`.
