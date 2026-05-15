# Hermes iroh Rollout Status

## 2026-05-15 — Phase A local proof

**Gate status:** local proof green; GitHub workflow still pending after push.

Completed:
- Rust host checks passed for `openburnbar-iroh` in debug and release.
- Rust Apple target release builds passed for `aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios`.
- `scripts/build-iroh-xcframework.sh` produced `Vendor/OpenBurnBarIroh.xcframework` and UniFFI Swift bindings.
- `OpenBurnBarCore` builds with the local xcframework present and also builds from a fresh-checkout state when `Vendor/OpenBurnBarIroh.xcframework` is absent.
- `OpenBurnBar` macOS app build passed.
- `OpenBurnBarMobile` generic iOS device build passed.
- `OpenBurnBarMobile` iPhone 17 Pro Max simulator build passed.
- `functions` completed `npm ci && npx tsc --noEmit`.
- `OpenBurnBarCore` completed `swift build && swift test`: 641 tests passed, 2 skipped, 0 failures.

Notes:
- The generated xcframework is intentionally ignored at `Vendor/OpenBurnBarIroh.xcframework/` because the local artifact is 442 MB; CI and release lanes should regenerate/upload it rather than commit it.
- `OpenBurnBarCore/Package.swift` conditionally wires the UniFFI binary target only when the xcframework exists, so normal app CI can still compile the relay package without the binary artifact.
- The iOS adapter now has its own Keychain-backed `IrohRelayKeyStore` and Firestore audit logger; the audit protocol and event enums live in the shared relay package.

Next action:
- Commit and push the Phase A fixes, then watch the `OpenBurnBarIroh xcframework` workflow on GitHub. Phase A is not complete until that workflow is green on the latest commit.
