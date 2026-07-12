# OpenBurnBar Windows physical-release certification report

**Certification date:** 2026-07-11  
**Independent owner:** Windows physical-release certification lane  
**Overall verdict:** **NO-GO**

This report is a new certification addendum. It does not edit or overwrite the existing parity receipts, PR #1541's signed MSIX lifecycle work, or PR #1542's consolidated evidence worktree.

## Verdict matrix

| Workstream | Verdict | Evidence | Boundary |
|---|---|---|---|
| Physical performance x64 | **BLOCKED** | `blockers/physical-performance-x64.md` | No named physical Windows 11 x64 device and no physical raw performance/lifecycle traces in this session. |
| Physical performance ARM64 | **BLOCKED** | `blockers/physical-performance-arm64.md` | The open ARM64 UTM guest is a VM/vTPM and is explicitly excluded from physical certification. |
| Accessibility/display | **BLOCKED** | `blockers/accessibility-display.md` | No physical signed-in Windows desktop operator run for Narrator, keyboard-only, 150%/200% DPI, OS high contrast, reduced motion/transparency, focus/live regions, or mixed-DPI monitors. |
| Live staging cloud | **BLOCKED** | `blockers/staging-cloud.md` | No configured Windows OAuth client secret names, staging interactive account/permission, enforced live App Check endpoint, or physical TPM claim receipt available. |
| Mercury/media/Computer Use safety | **BLOCKED** | `blockers/media-computer-use-safety.md` | No physical Windows host plus paired Mac/mobile staging peers and permissions for capture, transfer, secure-desktop, kill, audit, and replay proof. |
| Store/update lifecycle | **BLOCKED** | `blockers/store-update-lifecycle.md` | Private Store flight/Partner Center approval and authorized physical lifecycle devices are absent; public release was not advanced. |
| macOS-reachable automated Windows matrix | **PASS** | `post-fix-e0c0678aed/certification-manifest.json` | 50/50 local commands passed after the chat producer-lifecycle fix. This is supporting evidence, not physical certification. |
| Windows-native automated matrix | **PASS** | `windows-native-vm-b271c7d038/certification-manifest.json` | 50/50 commands passed on the Windows 11 ARM64 UTM guest for exact clean source `b271c7d038`; the receipt is explicitly `windows-native-unattested` and cannot satisfy a physical gate. |

## Code and automated fixes

- `6b91539fea` added the fail-closed receipt schema/validator, local matrix runner, Windows physical host collector, explicit hardware attestation requirement, supplemental receipt import, and CI contract checks.
- `e0c0678aed` fixed the real output-limit defect: the chat runner now observes individual stdout/stderr drain faults, cancels the linked process, kills the producer, and completes the stream instead of waiting forever on an unbounded producer.
- `4627abc093` made local collector host identity platform-aware and fail-closed instead of labeling native Windows execution as a macOS authoring host.
- `5d1299e6b7`, `eb08545fae`, and `b271c7d038` retained the existing fast hang limits on macOS/CI while allowing the cold aggregate and Swift-backed B0 paths to finish under x64-on-ARM Windows emulation.
- `b139973282` forced UTF-8 for collector subprocesses so repository-wide Python gates do not fail on the Windows CP-1252 console after completing their scan.
- The post-fix aggregate Windows solution test, B0 spike suite, full chat suite, every discovered Windows `*.Tests.csproj`, packaging verifier, parity ledger, workflow lint, suppression gate, and evidence-validator tests passed in the macOS-reachable matrix.
- The same 50-command matrix then passed natively in Windows with zero failures and zero timeouts; the independently revalidated bundle is committed by `4e4d238387`.

## Distribution artifact references

The following are recorded references only; this bundle does not claim their physical behavior:

- PR #1541 exact signed workflow run `29166970379`, commit `9dbcaa791794944326ce9ffb18ed4d9771f31ecc`, artifact `windows-release-v1.0.29`, with signed x64 package SHA-256 `ac5b63a258c2151c7f1c8f3092ff54720d8c97b375efa38754a2e4a1857e0f43` and signed ARM64 package SHA-256 `7350fd248f65fd9de6eb3b2b5804508d9b47386a9fa0d9028526d70791874d8b`. The run completed successfully; see `reference-artifacts.json`. These signed packages are historical evidence for `9dbcaa7917`, not exact artifacts for the later integrated source.
- PR #1541 merged as `4a155b5dfa`, PR #1546 merged as `1cf8c8c4e3`, and PR #1542 merged as `8ca407b0d6`. PR #1545 remains the open certification/final-integration lane. None of those merge facts closes the physical/manual/staging/safety/public lifecycle gates.

## Evidence bundles and hashes

- Initial pre-fix attempt: `certification-manifest.json` at this directory, source `6b91539fea277f994f0ead990cd55b44ed116d3f`, status `NO-GO`; it preserves the three failing aggregate/chat/B0 observations.
- Post-fix attempt: `post-fix-e0c0678aed/`, source commit `949cdd8b6f923fc2d3ee415ee8c461e677bdb4da`, dirty-tree `true` only because generated `TestResults` directories remained outside the committed evidence; 50/50 commands passed; six release gates remain blocked.
- Windows-native VM rehearsal: `windows-native-vm-b271c7d038/`, exact clean source `b271c7d0387060fb1c040f0047cf0f2ebd8408ac`, Windows 11 build `10.0.26200`, 50/50 commands passed, zero failures/timeouts, and six named external blockers. Its device kind is `windows-native-unattested`, so it cannot retire either physical-performance gate.
- Validate either bundle with:

```bash
node scripts/windows-port/validate-release-certification-evidence.mjs <bundle>
shasum -a 256 -c <bundle>/SHA256SUMS
```

- Provisional performance thresholds are in `performance-budget-proposal.json`. They are not release gates until Alberto approves them; documented dashboard/search SLOs are distinguished from provisional interaction/resource/frame proposals.

## Exact human actions to reach a non-NO-GO verdict

1. Merge PR #1545, then run the Windows release workflow with `allow_unsigned=false` against that exact post-merge `main` commit. Record the workflow URL, artifact manifest, package hashes, verified signatures, SBOMs, and attestations before using the artifacts in any remaining protocol.
2. Provide a named physical Windows 11 x64 device and a named physical Windows 11 ARM64 device, with the exact signed-candidate manifest and operator hardware-attestation receipts. Run the physical-performance protocol and attach WPR/ETW/counter/frame/soak evidence.
3. Supply only the names of configured staging secrets or use an interactive login: a Windows Desktop OAuth client/Web API key, staging Firebase/App Check enforcement access, a staging account, and permission to exercise the physical TPM claim path. Do not paste values into chat.
4. Run the complete Narrator/manual keyboard/display protocol on physical x64 and ARM64 devices, including the 100/150/200% DPI sweep, OS high contrast, reduced motion/transparency, focus/live regions, and mixed-DPI multi-monitor cases.
5. Pair a physical Windows host with Mac/mobile staging peers and run the harmless Mercury/file-transfer/Computer Use safety fixtures, including protected-target/secure-desktop denials, permission revoke/recovery, quarantine/MOTW, panic/watchdog/kill switches, audit-chain tamper, and phone replay rejection.
6. Obtain Microsoft Partner Center reservation/private-flight approval and run authorized Store/direct-download/update/rollback/repair/uninstall/reinstall lifecycle checks. Do not publish broadly or advance rollout without explicit approval at that boundary.

Until those named actions have fresh receipts, the release remains **NO-GO**. No source, unit, VM, hosted-runner, package-registration, or signing result is being promoted to physical, Store, or public-release certification.
