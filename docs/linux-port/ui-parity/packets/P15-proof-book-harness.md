# P15 — Visual proof book, a11y, perf harness (continuous lane)

**Continuous · Owns evidence, shared-file arbitration, and G3 certification. Runs alongside every wave and lands last.**

## Mission

Keep the evidence system truthful as surfaces evolve, extend it to cover new components, arbitrate the shared files no other lane may touch, and assemble the final G3 dossier. This lane is the difference between "surfaces exist" and "parity is certified".

## Read first

- README §1, §5; `docs/LINUX_PORT_MASTER_PLAN.md` §7 (gates), §9.11 (W10).
- Harness: `src/shellEvidenceModel.ts`, `src/shellEvidence.harness.test.ts`.
- Smoke: `scripts/linux-port/run-shell-smoke.mjs`, `linux-desktop-session.sh` (nav click coordinates live here), `run-perf-budget.mjs`, `budgets/linux-desktop.perf.json`.
- Ledger: `docs/linux-port/parity-ledger.json` + `validate-parity-ledger.mjs`.

## Responsibilities

1. **Evidence model growth.** As packets land, extend `routeSnapshotCases()`, `failureStateCases()`, `automatedAccessibilityScan()`, and route a11y snapshots to cover new sub-states (e.g. chat tool-card states, quota-bucket meters, membership veil inertness). Every new user-visible state gets an evidence row.
2. **Owned shared files.** Only this lane edits: `src/routes.ts` (route additions), `NavRail.tsx` geometry, `linux-desktop-session.sh` click coordinates, `budgets/linux-desktop.perf.json`, `src/app/App.tsx`. A packet needing a new route files a request in its PR body; P15 lands the route + coordinates + evidence in one atomic PR.
3. **Visual proof book.** After each wave, run the packaged smoke and refresh `docs/linux-port/evidence/mission-001-shell-ux/` screenshots for both skins; diff against the previous book and record intentional changes in `visual-review.md`.
4. **Perf budgets.** Watch repeated native shell percentiles and the matched production-linked macOS/Linux comparison; if a surface threatens a budget, file a `FIX` on that lane with the numbers. Budgets do not move to accommodate regressions.
5. **A11y certification.** Keyboard-only traversal script per route; AT-SPI2 snapshot from the packaged session; contrast checks for any new token pairs (extend the contrast rows in the harness).
6. **Parity ledger.** Keep Tier A/B/C rows for every W7 surface current with evidence paths; run `validate-parity-ledger.mjs --allow-blocked` per PR and the strict mode for promotion.

## G3 exit checklist (assemble as `docs/linux-port/evidence/ui-parity-g3/`)

- [ ] Every route renders real fixture data in the packaged session (screenshots, both skins).
- [ ] Interaction scripts pass for tray→popover, every route, and every packet's primary interaction.
- [ ] Keyboard-only + AT-SPI2 snapshots green; zero unlabeled controls.
- [ ] Reduced-motion capture shows no animation on any surface (including foil, shimmer, mesh, pet).
- [ ] Perf budget report `allPass: true` from a clean packaged run.
- [ ] Parity ledger strict validation exits 0 for all W6/W7 rows.
- [ ] Visual review doc updated with per-wave diffs and accepted divergences.

## Forbidden

Weakening a budget or evidence assertion to make a lane green; accepting a packet PR that renames pinned contracts; editing surface code beyond evidence wiring (file a FIX on the owning lane instead).
