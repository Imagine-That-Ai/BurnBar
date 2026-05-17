# Computer Use — App Store + direct-download distribution playbook

**Plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../../plans/2026-05-16-computer-use-master-plan.md) § F.4 · **Reference:** [`HERMES_COMPUTER_USE.md`](../HERMES_COMPUTER_USE.md)

## Why two distribution channels

Path A (Agent Watch) and Path B (Browser CU) are MAS-compatible: Playwright is launched out-of-process and the agent never escapes the Chromium sandbox.

Path C (Mac System CU) requires the macOS Accessibility permission, which Apple does **not** allow sandboxed (MAS) apps to request. We ship Path C only via direct download with notarization. The MAS build hard-codes Path C off via `#if DISTRIBUTION_MAS`.

## MAS build

- `OpenBurnBar.xcodeproj` target `OpenBurnBar` builds with `DISTRIBUTION_MAS=1` defined.
- `MacInputController`, `MacAccessibilityInspector`, and `MacActionDispatcher` source files compile to no-ops when `DISTRIBUTION_MAS` is defined.
- Setup wizard hides the "Mac System" capability card.
- `NSAppleEventsUsageDescription` ships in Info.plist anyway because Path B's daemon may invoke it for future browser-channel detection.
- Reviewer notes: see § F.4 of the master plan.

## Direct-download build

- Same Xcode project, scheme `OpenBurnBar (Direct)`. `DISTRIBUTION_MAS` undefined.
- Signed with the team's Developer ID Application certificate.
- Notarized via `xcrun notarytool submit --keychain-profile DirectDownloadNotary --wait <pkg>`.
- Stapled with `xcrun stapler staple <pkg>`.
- Verified locally with `spctl --assess --type install <pkg>` before release.
- Pushed to `https://burnbar.ai/download/openburnbar-direct-<version>.dmg` (Firebase Hosting).
- The user-facing "Get Direct Download" CTA appears only on machines that have entitled `hosted_computer_use_sync.system` for ≥ 1 hour — preventing casual install.

## Hardened Runtime entitlements

| Entitlement | Reason | Distribution |
|---|---|---|
| `com.apple.security.cs.disable-library-validation` | Required to launch user-installed Playwright | Both |
| `com.apple.security.cs.allow-jit` | Playwright Chromium V8 JIT | Both |
| `com.apple.security.network.client` | iroh QUIC + Hermes relay | Both |
| `NSAppleEventsUsageDescription` | Documented for future paths | Both |
| AX permission prompt | `AXIsProcessTrusted()` triggers it on first input post | Direct-download only |

## App Store reviewer walkthrough video

Stored at `https://burnbar.ai/internal/asc/computer-use-walkthrough-<version>.mp4`. 90 s recording. Demonstrates:

1. User starts a Manual-mode browser CU session.
2. Each browser action shows an approval sheet pre-screenshot.
3. The user approves one action, rejects the next.
4. `⌃⌥⌘.` global hotkey halts mid-session.
5. Audit chain validation passes 100/100.

## Update cadence

- MAS build updates require App Store re-submission for new tool kinds or new entitlement.
- Direct-download build can ship faster (Sparkle update flow). Both builds always share a version number.
