# F2 implementation slice - 2026-07-13

Ledger row: f2-local-http-gateway, f2-local-mission-execution, f2-browser-computer-use, f2-model-proxy-router, f2-companion-cli, f2-project-code-lexical, f2-elder-wand-fusion

What this proves: The current Windows checkout contains exercised implementation for the F2 seams that were previously only represented by a ledger row or a minimal core. The loopback gateway accepts bounded OpenAI-compatible completion requests, chooses an explicit healthy model route, records success/degrade metrics, and fails closed when no route is available. The durable headless-run and Mission DAG services write metadata-only JSONL state, validate dependencies and approvals, and recover completed steps. Browser process mode uses a direct executable and JSON-line bridge rather than a shell. The project symbol index persists only symbol metadata and refreshes from a bounded file watcher. The companion CLI has bounded request handling and injectable health/models/run commands. Elder Wand journaling stores lifecycle metadata and SHA-256 output digests, never prompts or tool output. Focused tests currently pass: managed runtime 22/22, presentation project/index and Elder Wand tests 6/6 in their filters, and Computer Use 111/111. This evidence does not claim physical Windows host behavior, full AST parsing, live Pensieve/cloud composition, or public release certification; those remain separate gates.

Validation commands:

```text
dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ProjectCodeLexicalScannerTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ElderWandFusionOrchestratorTests
dotnet test windows/tests/computeruse/OpenBurnBar.ComputerUse.Tests.csproj --no-restore
```

The F1 parity ledger remains the machine-scanned 46-row source/product gate.
WPD-0009 still defines F2 True 1:1 as the full parity finish line and requires
production composition plus host evidence before these rows can be promoted.
