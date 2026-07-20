# Windows v1.0.38 Exact Release Evidence

This packet binds the Windows physical-certification campaign to protected tag
`windows-v1.0.38`. It records a stable signed x64 candidate and a
validator-clean **NO-GO** physical retry. It does not turn incomplete
supplemental protocols into a release PASS.

## Exact candidate

- Source commit: `48837746490b6468efa4dc06a476f305d496039c`
- Independent harness commit: `00d0751f1c671d99fe7ef8f4059e91d689a30f44`
- Release workflow: [29676266545](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29676266545)
- Staging workflow: [29675617068](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29675617068)
- x64 direct MSIX SHA-256: `fd14adb0870473f907c10f342eb3ee300cebf39c500848505a5887ad89602e69`
- Direct-download signer: `CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US`

The signed release checksums, Authenticode timestamp, native Swift resource
layouts, hosted x64 lifecycle, Ed25519 update feed, SBOM, OpenVEX, and Sigstore
provenance passed before physical transfer.

## Physical Intel x64 retry

The HP ENVY x360 Intel/AMD64 retry passed artifact binding, physical hardware
attestation, clean checkout, 20/20 cold launches, 20/20 warm launches,
uninstall/reinstall, 300 seconds of idle sampling, and a 30-minute soak with
1,800 samples and no crash, hang, or unresponsive sample. All 26 routed UI
screenshots and route-root UI Automation anchors passed, including high
contrast, reduced transparency, 100 percent DPI, and the `640x720` compact
scenario.

The external evidence archive is retained on the `BURNBAR` removable drive:

- File: `OpenBurnBar-v1.0.38-physical-x64-retry-evidence-bf10318474556b1ea3f69b05831fa09dfc4f8b36ac9470fb113092ec4f7ed876.zip`
- SHA-256: `bf10318474556b1ea3f69b05831fa09dfc4f8b36ac9470fb113092ec4f7ed876`
- ZIP integrity: PASS
- Internal `SHA256SUMS`: 436/436 PASS
- Evidence validator: PASS for the seven-receipt NO-GO bundle

The compact machine-readable index is
[`physical-x64-retry-summary.json`](physical-x64-retry-summary.json). The
detailed result and exact recovery actions are in
[`PHYSICAL_X64_RETRY_RESULT.md`](PHYSICAL_X64_RETRY_RESULT.md).
The native-operator continuation prompt is
[`HP_SUPPLEMENTAL_CERTIFICATION_PROMPT.txt`](HP_SUPPLEMENTAL_CERTIFICATION_PROMPT.txt).

## Certification boundary

The exact package is stable on physical x64, but the release remains `NO-GO`.
Accessibility still needs manual Narrator, keyboard, 150/200 percent and
mixed-DPI proof. Performance still needs canonical surface latency, frame
pacing, and sleep/wake measurements. Staging needs the approved drills,
media/Computer Use needs paired-device safety evidence, and Store/update needs
an authorized private flight. Physical ARM64 remains an explicit beta
limitation until qualifying hardware is available.

No production system, public rollout, disk, partition, firmware, or VM was
modified by the retry or this evidence import.
