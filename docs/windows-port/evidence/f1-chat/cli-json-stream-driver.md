# Ledger row: nav-chat

**What this proves:** Production chat composition defaults to a live CLI process
stream-json path — not Unavailable as the normal default.

1. `ChatStreamDriverFactory.CreateDefault()` returns `CliJsonLineChatStreamDriver`
   unless sample mode or `OPENBURNBAR_CLI_DISABLE=1`.
2. Line source is `CliProcessLineSource.ForChatTurn` which spawns the platform
   shell with the product-owned direct CLI process path.
3. Each stdout NDJSON line is parsed by shipped `ClaudeCodeStreamJsonParser` into
   `ChatStreamEvent` values consumed by `ChatSurfaceViewModel` / state machine.
4. Process start failures emit explicit stream-json text errors (fail-closed, not silent).

**Tests:** `windows/tests/chat/ChatStreamDriverRuntimeTests.cs`,
`CliProcessLineSourceTests.cs`, `windows/tests/presentation/Chat/ClaudeCodeStreamJsonParserTests.cs`.

**Host residual (operational, not composition):** installing Claude CLI and
network credentials on a given machine. Composition is production-real without
sample/demo defaults.
