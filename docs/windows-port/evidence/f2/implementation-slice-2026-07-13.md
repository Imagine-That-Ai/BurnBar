# F2 implementation slice - 2026-07-13

Ledger row: f2-local-http-gateway, f2-local-mission-execution, f2-browser-computer-use, f2-model-proxy-router, f2-companion-cli, f2-project-code-lexical, f2-elder-wand-fusion

What this proves: The current Windows checkout contains exercised implementation for the F2 seams that were previously only represented by a ledger row or a minimal core. The loopback gateway accepts bounded OpenAI-compatible completion requests, chooses an explicit healthy model route, records success/degrade metrics, caps upstream response bodies, and fails closed when no route is available. The durable headless-run and Mission DAG services write metadata-only JSONL state, validate dependencies and approvals, and recover completed steps. Mission planning now validates payload bounds and graph cycles before journaling, emits a deterministic topological order, and applies a shared fixed-window rate limiter that fails closed when execution budget is exhausted. App startup composes the gateway, companion CLI, and run journal; the CLI exposes bounded health/models/run commands plus a bounded `fusion.run` hook, with only safe built-in steps enabled by default and arbitrary shell/provider work denied. Browser process mode uses a direct executable and JSON-line bridge rather than a shell; the bridge accepts both the existing method envelope and the Windows launch/navigate/evaluate/close envelope, with SSRF/DNS-rebinding guards retained. The project symbol index persists only symbol metadata, refreshes from a bounded file watcher, and can invoke the existing Rust Tree-sitter parser with Git-blob SHA verification. A long-lived `ProjectCodeMemoryService` composes that index at app startup when a project root is configured and exposes bounded `code.index`, `code.search`, `code.symbol`, `code.status`, and explicit `code.context_pack` companion operations. Context packs read only bounded, path-confined snippets on demand, redact common secret forms, mark source as untrusted, and never persist source text; lexical fallback remains available when the parser is unavailable. The Windows release workflow builds and signs one parser executable per RID and requires both parser and native engine inputs before publish. Elder Wand journaling stores lifecycle metadata and SHA-256 output digests, never prompts or tool output. Focused managed-runtime (29/29 in the mission/runtime project and 97/97 in the managed-agent-runtime project), presentation (749/749), Computer Use, bridge-policy, provider-boundary, and Rust parser tests pass. This evidence does not claim physical Windows host behavior, full live Pensieve/cloud composition, or public release certification; those remain separate gates.

Validation commands:

```text
dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ProjectCodeLexicalScannerTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ElderWandFusionOrchestratorTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ProjectCodeMemoryServiceTests
dotnet test windows/tests/computeruse/OpenBurnBar.ComputerUse.Tests.csproj --no-restore
node scripts/test-playwright-bridge-guard.mjs
```

The continuation commits are `9219ee737e` (browser bridge protocol),
`0394a9fe03` (Elder Wand fusion command), `47b8db89b5` (provider response
bound), `1e82b11e6f` (project-code watcher/index plus companion `code.*`
operations), `bcaeb38b9e` (mission planner, payload bounds, and rate limiter),
and `3b0a7581f5` (bounded, redacted project context packs). Their focused tests
are included in the current local validation run. A macOS-hosted app build
reaches all managed projects but cannot execute
WinUI's Windows-only `XamlCompiler.exe`; the Windows CI/host build remains the
authoritative XAML validation surface.

The F1 parity ledger remains the machine-scanned 46-row source/product gate.
WPD-0009 still defines F2 True 1:1 as the full parity finish line and requires
production composition plus host evidence before these rows can be promoted.
