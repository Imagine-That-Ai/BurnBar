# Mercury media pipeline (Windows)

Windows port of the macOS **Mercury** media surface (`AgentLens/Services/Media/*` +
`OpenBurnBarCore/Sources/OpenBurnBarMedia/*`): screen mirror, audio / mic / camera capture,
RFB/VNC remote control, file transfer, and the consent + media-budget enforcement that gates
all of it.

## Projects

### `OpenBurnBar.Integrations.Mercury` (portable, `net8.0`)

The dependency-free logic, unit-tested on macOS (`windows/tests/mercury`, `dotnet test`):

| Area | File(s) | macOS parity source |
|------|---------|---------------------|
| Media-frame packet codec (byte-exact) | `Wire/MediaFrame.cs`, `Wire/MediaPacketCodec.cs` | `OpenBurnBarMedia/MediaFrame.swift`, `MediaPacketCodec.swift` |
| RFB/VNC wire codec | `Wire/RfbProtocol.cs` | `AppleRemoteDesktopRFBClient.swift` (handshake, input events, ServerInit) + RFC 6143 FramebufferUpdate |
| Apple-ARD security-type-30 auth | `Wire/RfbArdAuth.cs` | `AppleRemoteDesktopRFBClient.swift` (credential block, AES-128-ECB, DH modexp, MD5 KDF) |
| Stream classes | `Sessions/MediaStreamClass.cs` | `OpenBurnBarMedia/MediaStreamClass.swift` |
| Media-session state machine | `Sessions/MediaSessionStateMachine.cs` | `MediaSessionCoordinator.swift` (phase transitions + admission recheck) |
| Budget models | `Budget/MediaBudget.cs` | `OpenBurnBarMedia/MediaBudgetEnvelope.swift` |
| **Capability gate (consent/budget/kill-switch)** | `Budget/MediaCapabilityGate.cs`, `Budget/MediaCapabilityEvaluator.cs` | `MacMediaCapabilityGate.swift` |
| Fail-closed budget status store | `Budget/MediaBudgetStatusStore.cs` | `MediaBudgetStatusStore.swift` |
| Mirror-consent grant ledger | `Consent/MercuryConsentStore.cs`, `Consent/MercuryConsentCodec.cs` | `MercuryConsentStore.swift` |
| File-transfer chunk / reassemble | `FileTransfer/FileTransferChunker.cs`, `FileTransfer/FileTransferReassembler.cs` | `OpenBurnBarMedia/MediaFileTransferService.swift` |
| Platform seams | `Adapters/IMediaCaptureAdapters.cs` | the interfaces the Windows adapters implement |

### `OpenBurnBar.Integrations.Mercury.Windows` (adapters, `net8.0-windows`)

Implements the seam interfaces over WinRT projections:

| Adapter | File | API | macOS parity source |
|---------|------|-----|---------------------|
| Screen mirror | `GraphicsCaptureScreenSource.cs` | Windows.Graphics.Capture | `ScreenCapturePipeline.swift` |
| Audio capture | `AudioGraphCaptureSource.cs` | Windows.Media.Audio (WASAPI) | `MicrophoneCapturePipeline.swift` |
| Camera | `MediaCaptureCameraSource.cs` | Windows.Media.Capture | `CameraCapturePipeline.swift` |
| Video encode | `MediaFoundationVideoEncoder.cs` | Windows.Media (MediaFoundation) | `VideoEncoder.swift` |
| VoIP wake | `WindowsWnsVoipPushTrigger.cs` | Windows.Networking.PushNotifications (WNS raw push) | `VoIPCallTrigger.swift` (APNs) |

## Preserved security invariants (master plan § 9.5 / R17)

- **Fail-closed admission.** `MediaCapabilityEvaluator` evaluates entitlement → kill-switch →
  budget level (hard/soft) → daily cap → per-session cap → concurrent cap, in that order, and
  never emits an `Allowed` envelope after any deny. Kill switch and hard cap refuse before any
  quota math.
- **Fail-closed budget status.** `MediaBudgetStatusStore` cold-starts to the *conservative
  closed* (hard-cap) status, holds last-known-good on permission-denied, and only promotes a live
  envelope — it never fails open to `initialNormal` (RR-9).
- **Peer-bound consent.** `MercuryConsentStore` auto-accepts only when the declared
  control-authority peer node id matches the connected remote peer; grants expire on a TTL; a
  failed encode leaves the persisted ledger intact rather than wiping consent.
- **Content-addressed transfer.** `FileTransferReassembler` verifies the whole-file length +
  SHA-256 against the manifest before handing back bytes, rejecting tamper / corruption.

## Verification ceiling (honest)

- **macOS-verified:** the portable lib builds + `dotnet test` passes (see `windows/tests/mercury`);
  the Windows adapter compiles Roslyn-clean against the Windows SDK projection ref pack
  (`EnableWindowsTargeting=true`, 0 errors).
- **Windows dev-host / CI deferred:** actual capture / encode / WNS delivery — the WinRT APIs have
  no macOS runtime. The device-touching leaves (D3D surface readback, audio buffer drain, MFT
  sample loop) are marked as dev-host seams in the adapter source.
