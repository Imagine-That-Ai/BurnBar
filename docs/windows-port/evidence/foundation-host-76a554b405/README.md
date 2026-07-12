# Windows foundation host evidence: 76a554b405

This receipt records the exact-candidate Windows 11 ARM64 UTM evidence run for
the Windows parity implementation. The full screenshot/UIA bundle remains an
external validation artifact identified by its content hash; secrets and
disposable scenario profiles are not committed.

## Candidate provenance

- Commit: `76a554b405526df00d8d33f547ca04d84e58ab34`
- Tree: `80de10adad15021584fa5f8e9bba4d6a2548cd08`
- Tracked files: `10252`
- Archive SHA-256: `63886931f3fe6ce4e7341312fb14df165d09be5790c86a12ed80a7523775afb3`
- Manifest SHA-256: `fd18f3414fd9548455ca9cf648c9b82c80d30374af6c356ebb2f2ce7600edda6`
- Manifest payload SHA-256: `32370f0899561f4da3cacad3dead648359bc431c11429960784622af862a7cd8`

## Import and execution

- Import verification: passed, `10252 / 10252` files checked, `0` mismatches.
- Independent post-import verification: passed, `10252 / 10252` files checked,
  `0` mismatches.
- Foundation manifest: passed.
- Runner stages: `4 / 4` exited `0`.
- Required scenarios: `53 / 53` captured, `0` missing.
- Interactive UIA: `14 / 14` captured in desktop session `1`, `0` failed.
- Fail-closed checks: `0` missing rows, `0` failed commands, `0` secret
  findings, no session-0 UI, and no stale-candidate condition.
- Canary secret scan: passed with `3` canaries and `0` findings.

## Bundle

- File: `openburnbar-foundation-evidence-76a554b40552.zip`
- Size: `2726986` bytes.
- SHA-256: `8d5e4223eb200476a859f0de37a777a6e0b34da70dd58d14bf1182c785ee26b0`
- Independent validator: `PASS: Windows foundation host evidence manifest is complete.`
