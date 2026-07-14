# Ledger row: f2-local-http-gateway / f2-local-mission-execution / project-code-static-parser

**What this proves:** F2 workstreams have live production cores:
LocalHttpGatewayHost serves loopback health and models JSON;
ProjectCodeLexicalScanner inventories code files by extension from a real
filesystem root (empty inventory when missing). The original MissionLocalExecutor
core evidence is superseded by `local-mission-production-composition.md`.

**Tests:** windows/tests/managed-runtime/LocalHttpGatewayHostTests.cs and
windows/tests/presentation/Projects/ProjectCodeLexicalScannerTests.cs.

**Historical boundary:** this foundational core evidence is superseded for
project-code depth by `project-code-memory-store.md`,
`live-lsp-parser-client.md`, and `project-code-root-selection.md`. Browser host
proof and physical Computer Use safety remain external gates.
