# physical-performance-x64 blocker

- id: EXT-PHYSICAL-WINDOWS-X64
- status: BLOCKED
- owner: Alberto
- missing: A named physical Windows 11 x64 device with GPU, display, power, TPM, and signed exact-candidate artifact is not attached to this macOS session.
- recovery: Run run-physical-release-certification.ps1 on the physical x64 device with the signed artifact manifest and hardware attestation; capture WPR/ETW, counters, frame pacing, lifecycle, and soak evidence.
- capturedAtUtc: 2026-07-11T21:22:45.773Z
