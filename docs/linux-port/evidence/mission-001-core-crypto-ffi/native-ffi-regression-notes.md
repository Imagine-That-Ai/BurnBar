# Mission 001 Native/Rust/FFI Regression Notes

## Toolchain

The Linux Docker toolchain image now installs Rust with rustup instead of apt `rustc`/`cargo`.

- Image: `openburnbar-linux-toolchain:mission-001-core-crypto-ffi`
- Evidence: `docker-build-rust196.log`, `docker-toolchain-versions.txt`
- Rust: `rustc 1.96.0 (ac68faa20 2026-05-25)`, `cargo 1.96.0`
- Swift: `Swift version 6.2.4`, target `aarch64-unknown-linux-gnu`

## iroh

Native Rust support is buildable and tested in the Docker toolchain:

- Command evidence: `iroh-rust-cargo-test-build.log`
- Artifact evidence: `iroh-rust-artifact-inspection.txt`
- `cargo test --locked`: 18 library tests plus 1 loopback handshake test passed.
- `cargo build --locked --release`: produced `libopenburnbar_iroh.rlib`, `libopenburnbar_iroh.a`, and `libopenburnbar_iroh.so`.
- `libopenburnbar_iroh.so` SHA-256: `1e1c5638d0a35baa92c11876066c516d47a22b621e89ef21e65f01c5a8abd170`.
- `ldd libopenburnbar_iroh.so` links Linux `libgcc_s`, `libm`, and `libc` only; no Apple UI/security framework dependency is present.

Swift product status in this workspace is still explicit non-shipping for the packaged iroh FFI product:

- Selected Swift test evidence prints `iroh=non-shipping:OpenBurnBarIrohFFI-unlinked`.
- Exact blocker: `Vendor/OpenBurnBarIroh.xcframework` is absent, so `Package.swift` does not create the `OpenBurnBarIrohFFI` product or binary target.
- Owner: native artifact packaging lane for `scripts/build-iroh-xcframework.sh` / `Vendor/OpenBurnBarIroh.xcframework`.

## Signal

Signal native/libsignal support is explicit non-shipping in this workspace and is not counted as a shipped integration:

- Selected Swift test evidence prints `signal=non-shipping:libsignal-missing`.
- Exact blocker: `Vendor/libsignal/swift/Package.swift` is absent, so `Package.swift` compiles only `OpenBurnBarSignalCoreUnavailable.swift` and `OBBSignalSessionTransportUnavailable.swift`, excluding full Signal session/at-rest implementation files.
- Owner: libsignal vendoring/artifact lane for `Vendor/libsignal/swift` and platform Signal FFI xcframeworks.

## Media

Mercury media in the selected core contract is a pure Swift shared contract product, not a native FFI product in this workspace:

- Selected Swift test evidence prints `media=pure-swift-contract`.
- Linux selected tests compile and run `OpenBurnBarMedia` through the package test target.
- Crypto paths route through `PlatformCrypto`.

## Computer Use

Computer Use core in the selected contract is a pure Swift shared contract product, not a native FFI product in this workspace:

- Selected Swift test evidence prints `cu=pure-swift-contract`.
- Linux selected tests compile and run `OpenBurnBarComputerUseCore` through the package test target.
- Crypto/security operations route through `PlatformCrypto`; Security/Secure Enclave paths are guarded Apple-only paths.
