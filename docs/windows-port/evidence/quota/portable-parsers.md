# Evidence — Portable quota parsers (Real)

**Ledger row:** `quota-portable-parsers`  
**Status claim:** Real  
**Date recorded:** 2026-07-09  

## What this proves

Four Windows portable parse cores produce correct quota snapshots from committed fixtures without sample-mode UI:

1. Claude statusline  
2. Cursor usage  
3. Codex usage  
4. Anthropic rate-limit headers  

## Artifacts

| Artifact | Location |
|----------|----------|
| Claude parser | `windows/app/OpenBurnBar.App.Presentation/Quota/ClaudeStatuslineQuotaParser.cs` |
| Test project | `windows/tests/quota/` (`*QuotaParserTests.cs`, fixtures) |

## Explicit non-claims

- File-system watchers, credential probes, and `QuotaWorkspacePage` composition are **not** covered by this Real claim (see `nav-quota` Substituted).
- Live `%APPDATA%` acquisition on Windows is WS-D / host-gated.
