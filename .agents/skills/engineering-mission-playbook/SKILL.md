---
name: engineering-mission-playbook
description: "Use when planning or replanning engineering missions that create, change, port, migrate, integrate, or preserve durable codebase behavior across UI, API, CLI, background jobs, data/migrations, libraries, or operator workflows. Defines investigation, scope inventory, coherent VAL-* contracts, evidence floors, multi-target task topology, engineering validation, root-cause patching, and durable guidance. For pure metric search, use optimization-mission-playbook instead."
---

# Engineering Mission Playbook

## 1. Engineering Success Invariants

Engineering success means the accepted user, caller, operator, or consumer-visible behavior is implemented, preserved, and independently proven on the real surface. Code motion, file diffs, worker claims, green commands, or task completion are not success by themselves.

Success requires:

- accepted scope is preserved through `mission.md` or the current scope charter, the scope/capability inventory, live `VAL-*` assertions, or explicit accepted non-goal/risk decisions;
- every user-mentioned engineering requirement is represented in the inventory and contract unless explicitly removed by the user or a recorded decision;
- contract assertions define the mission's done criteria; task bodies and skills may explain how to work, but they must not hide acceptance promises;
- real user/caller/operator surfaces are tested whenever they exist: browser/UI behavior through an actual browser, APIs through real requests, CLI/TUI behavior through real commands or terminal interaction, background jobs through real triggers and outputs, generated artifacts through real generation and consumption, migrations/data behavior through actual before/after state, and public libraries through real imports/calls;
- validation covers the full requested behavior surface, including common paths, edge cases, error paths, empty states, retries, persistence, compatibility, permissions, unusual but plausible cases, and narrow or low-frequency behaviors that are still part of the accepted scope;
- automated test coverage must include relevant unit, integration, regression, fixture/golden, end-to-end, and system-level checks when those layers exist or are needed to prove the assertion;
- for porting, parity, compatibility, or drop-in replacement missions, the target must pass the relevant original/source test suite, golden corpus, differential command/API checks, and compatibility examples for the accepted source version, unless a specific divergence is explicitly accepted and recorded;
- task topology groups implementation effort without changing assertion granularity, ownership clarity, evidence requirements, or verdict clarity;
- many atomic assertions may map to fewer coherent work tasks when implementation boundaries are shared;
- every live assertion has exactly one active owning `work` task that completes it, not merely contributes to it;
- validators prove assertions independently through the surface and evidence required by each assertion;
- `Needs` and `Evidence` fields are binding: unmet prerequisites, missing evidence, skipped assigned targets, wrong validation surface, or incomplete source-suite parity means blocked or failed, not passed;
- automated tests, source inspection, worker-authored specs, and green commands are supporting evidence unless the assertion names them as the oracle;
- gates and closure claims seal only evidence-backed assertions or explicit accepted-risk/scope decisions.

Do not accept a mission as successful when only happy paths pass, only worker-authored tests pass, only source inspection looks correct, or only a small manually chosen subset was exercised while requested real surfaces, rare cases, compatibility behavior, or source-suite parity remain unproven.

Honest failure is allowed. Do not convert missing setup, weak oracle, broad contract, bad task topology, unavailable evidence, incomplete test coverage, repeated worker miss, or changed scope into a speculative pass, weaker validator method, vague assertion, or late scope shrink.

## 2. Operating Order

Use this playbook in order. Do not write contract files, task lists, project skills, or durable guidance until investigation has produced an evidence-backed engineering mission model.

On a planning wake, follow this order:

1. **Confirm engineering boundary**: identify which parts of the request are durable engineering behavior, which parts belong to another playbook, and where mixed-domain boundaries sit.
2. **Investigate**: gather evidence for requirements, codebase structure, real user/caller/operator surfaces, environment, setup, existing tests, source baselines, oracles, and fake-pass risks.
3. **Prove validation readiness**: confirm that the intended validation surfaces can actually run. For UI, verify browser access; for API, verify real request paths; for CLI/TUI, verify real commands; for data/migrations/jobs/artifacts, verify setup and observable outputs; for porting/parity, verify access to the source/original suite, golden corpus, or differential oracle.
4. **Write or update the mission scope charter**: capture accepted scope, strategy, expected functionality, setup, infrastructure, validation approach, non-functional requirements, risks, and accepted scope cuts.
5. **Build the scope/capability inventory**: enumerate every requested behavior, workflow, command, endpoint, page, public API, job, artifact, data state, compatibility surface, edge case family, and non-functional promise that must be covered or explicitly decided out of scope.
6. **Author `VAL-*` contract assertions**: convert the inventory into compact, falsifiable validation targets with `Surface`, `Needs`, `Behavior`, and `Evidence`.
7. **Review the contract adversarially**: use `contract-review` before task planning. Fix missing coverage, broad buckets, unverifiable evidence, shortcut paths, and inventory-to-contract mapping gaps before continuing.
8. **Define the validation floor**: choose scrutiny, real-surface, parity, source-suite, golden, regression, or project-specific validation methods required for each assertion or milestone.
9. **Design team and skills**: choose existing skills or create project skills for recurring worker/validator procedures, setup rules, oracle use, handoff requirements, and shortcut checks.
10. **Plan task topology**: create current-runtime `work`, `validate`, and `gate` tasks from the reviewed contract. Preserve many atomic assertions mapped into fewer coherent work tasks when implementation boundaries are shared.
11. **Submit and execute through runtime**: call `submit_plan`, then drive work with `advance_project`. Do not implement product behavior in the orchestrator.
12. **Patch from evidence**: when attention, failures, or new evidence appear, diagnose the root cause and patch the earliest invalid artifact.
13. **Curate durable memory**: update `mission.md`, inventory, contract files, task list, project skills, `AGENTS.md`, `MEMORY.md`, and decisions when their old content would mislead later agents.
14. **Close only from evidence**: close only after assertions, validation, gates, source-of-truth consistency, and runtime closure support the claim.

On an attention or replan wake, do not resume from the current symptom. Trace the issue back to the earliest invalid step in this order. A failed validator may mean bad implementation, but it may also mean missing inventory coverage, weak contract, missing setup, wrong oracle, wrong task topology, stale skill, weak validation method, or changed scope.

Investigation, decomposition, contract authoring, validation-readiness checks, and task design are planning responsibilities. Do not hide them as runtime `work` tasks merely to postpone thinking.

## 3. Investigation And Scope Inventory

Investigation is planning work. Do not create runtime `work` tasks for generic repository analysis, architecture mapping, test discovery, verifier discovery, source-suite discovery, feature enumeration, or task decomposition. Resolve those questions before `submit_plan`.

Before contract authoring, build an evidence-backed engineering mission model from primary sources:

- **Requirement surface**: real actor, workflow, user/caller/operator actions, expected results, success states, empty states, error paths, retries, cancellation, recovery, permissions, compatibility expectations, non-functional requirements, constraints, non-goals, and accepted divergences.
- **Codebase surface**: entry points, modules, public APIs, commands, routes, pages, jobs, migrations, generated files, data flows, dependency boundaries, existing conventions, and likely edit surfaces.
- **Verification surface**: existing tests, unit/integration/e2e suites, fixtures, factories, golden files, source baselines, regression suites, browser/API/CLI validation paths, manual flows, known flakes, and what each can or cannot prove.
- **Environment surface**: install commands, package managers, runtime versions, build commands, services, ports, databases, queues, browsers, credentials, seed data, external accounts, supported platforms, resource limits, and cleanup requirements.
- **Oracle surface**: source implementation, original test suite, compatibility suite, golden corpus, differential command/API examples, scoring verifier, reward script, benchmark harness, rubric, or accepted external reference.
- **Risk surface**: fake-pass routes, mocked proof, hardcoded examples, changed oracles, skipped rare cases, stale generated artifacts, hidden state, auth/authz, concurrency, idempotency, migration safety, data integrity, source-to-target drift, and hidden edge cases.

Use bounded `investigator` lanes for non-trivial missions. A mission is non-trivial when it spans multiple surfaces, changes public behavior, preserves compatibility, ports behavior, depends on an external oracle, needs validation setup, has unclear scope, or likely needs more than one coherent worker session. Give each lane one focused question, why it matters for contract quality, exact paths or surfaces, non-goals, evidence to collect, and a stop condition.

For broad, parity, migration, porting, drop-in replacement, product-surface, multi-flow, or ambiguous missions, create a scope/capability inventory before writing `VAL-*` files. The inventory is not the contract and not the task list. It is the coverage map that prevents silent scope shrinkage.

The inventory must enumerate:

- requested capabilities and workflows;
- user/caller/operator actions and observable outcomes;
- commands, endpoints, pages, public APIs, jobs, generated artifacts, data states, migration states, file formats, or integration points in scope;
- common paths, edge cases, rare but plausible cases, error paths, compatibility cases, persistence behavior, and cross-flow behavior;
- constraints, performance/reliability/security/portability requirements, and other non-functional promises;
- accepted non-goals, accepted divergences, deferred-scope candidates, and questions requiring user or parent decision;
- validation surfaces, required evidence, oracles, baselines, setup blockers, and fake-pass risks for each area.

For porting, parity, compatibility, or drop-in replacement missions, the inventory must name the accepted source version or commit, source-to-target surface map, original/source test suite, golden corpus, differential checks, compatibility examples, accepted divergences, and environment required to run both source and target. Missing access to the source suite, golden corpus, or differential oracle is a planning blocker unless the user explicitly accepts the validation risk.

When the workspace includes an external verifier, reward script, scoring test suite, benchmark harness, oracle config, or hidden/public evaluator wrapper, treat it as primary evidence for success. Read the allowed verifier/reward surface before freezing scope. Record scored capabilities, commands, APIs, files, weights, anti-cheat rules, required setup, and known unscored areas. Do not mark scored behavior as out of scope just because it is broad or hard.

After investigation, synthesize the inventory into a planning diagnosis:

- what behavior must be created, changed, preserved, or ported;
- what full behavior surface must be proven, including rare and edge cases;
- what evidence will prove each area;
- which inventory items must become `VAL-*` assertions;
- what setup, oracle, fixture, source suite, validator, or project skill is required;
- what remains unknown, blocked, risky, out of scope, or decision-dependent.

Do not proceed to contract authoring while required surfaces have only generic conclusions. Missing evidence, unknown oracle behavior, unavailable source suites, unclear setup, or ambiguous scope must be recorded as explicit blockers or decisions, not hidden inside vague contract wording.

## 4. Contract Method And Review

Engineering contracts use `VAL-*` assertions. Each assertion is a compact validation target stored as `contract/<ID>.md` under the current runtime mission contract directory. The contract is the engineering definition of done; it is not the task list, not the implementation plan, and not a summary of work packages.

Author contracts from the accepted scope charter, scope/capability inventory, investigation evidence, and actor interaction inventory. Enumerate what the user, caller, operator, or consumer can do, see, click, type, call, run, trigger, retry, cancel, edit, delete, import, export, migrate, recover, or observe. Organize assertions by feature area, surface area, workflow, and cross-area flow when useful.

Do not let task count determine assertion count. A broad mission should normally have many more `VAL-*` assertions than work tasks. One `work` task may later own many related assertions when one coherent implementation boundary completes them. Contract boundaries are chosen by validation coherence, not task topology.

Each assertion should be compact and falsifiable:

```markdown
# VAL-AREA-001: Short user/caller/operator-facing title

Surface: browser | api | cli | tui | job | artifact | data | migration | library | parity | other.
Needs: none | prerequisite assertion/setup/oracle/source baseline/fixture/service.
Behavior: one coherent actor/action/outcome promise or related scenario set.
Evidence: exact evidence a validator must collect.

Fail: optional failure or blocked condition.
Oracle: optional source baseline, golden corpus, compatibility suite, rubric, or authoritative reference.
Scope: optional non-goals, accepted divergences, or adjacent boundaries.
```

`Surface`, `Needs`, `Behavior`, and `Evidence` are required. Use `none` for `Needs` only when no prerequisite is known. Add `Fail`, `Oracle`, or `Scope` when needed to prevent ambiguity, shortcut passing, or silent scope shrink.

Split assertions when grouped behavior would hide unrelated proof, owner, setup, oracle, validator method, milestone boundary, or failure diagnosis. Keep related scenarios together when they share actor, surface, setup, oracle, work owner, milestone boundary, and validators can still give clear evidence and verdicts.

Reject broad bucket assertions such as "refs work", "status works", "API works", "object database works", "migration works", or "UI works" unless the assertion defines the bounded scenario set, oracle, per-scenario evidence path, and failure conditions tightly enough for independent validation.

For cross-area behavior, write explicit `VAL-CROSS-*` assertions. Include first-use flows, actual reachability/navigation, persistence across surfaces, import/edit/export flows, auth/session state, generated artifact consumption, migration-to-runtime behavior, background side effects, recovery, rollback, and compatibility handoffs when relevant.

For porting, parity, compatibility, or drop-in replacement missions, assertions must preserve source behavior through named source version, source test suite, golden corpus, differential command/API/library examples, and accepted divergences. Do not replace source-suite parity with a few handpicked examples unless the user accepts that validation risk.

For each assertion, the `Evidence` field must say what fresh validator evidence proves it: screenshots, console/network observations, request/response traces, stdout/stderr/exit codes, generated files, DB/state checks, logs, golden diffs, source-suite output, compatibility suite output, or differential source/target results. Missing required evidence means failed or blocked, not passed.

Contract review is mandatory before task planning. Use the `contract-review` subagent to review the full contract set against the user request, accepted scope, scope/capability inventory, actor interaction inventory, loaded playbook, evidence floor, shortcut risk, and future task-mapping shape.

For non-trivial engineering missions, run at least two sequential contract-review passes. After each pass, synthesize findings, revise contract files, then review the revised contract again. Do not author or submit the task list while review returns missing coverage, broad buckets, unverifiable assertions, weak evidence floors, shortcut risk, or unresolved inventory-to-contract gaps.

Contract review must check:

- every user-mentioned engineering requirement is covered or explicitly out of scope;
- every inventory item maps to one or more `VAL-*` assertions, an accepted non-goal, or an explicit deferred-scope decision;
- every important actor action and observable outcome is covered;
- edge cases, rare but plausible cases, error paths, empty states, permissions, persistence, compatibility, recovery, migration/data integrity, generated artifacts, public APIs, and cross-area flows are covered when relevant;
- assertions are compact, coherent, falsifiable, and not implementation tasks;
- assertions are not too broad, duplicate, contradictory, unverifiable, stale, or shortcut-prone;
- every assertion has credible `Needs` and `Evidence`;
- source-suite, golden, differential, verifier, or compatibility evidence is present for porting/parity/drop-in surfaces;
- no acceptance promise exists only in task bodies, skills, worker reports, or assumptions;
- the future task topology can assign each assertion to exactly one active work owner without forcing assertion granularity to match task granularity.

The review output is a contract set ready for task planning: coverage gaps resolved, broad assertions split or clarified, stale assertions removed or superseded, validation blockers named, accepted risks recorded, and every live assertion ready to map to one owning `work` task plus independent validation.

## 5. Evidence And Validation

Validation proves `VAL-*` assertions through independent evidence. It does not confirm worker prose, task completion, or optimistic summaries.

Choose validation from the assertion surface and risk:

- `scrutiny-validator`: implementation, diff, tests, fixtures, generated outputs, hard-gate commands, evidence integrity, fake-pass risk, maintainability, and responsibility drift.
- `user-testing-validator`: real user, caller, operator, or consumer surfaces: browser, API, CLI/TUI, background job, generated artifact, migration/data state, public library call, operator workflow, or parity flow.
- Project validator skill: narrow project-specific validation when the assertion, task body, and project skill define the evidence floor explicitly.

For user-visible, caller-visible, operator-visible, generated-artifact, migration/data, public API, CLI, or parity behavior, fresh real-surface evidence is the verdict source. Automated tests, worker-authored E2E specs, source inspection, and green commands are supporting evidence unless the assertion explicitly names them as the oracle.

Validators must parse and honor every assigned assertion field:

- `Surface`: choose the real validation surface named by the contract.
- `Needs`: verify prerequisite assertions, setup, fixtures, services, credentials, source baselines, accepted decisions, and oracles before exercising behavior.
- `Behavior`: exercise the actor/action/outcome promise and relevant scenarios.
- `Evidence`: collect the exact artifacts required by the contract.
- `Fail`, `Oracle`, and `Scope`: apply them when present; do not pass by ignoring boundaries or accepted divergences.

Missing required evidence, skipped assigned targets, unmet `Needs`, unavailable setup, missing source baseline, wrong surface, unverifiable assertion, or evidence artifacts that cannot be attributed to the target mean `passed=false` or blocked attention, not pass.

Use a two-lane validation model for externally observable engineering behavior:

- **Scrutiny lane**: tests, lint/typecheck/build, source review, fixture/golden review, generated-output review, migration safety review, hard-gate commands, and evidence-integrity checks.
- **Real-surface lane**: fresh validator-collected behavior proof through browser, API request/response, CLI/TUI command, job trigger/output, artifact generation/consumption, DB/state transition, public library import/call, or source-target differential.

The real-surface lane carries the verdict for real-surface behavior. The scrutiny lane may fail an assertion on integrity or implementation grounds, but it cannot pass a real-surface assertion by itself unless the contract names scrutiny as the oracle.

For porting, parity, compatibility, or drop-in replacement missions, validation must include the relevant source/original suite, golden corpus, compatibility examples, or differential source-target checks for the accepted source version. Target-only tests and handpicked examples are supporting evidence, not full parity proof, unless the user accepted that limitation.

For UI/browser assertions, evidence should include real navigation or interaction steps, screenshots, console error review, and relevant network observations. For API assertions, include real request/response traces, auth context, status/body/schema, and persistence side effects when relevant. For CLI/TUI assertions, include exact commands or interactions, stdout/stderr, exit code, cwd/env assumptions, and terminal behavior when relevant.

For generated artifacts, migrations, jobs, and data behavior, evidence must prove the real producer and consumer path where applicable: generation command, artifact path, schema/golden/checksum diff, before/after data state, idempotency, rollback/retry behavior, logs/events, and downstream consumption.

When validators use `flow-validator` lanes, each lane must receive exact target ids, contract bodies or paths, isolation resources, evidence directory or artifact prefix, setup/recovery limits, non-goals, and output schema. Parallel lanes must not share mutable state unless isolation is explicit. Parent validators must reject or fail lane results whose evidence cannot be attributed to exact assertions.

Validation cost is scheduling pressure, not permission to weaken the contract. Reduce cost by batching validators that share setup, surface, oracle, isolation, or evidence artifacts, but keep per-assertion verdicts and evidence. Do not broaden assertions or drop rare cases to make validation cheaper.

If required evidence cannot be collected, patch setup, oracle, fixtures, contract clarity, task topology, or validator skill. Do not downgrade the validation method to fit convenient evidence.

## 6. Task Topology

Build the SWE task list after the mission scope, target set, and validation floor are already clear. This section is only about arranging runtime tasks: implementation ownership, parallel execution, tester lanes, ordering, and gates. Do not use task topology to redefine scope.

Use task types deliberately:

- `work`: a coherent implementation or setup unit.
- `validate`: an independent tester lane for a milestone.
- `gate`: a checkpoint after required validation lanes complete.

Create `work` tasks by implementation boundary. Group work when it belongs to the same subsystem, files, setup, behavior, or handoff. Split work when chunks can be owned independently, run safely in parallel, reduce risk, or make debugging and review clearer.

Tasks that do not depend on each other may run in parallel. Use `depends_on` only for real ordering: setup before dependent work, one work task before another when it needs the earlier result, work before milestone validation, validation before gate, and promotion/integration before validation when a candidate was not auto-merged.

Leave work tasks independent only when they can start from the same project state and neither task needs the other's output. Add dependencies when tasks share mutable files, services, fixtures, data, generated artifacts, or behavior that must be integrated before the next task can proceed.

Create `validate` tasks as independent tester lanes for a milestone, not as mirrors of worker tasks. A validator receives the milestone target set and performs comprehensive adversarial testing for its assigned lane. It should act like a real tester: inspect implementation when useful, run real product flows, exercise edge cases, check regressions, verify setup, and collect evidence across the milestone scope.

At the end of a milestone, plan the tester lanes needed to prove the milestone as a whole. Split validators only when the milestone needs distinct tester perspectives, such as implementation scrutiny, real user-surface testing, benchmark/performance validation, security review, migration/data validation, or source/parity validation. Do not create one validator per worker unless the worker boundary is also genuinely the validation boundary.

Create `gate` tasks by milestone. A gate depends on the relevant validators and seals only the milestone targets covered by those validators.

Work task bodies must be comprehensive and detailed enough for a worker to execute without guessing. Include assigned target ids, milestone or slice name, required setup, relevant surfaces/files, behavior to change or preserve, constraints, non-goals, expected output, self-checks, and handoff requirements. Add implementation guidance when it reduces ambiguity.

Validate task bodies must be comprehensive and detailed enough for a tester to verify the milestone independently. Include assigned target ids, tester lane purpose, setup, surfaces or flows to exercise, edge cases and regressions to probe, evidence artifacts to collect, blocked/fail policy, and required per-target verdicts. Make the tester's job clear enough that they can attack the milestone without reconstructing the plan from prior context.

Targetless setup work is allowed only when it enables later implementation work and cannot honestly be folded into a concrete work task. Keep it few, explicit, and dependency-linked.

Avoid one-task-per-target planning unless the implementation boundary is truly that small. Avoid one-validator-per-worker planning unless the validation boundary truly matches the worker boundary. Avoid catch-all work, validator, or gate tasks whose scope is too broad for clear ownership, evidence, or failure diagnosis.

Before `submit_plan`, check:

- each `work` task has a coherent implementation boundary;
- independent work tasks have no dependency between them;
- real ordering is expressed through `depends_on`;
- each milestone has comprehensive tester lanes;
- validators are not created by mirroring workers;
- each gate depends on the relevant validators;
- work and validate task bodies are detailed enough for agents to execute without guessing;
- no task is so broad that ownership, evidence, or failure diagnosis becomes unclear.

## 7. Durable Memory And Artifacts

Use durable memory to preserve operational facts that later workers and validators need without depending on session memory. Engineering missions often discover setup, services, commands, source baselines, oracles, and validation procedures during investigation or execution. Promote the durable parts into the right carrier before more work depends on them.

When reproducing or migrating behavior from an older harness, inspect old operational artifacts such as `init.sh`, `services.yaml`, service manifests, validation scripts, source-suite commands, browser setup notes, fixture setup, and library notes. Do not copy them blindly. Distill the reusable facts and preserve pointers to the original artifacts when useful.

Use carriers by purpose:

- `MEMORY.md`: reusable engineering facts such as package manager, setup sequence, service map, ports, commands, healthchecks, source-suite command, golden corpus path, fixture setup, oracle locations, baseline refs, known flakes, accepted divergences, and validation limitations.
- `AGENTS.md`: normative guidance that all workers and validators must obey, such as port boundaries, off-limits resources, cleanup rules, required command discipline, source-suite requirements, and validation constraints.
- `skills/`: reusable worker or validator procedures when setup, oracle use, source-suite execution, browser validation, migration checks, or artifact generation would otherwise be repeated in task bodies.
- `contract/<VAL-ID>.md`: mission-specific done criteria and evidence requirements.
- `decisions/`: rationale for accepted scope cuts, accepted validation risk, changed setup, deferred source-suite coverage, retry/patch choices, or aborts.
- `attempts/`, `regressions/`, and `evidence/`: raw command output, logs, screenshots, traces, source-suite output, failed reproductions, and forensic records.

Do not paste full scripts, raw logs, or long one-off attempt summaries into `MEMORY.md`. Promote only curated facts, procedures, constraints, and failure lessons that future agents need to act correctly.

If a discovered fact changes how future work should be planned, implemented, or validated, update memory before dispatching more work. If old memory conflicts with current setup, update or supersede it instead of leaving two truths alive.

## 8. Engineering Anti-Patterns

Avoid these failure modes:

- Planning from the user brief alone instead of investigating real behavior, codebase, environment, validation surfaces, and oracles.
- Treating investigation, source-suite discovery, verifier discovery, validation readiness, or task decomposition as runtime `work` tasks.
- Writing contract files before `mission.md` or the current scope charter and scope/capability inventory preserve accepted scope.
- Writing task topology before contract authoring and adversarial contract review.
- Letting task count determine `VAL-*` assertion count.
- Treating `exactly one active owning work task per assertion` as `one assertion per work task`.
- Creating broad contract buckets that hide independently breakable behavior, edge cases, rare cases, source-suite parity, or failure diagnosis.
- Shrinking requested scope through contract wording, task grouping, "later" language, accepted non-goals without decision, or closure prose.
- Putting acceptance promises only in task bodies, skills, worker reports, or assumptions.
- Treating worker reports, worker-authored tests, source inspection, green commands, or validator summaries as proof when the contract requires real-surface evidence.
- Passing validators with missing `Needs`, missing `Evidence`, skipped assigned targets, wrong surface, unverifiable setup, unattributed artifacts, or missing per-assertion verdicts.
- Replacing browser/API/CLI/job/artifact/data/library validation with source-only review when the behavior exists on a real surface.
- Replacing porting/parity/drop-in validation with a few handpicked examples instead of the source/original suite, golden corpus, compatibility suite, or differential oracle.
- Routing pure metric search or benchmark optimization through engineering validation instead of `optimization-mission-playbook`.
- Weakening validation because source suite, browser, services, credentials, fixtures, or oracle setup is hard.
- Batching work, validators, or gates so broadly that ownership, evidence, or failure diagnosis becomes ambiguous.
- Retrying unchanged tasks when the real defect is missing inventory coverage, broad contract, wrong task topology, weak validator method, missing setup, missing oracle, stale memory, or inadequate project skill.
- Updating one source of truth while leaving another with old scope, setup, oracle, validation method, or accepted risk.
- Treating terminal review, mission closeout, or "all tasks completed" as a substitute for evidence-backed validation and gates.
