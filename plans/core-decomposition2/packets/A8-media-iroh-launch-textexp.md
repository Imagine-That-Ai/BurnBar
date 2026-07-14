# Packet A8: Media + IrohRelay + LaunchServices + TextExpansion — curation

STATE: QUEUED  LANE: WS-A curation  DEPENDS-ON: A0  BASE: core-decomp2/a0 (or main once merged)
BASELINE-TOUCHING: budgets/public-api-baseline.json (see A0-README etiquette)

Read A0-README.md shared rules FIRST.

## Scope

### OpenBurnBarMedia — dead (3)
DecodeError, InvalidationResult, MediaAnalyticsSink
(MediaAnalyticsSink: its test-only NoOp twin waits for A9 — deleting the
protocol now would strand the twin; if the protocol truly has no conformers
outside tests, delete BOTH here and note it, since A9 would otherwise inherit
a dangling pair.)

### OpenBurnBarIrohRelay — dead (3)
IrohNodeIdNormalization, OpenBurnBarIrohFFIBackend, OpenBurnBarIrohFFIStream
CAUTION: FFI backends can be reached from generated UniFFI glue or the Rust
crates (crates/openburnbar-iroh) — re-verify across *.rs and generated glue.

### OpenBurnBarIrohRelay — own-module-only (1)
OpenBurnBarIrohBlobFFIBackend

### OpenBurnBarLaunchServices — dead (4)
CLIAuthState, DefaultCLIFallbackPlanner, ProductionBrowserAvailabilityProvider,
SwitcherCLILAunchService (yes, the typo'd name — K5 renamed a different typo;
confirm this one was not left as a deprecated alias on purpose)

### OpenBurnBarLaunchServices — own-module-only (1)
BrowserLaunchInvoker

### OpenBurnBarTextExpansion — dead (1)
TextExpansionInboxError

### test-only — DO NOT TOUCH (Media 3, IrohRelay 2, LaunchServices 4; A9)

## Method
Dead deletions first (per-module commits), then internalizations.
Full V-list. Converged-reality section into this card.
