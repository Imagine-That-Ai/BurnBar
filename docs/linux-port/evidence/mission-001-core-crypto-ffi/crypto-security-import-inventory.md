# Mission 001 Core Crypto/Security Import Inventory

## Baseline Before This Repair

W01CoreValidationRepair left these Linux-visible shared call-site classes as residual VAL-CORE-003 risk:

- Computer Use signing, sealing, audit, key pinning, remote unlock, and phone-control paths still imported or directly used `CryptoKit`/`Crypto` primitives in shared products.
- Core shared model crypto paths still contained direct hash/HMAC/AES/HKDF/P256/HPKE use in `CloudVaultCrypto`, `CloudVaultDeviceKeypair`, `HermesRelayCrypto`, `HermesRatchetCrypto`, `PensieveVectorCloak`, `MemorySecretPIIGate`, `VerdictCache`, and digest/chunking helpers.
- Iroh relay pairing and Mercury media AEAD/session code still used direct Ed25519/AES/HKDF primitives outside a portable seam.
- Signal at-rest and session files contained direct CryptoKit/Security imports, but the manifest did not yet have evidence distinguishing vendored-libsignal builds from fallback builds.

## After This Repair

Shared Linux-visible crypto operations now route through `OpenBurnBarCore/Sources/OpenBurnBarCore/Platform/PlatformCrypto.swift`, including secure random bytes, SHA-256, HMAC-SHA256, AES-GCM, HKDF-SHA256, Ed25519, P256 signing/key agreement, X25519 HPKE, P256 HPKE, canonical JSON, and hex encoding.

Post-migration source scan:

- `crypto-security-import-scan-after.txt`
- Command: `rg -n "^(#if canImport\\((CryptoKit|Security)\\)|(@preconcurrency )?import (Crypto|CryptoKit|Security))" OpenBurnBarCore/Sources`
- `crypto-primitive-call-scan-after.txt`
- Command: `rg -n "\\b(SHA256|HMAC|AES\\.GCM|SymmetricKey|Curve25519\\.|P256\\.|HPKE\\.|SharedSecret)\\b" OpenBurnBarCore/Sources/OpenBurnBarCore OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore OpenBurnBarCore/Sources/OpenBurnBarIrohRelay OpenBurnBarCore/Sources/OpenBurnBarMedia --glob "!**/Platform/PlatformCrypto.swift" --glob "!**/OpenBurnBarSignalCore/**" --glob "!**/OpenBurnBarSignalSessionTransport/**"`

Remaining source hits are classified as:

- `PlatformCrypto.swift`: allowed platform abstraction layer; it is the single shared crypto seam and imports CryptoKit on Apple or Swift Crypto on Linux.
- `OpenBurnBarSignalCore/OBBSignalProtocolStore.swift`, `SignalAtRestSealer.swift`, `SignalIdentityKeyStore.swift`, and `OpenBurnBarSignalSessionTransport/OBBSignalSessionCipherTransport.swift`: not compiled in this workspace because `Vendor/libsignal/swift/Package.swift` is absent. `Package.swift` sets `sources: ["OpenBurnBarSignalCoreUnavailable.swift"]` and `sources: ["OBBSignalSessionTransportUnavailable.swift"]` for the fallback targets, excluding the full Signal crypto/session files.
- `ComputerUseAuditExportSignerProvider.swift`, `PrivilegedSocketTrust.swift`, `ControllerKeyPinStore.swift`, `IrohHostKeyPinStore.swift`, `Mac/SecKeychainInteractionGate.swift`, `CloudVaultDeviceKeypair.swift`, `CloudVaultCrypto.swift`, and `VerdictCache.swift`: guarded `#if canImport(Security)` Apple secure-storage or platform identity paths. Linux selected tests compile through the non-Security fallback paths.
- `PhoneControlAuthoritySigningKey.swift`: guarded `#if canImport(CryptoKit)` Secure Enclave extension only. Software P256 signing and verification route through `PlatformCrypto`.
- The direct primitive scan outside `PlatformCrypto` and excluded Signal sources contains no active direct SHA/HMAC/AES/HPKE/key construction call sites. Remaining hits are comments, wire algorithm labels, data-field names, or the guarded Secure Enclave extension.

## Linux Product Import/Link Evidence

Product import scan:

- `product-apple-import-scan.txt`
- Command: `rg -n "^import (AppKit|SwiftUI|UIKit|AVFoundation|CoreGraphics|LocalAuthentication|Security|CryptoKit)|^#if canImport\\((Security|CryptoKit)\\)" OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore OpenBurnBarCore/Sources/OpenBurnBarMedia OpenBurnBarCore/Sources/OpenBurnBarIrohRelay OpenBurnBarCore/Sources/OpenBurnBarSignalCore OpenBurnBarCore/Sources/OpenBurnBarSignalSessionTransport`
- Result classification:
  - Signal `CryptoKit`/`Security` hits are in full Signal files that are excluded when `Vendor/libsignal/swift/Package.swift` is absent.
  - `ComputerUseAuditExportSignerProvider.swift` imports `LocalAuthentication` only inside `#if os(macOS)`.
  - `MercuryStreamingStats.swift` imports `UIKit` only inside `#if canImport(UIKit)` for iOS battery state probes.
  - Computer Use `Security` imports are guarded Apple keychain/trust paths; the Linux target excludes `Mac/` and `PrivilegedSocketTrust.swift`, and the remaining key-store code compiles through non-Security branches.
  - `PhoneControlAuthoritySigningKey.swift` imports `CryptoKit` only for the Secure Enclave extension under `#if canImport(CryptoKit)`; non-Secure-Enclave signing routes through `PlatformCrypto`.

Linux link inspection:

- `linux-swift-link-inspection.txt`
- The selected Linux Swift test executable is an ELF aarch64 binary. `ldd` shows Linux Swift/Foundation/XCTest, SQLCipher, libc/libm/libz/libssl/libcrypto/libcurl, and related Linux system libraries. It does not link AppKit, SwiftUI, UIKit, Security.framework, CryptoKit.framework, AVFoundation, CoreGraphics.framework, or LocalAuthentication.

## KAT Evidence

`macos-selected-tests.log` and `linux-selected-tests.log` both pass the same selected suite and print identical stable KAT hashes for PlatformCrypto, SHA-256, HMAC-SHA256, AES-GCM, Ed25519, canonical JSON, HPKE v3 open, CloudVault payload open, and the provider model fixture.
