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
