# Post-review macOS-reachable certification run

- Schema: `openburnbar.windows.release-certification-bundle.v1`
- Source commit: `349a34e7d86aeec7ab8e0c3b38f061b5887adec1`
- Source tree: clean
- Surface: macOS authoring host only; this is not Windows x64, Windows ARM64, VM, or physical certification.
- Command matrix: 50 commands, 50 passed, 0 failed, 0 timed out.

This run follows the certification review fixes for gate/receipt identity, source-commit binding, fail-closed GO derivation, physical architecture enforcement, live hardware-attestation matching, accessibility supplemental receipt import, quoted-secret redaction, and chat drain failure monitoring.

The local automated receipt is a supporting PASS. The six release gates requiring physical Windows hardware, manual accessibility, live staging accounts/TPM, paired media/Computer Use devices, or a private Store flight remain `BLOCKED` with named reasons. Do not promote any of those statuses based on this run.
