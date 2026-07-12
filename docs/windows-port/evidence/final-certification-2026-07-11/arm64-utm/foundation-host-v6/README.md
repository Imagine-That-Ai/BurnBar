# Foundation host evidence v6

This directory records the decisive Windows 11 Pro ARM64 UTM pass for exact
foundation candidate `778e735a69ea9d812db87146630223ac1a3a49d7`, tree
`97a56caca0f60cf62ecb027f24334899d21d2f72`.

The run captured 53/53 required scenarios, including 17 process scenarios and
14 interactive UIA scenarios in signed-in session 1. The final manifest indexes
94 artifacts with no missing scenarios and zero secret findings.

## Evidence map

- `candidate-tree-verification.json`: 10,475/10,475 imported files verified.
- `signed-candidate-import-verification.json`: the corrected signed runtime
  candidate's 10,477/10,477-file ARM64 import with zero mismatches.
- `foundation-host-wrapper.json`: runner identity and collector hash binding.
- `foundation-host-evidence-manifest.json`: scenario and artifact integrity
  index, including hashes for deliberately uncommitted PNG captures.
- `interactive-result.json`: aggregate interactive actor, action, and scenario
  result.
- `interactive-uia/scenarios/`: all 34 manifest-indexed UIA tree and route-result
  JSON artifacts, byte-for-byte matching the manifest hashes.
- `process-evidence-redacted.json`: all 17 process scenarios. The only transform
  replaces 34 `C:\Users\<signed-in-user>` path prefixes with `%USERPROFILE%`.
- `chat-host-artifact-index.json`: compact mapping from chat scenario IDs to
  their artifact paths, sizes, and hashes.
- `artifact-secret-scan.json`: three canaries tested, zero findings.
- `host-evidence-provenance.json`: candidate lineage, collector binding, host
  identity, raw hashes, committed hashes, and redaction receipt.

The corrected signed runtime candidate is the exact descendant
`9dbcaa791794944326ce9ffb18ed4d9771f31ecc`. Its package lifecycle receipts live
one directory above and are not represented as evidence from the foundation
candidate. Git ancestry establishes `778e735a` as its merge base and ancestor.
The eight-file delta is confined to release workflows, candidate export and
evidence tooling, and MSIX packaging/lifecycle gates; no Windows app/product
source file differs.
