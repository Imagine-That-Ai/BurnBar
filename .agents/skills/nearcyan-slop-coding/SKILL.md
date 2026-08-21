---
name: nearcyan-slop-coding
description: Prevents weak specs, subagent unverified delegation, lazy orchestration, and hand-wavy verification. Enforces strict contracts, intermediate evidence checks, and end-to-end validation.
---

# Anti-Slop Orchestration & Coding (@nearcyan)

Eliminates the "slop coding" loop: launching agents or sub-tasks with underspecified prompts, trusting superficial status responses without inspecting raw output, and assuming composite tasks succeeded without verifying concrete artifacts.

---

## 1. The Slop Orchestration Anti-Patterns

1. **Vague Delegation:** Passing loosely phrased goals to subagents ("Refactor the auth system and make it cleaner") without explicit boundaries, expected types, and success criteria.
2. **Blind Trust in Status Reports:** Accepting "Task completed successfully!" from a subagent or script without checking modified files, compiler output, or test execution logs.
3. **Cascading Hallucination:** Agent A invents an API contract, Agent B writes code targeting the fictional API, and neither runs the compiler to verify.
4. **Superficial "Looks Good":** Checking that a process exited with code 0 without verifying that it produced the expected output artifacts or side-effects.

---

## 2. The Rigid Spec & Verify Standard

### Phase 1: Crisp Contracts Before Execution
- Every task or subagent call must define:
  - Exact inputs, target file paths, and interfaces.
  - Invariants that must remain true.
  - Acceptance criteria and exact verification command.

### Phase 2: Mandatory Intermediate Evidence
- Never proceed based on text claims alone.
- Verify file modifications with git diff or file inspection.
- Inspect exit codes AND stdout/stderr for warnings or partial failures.

### Phase 3: End-to-End Grounded Verification
- Run the real compiler, linter, or test suite directly.
- Inspect the generated artifact (binary, bundle, DB migration, rendered HTML) to confirm it is non-empty, well-formed, and functioning.

```
[Agent Request] ➔ [Rigid Contract + Invariants] ➔ [Execute] ➔ [Raw Diff & Output Check] ➔ [Independent E2E Verification]
```
