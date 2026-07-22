# Post-fix macOS-reachable certification run

- Schema: `openburnbar.windows.release-certification-bundle.v1`
- Source commit recorded by the run: `949cdd8b6f923fc2d3ee415ee8c461e677bdb4da`
- Source tree: dirty because the earlier test runs left generated `windows/tests/b0-spike/TestResults/` and `windows/tests/chat/TestResults/` directories; those generated files are not part of this evidence commit.
- Surface: macOS authoring host only; this is not Windows x64, Windows ARM64, VM, or physical certification.
- Command matrix: 50 commands, 50 passed, 0 failed, 0 timed out.
- Defect fixed before this run: `e0c0678aed` now terminates an unbounded chat producer when stdout/stderr drain reports the output-limit failure. The post-fix aggregate solution, B0 spike, and full chat suites pass.

The local automated receipt is a supporting PASS. The six release gates requiring physical Windows hardware, manual accessibility, live staging accounts/TPM, paired media/Computer Use devices, or private Store flight remain `BLOCKED` with named reasons. Do not promote any of those statuses based on this run.
