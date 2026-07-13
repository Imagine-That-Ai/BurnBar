# F2 implementation slice - 2026-07-13

Ledger row: f2-local-http-gateway, f2-local-mission-execution, f2-browser-computer-use, f2-model-proxy-router, f2-companion-cli, f2-project-code-lexical, f2-elder-wand-fusion

What this proves: The current Windows checkout contains exercised implementation for the F2 seams that were previously only represented by a ledger row or a minimal core. The loopback gateway accepts bounded OpenAI-compatible completion requests, chooses an explicit healthy model route, records success/degrade metrics, caps upstream response bodies, and fails closed when no route is available. The durable headless-run and Mission DAG services write metadata-only JSONL state, validate dependencies and approvals, and recover completed steps. App startup composes the gateway, companion CLI, and run journal; the CLI exposes bounded health/models/run commands plus a bounded `fusion.run` hook, with only safe built-in steps enabled by default and arbitrary shell/provider work denied. Browser process mode uses a direct executable and JSON-line bridge rather than a shell; the bridge accepts both the existing method envelope and the Windows launch/navigate/evaluate/close envelope, with SSRF/DNS-rebinding guards retained. The project symbol index persists only symbol metadata, refreshes from a bounded file watcher, and can invoke the existing Rust Tree-sitter parser with Git-blob SHA verification. The Windows release workflow builds and signs one parser executable per RID and requires both parser and native engine inputs before publish. Elder Wand journaling stores lifecycle metadata and SHA-256 output digests, never prompts or tool output. Focused managed-runtime, presentation, Computer Use, bridge-policy, provider-boundary, and Rust parser tests pass. This evidence does not claim physical Windows host behavior, full live Pensieve/cloud composition, or public release certification; those remain separate gates.

Validation commands:

```text
dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ProjectCodeLexicalScannerTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ElderWandFusionOrchestratorTests
dotnet test windows/tests/computeruse/OpenBurnBar.ComputerUse.Tests.csproj --no-restore
node scripts/test-playwright-bridge-guard.mjs
```

The continuation commits are `9219ee737e` (browser bridge protocol),
`0394a9fe03` (Elder Wand fusion command), and `47b8db89b5` (provider response
bound). Their focused tests are included in the current local validation run.

The F1 parity ledger remains the machine-scanned 46-row source/product gate.
WPD-0009 still defines F2 True 1:1 as the full parity finish line and requires
production composition plus host evidence before these rows can be promoted.
