# Windows v1.0.37 ARM64 VM Evidence

- Classification: PASS for applicable Windows 11 ARM64 VM validation
- Physical ARM64 certification: not claimed
- Source commit: `2757652e89440eb647d21721895fc61ec89935d3`
- Release workflow: `29650389335`
- ARM64 MSIX SHA-256: `70de3a3dbd22fc51b21346d8d213532601ee79bb234be66c8998b86bf6b01918`
- ARM64 portable ZIP SHA-256: `72bf88caa615a8a08ccb5e17742e992927987f99aab58d011b33dd8b32d89865`
- Evidence ZIP SHA-256: `7cb325721430934d765cf32d115bcbf027e23f18589a41b0b1f653d2b1357e95`

Observed results:

- Authenticode signer and Microsoft RFC 3161 timestamp verified.
- Direct MSIX clean install, responsive 20-second launch, uninstall, reinstall,
  and second responsive 20-second launch passed with zero crash events.
- Portable native layout contained both required Swift resource bundles and
  passed a responsive 20-second launch with zero crash events.
- The exact UI Automation rerun passed 25/25 route/scenario runs, including
  semantic UIA, high contrast, reduced transparency, 100% DPI, and input-safety
  contracts.
- A 30-second VM diagnostic soak remained responsive with zero crash events.

The certification runner correctly returned `NO-GO` for physical release
because QEMU/UTM cannot satisfy physical ARM64 performance, physical Narrator,
or mixed-DPI/multi-monitor requirements.
