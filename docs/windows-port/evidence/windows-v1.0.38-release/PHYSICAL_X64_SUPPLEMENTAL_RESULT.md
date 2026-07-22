# OpenBurnBar v1.0.38 physical Windows x64 supplemental result

Overall verdict: **NO-GO**. The evidence validator passes, but certification is not complete because several required protocols remain blocked.

- Machine: HP ENVY x360 2-in-1 Laptop 15-ew0xxx; Intel x64/AMD64; Windows 11 Home build 26200; asset tag CND2360WQ8.
- Candidate commit: `48837746490b6468efa4dc06a476f305d496039c`.
- Independent harness commit: `ddd839cf2719d2b3f54bce0d13d880c244d0d26d`.
- Signed artifact: `OpenBurnBar-1.0.38-x64.msix`; SHA-256 `fd14adb0870473f907c10f342eb3ee300cebf39c500848505a5887ad89602e69`.
- Authenticode: Valid; signer exactly `CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US`; RFC 3161 timestamp certificate present.

## Gates

- `local-automated-checks`: PASS — Release build and full solution tests passed after the exact signed package native domain-core DLL was supplied to ignored test output; no source was changed.
- `accessibility-display`: BLOCKED — fresh route/UIA captures passed 26 routes, but signed-package semantic capture is unavailable and physical Narrator, keyboard-only, 150%/200% DPI, high-contrast, reduced-motion, and mixed-DPI observations remain outstanding.
- `physical-performance-x64`: BLOCKED — signed-package soak passed 180/180 samples over 30 minutes with zero crashes, zero hangs, and zero matching crash events; the complete 18-measurement receipt is not complete because sleep/wake, Explorer recovery, interaction measurements, and approved frame-pacing capture remain outstanding.
- `staging-cloud`: BLOCKED — `burnbar-staging` baseline values match, but the Remote Config GET response supplied no ETag, so the committed fixture helper correctly refused mutation. Recovery: restore ETag/concurrency support, run Baseline/ComputerKill/MediaKill/MalformedSystem, then restore Baseline.
- `media-computer-use-safety`: BLOCKED — iPhone is detected, but no paired Mac/mobile Computer Use session and approved harmless-fixture protocol were available on this Windows lane.
- `store-update-lifecycle`: BLOCKED — no explicit private-flight authorization; public Store/update systems were not touched.
- `physical-performance-arm64`: BLOCKED — explicit beta limitation; no physical ARM64 claim.

Install/uninstall/reinstall of the exact signed MSIX passed, including a responsive second launch. Only the package installed by this run was removed after evidence capture. No production systems, public rollout, disks, partitions, firmware, or source files were modified.
