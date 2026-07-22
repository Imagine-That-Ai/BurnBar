# physical-performance-arm64 blocker

- id: EXT-PHYSICAL-WINDOWS-ARM64
- status: BLOCKED
- owner: Alberto
- missing: A named physical Windows 11 ARM64 device with GPU, display, power, TPM, and signed exact-candidate artifact is not attached to this macOS session; the UTM VM is not physical certification.
- recovery: Run run-physical-release-certification.ps1 on the physical ARM64 device with the signed artifact manifest and hardware attestation; capture WPR/ETW, counters, frame pacing, lifecycle, and soak evidence.
- capturedAtUtc: 2026-07-11T21:22:45.773Z
