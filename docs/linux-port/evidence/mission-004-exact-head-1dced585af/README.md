# Mission 004 — Current-head Nightly shell evidence

Run: [Linux Nightly Matrix #29660228199](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29660228199)
Source: `1dced585af2441ac8ac1d4fdcb2e4666177f0474`
Captured: 2026-07-18 UTC

This directory contains small, ranged extracts from the immutable Ubuntu
GNOME/X11 artifact. The full screenshots, logs, package, and raw shell
transcript remain in GitHub artifact `8435091387`; the 155 MB artifact was not
copied into this worktree.

The X11 row ran Ubuntu 24.04.4 aarch64 under Xvfb/X11 with XFCE/openbox. It
passed the packaged 19-route session, daemon health, accessibility, onboarding,
text-expansion, and all four native performance budgets. The matched nightly
workload also passed all four checksum/parity/resource checks.

The three Wayland/wlroots rows are intentionally declared blocked in the
workflow, so their successful workflow jobs mean the blocked-row contract was
honored; they are not compositor parity receipts. The fail-closed parity ledger
therefore remains `0/40` product rows and `0/7` environment receipts.
