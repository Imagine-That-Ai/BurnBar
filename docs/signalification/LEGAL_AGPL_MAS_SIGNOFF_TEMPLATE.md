# SOTASIGNAL Legal / AGPL / MAS Sign-Off Template

**Purpose:** record approval for shipping official Signal `libsignal` artifacts in OpenBurnBar and for handling AGPL-3.0-only obligations before Phase-E activation or store release.

This can be completed by counsel, an OSS compliance specialist, or Alberto as explicit owner risk acceptance. If Alberto self-accepts, label it as **owner risk acceptance**, not outside legal advice.

## Reviewer / Approver

- Name:
- Role:
- Organization:
- Date:
- Reviewed commit SHA:
- Sign-off artifact path:

## Artifacts Reviewed

- [ ] `.gitmodules`
- [ ] `Vendor/libsignal/`
- [ ] `Vendor/OpenBurnBarSignalFfi.xcframework/`
- [ ] `scripts/build-signal-ffi-xcframework.sh`
- [ ] `OpenBurnBarCore/Package.swift`
- [ ] `Vendor/libsignal/swift/Package.swift`
- [ ] Android Gradle Signal dependencies and Maven repository
- [ ] `packages/libsignal-protocol/package.json`
- [ ] `packages/libsignal-bridge/package.json`
- [ ] license/source metadata (`LICENSE`, `NOTICE`, `THIRD_PARTY*`, `LICENSES/`, `REUSE.toml`, or equivalent)
- [ ] `website/src/data/trust.generated.ts`
- [ ] MAS/direct-download distribution plan

## Required Decisions

- [ ] AGPL-3.0-only source-offer obligations are understood and satisfied.
- [ ] Corresponding source URL and release-source retention plan are approved.
- [ ] Dynamic/static linking posture is approved for each shipped Apple artifact.
- [ ] Android distribution posture is approved.
- [ ] MAS build either excludes the AGPL-linked Signal path or counsel/owner approves distribution.
- [ ] Direct-download notarized build plan is approved.
- [ ] Generated public trust copy is approved by product/copy owner.

## Rule-0 Approvals

| Rule-0 item | Approved? | Evidence / note |
| --- | --- | --- |
| `.gitmodules` | yes/no |  |
| `Vendor/libsignal/` | yes/no |  |
| `website/src/data/trust.generated.ts` | yes/no |  |

## Sign-Off Decision

Choose exactly one:

- [ ] **Approved for Phase-E canary**.
- [ ] **Approved for direct-download only; MAS excluded pending further review**.
- [ ] **Owner risk accepted for canary only**.
- [ ] **Not approved; do not activate or ship**.

Approver signature / typed approval:

Owner risk acceptance, if any:
