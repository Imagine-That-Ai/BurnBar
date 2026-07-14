// SPDX-License-Identifier: AGPL-3.0-only
//
// Phase-2 WS-K (Kernel diet) S0 scaffold — docs/CORE_DECOMPOSITION_PROGRAM.md.
//
// OpenBurnBarKernelCrypto owns the key-material / sealed-envelope tier of the
// OpenBurnBarKernel split: the CloudVault chain (CloudVaultCrypto +
// CloudVaultDeviceKeypair + CloudVaultSignalEnvelopeModels), the Escrow chain
// (EscrowDeviceSafetyCode + EscrowModels), the Hermes relay crypto
// (HermesRelayCrypto + HermesRatchetCrypto + HermesRelayAuthenticatedRequest),
// PiConnectionTypes, SignalEnvelopeAAD, RoamingProfilePayload, and the two
// CloudVaultCrypto *consumers* proven by grep (CLIAgentSessionRecord +
// CLIAgentResumePresentation call `CloudVaultCrypto.sealPayload/.openPayload`).
// Deps: OpenBurnBarKernelPlatform, OpenBurnBarKernelModels.
//
// Boundary rule (docs/CORE_DECOMPOSITION_PROGRAM.md): a file that is pure
// serializable data with NO key material and NO reference to a crypto type goes
// to Models even if named crypto-ish. PiConnectionTypes/SignalEnvelopeAAD/
// RoamingProfilePayload carry no crypto framework use but are kept in this
// cohesive crypto cluster (they are consumed only by the crypto/contracts tiers;
// nothing in Models references them, so Models has no edge onto Crypto — the
// Models < Crypto layering holds, verified by grep at K0).
//
// At S0 this target holds only this marker. Packet K3 `git mv`s the real files
// in and deletes this marker in the same commit.
enum OpenBurnBarKernelCryptoModuleMarker {}
