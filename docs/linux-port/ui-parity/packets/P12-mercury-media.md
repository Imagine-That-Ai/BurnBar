# P12 — Mercury media surfaces

**Wave 2 (after P04's event-stream idiom) · Surface: media section (initially under `support`; route promotion via P15).**

## Mission

Surface Mercury media on Linux: paired-device list, media session status (screen-share/file-transfer/call state), and the media-control staging readout that backs the `media.control.stage` perf sample. v1 is **observe + stage**: full call UX is gated on W5 (Computer Use/Mercury engine) reaching Linux; render real engine state, never a demo call UI.

## Read first

- README §1–§2; P04 packet (Tauri event-stream pattern).
- macOS oracle: Mercury media views (search `Mercury` under `AgentLens/Views/`); `AgentLens/Views/Chat/MercuryShimmerModifier.swift` for the shimmer idiom.
- Engine reality: master plan §9.6 (W5) — media transport lands separately; this packet consumes whatever `media.control` RPC the daemon exposes today (`BurnBarDaemonServer+RPCObservability.swift` names `media.control.stage`).
- Evidence: `preserved-qemu-portal-mobile/` notes under `docs/linux-port/evidence/mission-001-computer-use-media-mobile/`.

## Data contract

1. Bridge: `media_status` → `{ pairedDevices: {id,name,platform,lastSeenAt}[], activeSession?: {kind:'screen-share'|'file'|'call', state, peer} }`; stage events via Tauri events `mercury://stage` if the daemon streams them.
2. If the daemon lacks a method, the surface renders the **capability-absent** state ("Media engine not yet available on this Linux build") — a named honest state, not an error.
3. Fixtures: 2 paired devices + one active screen-share session.

## W5-F5 outbound Linux capture

The Linux shell media socket is daemon-to-shell only: daemon-origin frames flow to the shell viewer as `[u32 length][kind][flags][ptsMs][payload]`. Outbound Linux screen capture is daemon-owned. During an accepted mirror session the daemon opens or receives the Wayland portal PipeWire remote, starts `media_capture_start(...)` through `COpenBurnBarMediaCapture`, wraps callback frames with `MediaPacketCodec`, and forwards them to the phone as `media.stream.frame`.

VAL-CU-001 proves the Wayland portal path: `CreateSession -> SelectSources -> Start` returns a PipeWire `node_id`, and `OpenPipeWireRemote` returns an fd that produces frames on Sway/PipeWire. That fd is process-local. If a helper or shell process ever obtains it, it must pass the descriptor to the daemon with Unix `SCM_RIGHTS`; serializing the numeric fd through JSON or Tauri command params is invalid.

The shell contract remains the five daemon RPC-backed Tauri commands: `media_session_state`, `media_accept_call`, `media_decline_call`, `media_end_call`, and `media_capability_get`, plus viewer events `media-incoming-call` and `media-call-state-changed`. Capability reporting uses the media C FFI probe and keeps H.264 false unless the user installs and enables it explicitly.

## Files

`src/state/mediaStore.ts`; `src/surfaces/media/` (`MediaSection.tsx`, `DeviceRow.tsx`, `SessionStatusCard.tsx`) + tests; mount inside `SupportSurface` below diagnostics (coordinate with P09; Cross-agent receipt); `app.css` `/* ---- P12 media ---- */`.

## Build steps

1. `DeviceRow`: platform glyph, name, last-seen relative time; no actions in v1 beyond "Forget" **only if** the daemon exposes an unpair method.
2. `SessionStatusCard`: kind badge, peer, state timeline (staged → connecting → active → ended) rendered as the step-rail idiom from onboarding.
3. Shimmer for connecting state: CSS gradient sweep, killed by reduced motion.
4. Keep `media.control.stage` measurement untouched (it flows through the existing support-route perf path).

## Required states

Populated / capability-absent / loading / empty ("No paired devices — pair from the mobile app") / error / offline; session sub-states staged/connecting/active/ended.

## A11y / Perf / Tests

- Session state changes announced politely; timeline steps are text, not color-only.
- Tests: capability-absent detection, device list, session timeline transitions from fixture events, five states.

## Done / Forbidden

README §4. Forbidden: fake call controls; WebRTC/library additions (transport is engine-side); renaming `media.control.stage`.
