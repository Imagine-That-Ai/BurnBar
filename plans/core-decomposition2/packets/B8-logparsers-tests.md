# Packet B8: move LogParsers-owned tests → OpenBurnBarLogParsersTests (4 files)
STATE: READY  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

Destination: `OpenBurnBarCore/Tests/OpenBurnBarLogParsersTests/` (cross-platform; target dep at
B0: OpenBurnBarLogParsers). Delete `PlaceholderTests.swift` here.

## git mv list (flat)
ClaudeCodeProjectPathCodecEngineTests.swift, ClaudeConversationAccumulatorTests.swift,
GrokParserTests.swift, LogPathPlatformTests.swift

## Expected @testable rewrite per file
Default: `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarLogParsers`.
- GrokParserTests: already has `@testable import OpenBurnBarLogParsers` — drop the Core
  import only.
- NOT in this packet: OBBCAbiUsageScanExportTests (LogParsers 3 hits but primary is the
  OpenBurnBarCoreCAbi export surface — INTEGRATION, stays in CoreTests; see B0-mapping.md).

## Fixtures
None referenced (verify with a `Bundle.module` grep at move time). The parser byte-compat
golden corpus lives under `Sources/OpenBurnBarG2ParserParity/Fixtures` — untouched.

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list.
