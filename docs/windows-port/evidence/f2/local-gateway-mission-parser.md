# Ledger row: f2-local-http-gateway / f2-local-mission-execution / project-code-static-parser

**What this proves:** F2 workstreams have live production cores: LocalHttpGatewayHost
serves loopback health and models JSON; MissionLocalExecutor runs ordered steps
fail-closed; ProjectCodeLexicalScanner inventories code files by extension from
a real filesystem root (empty inventory when missing).

**Tests:** windows/tests/managed-runtime/LocalHttpGatewayHostTests.cs,
windows/tests/presentation/MissionControl/MissionLocalExecutorTests.cs,
windows/tests/presentation/Projects/ProjectCodeLexicalScannerTests.cs.

**Depth residual:** full AST static analyzer, browser Playwright CU, and Elder Wand
fusion remain deeper F2 workstreams beyond these production cores.
