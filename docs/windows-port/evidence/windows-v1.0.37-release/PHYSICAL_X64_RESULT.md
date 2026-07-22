# Windows v1.0.37 Physical Intel x64 Result

**Verdict:** **NO-GO**

This receipt records the completed physical Intel x64 campaign for exact signed
candidate `windows-v1.0.37`. It is a documentation pointer to the external,
content-addressed evidence bundle; the large binary ZIP is intentionally not
committed to Git.

## Identity

- Machine: HP ENVY x360 2-in-1 Laptop 15-ew0xxx
- Native architecture: Intel AMD64/x64
- Candidate commit: `2757652e89440eb647d21721895fc61ec89935d3`
- Harness commit: `00d0751f1c671d99fe7ef8f4059e91d689a30f44`
- Direct MSIX SHA-256: `63a9c374bb8d817f4642ddbcbc1c4847d5bcc0388d40fdac4c45b202e7e64bd9`
- Signature: valid; exact Imagine That AI LLC signer; valid RFC 3161 timestamp
- Evidence ZIP SHA-256: `ba03236c7f2b0c018f9639a42e344e691d91ac7c5cfd28f9e3bd0effd5854eb9`
- Laptop canonical path: `C:\BurnBar-cert\windows-v1.0.37\windows-v1.0.37-physical-x64-evidence-ba03236c7f2b0c018f9639a42e344e691d91ac7c5cfd28f9e3bd0effd5854eb9.zip`
- Removable-drive directory: `BurnBar-cert/windows-v1.0.37-physical-x64-result-20260718-182704Z/`

## Passed evidence

- Exact candidate binding, artifact hash, Authenticode identity, and timestamp
- Clean install, uninstall, reinstall, normal launch, cold launch, and Explorer restart
- Local automated checks
- Final evidence-bundle validator
- 30-minute soak: 1,800 samples; no crash, hang, unresponsive sample, or retained memory growth
- Five-minute idle: 2.018% average CPU, 0.316 MB/min disk writes, 168 MB maximum private memory
- GPU: 15.116% p95, 17.153% maximum

## Release blockers

1. The native WebView2 and Win2D composition layers cover the signed
   Providers/dashboard XAML. Disabling both layers exposes the content only as
   a diagnostic override and is not a PASS.
2. Focusable header and top-tab controls lack accessible names.
3. Top navigation clips at a 640-pixel window width.
4. A Pretext not-ready path emits an unobserved task exception.
5. Physical performance cannot pass without the required interactive workload
   against a usable UI.

Accessibility/display, staging cloud, media/Computer Use safety, and
Store/update lifecycle remain blocked for this exact candidate. Physical ARM64
remains an explicit beta limitation.

## Remediation boundary

PR #1854 contains the source fix and regression coverage. It does not alter
this receipt or authorize release of v1.0.37. Produce a newly signed successor,
verify its artifact identity, then rerun the complete physical protocol.
