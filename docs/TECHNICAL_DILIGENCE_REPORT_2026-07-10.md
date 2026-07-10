# Technical Diligence Report - 2026-07-10

> Scope: `origin/main @ 8943aae79a`, the `codex/sota-9` remediation diff, repository history and
> live GitHub Actions/issue state observed on 2026-07-10. This report incorporates
> `TECH_DEBT_AUDIT_2026-07-09.md`; that audit remains the detailed finding register.

## 1. Executive Summary

OpenBurnBar is an ambitious startup codebase with pockets of genuinely excellent engineering. It
is not a hacky prototype. Its security boundaries, fail-closed CI ratchets, cross-platform contract
work, test breadth, and written architecture show strong engineering taste. The remediation branch
also closes material gaps in account erasure, Computer Use quota enforcement, deploy trust
boundaries, and gate non-vacuity.

It is nevertheless **not ready for an evidence-backed production launch today**. The reason is not
primarily source quality; it is operational credibility. The latest successful main-branch
Functions and Cloud Run deployments were on June 18. The latest v1.0.29 deployment attempts failed.
The ten most recent Firestore deploy runs failed. The current full harness already has three
terminal job failures. The current DAST run failed its website, Functions-emulator, and privileged-
socket lanes. Nine P0 issues remain open, including duplicate stale incidents. This is a
serious control-system failure: the repository has sophisticated safety machinery, but the team has
allowed its strongest proof lanes to become chronically red.

A strong CTO or Series A diligence team would be both impressed and nervous. They would be
impressed by the quality ceiling and the seriousness of the security/test architecture. They would
be nervous that platform breadth and automation volume exceed the team's demonstrated capacity to
keep production proof current. The codebase can become diligence-ready without a wholesale rewrite,
but it first needs a sustained period in which red production gates are treated as stop-the-line
events.

## 2. Final Verdict

- **Professionalism:** credible startup-grade engineering with unusually strong local rigor, offset
  by weak operational closure.
- **Maturity class:** ambitious but operationally messy startup codebase, approaching a credible
  production system. It is not yet a genuinely impressive engineering foundation end to end.
- **Launch readiness:** **Not launch ready** under a serious production-certification standard.
- **Series A readiness:** not ready for clean technical diligence; a good reviewer will find the
  source promising and the live proof plane alarming.
- **12-24 month trajectory:** the architecture will accelerate the team only if structural
  convergence and platform ownership resume. Without that, duplicated implementations and red
  automation will slow feature work and raise regression cost.
- **Hidden rewrite risk:** medium-high. Core systems are salvageable; selected seams risk expensive
  rework.
- **Confidence:** high (93%). The repository was sampled broadly, critical paths were tested
  directly, and launch claims were checked against live GitHub state.

## 3. Scorecard

| Category | Score | Rationale | Severity summary |
|---|---:|---|---|
| Architecture | 7/10 | Clear packages, contracts, ADRs, and trust boundaries; mission split-brain, UI-carrying Core, and cross-platform duplication remain. | Serious weakness |
| Code Quality | 8/10 | Strong Swift/TS/Kotlin discipline, low suppression debt, focused abstractions, and extensive meta-tests. | Medium concerns |
| Reliability / Ops | 4/10 | Resilience helpers and SLO/runbook machinery are good; stale deploy proof, broken harnesses, and normalized P0s are not. | Launch blocker |
| Security | 8/10 | Strong auth catalogs, App Check, rules tests, secret scanning, WIF boundaries, erasure barriers, and privacy-safe metering. Residual dependency/secret risks remain. | Serious weakness |
| Performance / Scalability | 6/10 | Query tracing and budgets exist; FTS deletion/indexing, transcript retention, and multi-copy data growth remain credible ceilings. | Serious weakness |
| Testing / CI / Delivery | 6/10 | Test breadth is high and gate self-tests are unusually good; hosted proof is chronically red and mobile/Linux/Windows authority is incomplete. | Launch blocker |
| Documentation / Maintainability | 9/10 | Architecture, schema, privacy, runbooks, platform plans, and debt registers are unusually comprehensive and cross-linked. | Polish items |
| Overall Professionalism | 7/10 | High engineering taste in source and controls, inconsistent follow-through in production operations. | Serious weakness |
| Launch Readiness | 4/10 | Exact-commit protected CI, live backend deployment, Firestore deployment, DAST, and erasure/metering drills are not green. | Launch blocker |
| Series A Technical Diligence | 5/10 | Strong underlying team signal, but a diligence reviewer cannot accept stale or failing operational evidence. | Diligence blocker |

**Overall weighted score: 66/100.** Weighting emphasizes architecture, security, reliability, and
delivery over documentation polish.

## 4. What Inspires Confidence

1. **Security boundaries are concrete.** `functions/src/security/`, generated endpoint
   authorization catalogs, `firestore.rules`, `storage.rules`, App Check enforcement, and the WIF
   split in production workflows show defense in depth rather than security-by-documentation.
2. **Account erasure is being treated as a distributed systems problem.** The remediation adds a
   durable barrier, resumable reconciler, retained audit receipts, token revocation, storage denial,
   and focused rules/Functions tests in `functions/src/accountErasure*.ts` and
   `docs/runbooks/account-erasure.md`.
3. **Computer Use safety has real invariants.** Local quota reservations, replay denial, monotonic
   reconciliation, server-owned aggregation, approval controls, revocation checks, and privacy-safe
   headers span `OpenBurnBarComputerUseCore`, app, daemon, Functions, and rules.
4. **The team tests its tests and gates.** Suppression, diff-coverage, repair-loop provenance,
   production deploy auth, jscpd non-vacuity, migration catalog, and Linux test-manifest verifiers
   have adversarial positive/negative fixtures under `scripts/ci/` and `scripts/linux-port/`.
5. **Written engineering context is exceptional for a startup.** `docs/ARCHITECTURE/`, schema
   references, privacy docs, SLOs, release runbooks, platform parity audits, and debt metrics provide
   real operating context.
6. **Local remediation evidence is substantive.** Functions lint/build and the full 1,176-case
   unit suite, Firestore/Storage emulator suites, Android JVM/detekt, app/Core/daemon tests,
   Actionlint, jscpd, and the Linux targets passed across the documented local runs.

## 5. What Would Alarm a Serious Reviewer

1. **The proof plane is not trusted.** The full harness is currently failing while merges continue.
   This defeats the repository's intended light-PR/heavy-post-merge safety model.
2. **Production deployment evidence is stale or red.** Functions and Cloud Run have no successful
   main deployment since June 18; v1.0.29 attempts failed; Firestore has ten consecutive failures.
3. **P0 has lost semantic force.** Nine open critical issues, including stale duplicates and issues
   with dozens of recurring failures, indicate ownership and alert lifecycle breakdown.
4. **Five-platform ambition exceeds current convergence.** Swift, Kotlin, C#, TypeScript, and Linux
   paths still mirror meaningful behavior. Some byte-level contracts prove copies match without
   proving every platform executes the same semantics.
5. **Architecture paydown stalled at ratchet baselines.** Daemon-to-UI-Core coupling and mission
   authorization split-brain are measured but not materially reduced.
6. **Data growth has no convincing long-term answer.** FTS maintenance, duplicate transcript
   storage, and absent retention/GC can turn user growth into latency and storage incidents.
7. **The remediation unit is unusually broad.** More than 120 tracked files span CI, Functions,
   Swift, Android, Linux, Windows, supply chain, and website policy. Even with a review map, this is
   high integration and independent-review risk.
8. **Debt metrics omit the operating proof plane.** `TECH_DEBT_METRICS.md` tracks source debt but
   not green-harness age, deploy freshness, P0 age, or repair-loop noise, so its headline can look
   healthy while production evidence is red.
9. **Cloud metering is not anti-abuse authority.** Aggregate documents are server-written, but the
   source headers are owner-created and lack executor-signed provenance. They are honest-client
   operational telemetry, not authoritative billing evidence.

## 6. Launch Blockers

1. Protected CI must pass on the exact submitted commit, including macOS/iOS, Android coverage,
   Windows, Linux ARM64, Functions integration, and workflow policy checks.
2. Firestore rules/indexes/storage must deploy successfully through the hardened production lane,
   followed by drift/readback verification.
3. Functions and hosted Cloud Run services must deploy successfully through WIF-authenticated
   workflows; deployed revisions/digests must match the release commit.
4. Full Harness, Nightly E2E, DAST, CodeQL, and commercial launch checks must complete green or have
   a specific, time-bounded external blocker accepted by an owner.
5. Open P0s must be deduplicated, assigned, and resolved. P0 cannot remain a recurring bot archive.
6. Run an operator-observed account-erasure drill and Computer Use quota/metering ring validation
   against production-like data before broad enablement.
7. Verify the erasure reconciler's oldest-first rotation and poison quarantine against production-
   like failure cases so malformed receipts cannot starve later privacy requests.

## 7. Diligence Risks

- A reviewer will ask why newer clients shipped while backend production proof remained weeks old.
- They will challenge whether dozens of workflows are reliable controls or automation theater.
- They will ask for named owners and recovery SLO evidence for every protected deployment plane.
- They will question the economics of maintaining Android, iOS/macOS, Windows, Linux, web,
  Functions, extensions, and hosted services with duplicated domain logic.
- They will require evidence of secret rotation and closure of the old preserve-tag exposure, plus a
  plan for the lagging vendored libsignal fork.
- They will expect repository/artifact retention policy after observing large tracked evidence,
  roughly 322 MB of tracked `.glb` assets, and about 35 MB of tracked documentation. Historical
  machine/fleet pack and branch counts are not treated as intrinsic repository measurements.
- They will note that Cloud Run has a separated build/deploy trust boundary while the Functions
  workflow still checks out and builds repository code inside the tag-bound WIF-capable job.

## 8. Hidden Rewrite Risks

1. **Windows sharing seam:** one C-ABI export beside a large C# reimplementation is neither a real
   shared kernel nor an explicitly governed independent port.
2. **Daemon/Core boundary:** linking a UI-carrying Core into the daemon increases build weight,
   actor/concurrency complexity, and extraction cost.
3. **Mission authorization:** split ownership can produce policy disagreement and security bugs as
   capabilities expand.
4. **Schema/migrator authority:** equality gates now stop silent drift, but duplicated authorities
   keep change cost high until single-sourcing is completed.
5. **FTS and retention:** current local fixes do not remove the need for indexed deletion,
   trigger-aware updates, and lifecycle policy before data volume grows.
6. **Rules monolith:** the tested but very large Firestore rules file is approaching a human review
   ceiling and will become harder to reason about with every product surface.

## 9. Top 10 Highest-Leverage Improvements

1. Restore production deploys and exact-revision readback; freeze releases until they are green.
2. Make red full-harness/P0 state block normal merge or release activity after a short recovery SLO.
3. Land the remediation branch with protected evidence, then verify erasure and metering in rings.
4. Assign one accountable owner per proof plane and add deploy freshness, green-harness age, P0 age,
   and repair-loop noise to the generated debt metrics.
5. Resume daemon/UI-Core and mission-authorization structural paydown with declining ratchets.
6. Decide the Windows strategy: expand the shared kernel/C-ABI or govern a deliberate independent
   implementation with semantic conformance suites.
7. Execute the v55 data plan: indexed FTS maintenance, trigger-aware updates, retention, and GC.
8. Single-source database migrations and shared schema models instead of validating hand-copied
   twins indefinitely.
9. Close secret-rotation and libsignal ownership/update risks with auditable evidence.
10. Introduce repository evidence/artifact lifecycle policy and remove stale branches/binaries from
    the normal source-control path.

## 10. Appendix

### Evidence inspected

- Repository policy and manifests: `AGENTS.md`, `project.yml`, Swift packages, npm lockfiles,
  Gradle configuration, Dockerfiles, Firebase config, and `.github/workflows/`.
- Critical implementation paths: `AgentLens/Services/ComputerUse/`,
  `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/`, `functions/src/`, Firestore and Storage
  rules, migration scripts, Linux release tooling, and Android data/build paths.
- Operational documentation: `docs/runbooks/`, `docs/ARCHITECTURE/`, privacy/schema docs,
  `TECH_DEBT_METRICS.md`, and `TECH_DEBT_AUDIT_2026-07-09.md`.
- Live GitHub evidence observed 2026-07-10: Full Harness `29089443236`, Nightly E2E
  `29091929862`, CodeQL `29091577027`, DAST `29093054422`, latest main Functions success
  `27775189384`, latest main Cloud Run success `27780862409`, and failing Firestore deploy
  `29027762247`. At observation time the full harness had three terminal failures and DAST had
  failed all three substantive lanes.

### Representative verification

- Functions: lint/build, 1,176 passing Vitest cases (4 skipped), and the account-deletion retry
  harness passed.
- Rules: Computer Use **25/25** and Storage **19/19**; account-erasure barrier passed.
- Native: focused Core/app/daemon tests and stable-Xcode macOS build passed.
- Android: JVM suite and detekt passed.
- Gate integrity: 36 Node policy cases, 15 Linux verifier tests, Actionlint, no-suppression,
  diff-coverage self-tests, RPC canon, migration catalog, repair provenance, and deploy-auth passed.
- Duplication: 3,666 Swift/Kotlin/TypeScript files analyzed; 4.51% duplication.
- Linux: manifest/graph validation passed. The first amd64-container run passed Core **14/14**,
  Security **11/11**, Data **6/6**, and Vectors **5/5** before exposing and stopping on a daemon
  cross-platform compile defect. After that defect was fixed, the daemon compiled and passed
  **14/14** in a targeted container run. A single all-target rerun is locally blocked by a
  reproducible async XCTest hang under amd64-on-arm64 QEMU; the hosted arm64 lane remains the
  authoritative end-to-end proof.

### Bottom line

If this repository were shown to excellent engineers and Series A investors tomorrow, they would be
**both impressed and nervous**. The engineering ceiling is high. The present operating discipline is
not yet high enough to make the launch or diligence case credible.
