# Cold-native-timeout certification run

- Schema: `openburnbar.windows.release-certification-bundle.v1`
- Source commit: `a364b9ece892f93463d0d804eba47cebe8f4efd0`
- Source tree: clean
- Surface: macOS authoring host only; this is not Windows x64, Windows ARM64, VM, or physical certification.
- Command matrix: 50 commands, 50 passed, 0 failed, 0 timed out.

This run verifies the certification collector after allowing the B0 native spike up to 180 seconds of test inactivity and 360 seconds of process time for cold Swift/native startup. Every other Windows test project retains the 60-second inactivity and 180-second process limits.

The local automated receipt is a supporting PASS. The six release gates requiring physical Windows hardware, manual accessibility, live staging accounts/TPM, paired media/Computer Use devices, or a private Store flight remain `BLOCKED` with named reasons. Do not promote any of those statuses based on this run.
