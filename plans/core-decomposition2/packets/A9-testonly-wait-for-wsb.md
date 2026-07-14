# Packet A9: test-only internalizations — WAIT-FOR-WS-B (BLOCKED)

STATE: BLOCKED (named blocker: WS-B per-module @testable imports not landed)
LANE: WS-A curation  DEPENDS-ON: A0 + ALL of WS-B  BASE: main after WS-B

117 public type names across the WS-A modules are referenced ONLY by test
code (docs/API_CURATION_REPORT.md, "test-only (WAIT-FOR-WS-B)" sections; the
per-module lists live in the A1–A8 sibling cards' modules). Today the test
targets reach them through the PUBLIC surface re-exported by the umbrella;
`@_exported` carries only PUBLIC symbols, so internalizing now would break the
suite. WS-B gives each test target a per-module `@testable import` — after
that, these become plain internalizations.

## Method (once unblocked)
1. Regenerate the report (`scripts/debt/check-public-api-budget.sh --report`)
   against post-WS-B main — the test-only lists WILL have drifted.
2. Per module: flip test-only publics to internal; the test target keeps
   reaching them via `@testable import <Module>` (test targets stay Swift-5
   language mode — house rule).
3. Chunk by module into A9a/A9b/... if the diff exceeds a reviewable unit.
4. Full V-list (swift test is the load-bearing check here).
5. Ratchet-down --update per A0-README etiquette.
