---
name: anti-review-theater
description: Prevents superficial review theater, rubber-stamping, generic praise, and nitpicking trivialities while missing critical bugs, security gaps, performance regressions, and broken invariants.",
---

# Anti-Review Theater: Rigorous Code Review (@aakashgupta)

Eliminates superficial review theater where automated reviewers or agents rubber-stamp PRs with generic praise, nitpick cosmetic formatting, or leave non-actionable comments while missing real regressions.

---

## 1. Hallmarks of Review Theater

- ❌ **Rubber-stamping:** *"LGTM! Clean code and great structure! 🚀"*
- ❌ **Cosmetic nitpicking:** Focusing exclusively on variable names or comment punctuation while ignoring a race condition or unindexed database query.
- ❌ **Hallucinated suggestions:** Suggesting rewrites that break existing API contracts or introduce subtle syntax errors.
- ❌ **Restating the diff:** Explaining what each line does without evaluating correctness, edge cases, or performance impact.

---

## 2. The Real Review Framework

Every review must evaluate the change against the **5 Critical Invariants**:

1. **Correctness & Edge Cases:**
   - Are null/nil, empty, maximum, and negative values handled?
   - What happens on network disconnects, timeouts, or concurrent requests?
   - Are errors propagated correctly without masking or swallowing?

2. **Security & Data Safety:**
   - Is user input sanitized/validated?
   - Are authorization and authentication checks enforced on every path?
   - Are secrets, tokens, or PII exposed or logged?

3. **Performance & Resource Limits:**
   - Are there N+1 queries, unindexed searches, or unbounded memory allocations?
   - Are background tasks, timers, or event listeners cleaned up to prevent leaks?

4. **Backward Compatibility & Invariants:**
   - Does this break existing database schemas, API contracts, or client versions?
   - Are migrations safe to run on live production tables?

5. **Test Grounding:**
   - Do tests actually exercise the changes and fail on regressions?

---

## 3. Review Output Format

- **Blocker (Must Fix):** Explicit bug, security vulnerability, data loss risk, or broken contract with file and line references.
- **Warning (Should Fix):** Performance concern, missing edge-case handling, or maintainability risk.
- **Verification Evidence:** Proof of compiler, lint, and test pass/fail results.
