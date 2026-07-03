# Windows Signal cross-device interop KAT copy (VAL-P0-HARNESS-026)

`android-alice-to-swift-bob.json` is the **4th byte-identical copy** of the
reverse-direction Signal interop known-answer test (KAT), alongside the three shipped
platform copies:

- `tests/fixtures/signal-interop/android-alice-to-swift-bob.json` (shared / TS root)
- `android/app/src/test/resources/signal-interop/android-alice-to-swift-bob.json` (Kotlin / Android)
- `OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/Fixtures/android-alice-to-swift-bob.json` (Swift)

The Windows libsignal-interop lane consumes this copy so the Windows port decrypts the
**same** Android-Alice→Bob PreKey wire vectors the Mac and Android suites already open
(schema `obb-signal-interop-v1`, both legs `PREKEY_TYPE`).

## Byte-identity is enforced fail-closed

`scripts/ci/check-reverse-interop-fixture.mjs` (run from
`scripts/ci/verify-signal-cross-device-kats.sh` /
`.github/workflows/signal-cross-device-kats.yml`, Node/Linux — headless) requires all
**four** copies to be present and byte-identical (sha256). A silent drift, a deleted
copy, or a single flipped byte in any copy fails CI. Do **not** hand-edit this file:
regenerate the KAT with the Android `AndroidSignalInteropFixtureGen` and copy the
identical bytes into all four locations.
