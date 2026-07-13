# F2 implementation slice - 2026-07-13

Ledger row: f2-local-http-gateway, f2-local-mission-execution, f2-browser-computer-use, f2-model-proxy-router, f2-companion-cli, f2-project-code-lexical, f2-elder-wand-fusion, f2-connector-cli

The command palette now searches the full bounded local session index rather
than a fabricated twelve-row recent slice. It uses ranked FTS ids when the
database provides them, deterministic title/project/provider/session fallback
matching for older databases, cancellation on each new query, and explicit
loading, empty, and unavailable states. Activating a session carries its id
through shell navigation and selects the record in the session-log detail pane.
`SessionLogSearchTests` covers recency ordering, FTS order, metadata and
subsequence fallback, multi-term matching, and limits.

What this proves: The current Windows checkout contains exercised implementation for the F2 seams that were previously only represented by a ledger row or a minimal core. The loopback gateway accepts bounded OpenAI-compatible completion requests, chooses an explicit healthy model route, records success/degrade metrics, caps upstream response bodies, and fails closed when no route is available. Its provider executor also has a bounded Anthropic Messages adapter for non-streaming text and tool requests: system-message conversion, API-key versus OAuth bearer authentication, required version headers, OpenAI tool-definition and tool-result conversion, tool-choice mapping, normalized `tool_calls` responses, and bounded Anthropic SSE-to-OpenAI event conversion are covered; truncated streams, malformed tool payloads, and other invalid shapes fail closed before transport. The desktop gateway composition preserves a configured bearer token or generates and persists a URL-safe 256-bit token through the platform secret store; unauthenticated loopback requires an explicit opt-out. The durable headless-run and Mission DAG services write metadata-only JSONL state, validate dependencies and approvals, recover completed steps, and expose a bounded `run.recover` companion operation for interrupted runs; app startup records only the recoverable-run count. Mission planning now validates payload bounds and graph cycles before journaling, emits a deterministic topological order, and applies a shared fixed-window rate limiter that fails closed when execution budget is exhausted. App startup composes the gateway, companion CLI, and run journal; the CLI exposes bounded health/models/run commands plus a bounded `fusion.run` hook, with only safe built-in steps enabled by default and arbitrary shell/provider work denied. Browser process mode uses a direct executable and JSON-line bridge rather than a shell; the bridge accepts both the existing method envelope and the Windows launch/navigate/evaluate/close envelope, with SSRF/DNS-rebinding guards retained. The project symbol index persists only symbol metadata, refreshes from a bounded file watcher, and can invoke the existing Rust Tree-sitter parser with Git-blob SHA verification. A long-lived `ProjectCodeMemoryService` composes that index at app startup when a project root is configured and exposes bounded `code.index`, `code.search`, `code.symbol`, `code.status`, and explicit `code.context_pack` companion operations. Context packs read only bounded, path-confined snippets on demand, redact common secret forms, mark source as untrusted, and never persist source text; lexical fallback remains available when the parser is unavailable. The connector session preflights enabled providers and exposed models before any broker, proxy, tunnel, or Cursor-settings runtime side effect; API-key validation remains in the platform secret-store step. The Windows release workflow builds and signs one parser executable per RID and requires both parser and native engine inputs before publish. Elder Wand journaling stores lifecycle metadata and SHA-256 output digests, never prompts or tool output. Focused managed-runtime (40/40 in the mission/runtime project and 97/97 in the managed-agent-runtime project), CloudSync (60/60), connector (99/99), presentation (755/755), Computer Use, bridge-policy, provider-boundary, and Rust parser tests pass. This evidence does not claim physical Windows host behavior, full live Pensieve/cloud composition, full Anthropic multimodal parity, or public release certification; those remain separate gates.

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

The F1 parity ledger remains the machine-scanned 46-row source/product gate.
WPD-0009 still defines F2 True 1:1 as the full parity finish line and requires
production composition plus host evidence before these rows can be promoted.
