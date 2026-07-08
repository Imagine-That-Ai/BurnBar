# P14 — Text expansion v1 polish

**Wave 1 · Route: `text-expansion`.**

## Mission

Polish the in-app text-expansion manager: live expansion preview, import/export of snippets, trigger-conflict detection, and refined form UX — while preserving the safety contract exactly (in-app only, consent-gated, zero global capture).

## Read first

- README §1–§2 — the safety evidence is the strictest here.
- Existing: `src/surfaces/TextExpansionSurface.tsx`, `textExpansionStore.ts`, `textExpansionConsent.ts`.
- **Evidence pins:** `shellEvidence.harness.test.ts` scans `src/surfaces/TextExpansionSurface.tsx`, `src/textExpansionStore.ts`, `src/textExpansionConsent.ts` for forbidden terms (`evdev`, `uinput`, `global keyboard hook`, `CGEventTap`, `RegisterHotKey`) and counts `addEventListener('keydown')` occurrences (must stay 0 in those files). localStorage keys are pinned. The parity-ledger substitution line must keep rendering.
- macOS oracle: `AgentLens/Views/Chat/ChatTextExpansionPreviewState.swift` (preview semantics).

## Data contract

Local-only (localStorage) in v1; daemon sync is a later boundary (`textExpansionSafetyProof()` documents this). No bridge changes.

## Files

Edit `TextExpansionSurface.tsx`; create `src/surfaces/textExpansion/PreviewPane.tsx`, `SnippetImportExport.tsx`, extend `textExpansionStore.ts` (pure functions only: `exportSnippets(): string`, `importSnippets(json): {added,skipped}`, `findTriggerConflict(trigger, excludeId?)`) + tests; `app.css` `/* ---- P14 text expansion ---- */`.

## Build steps

1. `PreviewPane`: a labelled textarea where typing shows live expansion of the current buffer via `expandInAppBuffer` — React `onChange` only (no keydown listeners); result shown beside/below with the applied snippet highlighted.
2. Conflict detection: on form input, warn when the trigger equals or prefixes another enabled trigger; block save on exact duplicates with a `Banner`.
3. Import/export: JSON via download/file-input (`Blob` + `URL.createObjectURL`, `input[type=file]`); import validates shape, reports `{added, skipped}` in a status banner; never overwrites silently.
4. Form polish: trigger pattern hint, monospace trigger input, disabled-state styling in the list.

## Required states

Consent-gated (exists) / populated list / empty list / conflict warning / import success + import error / preview idle + preview expanded.

## A11y / Perf / Tests

- Preview result announced politely; conflict warning tied to the input via `aria-describedby`.
- Tests: conflict logic (exact, prefix, disabled snippets excluded), import/export round-trip, malformed import rejection, preview expansion, keydown-listener count in pinned files stays 0 (the harness enforces; run it).

## Done / Forbidden

README §4. Forbidden: keydown/keyup listeners in pinned files; any global capture language or API; new localStorage keys without harness update in the same PR; touching consent semantics.
