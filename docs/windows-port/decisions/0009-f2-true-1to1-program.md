# WPD-0009: F2 True 1:1 program — reclassified until workstreams ship

- **Status:** Accepted (goal driver, 2026-07-09)
- **Date:** 2026-07-09
- **Scope:** Master plan §14 F2 True 1:1 workstreams that are not F1 Ship Peer.
- **Consistent with:** WPD-0006 (daemon per-capability deferrals), WPD-0003
  (project-code static parser), finish line vocabulary F1 vs F2.

## Decision

**100% parity means F2 True 1:1.** F2 workstreams below are **DeferredApproved**
with explicit revive triggers. They must not be implied as present under F1.
When a workstream ships with production defaults + tests + evidence, promote its
ledger row(s) to `Real` and remove the corresponding deferral line.

| F2 workstream | Revive trigger |
|---|---|
| Local HTTP gateway multi-client | Live Windows Service or accepted in-process multi-client gateway with evidence |
| Model catalog / health / route logging / degrade metrics | Live gateway metrics surface on Windows with tests |
| Provider router + provider executors | Production router path on Windows with golden tests |
| Local Mission Control DAG/planner/policy | Local execution path (not dispatch-only) with evidence |
| Pensieve knowledge watcher | Live repo-docs/notes/session-end watcher + sealed queue on Windows |
| Browser Computer Use / Playwright | Host browser CU lifecycle evidence |
| Elder Wand fusion orchestrator | Fusion tool loop live (presets-only is F1) |
| Connector plane / tooling proxy / workspace broker | Live external connector consumer evidence |

Closed under this decision:

- Headless run service + protected checkpoints + metadata journal + recovery,
  approval, and leased tool dispatch: promoted by
  `docs/windows-port/evidence/f2/headless-run-recovery.md`.
- Standalone companion CLI + authenticated daemon-client core: promoted by
  `docs/windows-port/evidence/f2/companion-cli-client.md`. The separate
  connector plane remains deferred under WPD-0006 row 33.
- Project-code memory store, embeddings, and full static parser: promoted by
  `docs/windows-port/evidence/f2/project-code-memory-store.md`,
  `docs/windows-port/evidence/f2/live-lsp-parser-client.md`, and the WPD-0003
  revival addendum. The general Pensieve repo-docs/notes/session watcher remains
  deferred under WPD-0006 row 18.
- Gateway rate limiter: promoted by
  `docs/windows-port/evidence/f2/gateway-rate-limiter.md`. The production host
  now enforces the macOS token-bucket contract and the shared stricter
  unauthenticated-loopback ceiling before provider execution.

## Product language

- Never claim bare “100% parity” without naming **F2 True 1:1**.
- F1 Ship Peer remains the default launch target until F2 workstreams are Real
  or this WPD is superseded.
