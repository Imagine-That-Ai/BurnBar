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
| Headless run service + journal + recovery | Live run service evidence |
| Local Mission Control DAG/planner/policy | Local execution path (not dispatch-only) with evidence |
| Pensieve watcher + project-code memory store | Live watcher + store on Windows |
| Full project-code static parser | WPD-0003 revive + parser evidence |
| Browser Computer Use / Playwright | Host browser CU lifecycle evidence |
| Elder Wand fusion orchestrator | Fusion tool loop live (presets-only is F1) |
| Connector plane / companion CLI / daemon-client core | Live connector/CLI client evidence |

## Product language

- Never claim bare “100% parity” without naming **F2 True 1:1**.
- F1 Ship Peer remains the default launch target until F2 workstreams are Real
  or this WPD is superseded.
