# Packet A7: OpenBurnBarComputerUseCore — curation (security-sensitive)

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (see A0-README etiquette)

Read A0-README.md shared rules FIRST.

SECURITY NOTE: this module backs the privileged HID/computer-use binaries and
the remote-unlock capability chain. Every deletion here gets an explicit
"verified not reachable from the privileged binaries or daemon" line in the PR
body. When in doubt, internalize instead of delete.

## Scope

### dead (27) — delete after re-verification
AgentCapabilityGrantStatus, ComputerUseAuditExportSecurityKeyStore,
ComputerUseAuditExportSignatureTrust, ComputerUseAuditExportSignerStoreError,
ComputerUseScopeBundle, ComputerUseScopeLibrary, ControllerKeyKeychainPinBacking,
CryptoError, ExportResult, FinalizerError, InvariantViolation,
IrohHostKeyKeychainPinBacking, PhoneControlP256AuthoritySigning,
RemoteUnlockCapabilityPrivateKeyStoring, RemoteUnlockCapabilitySigningKeyStoreError,
RemoteUnlockCertificationEvidence, RemoteUnlockCertificationProbe,
RemoteUnlockCertificationProbes, RemoteUnlockSetupAction,
RemoteUnlockSystemScreenSharingStatus, ServerCodeSignatureValidator,
SessionError, StepUpEvidence, TokenRedemptionFailure, TransitionResult,
UnicodeTypingEvent, WriterError
CAUTION: *KeychainPinBacking / *KeyStore types may be selected at runtime by
platform conditionals (#if os(...)/canImport) — a macOS-side grep can miss the
Linux selection path; re-verify with the Linux boundary build
(OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1).

### own-module-only (6) — make internal
ComputerUseAuditExportSigning, ComputerUseOpenTimestampsProofVerifier,
ControllerKeyPinBacking, ControllerKeyPinLoad, InvalidReason,
PrivilegedInputExecutionXPCProtocol
CAUTION: PrivilegedInputExecutionXPCProtocol is an XPC boundary protocol — if
the privileged helper binary (outside OpenBurnBarCore/Sources) adopts it, the
grep would have said cross-module; a true own-module-only verdict here is
surprising. Re-verify against the HID helper sources FIRST; likely reclassify.

### test-only (18) — DO NOT TOUCH (WAIT-FOR-WS-B, packet A9)

## Method
Dead deletions first (own commit), then internalizations (own commit).
Full V-list + Linux boundary build. Converged-reality section into this card.

## Converged reality (executed on core-decomp2/a7-computerusecore)

STATE: DONE. Compiler-as-oracle over the classifier. Base: core-decomp2/a6-ui.

Result: **9 internalized, 24 reverted-to-public, 0 deleted.** The classifier's
27-dead + 6-own split over-counted heavily (24/33 candidates were actually
cross-module-reachable) — same pattern as A1 ("all 12 dead reclassified ALIVE").
The word-boundary grep cannot see a type reached through a public member's
return/parameter/property via type inference, nor through an enclosing
public/test-only type — those are exactly what the Core+daemon builds flagged.

### Internalized (9) — proven strictly in-module (0 refs anywhere outside the module dir)
`ComputerUseAuditExportSecurityKeyStore`, `ComputerUseAuditExportSignerStoreError`
(ComputerUseAuditExportSignerProvider.swift); `WriterError`
(ComputerUseAuditExportWriter.swift — thrown, never in a public signature);
`FinalizerError` (ComputerUseAuditHeadFinalizer.swift); `SessionError`
(ControlFrameSealSession.swift); `CryptoError` (RemoteUnlockCredentialEnvelopeCrypto.swift);
`RemoteUnlockCapabilitySigningKeyStoreError`
(OpenBurnBarRemoteUnlockCapabilitySigningKeyStore.swift); `ComputerUseScopeLibrary`
(ComputerUseScopeLibrary.swift); `PrivilegedInputExecutionXPCProtocol`
(PrivilegedInputXPCProtocol.swift).

### Not deleted — every "dead" symbol reclassified INTERNAL, not removed
Per the SECURITY NOTE ("when in doubt, internalize instead of delete"). 26/27
"dead" symbols have in-file/in-module use (they back other in-module decls) → they
are internal-worthy, not dead. The one symbol with zero code references,
`ComputerUseScopeLibrary` (only a docs-runbook prose mention), is security-sensitive
(scope library named in computer-use-rollout-status.md) → internalized, not deleted.
Deletions in this module = 0; every deletion would have needed the "not reachable
from privileged binaries" attestation, and internalizing achieves the same
public-surface shrink with zero risk.

### Reverted-to-public (24) — compiler-proven or public-signature-exposed cross-module
- **XPC boundary**: `ServerCodeSignatureValidator` — parameter of `public
  PrivilegedInputSocketClient.init(serverCodeSignatureValidator:)`.
  (`PrivilegedInputExecutionXPCProtocol` itself stayed internal: its only Swift
  users are in-module; the privileged helper binary keeps its own `@objc` mirror
  and does not import Core, so the wire contract is unaffected.)
- **Audit export**: `ComputerUseAuditExportSigning` (param of public
  `export/finalize/finalizeSessionDirectory/sign`), `ExportResult` (return of public
  `export()` — consumed by daemon ComputerUseService), `ComputerUseAuditExportSignatureTrust`
  (default param of public `verify`).
- **Value-flow into AgentLens**: `InvalidReason` (via public
  `ComputerUseAuditChain.ValidationResult.firstInvalidReason.userFacingDescription`,
  read in ComputerUseSettingsView), `UnicodeTypingEvent` (via public
  `MacInputCore.unicodeTypingEvents(for:)`, iterated in MacInputController),
  `AgentCapabilityGrantStatus` (public `.status`).
- **Test-only-coupled (belong to A9)**: `TransitionResult`, `TokenRedemptionFailure`,
  `InvariantViolation` are exposed by public members of the test-only
  `ComputerUseSafetyInvariantHarness`; `ComputerUseScopeBundle` by public members of
  the test-only `ComputerUseStarterBundles` + `ComputerUseScopeLibrary.bundles`.
  They can only be internalized together with their test-only parents in packet A9.
- **Own-file public accessors**: `ComputerUseOpenTimestampsProofVerifier`,
  `ControllerKeyPinBacking`, `ControllerKeyPinLoad`, `ControllerKeyKeychainPinBacking`,
  `IrohHostKeyKeychainPinBacking`, `RemoteUnlockCapabilityPrivateKeyStoring`,
  `RemoteUnlockCertificationEvidence/Probe/Probes`, `RemoteUnlockSetupAction`,
  `RemoteUnlockSystemScreenSharingStatus`, `StepUpEvidence`,
  `PhoneControlP256AuthoritySigning` — each surfaced by a public property/return/
  init/enum-case in its own file, so internalizing breaks the Core build.

### Platform-conditional safety
The card's `*KeychainPinBacking`/`*KeyStore` caution is fully neutralized: those
types either reverted to public (`ControllerKeyKeychainPinBacking`,
`IrohHostKeyKeychainPinBacking`) or, where internalized (`*SigningKeyStoreError`,
`*SecurityKeyStore`), the Linux-boundary composition build
(`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build`) passed, proving no
`#if os(Linux)` selection path needs them public.

### Baseline
`budgets/public-api-baseline.json`: OpenBurnBarComputerUseCore publicTypes
207 → 198 (−9), publicMembers unchanged (1013). Only this module's entry changed.
check-baseline-monotonic passes vs the real PR base (origin/core-decomp2/a6-ui);
its RC=1 vs the auto-detected origin/main merge-base is a stacked-branch artifact
(that merge-base predates the whole A/B/K stack, so it attributes the stack's debt
to this diff) — CI compares against the true PR base.
