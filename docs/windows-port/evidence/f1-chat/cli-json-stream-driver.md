# Ledger row: nav-chat (DeferredApproved — host stream revive)

**What this proves:** Portable Claude Code `stream-json` → `ChatStreamEvent` parser
(`ClaudeCodeStreamJsonParser`) and production `CliJsonLineChatStreamDriver` +
`ChatStreamDriverFactory` composition are shipped. Sample mode → scripted; CLI
configured (`OPENBURNBAR_CLI_COMMAND`) → CliJson driver; else honest unavailable.

**Tests:** `windows/tests/presentation/Chat/ClaudeCodeStreamJsonParserTests.cs`,
`windows/tests/chat/ChatStreamDriverRuntimeTests.cs` (factory + line driver through
shipped parser).

**Not claimed Real:** Live ConPTY/process attachment on Win11 streaming assistant
tokens end-to-end through ChatSurfaceViewModel (master plan H3 exit). Revive under
WPD-0010 when host evidence lands.
