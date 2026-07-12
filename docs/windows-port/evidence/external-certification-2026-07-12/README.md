# Windows external certification campaign - 2026-07-12

This namespace continues the six external protocols left open by the Windows
physical release-certification report. It does not replace the original bundle
and does not convert VM, hosted-runner, source, or unit-test evidence into a
physical PASS.

## Historical scope: superseded by later branch heads

This campaign is bound to source commit
`7c362298230e14bfd51dcdcbaf9476cd86cefa66` and its signed workflow artifacts.
The branch was subsequently repaired and rebased (post-#1557), so for any later
head this bundle is **historical supporting context only**: it must not back a
release or certification decision for a head other than the recorded commit.
To verify the retained bundle, pass the recorded commit explicitly:

```
node scripts/windows-port/validate-release-certification-evidence.mjs \
  docs/windows-port/evidence/external-certification-2026-07-12/windows-arm64-utm \
  --expected-commit 7c362298230e14bfd51dcdcbaf9476cd86cefa66
```

Validating with a newer head as `--expected-commit` fails by design. A release
or certification decision for the current head requires regenerating the full
external campaign (Windows rehearsal, staging cloud, and physical iOS peer
runs) against that head's own signed candidate.

## Exact candidate

- Source commit: `7c362298230e14bfd51dcdcbaf9476cd86cefa66`
- Workflow run: `29177583506`
- Workflow URL: <https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29177583506>
- x64 MSIX SHA-256: `9f3f085250d551dccf7ad887d2e7dc996edbcc25217c067b02cf9729ae9e8327`
- ARM64 MSIX SHA-256: `d8cd1423827e54b777a85cf58962b5c18ae6ae1118676b8255749894815c597e`
- Signer: `CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US`

## Current evidence

| Protocol | Status | Evidence | Boundary |
| --- | --- | --- | --- |
| Physical Windows x64 performance | BLOCKED | Original blocker remains authoritative | No named physical x64 host is attached or enrolled. |
| Physical Windows ARM64 performance | BLOCKED | `windows-arm64-utm/certification-manifest.json` | The exact signed candidate passed restore, serialized Release build, and full solution tests; UTM is QEMU virtual hardware and cannot satisfy this gate. |
| Accessibility and display | BLOCKED | `windows-arm64-utm/receipts/accessibility-display.json` | The service-session UIA rehearsal failed to launch WinUI routes; Narrator, keyboard, DPI, high contrast, reduced motion, and mixed-DPI still require a physical signed-in operator session. |
| Staging cloud | PARTIAL | `staging-cloud/receipt.json` | Firebase project and WIF exist; company billing-project quota blocks deployment and live OAuth/App Check/CloudVault/TPM proof. |
| Media and Computer Use safety | PARTIAL | `physical-ios/receipt.json` | The physical iPhone peer suite passed 114/114; no physical Windows peer was available for the live safety protocol. |
| Store and update lifecycle | BLOCKED | Exact signed direct-download lifecycle remains in the prior bundle | No controllable Partner Center session or authorized physical Store devices are available; no public rollout occurred. |

## Safety decisions

- `STAGING_ENABLED` remains unset while the staging project has no billing link.
- The unrelated `MurMurX` billing account was not used as a silent fallback.
- No production Firebase project, Store listing, public update feed, or public
  release channel was modified.
- The Windows rehearsal helper never passes `-PhysicalHardware`; its output is
  supporting VM evidence only.

## ARM64 VM rehearsal result

The retained bundle under `windows-arm64-utm/` is bound to the exact candidate
commit and signed ARM64 artifact above. The repository validator reports seven
valid receipts. Its immutable pre-execution source identity is clean, the local
automated gate is `PASS`, and the overall verdict is correctly `NO-GO` because
all six external protocols remain unsatisfied by a VM.

The UIA harness result is intentionally retained as a failed supporting probe:
Windows guest-agent commands execute in the non-interactive service session, so
all WinUI route launches failed. It is not accessibility evidence and does not
substitute for the signed-in physical protocol.
