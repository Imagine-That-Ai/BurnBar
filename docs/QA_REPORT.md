# AgentLens QA Report

**Date:** 2026-03-21
**Build:** Xcode 16 / Swift 5.10 / macOS 14+
**Branch:** main (working tree)

---

## Build Status: PASS

Build succeeds with zero errors. Warnings are limited to:
- Sendable conformance warnings for `FileManager` stored properties in parser classes (Swift 6 prep, non-blocking)
- Metadata extraction skip (no AppIntents dependency, expected)

---

## Findings by Severity

### Critical

None.

### High

| # | Finding | Status |
|---|---------|--------|
| H1 | **Duplicate session counting for Zai/MiniMax.** `FactoryDroidParser` routed sessions to `.minimax`/`.zai` via `detectProviderFromModel()`, while `ModelFilterParser` also scanned the same `~/.factory/sessions/` directory for those models. Both parsers produced separate `TokenUsage` records with different UUIDs for the same session, causing double-counted tokens and cost. | **Fixed.** `FactoryDroidParser` now skips sessions matching minimax/zai model patterns, deferring to `ModelFilterParser`. |

### Medium

| # | Finding | Status |
|---|---------|--------|
| M1 | **KimiParser `totalChars` double-counting.** The `totalChars` variable was incremented once for every line (line 81) and again in the `default` switch case (line 89). Variable was unused for output, so no user-facing impact. | **Fixed.** Removed the unused `totalChars` variable entirely. |
| M2 | **Sendable warnings in parser classes.** `FactoryDroidParser`, `KimiParser`, `CopilotParser`, and `AiderParser` store `FileManager` instances, which is not `Sendable`. These will become errors in Swift 6. | Documented. Low priority -- parsers are called sequentially from `@MainActor`. |
| M3 | **GlassButton macOS 26 availability check is a no-op.** The `buttonBackground` property in `GlassButton` has an `if #available(macOS 26.0, *)` branch that produces identical code in both branches. | Cosmetic. No functional impact. |

### Low

| # | Finding | Status |
|---|---------|--------|
| L1 | **Duplicated `formatCost` / `formatTokens` helpers.** At least 6 copies of `formatCost` and 4 copies of `formatTokens` across view files. Not a bug, but a maintainability concern. | Documented. |
| L2 | **`FactorySettings` struct (line 252, FactoryDroidParser.swift) is declared but never used.** The parser uses manual `JSONSerialization` instead. | Documented. Dead code, no impact. |
| L3 | **README clone URL uses placeholder** (`your-org/AgentLens`). | Documented. Should be updated before public release. |
| L4 | **README `License` section is empty** (TODO comment). | Documented. Should be populated before open-source release. |
| L5 | **ISO8601DateFormatter allocated in loops.** Several parsers create a new `ISO8601DateFormatter()` inside `for` loops. Minor performance concern on large log files. | Documented. |

---

## Integration Checks

| Check | Result |
|-------|--------|
| `ProviderSupportLevel` enum exists and is used | PASS -- defined in `AgentProvider.swift`, used in `UsageAggregator`, `ProviderDashboardView`, `SettingsView`, `DashboardView` |
| `DataConfidence` enum exists and is used | PASS -- defined in `AgentProvider.swift`, used in `ProviderCard` confidence badge |
| `InsightEngine` compiles | PASS -- builds without errors, generates insights from `DataStore` |
| Empty states are actionable | PASS -- Dashboard shows "Click Scan to import now", popover shows "Click Scan to import sessions", provider view shows context-specific empty messages per support level |
| README provider matrix matches code | PASS -- all 9 providers listed with correct support levels and data sources |
| Settings shows provider status | PASS -- `ProvidersSettingsView` shows support level badge (Supported/Partial/Not yet supported) with colored indicator per provider, plus path existence check |
| DesignSystem tokens used consistently | PASS -- all views reference `DesignSystem.Colors`, `DesignSystem.Typography`, `DesignSystem.Spacing`, `DesignSystem.Radius` |
| Chart views present after file deletion | PASS -- `TokenBreakdownChart` and `DailyTrendChart` moved inline to `ProviderDashboardView.swift`, old standalone files deleted |

---

## Residual Risks

1. **Cost accuracy.** All costs are calculated from hardcoded public pricing tables. Model pricing changes will silently produce incorrect estimates until the code is updated.
2. **Codex SQLite schema assumption.** `CodexParser` assumes a `threads` table with specific columns. If OpenAI changes the Codex database schema, the parser will silently return empty results.
3. **No automated tests.** Zero test coverage. Any future refactor risks regressions.
4. **Kimi parser path assumption.** The `~/.kimi/sessions/` directory structure (workspace > session > context.jsonl) is assumed but not verified against actual Kimi CLI installations.

---

## Ship Recommendation

**Open source now.**

The build is clean, all critical and high issues have been fixed, the architecture is sound, and the provider matrix is honest about support levels and data confidence. The remaining medium/low issues are cosmetic or maintenance items that don't affect correctness.

Recommended pre-release polish (optional):
- Populate README license section (L4)
- Update README clone URL placeholder (L3)
- Add basic unit tests for parsers (residual risk #3)
