# ADR: English-only for v1, with a cheap seam for localization later

**Status:** Accepted (2026-06-12)
**Context:** The 2026-06-11 tech-debt audit (gap-3, finding row 130) found zero localization scaffolding on all five user surfaces — no String Catalog or `.strings` file on any Apple target (0 `NSLocalizedString` calls vs ~2,235 hardcoded `Text` literals), an Android `values/strings.xml` holding only 7 framework-required strings (0 `stringResource` calls vs ~490 inline Compose literals), and hardcoded `lang="en"` with no i18n routing on the Astro marketing site and the Next.js console — and no recorded decision anywhere that English-only was intentional.

## Decision

**OpenBurnBar ships English-only for v1.** This is now a recorded architectural decision, not an accident:

- The product's launch market, docs, marketing copy, and support are English. Translating five surfaces (macOS, iOS/iPad, Android, marketing site, console) before product-market fit is cost without payoff.
- We deliberately do **not** retrofit string extraction across the existing ~2,700 hardcoded literals now. A bulk extraction would churn exactly the god files already slated for decomposition and would have to be redone after they are split.

### The seam we keep cheap

So that a future localization pass is a mechanical extraction rather than a redesign:

1. **Apple targets:** adopt **String Catalogs** (`.xcstrings`) when localization is funded — Xcode auto-extracts `Text("…")`/`String(localized:)` call sites, so today's idiomatic SwiftUI literals remain extraction-friendly. No action required now; avoid building string-assembly helpers that concatenate sentence fragments.
2. **Android:** keep **`strings.xml` discipline available** — new *reusable* user-facing strings may go through `stringResource`, but no retrofit is required for v1. Same fragment rule: format whole sentences with positional placeholders, never concatenate translated fragments.
3. **Web (Astro site + Next.js console):** copy already lives as data (`website/src/data/*.ts`); keep it there. No i18n routing until a second locale exists.
4. **Copy-as-data stays the pattern** for product-governed strings (e.g. `RemoteUnlockBlockerPresentationMap`): centralized copy maps localize for free later.

### Currency is locale-invariant USD, via shared formatters only

All monetary values in the product are **USD** and must render identically on every device locale, matching the Mac/iOS rendering: US-English separators with the `$` symbol (`$1,234.56`). Fixed alongside this ADR (audit finding-215/row-130): Android mixed a hardcoded `"$"` with default-locale number formatting, rendering `"$12,34"` on comma-decimal devices. All Android currency rendering now routes through `com.openburnbar.util.Formatting` (`formatCurrency`, `formatShortCurrency`, `formatPreciseCurrency`, `formatCompactCurrency`), which pin `Locale.US`. **Rule:** never combine a hardcoded currency symbol with default-locale number formatting (`"%.2f".format(x)` without an explicit locale is the bug); locale-stability is regression-tested in `FormatterTest`.

(Plain quantities — token counts, percentages, dates shown in the device's conventions — may keep device-locale formatting; the invariant applies to money.)

## Revisit triggers

Reopen this decision when **any** of: (a) a paid market with a non-English majority is targeted, (b) App Store / Play Store expansion requires localized metadata, (c) the god-file decompositions (ProjectsView/HermesTabView class) land — extraction is cheapest immediately after that refactor, or (d) a partner/enterprise deal requires a specific locale.

## Consequences

- No translation, pseudo-localization, or RTL work in v1; review effort goes to copy quality in English.
- A future first locale costs roughly: String Catalog adoption + extraction on Apple targets, `stringResource` extraction on Android, an i18n routing layer on web — all mechanical given the rules above.
- The currency rule is enforceable by grep (`"\$%` / `"\$\${"%` patterns) and by the `FormatterTest` locale-stability test; new ad-hoc formatters are a review reject.
