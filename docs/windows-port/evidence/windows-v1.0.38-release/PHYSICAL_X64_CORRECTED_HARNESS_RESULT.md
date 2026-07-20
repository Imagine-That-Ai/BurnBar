# OpenBurnBar v1.0.38 physical Windows x64 corrected-harness result

Overall verdict: **NO-GO**. The physical run preserved the exact signed
candidate and produced useful launch/UI evidence, but the final archive is not
validator-clean under the current harness.

- Machine: HP ENVY x360 2-in-1 Laptop 15-ew0xxx; native Intel x64/AMD64.
- Candidate commit: `48837746490b6468efa4dc06a476f305d496039c`.
- Declared harness commit: `37d88056066d876570df4b2887f33df7af7ebe56`.
- Signed artifact SHA-256: `fd14adb0870473f907c10f342eb3ee300cebf39c500848505a5887ad89602e69`.
- Authenticode: Valid; exact Imagine That AI LLC signer; RFC 3161 timestamp present.
- Evidence ZIP SHA-256: `dc9e37b1df2499528b8baa9587e3b6b93c5ac1151483486222bd6d162d620746`.
- ZIP integrity: PASS.
- Current independent evidence validator: **FAIL** because
  `operator-evidence/validator-final.log` is present in the final archive but
  absent from `SHA256SUMS`.

The exact signed package launched responsively for all 20 samples and was
removed afterward. `local-automated-checks` passed. Accessibility/display,
physical x64 performance, staging cloud, media/Computer Use safety, and
Store/update lifecycle remained blocked. Physical ARM64 remains an explicit
beta limitation.

The run also exposed two harness defects:

1. Firebase returned an unquoted Remote Config ETag. The PowerShell/.NET typed
   ETag property discarded it even though the raw header was present.
2. The certification runner invoked the independent script checkout but still
   compiled the UI Automation harness project from the old candidate checkout.

PR #1875 corrects both defects and makes the runner checksum its own final
validator log before the last validation. A fresh, exact-harness physical run
is required; this archive must not be relabeled as a validator PASS.

No production system, public rollout, Store listing, disk, partition, firmware,
source checkout, or VM was modified by the physical run.
