# P-07 browser computer-use proof

P-07 is not certifiable from the historical mission summary or from simulator-only fixtures. The feature proof must come from an installed-native session for the exact release candidate and current checkout.

## Capture input

Place a live session report and every artifact it references under:

`docs/linux-port/evidence/product-parity-inputs/P-07/<environment>/`

The report uses `openburnbar-linux-computer-use-session-v1` and must bind:

- the exact `targetHead`, candidate run ID, and candidate artifact SHA-256;
- an installed candidate executed through the Playwright Chromium backend;
- a physical iPad, iPhone, or Android controller;
- all six P-07 targets as installed-native passes;
- `VAL-CU-003` to the passing `VAL-CU-002` prerequisite;
- each target to non-empty, hash- and size-checked evidence inside the same P-07 input root;
- every rejection-policy field to `false`.

Run the capture after the live harness finishes:

```bash
node scripts/linux-port/capture-p07-computer-use-proof.mjs \
  --input-root docs/linux-port/evidence/product-parity-inputs/P-07/<environment> \
  --session-report docs/linux-port/evidence/product-parity-inputs/P-07/<environment>/live-session/computer-use-session.json \
  --environment <environment> \
  --target-head <git-sha> \
  --candidate-run-id <run-id> \
  --candidate-artifact-digest sha256:<artifact-sha256>
```

The command deletes stale P-07 proof outputs first, verifies the checkout and all live inputs, then writes:

- `feature-artifacts/p07-computer-use-proof.json`
- `feature-proof-registration.json` with the single `feature.computer-use` role

The shared feature-closure and requirement-input materializers can consume these files after P-07 is added to the product feature proof registry. Registration and workflow isolation remain separate ownership gates; this capture alone does not make P-07 ownership-ready.
