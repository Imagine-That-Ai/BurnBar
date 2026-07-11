// swift-tools-version:5.9
import PackageDescription

// Standalone authoritative KAT-vector generator for the CloudVault E2EE crypto.
//
// This executable depends ONLY on Apple's CryptoKit system framework — the SAME
// primitive stack the production macOS/iOS app uses through
// OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/PlatformSupport.swift
// (P256.KeyAgreement, HKDF<SHA256>, AES.GCM, HMAC<SHA256>, SHA256). It faithfully
// transcribes the recipe in OpenBurnBarCore/.../SharedModels/CloudVaultCrypto.swift
// with PINNED nonces / ephemeral scalars so the sealed bytes are reproducible, and
// self-verifies every seal by opening it again with CryptoKit before emitting.
//
// The emitted JSON is the committed, Mac/CryptoKit-origin cross-platform vector the
// Windows C# port (windows/cloudsync/OpenBurnBar.CloudSync.Crypto) must match
// byte-for-byte in BOTH directions. Zero external dependencies → builds in seconds,
// no swift-crypto / LibSignalClient binary pulls.
let package = Package(
    name: "CloudVaultVectorGen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CloudVaultVectorGen")
    ]
)
