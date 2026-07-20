# Linux product feature proof contract

The Linux parity gate separates release evidence from environment-specific feature evidence.
Release evidence is produced once by the immutable Linux candidate. Feature evidence is captured
on each row of the seven-environment support matrix and is never treated as a pass by collection
alone.

## Trust chain

1. `product-feature-proof-registry.json` declares the exact artifact roles, media types, and byte
   limits owned by each feature requirement. A requirement may register at most 16 roles, each
   limited to 256 MiB, with a combined declared budget no greater than 512 MiB. These limits are
   checked before any proof payload is read. Larger media must be chunked or gain a separately
   reviewed streaming verifier. The five release-only requirements (`P-01`, `P-03`, `P-04`,
   `P-37`, and `P-38`) cannot register feature roles.
2. `finalize-product-proof-closure.mjs` validates and snapshots that registry into the immutable
   candidate artifact. The aggregate closure records its SHA-256 and size.
3. A requirement capture harness writes only its observed artifacts under
   `feature-artifacts/` and an exact `feature-proof-registration.json` beside the downloaded
   candidate.
4. `finalize-product-feature-proof-closure.mjs` rejects missing, extra, duplicate, oversized,
   symlinked, or unregistered artifacts. Its `collected` closure binds their bytes to the current
   requirement, support environment, source commit, release version, candidate run, candidate
   artifact digest, aggregate product closure, and snapshotted registry.
5. `prepare-product-requirement-input.mjs` revalidates the complete binding and copies the exact
   subjects into deterministic paths under the requirement-owned release closure. The validator
   runner independently receives the trusted run ID and artifact digest from the GitHub resolver,
   requires the current schema, checks the requirement, environment, and selected package itself,
   and byte-compares every materialized feature subject with its immutable source before importing
   a requirement module. Those subjects are mandatory in the validator result, so replacement
   before or during validation fails closed.
6. Only the substantive `P-XX.mjs` validator may interpret the captured artifacts and return a
   passed receipt. Feature closure status is deliberately `collected`; it has no `passed` field.

## Adding a requirement

1. Add one sorted requirement entry and its sorted `feature.*` roles to
   `product-feature-proof-registry.json`.
2. Add a capture step before **Finalize registered feature proof closure** in
   `linux-product-parity.yml`. The capture must exercise the installed candidate in the live
   desktop session and write the exact registration manifest.
3. Implement the corresponding validator with semantic assertions for every registered artifact.
4. Add positive and mutation tests for capture, registration, materialization, and validator
   behavior. A screenshot or JSON file existing is not acceptance evidence by itself.

The candidate artifact digest is learned only after GitHub uploads the candidate, so it cannot be
embedded into that artifact without a circular digest. The environment closure supplies that final
binding after the exact candidate is resolved, while the registry SHA inside the candidate prevents
the environment job from changing the accepted artifact contract.

## P-02 parity certification preflight

P-02 captures `feature.parity-certification-preflight` before feature closure finalization. The
report inventories exactly P-01 through P-40, all canonical policies and seven environments,
substantive validator modules, registered capture roles, and release or feature materializer
ownership. It detects missing and duplicate rows, reused validator bytes or capture roles, fixture
implementations, stale candidate bindings, unsupported materializers, and self-reference.

Collection deliberately succeeds with `status: blocked` so the missing ownership is preserved as
evidence. The workflow uploads that JSON immediately as a clearly named, non-promotable diagnostic
artifact even when later validation fails. It is not a validator receipt, is not attested, and
cannot satisfy promotion.

Readiness is declared in the candidate-bound feature registry and requires an exact validator
source, semantic mutation test, capture producer and workflow, and materializer producer and
workflow. Ownership tests are unique to one requirement component. Capture extracts only the
target-commit certification surface into an isolated directory, executes each exact named test in
a controlled environment, replaces only the registry-owned exported entrypoint with a throwing
implementation, and requires the same test to fail. Target-commit symlinks are rejected, dependency
symlinks must resolve inside the copied dependency tree, and every child process has a hard timeout.
Only a normal integer nonzero mutation exit counts; timeout, output overflow, spawn error, or signal
termination remains a failed ownership check. Execution records preserve those process fields and
authenticate both normalized output digests as well as the baseline and mutation exit metadata.
Workflow ownership is parsed as YAML and requires the exact job, step, condition, and run script;
comments, dead branches, swallowed failures, and unrelated steps do not count. The resulting record
binds the source entrypoint and source/test blobs plus baseline and mutation outputs.
The P-02 validator independently repeats that isolated execution instead of trusting execution
claims in the feature proof, then recomputes and validates the inventory. It can pass only when
every one of the 40 rows has executable, mutation-sensitive ownership. A role, policy, empty test,
reused test, workflow comment, untracked helper, or hand-authored passed JSON cannot satisfy a
lane. Ten rows are registered, but target-commit semantic execution currently leaves only P-02,
P-05, and P-40 ownership-ready, with 37 named blockers. Registration is not ownership readiness,
and ownership readiness is not product certification: a ready row still requires passed receipts
from all seven support environments before it contributes to the strict 40/40 claim.

If collection itself fails, the capture producer atomically leaves a non-promotable
`capture-failed` diagnostic in a runner-owned `mktemp` directory, even when the downloaded input
tree or a repository `.linux-parity-diagnostics` path is hostile or unwritable. The capture step
publishes that exact temporary path as a step output; the `always()` upload consumes that path and
preserves both the diagnostic and combined output log. Neither file is registered as feature
evidence or accepted as a validator receipt.

## P-38 release automation certification

P-38 is release-owned because its acceptance subjects are produced by the immutable candidate,
not by a desktop-specific feature harness. Its materialized closure contains both architecture
sessions, aggregate package lifecycle smoke, provenance, the complete detached-signature and
Sigstore matrix, and a candidate-bound workflow-verification proof.

Before materialization, `capture-p38-release-automation.mjs` independently verifies the current
PR, nightly, candidate, product-parity, and promotion wiring and executes the workflow mutation
suite. The proof binds every inspected source byte to the target commit, environment, candidate
run, and immutable candidate artifact digest. The P-38 validator repeats the wiring verification
and rejects stale sources, a partial signing matrix, missing architecture sessions, blocked smoke,
or update/rollback records that do not name a distinct older version and the exact candidate.
Capture and materialization delete stale outputs first, so a forced workflow or mutation failure
cannot leave a reusable passed receipt.
